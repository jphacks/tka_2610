"""Hand detection on a flat face with a per-image skin model (+ the hand's cast shadow).

Adopted from bench/variants/hand_detect_adaptive.py (hand bench mean IoU 0.86 vs 0.42 for the fixed
Lab rule; 0 false pixels on the no-hand photos). Production change: skin-coloured backgrounds (wooden
desk, cork, kraft) are excluded from the seeds, see quad_detect._skin_coloured_background.

Contract: fn(photo_bgr uint8 HxWx3, quad normalised 0..1) -> bool mask HxW.
  detect             recommended: skin model + cast shadow / contact line
  detect_hand_only   skin model only (use this for curved objects: their own shading looks like a shadow)
  detect_no_edge_norm  shadow step without the per-side edge-darkening correction (ablation)

Idea
  1. Seeds: strict CIELAB skin rule (kt.segment.skin_like) OUTSIDE the cover, in components that reach
     (or nearly reach) the cover outline. The part of the hand outside the cover is usually large and well
     lit, so it samples this person's skin under this light. Skin-coloured print on the cover is never a
     seed (only where the cover is cut by the photo border do inside components touching it count).
  2. Per-image colour models in log-chromaticity (log R/G, log B/G of sRGB). A uniform brightness
     change (shade, the dark side of the thumb) only shifts these by a little, unlike the fixed rule.
     skin  = Gaussian fitted to the seeds (inflated a bit);
     cover = smoothed 2-D histogram of the cover itself (away from the seeds).
     A pixel is skin when the skin likelihood beats the cover likelihood (prior PRIOR) and it is
     close enough to the skin model. Covers whose own colour is close to skin (kraft) therefore
     raise the bar automatically. Guards: if the cover core itself passes the strict rule (SELF_STRICT)
     nothing on the cover is taken; if the models overlap (OVERLAP_LIMIT, SELF_SKIN) the fixed rule is
     used instead of the model.
  3. Only candidates connected to a seed are kept (a hand comes in from outside the cover), then small
     gaps are closed and enclosed holes filled.
  4. Cast shadow / contact line: in a band (SHADOW_BAND) next to the hand, cover pixels that are darker
     than the cover would be there, with the same chromaticity, connected to the hand. Reference =
     joint-bilateral (chromaticity-guided) normalised convolution of plain cover pixels around the band
     (print and glare excluded), corrected for the cover's own darkening towards each side.

Everything runs on a working copy whose cover is ~WORK px (sqrt of area); the mask is scaled back.
"""
from __future__ import annotations

import cv2
import numpy as np

from .segment import skin_like

WORK = 560            # cover size (sqrt of area) in the working copy
MARGIN = 0.15         # context around the cover (share of cover size) to see the hand outside
MIN_SEED = 0.002      # seed components smaller than this share of the cover area are ignored
PRIOR = 0.35          # prior of "hand" vs "cover" for a cover pixel in the likelihood ratio
MAX_MAHAL = 3.5       # max Mahalanobis distance to the (inflated) skin model
INFLATE = 1.6         # skin covariance inflation (side of the thumb, shade, mixed edge pixels)
OVERLAP_LIMIT = 0.35  # share of seed pixels the cover model explains better -> do not trust colour
SELF_SKIN = 0.06      # share of the cover core classified as skin -> cover too skin-like
SELF_STRICT = 0.05    # share of the cover core passing the strict skin rule -> cover is skin-coloured
SHADOW_BAND = 0.06    # search band for the cast shadow (share of cover size)
SHADOW_DARK = 0.955   # Y / Y_reference below this counts as shadow
SHADOW_MIN = 0.35     # ... but not darker than this (ink, black text)
SHADOW_CHROMA = 0.06  # max log-chromaticity change of a shadowed pixel
SHADOW_GAP = 0.02     # a shadow may start this far (share of cover size) from the detected hand
INK = 0.85            # darker than this share of the local paper level (5x5 closing at 1/4 scale) = print
GLARE = 1.12          # brighter than this share of the cover's median = glare
N_CLUSTERS = 8        # chromaticity clusters of the cover for the shadow reference
CHROMA_SIGMA = 0.04   # soft chromaticity weighting of those clusters
MIN_SUPPORT = 0.02    # min Gaussian weight of same-colour sources around a band pixel
EDGE_LAYERS_PER_BAND = 4  # layers of the side/edge-distance profile per shadow band width
EDGE_MIN_PIXELS = 15  # min plain cover pixels (at 1/4 resolution) of a side/layer outside the hand zone to correct it
PAD = 2.5             # shadow reference sources: up to this many band widths around the band
NEAR = 0.02           # seeds may end this far outside the cover outline (share of cover size)
MAX_SEED_IN = 0.25    # a skin component inside the face larger than this share is the face itself
BINS = np.linspace(-0.9, 0.9, 91)


