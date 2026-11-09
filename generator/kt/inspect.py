"""Measurement kit for writing a recipe by hand (the AI-design route): numbers in cm instead of pixels.

  kt inspect face  --photo P --size WxH          a flat face: rectified image, corner radius, colour, marks
  kt inspect edge  --photo P --length L --thickness T [--colour r,g,b]   a thin side: recesses along it, seams
  kt inspect views --glb model.glb [--photo key=path@yaw,pitch ...]       the model from 7 directions (+ photos)
  kt recipe --scene scene.json --photo key=path@yaw ...                   build a hand-written recipe

Nothing here knows object types: a face is a rectangle of known size seen in a photo, an edge is a long
strip of known length and thickness, a mark is anything clearly darker or brighter than its surroundings.
Coordinates: x from the face's left edge, y from its top edge (as in the photo), in cm; 'centred' adds
the recipe convention (x from the centre, y up from the bottom edge).
"""
from __future__ import annotations
import json
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps

from . import quad_detect as qd

PPC = 40                  # pixels per cm of rectified images


# ------------------------------------------------------------------ helpers
def _imread(path) -> np.ndarray:
    """cv2.imread that works with non-ASCII paths (Windows)."""
    return cv2.imdecode(np.fromfile(str(path), dtype=np.uint8), cv2.IMREAD_COLOR)


def load_bgr(path) -> np.ndarray:
    im = ImageOps.exif_transpose(Image.open(path)).convert('RGB')
    return cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2BGR)


def lab(bgr) -> np.ndarray:
    l = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    l[..., 0] *= 100 / 255; l[..., 1:] -= 128
    return l


def _upright_copy(path, out_dir: Path) -> Path:
    """Detection works on files; give it the EXIF-rotated photo."""
    p = out_dir / f'_{Path(path).stem}_upright.png'
    if not p.exists():
        cv2.imencode('.png', load_bgr(path))[1].tofile(str(p))
    return p


def _rgb01(bgr_vec) -> list:
    return [round(float(v) / 255, 3) for v in np.asarray(bgr_vec)[::-1]]


def _local_background(img, k_px):
    """Large-window median (on a 1/4 copy): what the surface looks like around a mark."""
    sm = cv2.resize(img, None, fx=0.25, fy=0.25, interpolation=cv2.INTER_AREA)
    k = max(3, min(255, int(k_px * 0.25) | 1))
    return cv2.resize(cv2.medianBlur(sm, k), (img.shape[1], img.shape[0]), interpolation=cv2.INTER_LINEAR)


