"""Automatic detection of a flat rectangular face (book cover, box side, card) in a photo.

Returns normalized corners in TL, TR, BR, BL order (x right, y down, 0..1 of the full image).
Strategy:
  1. Candidate masks: straight-line quads (LSD) + bright/low-chroma thresholds, each split
     with a light erosion so a cover touching a white desk can separate at the shadow line.
  2. The component nearest the image centre is fitted with a quadrilateral (hull -> 4 lines).
  3. Each side is refined by fitting a line to strong gradient pixels in a narrow band.
  4. Sides that run along the image border are reported as clipped.
"""
from __future__ import annotations
from dataclasses import dataclass, field
import cv2
import numpy as np

WORK = 900  # long side of the working image


@dataclass
class QuadResult:
    corners: list            # 4 x [x, y] normalized, TL TR BR BL; may extend outside 0..1 when recovered
    clipped_sides: list = field(default_factory=list)  # 'top','right','bottom','left'
    score: float = 0.0
    method: str = ''
    notes: list = field(default_factory=list)


def _load(path):
    data = np.fromfile(str(path), dtype=np.uint8)  # unicode-safe on Windows
    img = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError(f'cannot read image: {path}')
    return img


def _order(pts):
    pts = np.asarray(pts, float)
    c = pts.mean(0)
    ang = np.arctan2(pts[:, 1] - c[1], pts[:, 0] - c[0])
    pts = pts[np.argsort(ang)]            # clockwise in image coords starting from left-ish
    s = pts.sum(1)
    start = int(np.argmin(s))             # top-left has the smallest x+y
    return np.roll(pts, -start, axis=0)


def _hull_to_quad(contour):
    hull = cv2.convexHull(contour)
    peri = cv2.arcLength(hull, True)
    for eps in np.linspace(0.005, 0.08, 40):
        approx = cv2.approxPolyDP(hull, eps * peri, True)
        if len(approx) == 4:
            return approx.reshape(4, 2).astype(float)
    # fall back to minimum-area rectangle
    return cv2.boxPoints(cv2.minAreaRect(hull)).astype(float)