def _feats(bgr):
    f = bgr.astype(np.float32) + 6.0
    return np.stack([np.log(f[..., 2] / f[..., 1]), np.log(f[..., 0] / f[..., 1])], -1)


def _hist_density(samples, sigma_bins):
    h, _, _ = np.histogram2d(samples[:, 0], samples[:, 1], bins=[BINS, BINS])
    h = cv2.GaussianBlur(h.astype(np.float32), (0, 0), sigma_bins)
    return h / max(h.sum(), 1e-9) + 1e-7


def _lookup(dens, F):
    step = BINS[1] - BINS[0]
    i = np.clip(((F[..., 0] - BINS[0]) / step).astype(np.int32), 0, len(BINS) - 2)
    j = np.clip(((F[..., 1] - BINS[0]) / step).astype(np.int32), 0, len(BINS) - 2)
    return dens[i, j]


def _gauss_fit(X, iters=3):
    mu, cov = X.mean(0), np.cov(X.T) + np.eye(2) * 1e-5
    for _ in range(iters):
        d = _mahal(X, mu, cov)
        keep = X[d < 2.5]
        if len(keep) < 30:
            break
        mu, cov = keep.mean(0), np.cov(keep.T) + np.eye(2) * 1e-5
    return mu, cov


def _mahal(F, mu, cov):
    inv = np.linalg.inv(cov)
    d = F - mu
    return np.sqrt(np.einsum('...i,ij,...j->...', d, inv, d))


def _gauss_density(F, mu, cov):
    # density per histogram bin area so it is comparable with _hist_density
    area = (BINS[1] - BINS[0]) ** 2
    return area * np.exp(-0.5 * _mahal(F, mu, cov) ** 2) / (2 * np.pi * np.sqrt(np.linalg.det(cov)))


def _dist_to(mask):
    """Euclidean distance (px) to the nearest True pixel of mask."""
    if not mask.any():
        return np.full(mask.shape, 1e9, np.float32)
    return cv2.distanceTransform((~mask).astype(np.uint8), cv2.DIST_L2, 5)


def _disk(r):
    r = max(1, int(round(r)))
    return cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1))


def _fill_holes(m):
    from scipy.ndimage import binary_fill_holes
    return binary_fill_holes(m)


def _connected_to(cand, seed):
    n, lab = cv2.connectedComponents(cand.astype(np.uint8), connectivity=8)
    ids = np.unique(lab[seed & cand])
    ids = ids[ids > 0]
    return np.isin(lab, ids) if len(ids) else np.zeros_like(cand)