def find_marks(img, region, min_area_px, max_area_frac=0.25, polarity=('dark', 'bright'), window_px=None,
               join_px=0, skip_border=False):
    """Components clearly darker / brighter than the surface around them, inside `region`.
    A shadow or reflection boundary is rejected: a real mark differs from *all* of its surroundings
    (compared with the 25th / 75th percentile of a ring around it), a light/shade edge does not.
    join_px: close gaps up to this size and fill enclosed holes (a rubber foot with a highlight in it, a
    ring) so one object is one mark. skip_border: drop components touching the region's edge."""
    from scipy.ndimage import binary_fill_holes
    rim = region & ~cv2.erode(region.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32)
    window_px = window_px or max(31, int(0.25 * np.sqrt(region.sum())))
    src = img.copy()
    src[~region] = np.median(img[region], 0).astype(img.dtype)      # only the surface itself sets its background
    bg = _local_background(src, window_px).mean(2) if img.ndim == 3 else _local_background(src, window_px)
    out = []
    for pol in polarity:
        cand = (g < 0.75 * bg) if pol == 'dark' else (g > np.minimum(1.25 * bg, bg + 60))
        cand = cv2.morphologyEx((cand & region).astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
        if join_px:
            cand = cv2.morphologyEx(cand, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * join_px + 1,) * 2))
            cand = (binary_fill_holes(cand) & region).astype(np.uint8)
        n, labels, st, cen = cv2.connectedComponentsWithStats(cand, connectivity=8)
        for i in range(1, n):
            a = st[i, cv2.CC_STAT_AREA]
            if a < min_area_px or a > max_area_frac * region.sum():
                continue
            comp = labels == i
            if skip_border and (comp & rim).any():
                continue
            r = max(3, int(0.5 * np.sqrt(a)))
            ring = cv2.dilate(comp.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1,) * 2)).astype(bool) & ~comp & region
            if ring.sum() < 10:
                continue
            inside = float(np.median(g[comp]))
            if pol == 'dark':
                ok = inside < 0.8 * float(np.percentile(g[ring], 25))
                contrast = float(np.percentile(g[ring], 25)) / max(inside, 1)
            else:
                ok = inside > 1.15 * float(np.percentile(g[ring], 75))
                contrast = inside / max(float(np.percentile(g[ring], 75)), 1)
            if not ok:
                continue
            cs, _ = cv2.findContours(comp.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
            c = max(cs, key=cv2.contourArea)
            hull = cv2.convexHull(c)
            per = cv2.arcLength(c, True)
            out.append({'polarity': pol, 'comp': comp, 'contour': c, 'area_px': int(a), 'centroid_px': cen[i].tolist(),
                        'bbox_px': st[i, :4].tolist(), 'contrast': round(contrast, 2),
                        'circularity': round(float(4 * np.pi * a / max(per, 1) ** 2), 2),
                        'solidity': round(float(a / max(cv2.contourArea(hull), 1)), 2),
                        'colour_rgb': _rgb01(np.median(img[comp], 0))})
    return out


def _ruler(img, ppc, origin_px, w_cm, h_cm, step=1):
    v = img.copy()
    for k in range(int(w_cm) + 1):
        x = int(origin_px[0] + k * ppc)
        cv2.line(v, (x, 0), (x, 14 if k % 5 else 28), (0, 0, 255), 2)
        if k % 5 == 0:
            cv2.putText(v, str(k), (x + 2, 44), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
    for k in range(int(h_cm) + 1):
        y = int(origin_px[1] + k * ppc)
        cv2.line(v, (0, y), (14 if k % 5 else 28, y), (0, 0, 255), 2)
        if k % 5 == 0:
            cv2.putText(v, str(k), (30, y + 8), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
    return v


# ------------------------------------------------------------------ face
def measure_face(photo, size_cm, out_dir, corners=None, margin_cm=1.0, ppc=PPC, facing='front') -> dict:
    """A flat face of known size (W x H cm): rectify, measure corner rounding, colour and marks.
    facing='back': the photo looks at the model from behind (yaw 180), so x of the 'centred' (recipe)
    coordinates is mirrored; the face coordinates (from the photo's top-left) are unchanged."""
    sx = -1.0 if facing == 'back' else 1.0
    out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True)
    img = load_bgr(photo)
    h, w = img.shape[:2]
    if corners is None:
        r = qd.detect_face(_upright_copy(photo, out_dir))
        corners, support = r.corners, r.notes[0] if r.notes else ''
    else:
        support = 'given'
    q = np.array(corners, float) * [w, h]
    W, H = map(float, size_cm)
    side_w = (np.linalg.norm(q[1] - q[0]) + np.linalg.norm(q[2] - q[3])) / 2
    side_h = (np.linalg.norm(q[3] - q[0]) + np.linalg.norm(q[2] - q[1])) / 2
    note = []
    if (side_w > side_h) != (W > H) and abs(W - H) > 0.05 * max(W, H):
        W, H = H, W
        note.append(f'size taken as {W:g} x {H:g} cm to match the photo (the face is {"landscape" if side_w > side_h else "portrait"} there)')
    m = margin_cm
    dst = np.float32([[m, m], [m + W, m], [m + W, m + H], [m, m + H]]) * ppc
    M = cv2.getPerspectiveTransform(np.float32(q), dst)
    size = (int(round((W + 2 * m) * ppc)), int(round((H + 2 * m) * ppc)))
    rect = cv2.warpPerspective(img, M, size, flags=cv2.INTER_AREA, borderMode=cv2.BORDER_REPLICATE)
    L = lab(rect)
    face = np.zeros(rect.shape[:2], bool)
    face[int(m * ppc):int((m + H) * ppc), int(m * ppc):int((m + W) * ppc)] = True
    inner = np.zeros_like(face)
    ins = min(1.5, 0.15 * min(W, H))
    inner[int((m + ins) * ppc):int((m + H - ins) * ppc), int((m + ins) * ppc):int((m + W - ins) * ppc)] = True
    face_lab = np.median(L[inner], 0)

    # corner rounding: walk each diagonal from the sharp (line-intersection) corner inward until the colour
    # turns from the surroundings to the face; for a radius r that point lies r (sqrt2 - 1) from the corner
    corners_out = {}
    for name, cx, cy, dx, dy in (('top_left', m, m, 1, 1), ('top_right', m + W, m, -1, 1),
                                 ('bottom_right', m + W, m + H, -1, -1), ('bottom_left', m, m + H, 1, -1)):
        ts = np.arange(0, min(4.0, 0.3 * min(W, H)), 1 / ppc)
        pts = [(int(round((cx + dx * t / np.sqrt(2)) * ppc)), int(round((cy + dy * t / np.sqrt(2)) * ppc))) for t in ts]
        d = np.array([np.linalg.norm(L[y, x] - face_lab) for x, y in pts])
        outside = float(np.median(d[:3]))
        if outside < 12:
            corners_out[name] = {'radius_cm': None, 'reason': f'background too close to the face colour (dE {outside:.0f})'}
            continue
        i = int(np.argmax(d < 0.5 * outside))
        corners_out[name] = {'radius_cm': round(float(ts[i] / (np.sqrt(2) - 1)), 2), 'contrast_dE': round(outside, 1)}
    radii = [c['radius_cm'] for c in corners_out.values() if c.get('radius_cm') is not None]

    # colour: overall, darker half (a glossy face's bright part is the room's reflection), and the colour cast
    # of the light, judged on white-ish surroundings (paper, desk) if there are any
    px = rect[inner].astype(np.float32); lum = px.mean(1)
    darker = px[(lum >= np.percentile(lum, 10)) & (lum <= np.percentile(lum, 50))]
    around = ~face & (L[..., 0] > 75) & (np.hypot(L[..., 1], L[..., 2]) < 15)
    colour = {'median_rgb': _rgb01(np.median(px, 0)), 'darker_half_rgb': _rgb01(np.median(darker, 0)),
              'brightness_spread': round(float((np.percentile(lum, 95) - np.percentile(lum, 5)) / max(np.median(lum), 1)), 2)}
    if around.sum() > 200:
        white = np.median(rect[around].astype(np.float32), 0)
        cast = white.mean() / np.maximum(white, 1)
        colour['white_reference_rgb'] = _rgb01(white)
        colour['darker_half_rgb_cast_corrected'] = _rgb01(np.clip(np.median(darker, 0) * cast, 0, 255))
    if colour['brightness_spread'] > 0.5:
        note.append('strong light/shade on the face (reflection or shadow): a uniform material is likely; '
                    'use darker_half_rgb rather than the photo as texture')

    # marks on the face
    region = cv2.erode(face.astype(np.uint8), np.ones((int(0.3 * ppc),) * 2, np.uint8)).astype(bool)
    marks = []
    found = find_marks(rect, region, min_area_px=int(0.04 * ppc * ppc), join_px=max(1, int(0.05 * ppc)), skip_border=True)
    for k, mk in enumerate(sorted(found, key=lambda d: -d['area_px'])[:24]):
        cx_px, cy_px = mk['centroid_px']
        c = cv2.approxPolyDP(mk['contour'], 0.03 * ppc, True).reshape(-1, 2)
        x, y, bw, bh = mk['bbox_px']
        to_face = lambda px_: (px_[0] / ppc - m, px_[1] / ppc - m)
        cxf, cyf = to_face((cx_px, cy_px))
        marks.append({'id': k, 'polarity': mk['polarity'], 'area_cm2': round(mk['area_px'] / ppc ** 2, 3),
                      'centre_cm': [round(cxf, 2), round(cyf, 2)], 'centre_centred_cm': [round(sx * (cxf - W / 2), 2), round(H - cyf, 2)],
                      'bbox_cm': [round(x / ppc - m, 2), round(y / ppc - m, 2), round(bw / ppc, 2), round(bh / ppc, 2)],
                      'equivalent_diameter_cm': round(2 * np.sqrt(mk['area_px'] / np.pi) / ppc, 2),
                      'circularity': mk['circularity'], 'solidity': mk['solidity'], 'contrast': mk['contrast'],
                      'colour_rgb': mk['colour_rgb'],
                      'outline_centred_cm': [[round(sx * (px_[0] / ppc - m - W / 2), 3), round(H - (px_[1] / ppc - m), 3)]
                                             for px_ in (c[::-1] if sx > 0 else c)]})   # counter-clockwise either way
    vis = _ruler(rect, ppc, (m * ppc, m * ppc), W, H)
    for mk in marks:
        pts = np.array([[(sx * x + W / 2 + m) * ppc, (H - y + m) * ppc] for x, y in mk['outline_centred_cm']], np.int32)
        cv2.polylines(vis, [pts], True, (0, 0, 255) if mk['polarity'] == 'dark' else (255, 0, 0), 2)
        cv2.putText(vis, str(mk['id']), tuple(pts[0]), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 200, 0), 2)
    cv2.imencode('.png', rect)[1].tofile(str(out_dir / f'{Path(photo).stem}_face.png'))
    cv2.imencode('.jpg', vis)[1].tofile(str(out_dir / f'{Path(photo).stem}_face_marks.jpg'))
    res = {'photo': str(photo), 'facing': facing, 'size_cm': [W, H], 'corners_norm': np.round(corners, 4).tolist(), 'edge_support': support,
           'rectified': str(out_dir / f'{Path(photo).stem}_face.png'), 'pixels_per_cm': ppc, 'margin_cm': m,
           'corner_rounding': corners_out, 'corner_radius_cm': round(float(np.median(radii)), 2) if radii else None,
           'colour': colour, 'marks': marks, 'notes': note,
           'marks_image': str(out_dir / f'{Path(photo).stem}_face_marks.jpg')}
    (out_dir / f'{Path(photo).stem}_face.json').write_text(json.dumps(res, indent=1), encoding='utf-8')
    return res


# ------------------------------------------------------------------ edge (thin side)
def _strip_mask(img, colour_rgb=None, tol=18.0):
    """Pixels of the object's side. With a colour (from the face measurement), by colour; otherwise the
    darkest/most saturated elongated region is not guessed: use detect_strip instead."""
    L = lab(img)
    ref = lab(np.uint8([[np.array(colour_rgb[::-1]) * 255]]))[0, 0]
    d = np.linalg.norm(L - ref, axis=2)
    m = (d < tol).astype(np.uint8)
    return cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))