def _masks(img):
    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB).astype(float)
    L = lab[:, :, 0]
    chroma = np.hypot(lab[:, :, 1] - 128, lab[:, :, 2] - 128)
    out = []
    for q in (35, 45, 55, 65):
        thr = np.percentile(L, q)
        m = ((L > thr) & (chroma < 40)).astype(np.uint8) * 255
        out.append((f'bright{q}', m))
    # Otsu on lightness alone
    _, m = cv2.threshold(L.astype(np.uint8), 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    out.append(('otsu', m))
    # (GrabCut candidates removed: ~4 s per photo and never selected over line-based quads in validation)
    return out


def _components(mask):
    h, w = mask.shape
    for erode in (0, 3, 6, 10):
        m = mask
        if erode:
            m = cv2.erode(mask, np.ones((erode, erode), np.uint8))
        m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
        contours, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        for c in contours:
            if cv2.contourArea(c) < 0.08 * h * w:
                continue
            if erode:  # grow back what the erosion removed
                c = c.astype(float)
                centre = c.reshape(-1, 2).mean(0)
                c = (centre + (c.reshape(-1, 2) - centre) * 1.0).reshape(-1, 1, 2)
            yield erode, c.astype(np.int32)


def _on_border(a, b, shape, tol=0.006):
    h, w = shape
    na, nb = np.asarray(a) / [w, h], np.asarray(b) / [w, h]
    return any(abs(na[ax] - e) < tol and abs(nb[ax] - e) < tol for ax in (0, 1) for e in (0.0, 1.0))


_S = np.linspace(0.08, 0.92, 64)
_O = np.arange(-3, 4)
_GRAD_THR = 12


def _end_support(grad, quad):
    """Minimum edge support near the two ends of every real side. Samples outside the photo count
    as misses, so a quad whose corner is pushed outside the frame by a wrong (e.g. background) line
    is penalised, while sides lying on the image border are skipped."""
    gx, gy, mag = grad[:3]
    occ = grad[3] if len(grad) > 3 else None
    h, w = mag.shape
    worst = 1.0
    for i in range(4):
        a, b = quad[i], quad[(i + 1) % 4]
        if _on_border(a, b, (h, w)):
            continue
        d = b - a; L = np.linalg.norm(d)
        if L < 10:
            return 0.0
        t = d / L; n = np.array([-t[1], t[0]])
        for S in (np.linspace(0.03, 0.15, 12), np.linspace(0.85, 0.97, 12)):
            pts = (a + np.outer(S, d))[:, None, :] + _O[None, :, None] * n
            x = pts[..., 0].round().astype(int); y = pts[..., 1].round().astype(int)
            inside = (x >= 2) & (x < w - 2) & (y >= 2) & (y < h - 2)
            xc = np.clip(x, 0, w - 1); yc = np.clip(y, 0, h - 1)
            g = mag[yc, xc]
            c = np.abs(gx[yc, xc] * n[0] + gy[yc, xc] * n[1]) / (g + 1e-9)
            ok = (g > _GRAD_THR) & (c > 0.8) & inside
            known = np.ones(len(S), bool) if occ is None else ~(occ[yc, xc] & inside).any(1)
            if known.sum() < 3:              # this end is hidden by a hand: no evidence either way
                continue
            worst = min(worst, float(ok.any(1)[known].mean()))
    return worst


def _edge_support(grad, quad):
    """Fraction of in-image points along each side that sit on a strong edge aligned with the side.
    None = the side lies on the image border or mostly outside the photo (no evidence)."""
    gx, gy, mag = grad[:3]
    occ = grad[3] if len(grad) > 3 else None
    h, w = mag.shape
    out = []
    for i in range(4):
        a, b = quad[i], quad[(i + 1) % 4]
        if _on_border(a, b, (h, w)):
            out.append(None); continue
        d = b - a; L = np.linalg.norm(d)
        if L < 10:
            out.append(0.0); continue
        t = d / L; n = np.array([-t[1], t[0]])
        P = a + np.outer(_S, d)                                   # (S,2)
        pts = P[:, None, :] + _O[None, :, None] * n               # (S,O,2)
        x = pts[..., 0].round().astype(int); y = pts[..., 1].round().astype(int)
        inside = (x >= 2) & (x < w - 2) & (y >= 2) & (y < h - 2)
        rows_in = inside.all(1)
        if rows_in.mean() < 0.3:
            out.append(None); continue
        xc = np.clip(x, 0, w - 1); yc = np.clip(y, 0, h - 1)
        g = mag[yc, xc]
        cosang = np.abs(gx[yc, xc] * n[0] + gy[yc, xc] * n[1]) / (g + 1e-9)
        ok = (g > _GRAD_THR) & (cosang > 0.8) & inside
        known = rows_in.copy()
        if occ is not None:                                       # samples under a hand are unknown, not misses
            known &= ~occ[yc, xc].any(1)
        if known.sum() < 0.3 * rows_in.sum():
            out.append(0.5); continue                             # mostly hidden: neither evidence nor free pass
        out.append(float(ok.any(1)[known].mean()))
    return out


def _band_colors(lab, quad, near=0.015, far=0.045):
    """Median Lab colour of a thin band just inside each side (None for border/outside sides)."""
    h, w = lab.shape[:2]
    c = quad.mean(0)
    out = []
    for i in range(4):
        a, b = quad[i], quad[(i + 1) % 4]
        if _on_border(a, b, (h, w)):
            out.append(None); continue
        mid_in = []
        for s in np.linspace(0.15, 0.85, 24):
            p = a + (b - a) * s
            for f in np.linspace(near, far, 4):
                x, y = (p + (c - p) * f * 2).round().astype(int)
                if 0 <= x < w and 0 <= y < h:
                    mid_in.append(lab[y, x])
        out.append(np.median(np.array(mid_in), 0) if len(mid_in) > 20 else None)
    return out


def _consistency_penalty(lab, quad):
    cols = _band_colors(lab, quad)
    known = [c for c in cols if c is not None]
    if len(known) < 3:
        return 0.0
    pen = 0.0
    for i, col in enumerate(cols):
        if col is None:
            continue
        others = np.median(np.array([c for j, c in enumerate(cols) if j != i and c is not None]), 0)
        de = float(np.linalg.norm(col - others))
        pen += max(0.0, de - 6.0) / 8.0
    return pen


def _score(quad, contour, shape, grad, lab=None):
    h, w = shape
    qa = cv2.contourArea(quad.astype(np.float32))
    if qa <= 0:
        return -1, []
    area = qa / (h * w)
    angs = []
    for i in range(4):
        a, b, c = quad[i - 1], quad[i], quad[(i + 1) % 4]
        v1, v2 = a - b, c - b
        angs.append(np.degrees(np.arccos(np.clip(v1 @ v2 / (np.linalg.norm(v1) * np.linalg.norm(v2) + 1e-9), -1, 1))))
    angle_pen = sum(max(0, abs(x - 90) - 25) for x in angs) / 90
    support = _edge_support(grad, quad)
    known = [s for s in support if s is not None]
    if len(known) < 3:                                     # at most one side may be the image border
        return -1, support
    # the weakest real side decides: a quad cutting through the face has one unsupported side
    edge = 0.6 * min(known) + 0.4 * float(np.mean(known))
    score = edge * 3 + min(area, 0.6) * 0.8 - angle_pen
    if score > 2.0:                                        # only worth checking plausible quads
        score -= (1.0 - _end_support(grad, quad)) * 2.0
    return score, support


def _refine(gray, quad, band=10, occ=None):
    """Fit each side to strong gradients in a band around the current side. Positions whose band touches
    an occluder (a holding hand) are skipped: the strongest gradient there is the hand's outline."""
    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    mag = np.hypot(gx, gy)
    h, w = gray.shape
    lines = []
    for i in range(4):
        a, b = quad[i], quad[(i + 1) % 4]
        d = b - a; length = np.linalg.norm(d)
        if length < 10:
            return quad
        t = d / length; n = np.array([-t[1], t[0]])
        samples = []
        for s in np.linspace(0.1, 0.9, 60):          # skip rounded corners
            p = a + d * s
            offs = np.arange(-band, band + 1)
            pts = p + np.outer(offs, n)
            xi = np.clip(pts[:, 0].round().astype(int), 0, w - 1)
            yi = np.clip(pts[:, 1].round().astype(int), 0, h - 1)
            inside = (pts[:, 0] >= 1) & (pts[:, 0] < w - 1) & (pts[:, 1] >= 1) & (pts[:, 1] < h - 1)
            if not inside.all():
                continue
            if occ is not None and occ[yi, xi].any():
                continue
            g = mag[yi, xi]
            k = int(np.argmax(g))
            if g[k] > 25:
                samples.append(pts[k])
        if len(samples) < 12:
            lines.append((a, t))                       # keep the original side
            continue
        P = np.array(samples)
        # robust line fit (iteratively drop outliers)
        for _ in range(3):
            c = P.mean(0)
            _, _, vt = np.linalg.svd(P - c)
            dirn = vt[0]; nn = np.array([-dirn[1], dirn[0]])
            r = np.abs((P - c) @ nn)
            keep = r < max(1.5, np.percentile(r, 75) * 2)
            if keep.sum() < 8:
                break
            P = P[keep]
        lines.append((c, dirn))
    out = []
    for i in range(4):
        (p1, d1), (p2, d2) = lines[i - 1], lines[i]
        A = np.array([d1, -d2]).T
        if abs(np.linalg.det(A)) < 1e-6:
            return quad
        s = np.linalg.solve(A, p2 - p1)
        out.append(p1 + d1 * s[0])
    out = np.array(out)
    if np.abs(out - quad).max() > band * 3:          # refinement ran away
        return quad
    return out


def _skin_coloured_background(img, sk, ring_frac=0.04):
    """Pixels of a skin-coloured background (wooden desk, cork, kraft): when most of the photo's border ring
    is 'skin', that colour is the background, not a hand. Returns the skin pixels within the background's
    colour distribution (robust Lab mean/covariance of the ring, Mahalanobis^2 < 11.3 = 99% for 3 dof)."""
    h, w = sk.shape
    b = max(4, int(ring_frac * min(h, w)))
    ring = np.zeros((h, w), bool); ring[:b] = ring[-b:] = True; ring[:, :b] = ring[:, -b:] = True
    if sk[ring].mean() < 0.5:
        return np.zeros((h, w), bool)
    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB).astype(np.float32)
    lab[..., 0] *= 100 / 255; lab[..., 1:] -= 128
    ref = lab[ring & sk]
    med = np.median(ref, 0)
    core = ref[np.linalg.norm(ref - med, axis=1) < 15]           # drop a hand or shadow entering the ring
    if len(core) < 50:
        return np.zeros((h, w), bool)
    mu = core.mean(0); C = np.cov(core.T) + np.eye(3) * 2.0
    d = lab[sk] - mu
    m2 = np.einsum('ij,jk,ik->i', d, np.linalg.inv(C), d)
    out = np.zeros((h, w), bool); out[sk] = m2 < 11.3
    return out