def _prepare(photo_bgr, quad):
    H, W = photo_bgr.shape[:2]
    qpx = np.asarray(quad, float) * [W, H]
    size = float(np.sqrt(max(cv2.contourArea(qpx.astype(np.float32)), 1.0)))
    s = min(1.0, WORK / size)
    m = MARGIN * size
    x0, y0 = np.floor(np.maximum(qpx.min(0) - m, 0)).astype(int)
    x1, y1 = np.ceil(np.minimum(qpx.max(0) + m, [W, H])).astype(int)
    crop = photo_bgr[y0:y1, x0:x1]
    img = cv2.resize(crop, (max(1, round(crop.shape[1] * s)), max(1, round(crop.shape[0] * s))),
                     interpolation=cv2.INTER_AREA) if s < 1 else crop.copy()
    sx, sy = img.shape[1] / crop.shape[1], img.shape[0] / crop.shape[0]
    q = (qpx - [x0, y0]) * [sx, sy]
    face = np.zeros(img.shape[:2], np.uint8)
    cv2.fillPoly(face, [q.round().astype(np.int32)], 1)
    return img, face.astype(bool), size * s, (x0, y0, x1, y1), (H, W), q


def _restore(mask, box, shape):
    x0, y0, x1, y1 = box
    out = np.zeros(shape, bool)
    if mask.any():
        up = cv2.resize(mask.astype(np.uint8) * 255, (x1 - x0, y1 - y0), interpolation=cv2.INTER_LINEAR) > 127
        out[y0:y1, x0:x1] = up
    return out


def _inside_dist(face):
    """Distance of face pixels to the nearest non-face pixel; the photo border counts as non-face."""
    pad = cv2.copyMakeBorder(face.astype(np.uint8), 1, 1, 1, 1, cv2.BORDER_CONSTANT, value=0)
    return cv2.distanceTransform(pad, cv2.DIST_L2, 5)[1:-1, 1:-1]


def _components_touching(mask, touch, min_area):
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), connectivity=8)
    ids = [i for i in np.unique(lab[touch & mask]) if i > 0 and stats[i, cv2.CC_STAT_AREA] >= min_area]
    return np.isin(lab, ids) if ids else np.zeros_like(mask)


def _seeds(img, face, size):
    """Strict-rule skin OUTSIDE the cover in components that reach (or nearly reach) the cover outline:
    a hand comes in from outside, and a thumb right next to the edge still shades the cover. Skin-coloured
    print on the cover is never a seed. Only where the cover is cut by the photo border (the rest of the
    hand is not in the photo) do skin components inside the cover touching that border count."""
    from .quad_detect import _skin_coloured_background
    sk = skin_like(img)
    sk &= ~(_skin_coloured_background(img, sk & ~face) & ~face)    # a wooden desk is not a hand
    sk = cv2.morphologyEx(sk.astype(np.uint8), cv2.MORPH_OPEN, _disk(1)).astype(bool)
    min_area = MIN_SEED * face.sum()
    ring = ~face & (_dist_to(face) <= max(3.0, NEAR * size))
    seed_out = _components_touching(sk & ~face, ring, min_area)
    border = np.zeros_like(face)
    border[:3, :] = border[-3:, :] = True
    border[:, :3] = border[:, -3:] = True
    seed_in = _components_touching(sk & face, face & border, min_area)
    # a skin-coloured region covering much of the face is the face's own colour (peach cover), not a hand
    n, lab, stats, _ = cv2.connectedComponentsWithStats(seed_in.astype(np.uint8), connectivity=8)
    for i in range(1, n):
        if stats[i, cv2.CC_STAT_AREA] > MAX_SEED_IN * face.sum():
            seed_in[lab == i] = False
    return seed_out, seed_in, sk


