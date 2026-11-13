"""Outline polygons and extruded flat paper geometry.

Sheet coordinates: mm, x right, y down, origin at the sheet's top-left.
World (glTF): metres, +Y up, +Z towards the viewer; the sheet is centred in
X and its bottom edge lies at y = 0; the front face of the backing is z = 0.
"""
import cv2
import mapbox_earcut as earcut
import numpy as np


def mask_polygon(mask, ppm, origin=(0.0, 0.0), smooth_mm=0.55, simplify_mm=0.05):
    """Outer outline (N x 2, sheet mm, positive signed area) of a mask.

    The pixel staircase is removed by Gaussian smoothing along the contour
    (cut paper has smooth edges), then the outline is simplified.
    """
    m = mask.astype(np.uint8)
    up = 4                                       # sub-pixel contour on an upsampled, blurred mask
    big = cv2.resize(m * 255, None, fx=up, fy=up, interpolation=cv2.INTER_LINEAR)
    big = cv2.GaussianBlur(big, (0, 0), up * 0.6)
    cs, _ = cv2.findContours((big > 127).astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    if not cs:
        return None
    c = max(cs, key=cv2.contourArea).reshape(-1, 2).astype(float)
    xy = (c + 0.5) / (up * ppm) + np.asarray(origin, float)
    step = float(np.mean(np.linalg.norm(np.diff(xy, axis=0), axis=1)))
    sig = smooth_mm / max(step, 1e-6)
    half = int(np.ceil(3 * sig))
    if half >= 1 and len(xy) > 2 * half + 3:
        k = np.exp(-0.5 * (np.arange(-half, half + 1) / sig) ** 2)
        k /= k.sum()
        xy = np.stack([np.convolve(np.concatenate([xy[-half:, i], xy[:, i], xy[:half, i]]), k, mode='valid')
                       for i in (0, 1)], 1)
    ap = cv2.approxPolyDP(xy.astype(np.float32).reshape(-1, 1, 2), simplify_mm, True).reshape(-1, 2).astype(float)
    if len(ap) < 3:
        return None
    if signed_area(ap) < 0:
        ap = ap[::-1]
    return ap


def signed_area(ring):
    x, y = ring[:, 0], ring[:, 1]
    return 0.5 * float(np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y))


def to_world(x_mm, y_mm, z_mm, sheet_w, sheet_h):
    x, y, z = (np.asarray(v, float) for v in (x_mm, y_mm, z_mm))
    x, y, z = np.broadcast_arrays(x, y, z)
    return np.stack([(x - sheet_w / 2.0) / 1000.0, (sheet_h - y) / 1000.0, z / 1000.0], 1)


def orient(tri, pos, nrm):
    """Make triangle winding agree with the vertex normals."""
    fn = np.cross(pos[tri[:, 1]] - pos[tri[:, 0]], pos[tri[:, 2]] - pos[tri[:, 0]])
    flip = (fn * nrm[tri].mean(1)).sum(1) < 0
    tri = tri.copy()
    tri[flip] = tri[flip][:, ::-1]
    return tri


def triangulate(ring):
    tri = earcut.triangulate_float64(np.ascontiguousarray(ring, np.float64),
                                     np.array([len(ring)], np.uint32))
    return np.asarray(tri, np.int64).reshape(-1, 3)


def extrude(ring, z0_mm, z1_mm, sheet_w, sheet_h):
    """Flat slab from an outline: returns dict with 'top', 'bottom', 'side'
    surfaces, each (positions, normals, triangles) in world units; 'top_xy'
    holds the sheet-mm coordinates of the top vertices (for UVs)."""
    ring = np.asarray(ring, float)
    n = len(ring)
    tri = triangulate(ring)
    if len(tri) == 0:
        raise ValueError('triangulation failed')
    top = to_world(ring[:, 0], ring[:, 1], np.full(n, z1_mm), sheet_w, sheet_h)
    bot = to_world(ring[:, 0], ring[:, 1], np.full(n, z0_mm), sheet_w, sheet_h)
    nt = np.tile([0.0, 0.0, 1.0], (n, 1))
    nb = np.tile([0.0, 0.0, -1.0], (n, 1))
    out = {'top': (top, nt, orient(tri, top, nt)), 'bottom': (bot, nb, orient(tri, bot, nb)), 'top_xy': ring}
    # side walls: vertices duplicated per segment, outward normals per vertex
    nxt = np.roll(np.arange(n), -1)
    d = ring[nxt] - ring
    o = np.stack([d[:, 1], -d[:, 0]], 1) * np.sign(signed_area(ring))   # outward (sheet coords)
    o /= np.maximum(np.linalg.norm(o, axis=1, keepdims=True), 1e-12)
    ov = o + np.roll(o, 1, axis=0)
    ov /= np.maximum(np.linalg.norm(ov, axis=1, keepdims=True), 1e-12)
    # sheet y points down, world y up
    ow = np.stack([ov[:, 0], -ov[:, 1], np.zeros(n)], 1)
    pos = np.concatenate([top, bot])
    nrm = np.concatenate([ow, ow])
    i = np.arange(n)
    st = np.concatenate([np.stack([i, nxt, nxt + n], 1), np.stack([i, nxt + n, i + n], 1)])
    out['side'] = (pos, nrm, orient(st, pos, nrm))
    return out


def merge(*surfaces):
    """Concatenate (pos, nrm, tri) tuples into one."""
    P, N, T, off = [], [], [], 0
    for p, n, t in surfaces:
        P.append(p)
        N.append(n)
        T.append(t + off)
        off += len(p)
    return np.concatenate(P), np.concatenate(N), np.concatenate(T)


def rectangle(w_mm, h_mm):
    return np.array([[0.0, 0.0], [0.0, h_mm], [w_mm, h_mm], [w_mm, 0.0]])