def _strip_from_mask(mask, aspect, seed=None):
    """The elongated component(s) that form the strip: the component under `seed` (x, y px) or else the
    best-elongated large one, plus pieces on its axis (a holding hand may cut it). Returns (points, angle)."""
    n, labels, st, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    best, best_sc = None, 0
    rects = {}
    for i in range(1, n):
        if st[i, cv2.CC_STAT_AREA] < 0.0005 * mask.size:
            continue
        pts = np.column_stack(np.nonzero(labels == i))[:, ::-1].astype(np.float32)
        (cx, cy), (rw, rh), ang = cv2.minAreaRect(pts)
        lng, sht = max(rw, rh), max(1.0, min(rw, rh))
        rects[i] = ((cx, cy), lng, sht, ang if rw >= rh else ang + 90, pts)
        el = lng / sht
        if el < 3:
            continue
        sc = lng * min(1.0, el / aspect)
        if sc > best_sc:
            best, best_sc = i, sc
    if seed is not None:
        sid = labels[int(seed[1]), int(seed[0])]
        best = sid if sid in rects else best
    if best is None:
        return None
    (cx, cy), lng, sht, ang, pts = rects[best]
    axis = np.array([np.cos(np.radians(ang)), np.sin(np.radians(ang))]); nrm = np.array([-axis[1], axis[0]])
    keep = [pts]
    for i, ((x, y), l2, s2, a2, p2) in rects.items():
        if i == best:
            continue
        off = abs((np.array([x, y]) - [cx, cy]) @ nrm)
        if off < 0.6 * sht and abs(((a2 - ang + 90) % 180) - 90) < 8:
            keep.append(p2)
    return np.vstack(keep), ang