def _occluders(img):
    """Skin-coloured pixels (a holding hand), slightly grown, at working scale. None when the middle of
    the photo is itself skin-coloured (e.g. a peach cover), where this would hide the real edges."""
    from .segment import skin_like
    sk = skin_like(img)
    sk = cv2.morphologyEx((sk & ~_skin_coloured_background(img, sk)).astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    h, w = sk.shape
    if sk[h // 4:3 * h // 4, w // 4:3 * w // 4].mean() > 0.3:
        return None
    return cv2.dilate(sk, np.ones((7, 7), np.uint8)).astype(bool)


def _line_candidates(gray, max_per_class=10, occ=None):
    """Long straight edges as infinite lines (point, unit direction), split into horizontal / vertical classes.
    Image borders are added as pseudo-lines so a face clipped by the frame can still be enclosed."""
    h, w = gray.shape
    lsd = cv2.createLineSegmentDetector()
    segs = lsd.detect(gray)[0]
    segs = np.zeros((0, 4)) if segs is None else segs.reshape(-1, 4)
    min_len = 0.06 * min(h, w)
    lines = []
    for x1, y1, x2, y2 in segs:
        d = np.array([x2 - x1, y2 - y1]); L = np.linalg.norm(d)
        if L < min_len:
            continue
        if occ is not None:                   # the outline of a holding hand is not a side of the face
            sx = np.clip(np.linspace(x1, x2, 9).round().astype(int), 0, w - 1)
            sy = np.clip(np.linspace(y1, y2, 9).round().astype(int), 0, h - 1)
            if occ[sy, sx].mean() >= 0.5:
                continue
        d /= L
        if d[0] < 0 or (abs(d[0]) < 1e-9 and d[1] < 0):
            d = -d
        n = np.array([-d[1], d[0]])
        rho = np.array([x1, y1]) @ n
        lines.append([np.degrees(np.arctan2(d[1], d[0])), rho, L, x1, y1, x2, y2])
    # cluster collinear segments (angle within 2 deg, offset within 1% of size)
    clusters = []
    for ang, rho, L, x1, y1, x2, y2 in sorted(lines, key=lambda r: -r[2]):
        for c in clusters:
            if abs(c['ang'] - ang) < 2.0 and abs(c['rho'] - rho) < 0.01 * max(h, w):
                c['len'] += L; c['pts'] += [(x1, y1), (x2, y2)]; break
        else:
            clusters.append({'ang': ang, 'rho': rho, 'len': L, 'pts': [(x1, y1), (x2, y2)]})
    horiz, vert = [], []
    for c in sorted(clusters, key=lambda c: -c['len']):
        P = np.array(c['pts'], float); cen = P.mean(0)
        _, _, vt = np.linalg.svd(P - cen); d = vt[0]
        a = abs(np.degrees(np.arctan2(d[1], d[0]))) % 180
        if a < 40 or a > 140:
            if len(horiz) < max_per_class: horiz.append((cen, d))
        elif 50 < a < 130:
            if len(vert) < max_per_class: vert.append((cen, d))
    horiz += [(np.array([w / 2, 0.0]), np.array([1.0, 0])), (np.array([w / 2, h - 1.0]), np.array([1.0, 0]))]
    vert += [(np.array([0.0, h / 2]), np.array([0, 1.0])), (np.array([w - 1.0, h / 2]), np.array([0, 1.0]))]
    return horiz, vert


def _intersect(l1, l2):
    (p1, d1), (p2, d2) = l1, l2
    A = np.array([d1, -d2]).T
    if abs(np.linalg.det(A)) < 1e-6:
        return None
    s = np.linalg.solve(A, p2 - p1)
    return p1 + d1 * s[0]


def _line_quads(gray, occ=None):
    h, w = gray.shape
    horiz, vert = _line_candidates(gray, occ=occ)
    ys = lambda l: (l[0] + l[1] * ((w / 2 - l[0][0]) / l[1][0] if abs(l[1][0]) > 1e-9 else 0))[1]
    xs = lambda l: (l[0] + l[1] * ((h / 2 - l[0][1]) / l[1][1] if abs(l[1][1]) > 1e-9 else 0))[0]
    for i, t in enumerate(horiz):
        for b in horiz[i + 1:]:
            top, bot = (t, b) if ys(t) < ys(b) else (b, t)
            if ys(bot) - ys(top) < 0.25 * h:
                continue
            for j, l in enumerate(vert):
                for r in vert[j + 1:]:
                    left, right = (l, r) if xs(l) < xs(r) else (r, l)
                    if xs(right) - xs(left) < 0.08 * w:
                        continue
                    pts = [_intersect(top, left), _intersect(top, right), _intersect(bot, right), _intersect(bot, left)]
                    if any(p is None for p in pts):
                        continue
                    q = np.array(pts)
                    if (q[:, 0] < -0.15 * w).any() or (q[:, 0] > 1.15 * w).any() or (q[:, 1] < -0.15 * h).any() or (q[:, 1] > 1.15 * h).any():
                        continue
                    yield q


def detect_face(path, expect_aspect=None) -> QuadResult:
    """Detect the dominant flat rectangular face. expect_aspect = width/height of the real face (optional)."""
    full = _load(path)
    H, W = full.shape[:2]
    s = WORK / max(H, W)
    img = cv2.resize(full, (round(W * s), round(H * s)), interpolation=cv2.INTER_AREA)
    gray = cv2.GaussianBlur(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY), (3, 3), 0)
    h, w = gray.shape
    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3); gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    occ = _occluders(img)
    grad = (gx, gy, np.hypot(gx, gy), occ)
    candidates = [(q, 'lines') for q in _line_quads(gray, occ)]
    for name, m in _masks(img):
        for erode, c in _components(m):
            candidates.append((_order(_refine(gray, _order(_hull_to_quad(c)), occ=occ)), f'{name}/erode{erode}'))
    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB).astype(float)
    lab[:, :, 0] *= 100 / 255; lab[:, :, 1:] -= 128
    best = best_inside = None
    for q, method in candidates:
        sc, support = _score(q, None, (h, w), grad)
        if best is None or sc > best[0]:
            best = (sc, q, method, support)
        if support and None not in support and (best_inside is None or sc > best_inside[0]):
            best_inside = (sc, q, method, support)
    if best is None or best[0] < 0:
        raise ValueError('no rectangular face found')
    # A side on the photo border carries no edge evidence, so a border quad can beat the true face when
    # that face's edge is slanted or bent (e.g. a rounded spine fold next to the border). Prefer a quad
    # whose four sides are all real and strongly supported, unless it is much smaller.
    if None in best[3] and best_inside and min(best_inside[3]) >= 0.85:
        area = lambda q: cv2.contourArea(np.asarray(q, np.float32))
        if area(best_inside[1]) >= 0.6 * area(best[1]):
            best = (best_inside[0], best_inside[1], best_inside[2] + '+inside-preferred', best_inside[3])
    score, quad, method, support = best
    quad = _order(_refine(gray, quad, occ=occ))
    support = _score(quad, None, (h, w), grad)[1]
    norm = quad / [w, h]
    clipped = []
    tol = 0.006
    names = ['top', 'right', 'bottom', 'left']
    for i in range(4):
        a, b = norm[i], norm[(i + 1) % 4]
        for axis, edge in ((0, 0.0), (0, 1.0), (1, 0.0), (1, 1.0)):
            if abs(a[axis] - edge) < tol and abs(b[axis] - edge) < tol:
                clipped.append(names[i])
    notes = [f'edge support per side (top,right,bottom,left): {[None if s is None else round(s, 2) for s in support]}']
    return QuadResult(corners=norm.tolist(), clipped_sides=clipped, score=float(score), method=method, notes=notes)