def _hand_mask(img, face, size):
    """Seeds + per-image skin model -> hand mask (working resolution, includes the hand outside the cover)."""
    info = {'use_colour': False, 'overlap': 1.0, 'self_skin': 0.0, 'self_strict': 0.0}
    seed_out, seed_in, sk = _seeds(img, face, size)
    seed = seed_out | seed_in
    info['seed'] = seed
    if not seed.any():
        return seed, info
    near_seed = _dist_to(seed) < 0.10 * size
    core = (_inside_dist(face) > 0.12 * size) & ~near_seed
    # the cover itself passes the strict skin rule (kraft-like or skin-toned artwork): nothing on the cover
    # can be told apart from skin by colour -> keep only the hand outside the cover
    info['self_strict'] = self_strict = float(sk[core].mean()) if core.any() else 0.0
    if self_strict > SELF_STRICT:
        return seed_out, info
    F = _feats(img)
    L = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)[..., 0].astype(np.float32) * (100 / 255)
    valid = (L > 12) & (L < 97)
    seed_core = cv2.erode(seed.astype(np.uint8), _disk(1)).astype(bool) & valid
    if seed_core.sum() < 50:
        seed_core = seed & valid
    if seed_core.sum() < 10:
        return seed, info
    mu, cov = _gauss_fit(F[seed_core])
    cov_i = cov * INFLATE ** 2
    ps = _gauss_density(F, mu, cov_i)
    close = _mahal(F, mu, cov_i) < MAX_MAHAL
    hand = seed.copy()
    use_colour = True
    for it in range(2):
        cover_s = face & ~near_seed & ~hand & valid
        if cover_s.sum() < 500:
            cover_s = face & ~seed & valid
        if cover_s.sum() < 50:
            use_colour = False
            break
        pc = _lookup(_hist_density(F[cover_s], 1.5), F)
        post = PRIOR * ps / (PRIOR * ps + (1 - PRIOR) * pc)
        cand = (post > 0.5) & close & valid
        # guards: the colour model must separate this hand from this cover
        info['overlap'] = overlap = float((post[seed_core] <= 0.5).mean())
        info['self_skin'] = self_skin = float(cand[core].mean()) if core.any() else 0.0
        if overlap > OVERLAP_LIMIT or self_skin > SELF_SKIN:
            use_colour = False
            break
        hand = _connected_to((cand & face) | seed, seed)
        info['cand'] = cand
    if not use_colour:   # fixed rule as in kt.hands: strict-skin components on the cover joined to the seeds
        hand = _connected_to((sk & face) | seed, seed)
    info.update(use_colour=use_colour, mu=mu, cov=cov)
    hand = cv2.morphologyEx(hand.astype(np.uint8), cv2.MORPH_CLOSE, _disk(max(1, 0.006 * size))).astype(bool)
    return _fill_holes(hand), info


def detect_parts(photo_bgr, quad, shadow=True, edge_norm=True, debug=None):
    img, face, size, box, shape, qw = _prepare(photo_bgr, quad)
    hand, info = _hand_mask(img, face, size)
    if not hand.any():
        return _restore(np.zeros_like(face), box, shape)
    sh = _shadow(img, face, hand, size, qw if edge_norm else None) if shadow else np.zeros_like(hand)
    out = (hand | sh) & face
    out = _fill_holes(cv2.morphologyEx(out.astype(np.uint8), cv2.MORPH_CLOSE, _disk(2)).astype(bool)) & face
    if debug is not None:
        debug.update(info, hand=hand & face, shadow=sh & ~hand, img=img, face=face, box=box)
    return _restore(out, box, shape)