def _seeded_mask(img, at, tol=None):
    """Pixels like the side at `at` (normalised x, y on the side): colour sampled there, tolerance from its
    own variation, then closed so print/ports on the side do not split it."""
    h, w = img.shape[:2]
    x, y = int(at[0] * w), int(at[1] * h)
    L = lab(cv2.GaussianBlur(img, (5, 5), 0))
    r = max(4, int(0.004 * max(h, w)))
    patch = L[max(0, y - r):y + r + 1, max(0, x - r):x + r + 1].reshape(-1, 3)
    ref = np.median(patch, 0)
    tol = tol or float(np.clip(3 * np.median(np.linalg.norm(patch - ref, axis=1)) + 8, 10, 22))
    m = (np.linalg.norm(L - ref, axis=2) < tol).astype(np.uint8)
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((15, 15), np.uint8))
    return m, (x, y), [round(float(v), 1) for v in ref], round(tol, 1)


def _trace_strip(pts, ang, seed, size, bins=120):
    """Follow a strip of near-constant width from `seed` (or its middle) in both directions and stop where the
    width changes (the strip ends, or runs into a background of the same colour). Returns the 4 corners
    [end A side 1, end A side 2, end B side 2, end B side 1] or None."""
    pts = np.asarray(pts, np.float32)
    c0 = np.asarray(seed, np.float32) if seed is not None else pts.mean(0)
    # local direction around the seed (the far parts of a merged region would bias a global fit)
    rad = 0.15 * float(np.hypot(*size))
    near = pts[np.linalg.norm(pts - c0, axis=1) < rad]
    if len(near) < 50:
        return None
    _, _, vt = np.linalg.svd(near - near.mean(0), full_matrices=False)
    axis = vt[0]; nrm = np.array([-axis[1], axis[0]], np.float32)
    u = (pts - c0) @ axis; v = (pts - c0) @ nrm
    edges = np.linspace(u.min(), u.max(), bins + 1)
    step = edges[1] - edges[0]
    centres = (edges[:-1] + edges[1:]) / 2
    idx = np.clip(((u - edges[0]) / step).astype(int), 0, bins - 1)
    k0 = int(np.clip((0 - edges[0]) / step, 0, bins - 1))
    def span(k, centre, width):
        sel = idx == k
        if sel.sum() < 5:
            return None
        vv = v[sel]
        if width is not None:
            vv = vv[np.abs(vv - centre) < 1.5 * width]
            if len(vv) < 5:
                return None
        return float(np.percentile(vv, 3)), float(np.percentile(vv, 97))
    ref = [span(k, 0, None) for k in range(max(0, k0 - 3), min(bins, k0 + 4))]
    ref = [r for r in ref if r is not None]
    if not ref:
        return None
    w0 = float(np.median([r[1] - r[0] for r in ref])); cen = float(np.median([(r[0] + r[1]) / 2 for r in ref]))
    keep = {}
    max_miss = max(3, int(np.ceil(2.5 * w0 / step)))      # ports, slots and labels on the side are shorter than this
    for direction in (-1, 1):
        centre, miss, k = cen, 0, k0
        while 0 <= k < bins and miss < max_miss:
            sp = span(k, centre, w0)
            if sp is not None and 0.6 * w0 <= sp[1] - sp[0] <= 1.5 * w0:
                keep[k] = sp; centre = (sp[0] + sp[1]) / 2; miss = 0
            else:
                miss += 1
            k += direction
    if len(keep) < 6:
        return None
    ks = np.array(sorted(keep)); us = centres[ks]
    lo = np.array([keep[k][0] for k in ks]); hi = np.array([keep[k][1] for k in ks])
    pl = np.polyfit(us, lo, 1); ph = np.polyfit(us, hi, 1)
    u0, u1 = us.min() - step / 2, us.max() + step / 2
    corner = lambda uu, vv: c0 + uu * axis + vv * nrm
    return np.array([corner(u0, np.polyval(pl, u0)), corner(u0, np.polyval(ph, u0)),
                     corner(u1, np.polyval(ph, u1)), corner(u1, np.polyval(pl, u1))])