def overlay(path, results, out_path):
    """Draw detected quads on the photo for human review."""
    img = _load(path)
    H, W = img.shape[:2]
    colors = [(0, 0, 255), (0, 200, 0), (255, 0, 0)]
    for k, quad in enumerate(results):
        pts = (np.asarray(quad) * [W, H]).round().astype(np.int32)
        cv2.polylines(img, [pts], True, colors[k % 3], max(3, W // 400))
        for j, p in enumerate(pts):
            cv2.circle(img, tuple(int(v) for v in p), max(8, W // 150), colors[k % 3], -1)
            cv2.putText(img, 'TL TR BR BL'.split()[j], tuple(int(v) + 12 for v in p), cv2.FONT_HERSHEY_SIMPLEX, W / 1200, colors[k % 3], 3)
    ok, buf = cv2.imencode('.jpg', cv2.resize(img, (W // 2, H // 2)), [cv2.IMWRITE_JPEG_QUALITY, 85])
    buf.tofile(str(out_path))


def _trim_strip_ends(gray, q, sup, portrait):
    """If a short end of the strip is the image border, look along the strip for the real end:
    the first position (from the border inward) where the strip interior becomes as bright as its body."""
    q = q.copy()
    h, w = gray.shape
    # long sides: (TL->BL) and (TR->BR) for portrait; (TL->TR) and (BL->BR) otherwise
    A0, A1 = (q[0], q[3]) if portrait else (q[0], q[1])
    B0, B1 = (q[1], q[2]) if portrait else (q[3], q[2])
    ends = [(0, 'start'), (2, 'end')] if portrait else [(3, 'start'), (1, 'end')]
    def row(t):
        a = A0 + (A1 - A0) * t; b = B0 + (B1 - B0) * t
        xs = a[None, :] + np.outer(np.linspace(0.15, 0.85, 15), b - a)
        x = np.clip(xs[:, 0].round().astype(int), 0, w - 1); y = np.clip(xs[:, 1].round().astype(int), 0, h - 1)
        return float(np.median(gray[y, x]))
    ts = np.linspace(0, 1, 200)
    prof = np.array([row(t) for t in ts])
    body = float(np.median(prof[40:160]))
    for side_index, which in ends:
        if sup[side_index] is not None:
            continue
        order = range(0, 50) if which == 'start' else range(199, 149, -1)
        cut = None
        for k in order:
            window = prof[k:k + 4] if which == 'start' else prof[max(0, k - 3):k + 1]
            if (window > body * 0.85).all():
                cut = ts[k]; break
        if cut is None or (which == 'start' and cut < 0.01) or (which == 'end' and cut > 0.99):
            continue
        removed = prof[ts < cut] if which == 'start' else prof[ts > cut]
        if removed.size == 0 or float(np.mean(removed)) > body * 0.7:   # not clearly background: keep the border
            continue
        a = A0 + (A1 - A0) * cut; b = B0 + (B1 - B0) * cut
        if portrait:
            if which == 'start': q[0], q[1] = a, b
            else: q[3], q[2] = a, b
        else:
            if which == 'start': q[0], q[3] = a, b
            else: q[1], q[2] = a, b
    return q


def detect_strip(path, min_len=0.45, width_range=(0.03, 0.30)) -> QuadResult:
    """Detect a long narrow face such as a book spine. The two long sides must be real edges;
    the short ends may be real edges or the image border (spine bottom often leaves the frame)."""
    full = _load(path)
    H, W = full.shape[:2]
    s = WORK / max(H, W)
    img = cv2.resize(full, (round(W * s), round(H * s)), interpolation=cv2.INTER_AREA)
    gray = cv2.GaussianBlur(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY), (3, 3), 0)
    h, w = gray.shape
    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3); gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    grad = (gx, gy, np.hypot(gx, gy))   # no occluder handling: narrow spines carry skin-like print (orange text)
    horiz, vert = _line_candidates(gray, max_per_class=14)
    portrait = h >= w
    longs, shorts = (vert, horiz) if portrait else (horiz, vert)
    span = h if portrait else w
    best = None
    for i, a in enumerate(longs):
        for b in longs[i + 1:]:
            for j, t in enumerate(shorts):
                for u in shorts[j + 1:]:
                    pts = [_intersect(t, a), _intersect(t, b), _intersect(u, b), _intersect(u, a)]
                    if any(p is None for p in pts):
                        continue
                    q = _order(np.array(pts))
                    if (q < -0.05 * max(h, w)).any() or (q[:, 0] > 1.05 * w).any() or (q[:, 1] > 1.05 * h).any():
                        continue
                    side = [np.linalg.norm(q[k] - q[(k + 1) % 4]) for k in range(4)]
                    length = (side[1] + side[3]) / 2 if portrait else (side[0] + side[2]) / 2
                    width = (side[0] + side[2]) / 2 if portrait else (side[1] + side[3]) / 2
                    if length < min_len * span or not (width_range[0] <= width / length <= width_range[1]):
                        continue
                    sup = _edge_support(grad, q)
                    long_sides = [sup[1], sup[3]] if portrait else [sup[0], sup[2]]
                    if any(v is None for v in long_sides):
                        continue
                    shorts_known = [v for v in ([sup[0], sup[2]] if portrait else [sup[1], sup[3]]) if v is not None]
                    sc = 2.0 * min(long_sides) + 1.0 * np.mean(long_sides) + 0.5 * (np.mean(shorts_known) if shorts_known else 0.3) \
                        + 1.0 * length / span - (1.0 - _end_support(grad, q)) * 1.5
                    if best is None or sc > best[0]:
                        best = (sc, q, sup)
    if best is None:
        raise ValueError('no strip-shaped face found')
    sc, q, sup = best
    q = _trim_strip_ends(gray, q, sup, portrait)
    sup = _edge_support(grad, q)
    norm = q / [w, h]
    clipped = []
    names = ['top', 'right', 'bottom', 'left']
    for i in range(4):
        a, b = norm[i], norm[(i + 1) % 4]
        if any(abs(a[ax] - e) < 0.006 and abs(b[ax] - e) < 0.006 for ax in (0, 1) for e in (0.0, 1.0)):
            clipped.append(names[i])
    return QuadResult(corners=norm.tolist(), clipped_sides=clipped, score=float(sc), method='strip-lines',
                      notes=[f'edge support per side: {[None if v is None else round(v, 2) for v in sup]}'])