def _shadow(img, face, hand, size, quad_w=None):
    """Cover pixels next to the hand that are a darker version of what the cover looks like there.

    Reference brightness = chromaticity-guided normalised convolution: for every band pixel, the
    Gaussian-weighted mean brightness of plain cover pixels around the band whose chromaticity is like
    its own (a shadow keeps the chromaticity). So a kraft pixel next to a dark-blue label is compared with
    kraft, not with a blend of kraft and label. Thin dark print and glare are never sources.
    Optionally (quad_w given) the cover's own darkening towards a side is factored out (_edge_factor)."""
    out = np.zeros_like(hand)
    r = max(4.0, SHADOW_BAND * size)
    d_hand = _dist_to(hand)
    zone = d_hand <= r
    band = zone & face & ~hand
    if not band.any():
        return out
    # work only around the band (sources up to PAD band widths away), reference at 1/k resolution
    k = 4
    ys, xs = np.nonzero(band)
    pad = int(PAD * r) + 2 * k
    H, W = hand.shape
    y0, x0 = max(0, (ys.min() - pad) // k * k), max(0, (xs.min() - pad) // k * k)
    y1, x1 = min(H, ys.max() + pad + 1), min(W, xs.max() + pad + 1)
    sl = (slice(y0, y1), slice(x0, x1))
    img_c, face_c, zone_c, band_c, dh_c = img[sl], face[sl], zone[sl], band[sl], d_hand[sl]
    hs, ws = max(1, img_c.shape[0] // k), max(1, img_c.shape[1] // k)
    small = cv2.resize(img_c, (ws, hs), interpolation=cv2.INTER_AREA)
    known = cv2.resize((face_c & ~zone_c).astype(np.uint8), (ws, hs), interpolation=cv2.INTER_NEAREST)
    known = cv2.erode(known, np.ones((3, 3), np.uint8)).astype(bool)
    gs = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY).astype(np.float32)
    ink = gs < INK * cv2.morphologyEx(gs, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))   # thin dark print
    paper = known & ~ink & (gs > 20)
    if paper.sum() < 30:
        return out
    glare = (gs > GLARE * float(np.median(gs[paper]))).astype(np.uint8)                 # glare + its halo
    src = paper & ~cv2.dilate(glare, np.ones((5, 5), np.uint8)).astype(bool)
    if src.sum() < 30:
        return out
    Fs = _feats(cv2.GaussianBlur(small, (0, 0), 0.7))
    X = Fs[src].astype(np.float32)
    K = int(min(N_CLUSTERS, max(1, len(X) // 200)))
    if K > 1:
        cv2.setRNGSeed(0)
        _, _, centres = cv2.kmeans(X, K, None, (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 20, 1e-3), 2,
                                   cv2.KMEANS_PP_CENTERS)
    else:
        centres = X.mean(0, keepdims=True)
    dist_s = np.linalg.norm(Fs[..., None, :] - centres[None, None], axis=-1)
    lab_s = np.argmin(dist_s, axis=-1)
    sig = max(1.0, r / k)
    # joint bilateral filter on a coarse chromaticity grid: per colour cluster a normalised Gaussian
    # convolution of the sources, mixed with soft weights by the pixel's distance to each cluster colour
    wts = np.exp(-0.5 * (dist_s / CHROMA_SIGMA) ** 2)
    num_t = np.zeros(gs.shape, np.float32)
    den_t = np.zeros(gs.shape, np.float32)
    for c in range(len(centres)):
        m = (src & (lab_s == c)).astype(np.float32)
        num_t += wts[..., c] * cv2.GaussianBlur(gs * m, (0, 0), sig)
        den_t += wts[..., c] * cv2.GaussianBlur(m, (0, 0), sig)
    ref_s = num_t / np.maximum(den_t, 1e-6)
    m = src.astype(np.float32)
    sup_all_s = cv2.GaussianBlur(m, (0, 0), sig)
    ref_all_s = cv2.GaussianBlur(gs * m, (0, 0), sig) / np.maximum(sup_all_s, 1e-6)
    if quad_w is not None:   # the cover's own darkening towards its sides, measured at the low resolution
        ok_s = (den_t > MIN_SUPPORT) & (np.min(dist_s, -1) < SHADOW_CHROMA)
        zone_s = cv2.resize(zone_c.astype(np.uint8), (ws, hs), interpolation=cv2.INTER_NEAREST).astype(bool)
        face_s = cv2.resize(face_c.astype(np.uint8), (ws, hs), interpolation=cv2.INTER_NEAREST).astype(bool)
        qs = (np.asarray(quad_w) - [x0, y0]) * [ws / img_c.shape[1], hs / img_c.shape[0]]
        ref_s = ref_s * _edge_factor(gs, ref_s, face_s, zone_s, qs, r / k, ok_s)
    up = lambda a: cv2.resize(a, (img_c.shape[1], img_c.shape[0]), interpolation=cv2.INTER_LINEAR)
    ref, sup, ref_all, sup_all = up(ref_s), up(den_t), up(ref_all_s), up(sup_all_s)
    F = _feats(cv2.GaussianBlur(img_c, (0, 0), 1))
    d_own = np.min(np.linalg.norm(F[..., None, :] - centres[None, None], axis=-1), axis=-1)
    gray = cv2.GaussianBlur(cv2.cvtColor(img_c, cv2.COLOR_BGR2GRAY).astype(np.float32), (0, 0), 1)
    ok = (sup > MIN_SUPPORT) & (d_own < SHADOW_CHROMA)
    ratio = (gray + 1) / (ref + 1)
    cand = band_c & ok & (ratio < SHADOW_DARK) & (ratio > SHADOW_MIN)
    touch = dh_c <= max(3.0, SHADOW_GAP * size)
    # right at the hand also the dark contact line / unlit fringe: any darkening, and when no cover colour
    # like the pixel's own is around (its chroma is unreliable when dark) against the overall cover brightness
    ratio_t = np.where(sup > MIN_SUPPORT, ratio, (gray + 1) / (ref_all + 1))
    cand |= band_c & touch & (sup_all > MIN_SUPPORT) & (ratio_t < SHADOW_DARK)
    cand = cv2.morphologyEx(cand.astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8)).astype(bool)
    out[sl] = _connected_to(cand, touch)
    return out


def _edge_factor(gray, ref, face, zone, quad_w, r, ok):
    """The cover's own darkening towards a side (bent cover near the spine, vignetting, shading of a
    curved surface): per side of the quad and per distance-from-that-side layer, the median of
    brightness / reference of the plain cover pixels OUTSIDE the hand's zone (locally, within the crop).
    A band pixel is then only called shadow if it is darker than its side/layer is elsewhere. Layers with
    too few such pixels (the hand covers that whole stretch) are not corrected."""
    h, w = gray.shape
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    dists = []
    for i in range(4):
        (ax, ay), (bx, by) = quad_w[i], quad_w[(i + 1) % 4]
        L = max(float(np.hypot(bx - ax, by - ay)), 1e-6)
        dists.append(np.abs((bx - ax) * (yy - ay) - (by - ay) * (xx - ax)) / L)
    dists = np.stack(dists, -1)
    nl = int(1.5 * EDGE_LAYERS_PER_BAND)
    layer = np.minimum((dists.min(-1) / (r / EDGE_LAYERS_PER_BAND)).astype(np.int32), nl)
    idx = np.argmin(dists, -1) * (nl + 1) + layer
    q = gray / np.maximum(ref, 1)
    stat = face & ~zone & ok & (q > SHADOW_MIN) & (layer < nl)
    table = np.ones(4 * (nl + 1), np.float32)
    ids, vals = idx[stat], q[stat]
    if len(ids):
        order = np.argsort(ids, kind='stable')
        ids, vals = ids[order], vals[order]
        uniq, start, count = np.unique(ids, return_index=True, return_counts=True)
        for u, s0, c in zip(uniq, start, count):
            if c >= EDGE_MIN_PIXELS:
                table[u] = float(np.clip(np.median(vals[s0:s0 + c]), 0.5, 1.0))
    return table[idx]


def detect(photo_bgr, quad):
    """Recommended entry point: adaptive skin model + cast shadow."""
    return detect_parts(photo_bgr, quad, shadow=True)


def detect_no_edge_norm(photo_bgr, quad):
    """Shadow step without the per-side edge-darkening correction."""
    return detect_parts(photo_bgr, quad, shadow=True, edge_norm=False)


def detect_hand_only(photo_bgr, quad):
    """Adaptive skin model only (no shadow step)."""
    return detect_parts(photo_bgr, quad, shadow=False)