def _fit_between(mask, p1, p2, bins=80):
    """Lateral boundaries of the side between two given end points (the caller saw where the side ends):
    per slice across the segment, the run of side-coloured pixels around the line; robust line fits."""
    p1 = np.asarray(p1, float); p2 = np.asarray(p2, float)
    axis = (p2 - p1) / max(np.linalg.norm(p2 - p1), 1); nrm = np.array([-axis[1], axis[0]])
    Lseg = np.linalg.norm(p2 - p1)
    h, w = mask.shape
    los, his, us = [], [], []
    reach = 0.25 * Lseg
    for u in np.linspace(0.04 * Lseg, 0.96 * Lseg, bins):
        vs = np.arange(-reach, reach, 1.0)
        pts = p1 + u * axis + np.outer(vs, nrm)
        ok = (pts[:, 0] >= 0) & (pts[:, 0] < w) & (pts[:, 1] >= 0) & (pts[:, 1] < h)
        vals = np.zeros(len(vs), bool)
        vals[ok] = mask[pts[ok, 1].astype(int), pts[ok, 0].astype(int)]
        c = len(vs) // 2
        if not vals[c]:
            continue
        lo = c
        while lo > 0 and vals[lo - 1]:
            lo -= 1
        hi = c
        while hi < len(vs) - 1 and vals[hi + 1]:
            hi += 1
        los.append(vs[lo]); his.append(vs[hi]); us.append(u)
    if len(us) < 8:
        return None
    us, los, his = map(np.array, (us, los, his))
    wid = his - los; keep = np.abs(wid - np.median(wid)) < 0.35 * np.median(wid)   # slices with a hand/shadow attached
    pl = np.polyfit(us[keep], los[keep], 1); ph = np.polyfit(us[keep], his[keep], 1)
    corner = lambda uu, vv: p1 + uu * axis + vv * nrm
    return np.array([corner(0, np.polyval(pl, 0)), corner(0, np.polyval(ph, 0)),
                     corner(Lseg, np.polyval(ph, Lseg)), corner(Lseg, np.polyval(pl, Lseg))])


def measure_edge(photo, length_cm, thickness_cm, out_dir, colour_rgb=None, at=None, ends=None, ppc=PPC) -> dict:
    """A thin side (laptop edge, book spine, box side) of known length and thickness: straightened strip,
    recesses/marks along it (position from both ends, size, place across the thickness), and seam lines."""
    out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True)
    img = load_bgr(photo)
    h, w = img.shape[:2]
    notes = []
    quad = None
    got = None
    side_mask = None
    given_ends = None
    if ends is not None:                                      # the caller marked both ends: trust them
        p1 = np.array(ends[:2]) * [w, h]; p2 = np.array(ends[2:]) * [w, h]
        mask, _seed, ref, tol = _seeded_mask(img, list((np.array(ends[:2]) + np.array(ends[2:])) / 2))
        quad = _fit_between(mask.astype(bool), p1, p2)
        if quad is not None:
            given_ends = True
            notes.append(f'ends given by the caller; width fitted to the side colour (Lab {ref}, dE {tol})')
    elif at is not None:
        mask, seed, ref, tol = _seeded_mask(img, at)
        side_mask = mask.astype(bool)
        got = _strip_from_mask(mask, length_cm / thickness_cm, seed)
        notes.append(f'strip found from the point {list(at)} (colour Lab {ref}, tolerance dE {tol})')
    elif colour_rgb is not None:
        got = _strip_from_mask(_strip_mask(img, colour_rgb), length_cm / thickness_cm)
        notes.append('strip found by colour')
    if got is not None and quad is None:
        quad = _trace_strip(got[0], got[1], seed if at is not None else None, (w, h))
        if quad is None:
            notes.append('the strip could not be traced; falling back to straight-edge detection')
    if quad is None:
        r = qd.detect_strip(_upright_copy(photo, out_dir))
        quad = np.array(r.corners) * [w, h]
        # order so that quad[0]->quad[1] is an end (short side)
        if np.linalg.norm(quad[1] - quad[0]) > np.linalg.norm(quad[3] - quad[0]):
            quad = quad[[1, 2, 3, 0]]
        notes.append('strip found by straight edges (detect_strip)')
    # quad: [end A side 1, end A side 2, end B side 2, end B side 1]
    # is each end really the end of the side, or is it cut by a hand / the photo border?
    from .segment import skin_like
    skin = skin_like(img)
    def end_state(p0, p1, q0, q1):
        mid, inward = (p0 + p1) / 2, ((q0 + q1) / 2 - (p0 + p1) / 2)
        out_dir_ = -inward / max(np.linalg.norm(inward), 1)
        width = np.linalg.norm(p1 - p0)
        pts_ = [mid + out_dir_ * t + (p1 - p0) * f for t in np.linspace(2, 0.8 * width, 6) for f in np.linspace(-0.4, 0.4, 5)]
        inside = [p_ for p_ in pts_ if 0 <= p_[0] < w and 0 <= p_[1] < h]
        if len(inside) < 0.5 * len(pts_):
            return 'cut by the photo border'
        if np.mean([skin[int(p_[1]), int(p_[0])] for p_ in inside]) > 0.25:
            return 'hidden by a hand'
        if side_mask is not None and np.mean([side_mask[int(p_[1]), int(p_[0])] for p_ in inside]) > 0.3:
            # the side's colour goes on past the end: a continuing side is as narrow as the side, a background
            # of the same colour (dark cloth behind a dark laptop) is wide
            outer = [mid + out_dir_ * t + (p1 - p0) * f for t in np.linspace(2, 0.8 * width, 6) for f in (-1.6, -1.2, 1.2, 1.6)]
            outer = [p_ for p_ in outer if 0 <= p_[0] < w and 0 <= p_[1] < h]
            if outer and np.mean([side_mask[int(p_[1]), int(p_[0])] for p_ in outer]) < 0.3:
                return 'continues beyond (cut by a shadow or a hand)'
            return 'visible (against a background of the same colour)'
        return 'visible'
    if given_ends:
        end_a = end_b = 'visible (given)'
    else:
        end_a = end_state(quad[0], quad[1], quad[3], quad[2])
        end_b = end_state(quad[3], quad[2], quad[0], quad[1])
    vis = lambda st_: st_.startswith('visible')
    if not vis(end_a) and vis(end_b):                        # measure from the visible end
        quad = quad[[3, 2, 1, 0]]
        end_a, end_b = end_b, end_a
    width_px = (np.linalg.norm(quad[1] - quad[0]) + np.linalg.norm(quad[2] - quad[3])) / 2
    len_px = (np.linalg.norm(quad[3] - quad[0]) + np.linalg.norm(quad[2] - quad[1])) / 2
    if vis(end_a) and vis(end_b):
        shown_cm = length_cm
        scale_note = 'both ends visible: scale from the length'
    else:
        shown_cm = min(length_cm, len_px / width_px * thickness_cm)
        scale_note = (f'end B {end_b}: scale from the thickness (+-10%); {shown_cm:.1f} of {length_cm:g} cm visible from end A'
                      if vis(end_a) else f'neither end visible ({end_a}, {end_b}): positions are rough')
        notes.append(scale_note)
    Lp, Tp = int(round(shown_cm * ppc)), int(round(thickness_cm * ppc))
    pad = int(0.3 * ppc)
    dst = np.float32([[pad, pad], [pad + Tp, pad], [pad + Tp, pad + Lp], [pad, pad + Lp]])
    Mh = cv2.getPerspectiveTransform(np.float32(quad), dst)
    strip = cv2.warpPerspective(img, Mh, (Tp + 2 * pad, Lp + 2 * pad), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    body = np.zeros(strip.shape[:2], bool); body[pad:pad + Lp, pad:pad + Tp] = True
    region = cv2.erode(body.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    marks = []
    for k, mk in enumerate(sorted(find_marks(strip, region, min_area_px=int(0.01 * ppc * ppc), max_area_frac=0.2,
                                             window_px=int(3 * ppc)), key=lambda d: d['centroid_px'][1])):
        x, y, bw, bh = mk['bbox_px']
        cy = mk['centroid_px'][1] - pad; cx = mk['centroid_px'][0] - pad
        marks.append({'id': k, 'polarity': mk['polarity'], 'from_end_a_cm': round(cy / ppc, 2),
                      'from_end_b_cm': round(length_cm - cy / ppc, 2) if vis(end_a) or vis(end_b) else None,
                      'across_fraction_from_side_1': round(cx / Tp, 2), 'length_cm': round(bh / ppc, 2), 'width_cm': round(bw / ppc, 2),
                      'contrast': mk['contrast'], 'colour_rgb': mk['colour_rgb']})
    # seams: narrow dark valleys in the across-thickness profile (median along the length)
    g = cv2.cvtColor(strip, cv2.COLOR_BGR2GRAY).astype(np.float32)[pad:pad + Lp, pad:pad + Tp]
    prof = np.median(g, 0)
    smooth = cv2.GaussianBlur(prof.reshape(1, -1), (0, 0), max(1, Tp / 12)).ravel()
    seams = []
    for i in range(2, Tp - 2):
        if prof[i] < prof[i - 1] and prof[i] <= prof[i + 1] and prof[i] < 0.85 * smooth[i] and 0.08 < i / Tp < 0.92:
            seams.append({'across_fraction_from_side_1': round(i / Tp, 2), 'depth': round(float(1 - prof[i] / smooth[i]), 2)})
    vis = cv2.resize(strip, None, fx=2, fy=1, interpolation=cv2.INTER_NEAREST) if Tp < 3 * ppc else strip.copy()
    sx = vis.shape[1] / strip.shape[1]
    vis = cv2.copyMakeBorder(vis, 0, 0, 0, 120, cv2.BORDER_CONSTANT, value=(255, 255, 255))
    for k in range(int(shown_cm) + 1):
        y = pad + k * ppc
        cv2.line(vis, (vis.shape[1] - 120, y), (vis.shape[1] - (100 if k % 5 else 80), y), (0, 0, 255), 2)
        if k % 5 == 0:
            cv2.putText(vis, f'{k}cm', (vis.shape[1] - 78, y + 8), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)
    for mk in marks:
        y = int(pad + mk['from_end_a_cm'] * ppc)
        cv2.putText(vis, str(mk['id']), (int((pad + Tp) * sx) + 4, y + 8), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 160, 0), 2)
    stem = Path(photo).stem
    cv2.imencode('.jpg', vis)[1].tofile(str(out_dir / f'{stem}_edge.jpg'))
    res = {'photo': str(photo), 'length_cm': length_cm, 'thickness_cm': thickness_cm,
           'strip_corners_px': np.round(quad).astype(int).tolist(),
           'end_a': 'the strip end nearer photo point ' + str(np.round(quad[0]).astype(int).tolist()),
           'side_1': 'the long side through photo points ' + str([np.round(quad[0]).astype(int).tolist(), np.round(quad[3]).astype(int).tolist()]),
           'end_a_state': end_a, 'end_b_state': end_b, 'scale': scale_note, 'shown_length_cm': round(shown_cm, 2),
           'marks': marks, 'seams': seams, 'notes': notes,
           'image': str(out_dir / f'{stem}_edge.jpg')}
    (out_dir / f'{stem}_edge.json').write_text(json.dumps(res, indent=1), encoding='utf-8')
    return res


# ------------------------------------------------------------------ views
STANDARD_VIEWS = {'hero': (30, 16), 'front': (0, 0), 'back': (180, 0), 'left': (-90, 0), 'right': (90, 0),
                  'top': (0, 89), 'bottom': (0, -89)}


def views_sheet(glb, out_path, photos=None, size=384) -> str:
    """The model from the 7 standard directions, and from each photo's direction next to that photo."""
    from katachi.render import render_glb
    out_path = Path(out_path); tmp = out_path.parent / f'_{out_path.stem}_views'
    views = dict(STANDARD_VIEWS)
    for key, (_p, yaw, pitch) in (photos or {}).items():
        views[f'photo_{key}'] = (yaw, pitch)
    render_glb(Path(glb), tmp, size=size * 2, views=tuple(views), camera_specs={k: {'angles': v} for k, v in views.items()})
    tile = lambda im, label: cv2.putText(cv2.resize(im, (size, size)), label, (6, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 200), 2)
    row1 = np.hstack([tile(_imread(tmp / f'{k}.png'), k) for k in STANDARD_VIEWS])
    rows = [row1]
    pairs = []
    for key, (p, yaw, pitch) in (photos or {}).items():
        ph = load_bgr(p); s = size / max(ph.shape[:2])
        ph = cv2.resize(ph, None, fx=s, fy=s); canvas = np.full((size, size, 3), 255, np.uint8)
        canvas[:ph.shape[0], :ph.shape[1]] = ph
        pairs += [tile(canvas, f'photo {key}'), tile(_imread(tmp / f'photo_{key}.png'), f'model {key}')]
    while pairs:
        chunk, pairs = pairs[:len(STANDARD_VIEWS) - len(STANDARD_VIEWS) % 2], pairs[len(STANDARD_VIEWS) - len(STANDARD_VIEWS) % 2:]
        chunk += [np.full((size, size, 3), 255, np.uint8)] * (len(STANDARD_VIEWS) - len(chunk))
        rows.append(np.hstack(chunk))
    cv2.imencode('.jpg', np.vstack(rows))[1].tofile(str(out_path))
    return str(out_path)
