#!/usr/bin/env python3
"""solid-glb: build a GLB of a simple solid object from a few photos and a JSON config.

Templates
  slab  a flat-topped object (box, board, tray, controller ...): outline traced on the top photo,
        stacked layers with their own height / inset, the rectified top photo as the top texture,
        round features (buttons, knobs, screws) and small marks on the side walls.

Commands
  grid   PHOTO OUT.jpg [x0 y0 x1 y1] [height]   photo with a labelled grid, to read positions as fractions
  build  CONFIG.json --out DIR                   model.glb, report.json, top_rectified.jpg, top_overlay.jpg
  check  DIR                                     validate, render the config's views, compare.jpg

Positions in a config are fractions of the photo (x right, y down) unless a key ends with _mm.
Output: metres, +Y up, base at y = 0, front +Z.
"""
import json, math, struct, subprocess, sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent


# ------------------------------------------------------------------ photo geometry
def quad_aspect(c, w, h):
    """Real width/depth ratio of a rectangle seen as quad c (back-left, back-right, front-right, front-left)."""
    m = np.c_[np.asarray(c, float) - [w / 2, h / 2], np.ones(4)]
    m1, m2, m4, m3 = m                                      # (0,0) (W,0) (W,D) (0,D)
    flat = (np.linalg.norm(m2 - m1) + np.linalg.norm(m4 - m3)) / (np.linalg.norm(m3 - m1) + np.linalg.norm(m4 - m2))
    k2 = np.dot(np.cross(m1, m4), m3) / np.dot(np.cross(m2, m4), m3)
    k3 = np.dot(np.cross(m1, m4), m2) / np.dot(np.cross(m3, m4), m2)
    n2, n3 = k2 * m2 - m1, k3 * m3 - m1
    if abs(n2[2] * n3[2]) < 1e-9:
        return flat, None
    f2 = -(n2[0] * n3[0] + n2[1] * n3[1]) / (n2[2] * n3[2])
    if not (0.3 * max(w, h)) ** 2 < f2 < (5 * max(w, h)) ** 2:      # implausible focal length: fall back
        return flat, None
    q = lambda n: (n[0] ** 2 + n[1] ** 2) / f2 + n[2] ** 2
    return math.sqrt(q(n2) / q(n3)), math.sqrt(f2)


class Top:
    """The top photo and its mapping to the object's top plane (x_mm to the right, z_mm towards the front)."""

    def __init__(self, cfg, base):
        self.im = cv2.imread(str(base / cfg['photo']))
        if self.im is None:
            raise SystemExit(f"cannot read {cfg['photo']}")
        h, w = self.im.shape[:2]
        self.c = np.array(cfg['corners'], float) * [w, h]
        ratio, self.focal = quad_aspect(self.c, w, h)
        self.W = float(cfg['width_mm'])
        self.D = float(cfg.get('depth_mm') or self.W / ratio)
        self.depth_assumed = 'depth_mm' not in cfg
        dst = np.array([[0, 0], [self.W, 0], [self.W, self.D], [0, self.D]], np.float32)
        self.H = cv2.getPerspectiveTransform(self.c.astype(np.float32), dst)

    def mm(self, frac):
        h, w = self.im.shape[:2]
        p = (np.asarray(frac, float).reshape(-1, 2) * [w, h]).astype(np.float32)[None]
        return cv2.perspectiveTransform(p, self.H)[0].astype(float)

    def rectified(self, ppm, margin):
        S = np.array([[ppm, 0, margin * ppm], [0, ppm, margin * ppm], [0, 0, 1]])
        size = (int(round((self.W + 2 * margin) * ppm)), int(round((self.D + 2 * margin) * ppm)))
        return cv2.warpPerspective(self.im, S @ self.H, size, flags=cv2.INTER_AREA, borderMode=cv2.BORDER_REPLICATE)


# ------------------------------------------------------------------ polygons
RPPM = 8.0   # raster used for rounding / insetting outlines (pixels per mm)


def poly_mask(poly, pad=20.0):
    lo = poly.min(0) - pad
    size = np.ceil((poly.max(0) + pad - lo) * RPPM).astype(int)
    m = np.zeros((size[1], size[0]), np.uint8)
    cv2.fillPoly(m, [np.round((poly - lo) * RPPM).astype(np.int32)], 1)
    return m, lo


def mask_poly(m, lo, eps=0.12):
    cnt = max(cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)[0], key=cv2.contourArea)
    p = cv2.approxPolyDP(cnt, eps * RPPM, True).reshape(-1, 2).astype(float) / RPPM + lo
    return ccw(p)


def ccw(p):
    a = np.sum(p[:, 0] * np.roll(p[:, 1], -1) - np.roll(p[:, 0], -1) * p[:, 1])
    return p if a > 0 else p[::-1].copy()


def disk(r_mm):
    k = max(1, int(round(r_mm * RPPM)))
    return cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * k + 1, 2 * k + 1))


def shape_outline(poly, round_mm=0.0, inset_mm=0.0):
    """Round the corners of a polygon and/or move it inwards (negative inset = outwards)."""
    m, lo = poly_mask(np.asarray(poly, float))
    if round_mm > 0:
        m = cv2.morphologyEx(cv2.morphologyEx(m, cv2.MORPH_OPEN, disk(round_mm)), cv2.MORPH_CLOSE, disk(round_mm))
    if inset_mm > 0:
        m = cv2.erode(m, disk(inset_mm))
    elif inset_mm < 0:
        m = cv2.dilate(m, disk(-inset_mm))
    return mask_poly(m, lo)


def triangulate(poly):
    import mapbox_earcut as earcut
    t = earcut.triangulate_float32(poly.astype(np.float32), np.array([len(poly)], np.uint32)).reshape(-1, 3)
    return t.astype(np.uint32)


# ------------------------------------------------------------------ meshes (mm; x right, y up, z front)
def face_up(pos, tri, want):
    n = np.cross(pos[tri[:, 1]] - pos[tri[:, 0]], pos[tri[:, 2]] - pos[tri[:, 0]])
    flip = n @ np.asarray(want, float) < 0
    tri = tri.copy(); tri[flip] = tri[flip][:, ::-1]
    return tri


def prism(poly, y0, y1, uv_of=None):
    """Extrude a polygon given in (x, z). Returns {'top','bottom','side'}: (pos, nrm, tri, uv or None)."""
    poly = ccw(np.asarray(poly, float)); n = len(poly); tri = triangulate(poly)
    cap = lambda y: np.c_[poly[:, 0], np.full(n, y), poly[:, 1]]
    top, bot = cap(y1), cap(y0)
    out = {'top': (top, np.tile([0, 1.0, 0], (n, 1)), face_up(top, tri, (0, 1, 0)), uv_of(poly) if uv_of else None),
           'bottom': (bot, np.tile([0, -1.0, 0], (n, 1)), face_up(bot, tri, (0, -1, 0)), None)}
    q = np.roll(poly, -1, 0); e = q - poly
    en = np.stack([e[:, 1], -e[:, 0]], 1); en /= np.maximum(np.linalg.norm(en, axis=1, keepdims=True), 1e-9)
    prev, nxt = np.roll(en, 1, 0), np.roll(en, -1, 0)
    smooth = lambda a, b: np.where((np.sum(a * b, 1) > 0.7)[:, None], (a + b) / np.maximum(np.linalg.norm(a + b, axis=1, keepdims=True), 1e-9), a)
    ns, ne = smooth(en, prev), smooth(en, nxt)                      # normals at the start / end of each edge
    v3 = lambda p, y: np.c_[p[:, 0], np.full(n, y), p[:, 1]]
    n3 = lambda a: np.c_[a[:, 0], np.zeros(n), a[:, 1]]
    pos = np.concatenate([v3(poly, y0), v3(q, y0), v3(q, y1), v3(poly, y1)])
    nrm = np.concatenate([n3(ns), n3(ne), n3(ne), n3(ns)])
    i = np.arange(n, dtype=np.uint32)
    st = np.concatenate([np.stack([i, i + n, i + 2 * n], 1), np.stack([i, i + 2 * n, i + 3 * n], 1)])
    out['side'] = (pos, nrm, fix_winding(pos, nrm, st), None)
    return out


def fix_winding(pos, nrm, tri):
    fn = np.cross(pos[tri[:, 1]] - pos[tri[:, 0]], pos[tri[:, 2]] - pos[tri[:, 0]])
    flip = np.sum(fn * nrm[tri[:, 0]], 1) < 0
    tri = tri.copy(); tri[flip] = tri[flip][:, ::-1]
    return tri.astype(np.uint32)


def lathe(cx, cz, y0, profile, seg=40, uv_of=None):
    """Round feature: profile = [(radius_mm, height_mm), ...] from the outer base up to the centre top."""
    pr = np.asarray(profile, float); th = np.linspace(0, 2 * np.pi, seg, endpoint=False)
    R, Yh = pr[:, 0][:, None], pr[:, 1][:, None]
    pos = np.stack([cx + R * np.cos(th), np.broadcast_to(y0 + Yh, (len(pr), seg)), cz + R * np.sin(th)], -1)
    d = np.gradient(pr, axis=0); pn = np.stack([d[:, 1], -d[:, 0]], 1)        # outward normal in (r, y)
    pn /= np.maximum(np.linalg.norm(pn, axis=1, keepdims=True), 1e-9)
    nrm = np.stack([pn[:, 0][:, None] * np.cos(th), np.broadcast_to(pn[:, 1][:, None], (len(pr), seg)), pn[:, 0][:, None] * np.sin(th)], -1)
    a, b = np.meshgrid(np.arange(len(pr) - 1), np.arange(seg), indexing='ij')
    a, b = a.ravel(), b.ravel(); b2 = (b + 1) % seg
    tri = np.concatenate([np.stack([a * seg + b, (a + 1) * seg + b, (a + 1) * seg + b2], 1),
                          np.stack([a * seg + b, (a + 1) * seg + b2, a * seg + b2], 1)])
    pos, nrm = pos.reshape(-1, 3), nrm.reshape(-1, 3)
    return pos, nrm, fix_winding(pos, nrm, tri), (uv_of(pos[:, [0, 2]]) if uv_of else None)


def merge(parts):
    pos, nrm, tri, uv, off = [], [], [], [], 0
    for p, n, t, u in parts:
        pos.append(p); nrm.append(n); tri.append(t + off); uv.append(u); off += len(p)
    has_uv = all(u is not None for u in uv)
    return np.concatenate(pos), np.concatenate(nrm), np.concatenate(tri), (np.concatenate(uv) if has_uv else None)


# ------------------------------------------------------------------ GLB
class Glb:
    def __init__(self):
        self.buf = bytearray(); self.views, self.accs, self.mats, self.meshes, self.nodes = [], [], [], [], []
        self.images, self.textures, self.tris = [], [], 0

    def _view(self, data, target=None):
        while len(self.buf) % 4: self.buf.append(0)
        v = {'buffer': 0, 'byteOffset': len(self.buf), 'byteLength': len(data)}
        if target: v['target'] = target
        self.buf.extend(data); self.views.append(v); return len(self.views) - 1

    def _acc(self, arr, typ, ctype, target, mm=False):
        arr = np.ascontiguousarray(arr)
        a = {'bufferView': self._view(arr.tobytes(), target), 'componentType': ctype,
             'count': int(arr.size if typ == 'SCALAR' else len(arr)), 'type': typ}
        if mm: a['min'], a['max'] = arr.min(0).tolist(), arr.max(0).tolist()
        self.accs.append(a); return len(self.accs) - 1

    def texture(self, bgr, quality=90):
        data = cv2.imencode('.jpg', bgr, [cv2.IMWRITE_JPEG_QUALITY, quality])[1].tobytes()
        self.images.append({'bufferView': self._view(data), 'mimeType': 'image/jpeg'})
        self.textures.append({'source': len(self.images) - 1, 'sampler': 0}); return len(self.textures) - 1

    def material(self, name, color=(0.8, 0.8, 0.8), roughness=0.6, metallic=0.0, texture=None):
        lin = lambda v: ((v + 0.055) / 1.055) ** 2.4 if v > 0.04045 else v / 12.92
        pbr = {'baseColorFactor': [lin(float(v)) for v in color[:3]] + [1.0], 'metallicFactor': float(metallic), 'roughnessFactor': float(roughness)}
        if texture is not None:
            pbr['baseColorFactor'] = [1, 1, 1, 1]; pbr['baseColorTexture'] = {'index': texture}
        self.mats.append({'name': name, 'pbrMetallicRoughness': pbr}); return len(self.mats) - 1

    def mesh(self, name, prims):
        out = []
        for mat, (pos, nrm, tri, uv) in prims:
            at = {'POSITION': self._acc((pos * 1e-3).astype('<f4'), 'VEC3', 5126, 34962, True),
                  'NORMAL': self._acc(nrm.astype('<f4'), 'VEC3', 5126, 34962)}
            if uv is not None: at['TEXCOORD_0'] = self._acc(uv.astype('<f4'), 'VEC2', 5126, 34962)
            out.append({'attributes': at, 'indices': self._acc(tri.astype('<u4').reshape(-1), 'SCALAR', 5125, 34963), 'material': mat, 'mode': 4})
            self.tris += len(tri)
        self.meshes.append({'name': name, 'primitives': out}); self.nodes.append({'name': name, 'mesh': len(self.meshes) - 1})

    def save(self, path, extras):
        n = len(self.nodes)
        g = {'asset': {'version': '2.0', 'generator': 'solid-glb'}, 'scene': 0, 'scenes': [{'nodes': [n]}],
             'nodes': self.nodes + [{'name': 'object', 'children': list(range(n)), 'extras': extras}],
             'meshes': self.meshes, 'materials': self.mats, 'accessors': self.accs, 'bufferViews': self.views}
        if self.textures:
            g.update(textures=self.textures, images=self.images, samplers=[{'magFilter': 9729, 'minFilter': 9987, 'wrapS': 33071, 'wrapT': 33071}])
        while len(self.buf) % 4: self.buf.append(0)
        g['buffers'] = [{'byteLength': len(self.buf)}]
        js = json.dumps(g, separators=(',', ':')).encode(); js += b' ' * ((4 - len(js) % 4) % 4)
        with open(path, 'wb') as f:
            f.write(struct.pack('<4sII', b'glTF', 2, 28 + len(js) + len(self.buf)))
            f.write(struct.pack('<I4s', len(js), b'JSON')); f.write(js)
            f.write(struct.pack('<I4s', len(self.buf), b'BIN\x00')); f.write(bytes(self.buf))
        return 28 + len(js) + len(self.buf)


def mat_of(glb, name, m, default):
    m = {**default, **(m or {})}
    return glb.material(name, m.get('color', (0.8, 0.8, 0.8)), m.get('roughness', 0.6), m.get('metallic', 0.0))


# ------------------------------------------------------------------ slab template
FEATURE_PROFILES = {   # (radius factor, height factor) from the outer base up to the centre
    'button': [(1.0, 0), (1.0, 0.42), (0.9, 0.5), (0.84, 0.55), (0.82, 0.88), (0.72, 1.0), (0, 1.0)],
    'dome': [(1.0, 0), (0.98, 0.3), (0.9, 0.62), (0.7, 0.88), (0.4, 0.98), (0, 1.0)],
    'disc': [(1.0, 0), (1.0, 0.85), (0.9, 1.0), (0, 1.0)],
}


def snap_circles(rect, ppm, margin, feats, tol_mm):
    """Move each round feature onto the nearest circle found in the rectified top photo (same size class)."""
    g = cv2.medianBlur(cv2.cvtColor(rect, cv2.COLOR_BGR2GRAY), 5); moved = 0
    for f in feats:
        r = f['diameter_mm'] / 2
        cs = cv2.HoughCircles(g, cv2.HOUGH_GRADIENT, dp=1.5, minDist=r * ppm, param1=90, param2=28,
                              minRadius=int(r * 0.7 * ppm), maxRadius=int(r * 1.25 * ppm))
        if cs is None: continue
        c = cs[0][:, :2] / ppm - margin
        d = np.linalg.norm(c - f['xz'], axis=1); k = int(np.argmin(d))
        if d[k] <= tol_mm:
            f['snap_mm'] = round(float(d[k]), 2); f['xz'] = c[k].astype(float); moved += 1
        else:
            f['nearest_circle_mm'] = round(float(d[k]), 2)
    return moved


def build_slab(cfg, base, out):
    top = Top(cfg['top'], base); W, D = top.W, top.D
    ppm = float(cfg.get('texture_px_per_mm', 6)); margin = 4.0
    rect = top.rectified(ppm, margin)
    raw = top.mm(cfg['outline'])
    outline = shape_outline(raw, round_mm=float(cfg.get('outline_round_mm', 0)))
    world = lambda p: np.stack([p[:, 0] - W / 2, p[:, 1] - D / 2], 1)       # canonical mm -> (x, z)
    uv_of = lambda xz: np.stack([(xz[:, 0] + W / 2 + margin) * ppm / rect.shape[1], (xz[:, 1] + D / 2 + margin) * ppm / rect.shape[0]], 1)

    glb = Glb(); tex = glb.texture(rect); m_top = glb.material('top_photo', roughness=float(cfg.get('top_roughness', 0.35)), texture=tex)
    y = 0.0; layers = []
    for i, L in enumerate(cfg['layers']):                                  # bottom to top
        poly = world(shape_outline(outline, inset_mm=float(L.get('inset_mm', 0))))
        h = float(L['height_mm']); pr = prism(poly, y, y + h, uv_of)
        m = mat_of(glb, L['name'], L.get('material'), {'color': (0.85, 0.85, 0.85)})
        textured = L.get('texture') == 'top'
        prims = [(m_top, pr['top'])] if textured else [(m, pr['top'][:3] + (None,))]
        prims.append((m, merge([pr['side'], pr['bottom']])))
        glb.mesh(L['name'], prims); layers.append({'name': L['name'], 'y0_mm': y, 'y1_mm': y + h, 'points': len(poly)}); y += h
    top_y = y

    feats = []
    for grp in cfg.get('features', []):
        for at in grp['at']:
            feats.append({'group': grp['name'], 'xz': top.mm([at])[0], 'diameter_mm': float(grp['diameter_mm'])})
    snapped = snap_circles(rect, ppm, margin, [f for f in feats if cfg_group(cfg, f['group']).get('snap', True)],
                           float(cfg.get('snap_tolerance_mm', 4))) if feats else 0
    for grp in cfg.get('features', []):
        prof = FEATURE_PROFILES[grp.get('shape', 'button')]; r, h = grp['diameter_mm'] / 2, float(grp['height_mm'])
        textured = grp.get('texture') == 'top'
        parts = [lathe(*(world(f['xz'][None])[0]), top_y, [(a * r, b * h) for a, b in prof], uv_of=uv_of if textured else None)
                 for f in feats if f['group'] == grp['name']]
        if parts:
            m = m_top if textured else mat_of(glb, grp['name'], grp.get('material'), {'color': (0.8, 0.8, 0.8)})
            glb.mesh(grp['name'], [(m, merge(parts))])

    body = {L['name']: L for L in layers}
    for mk in cfg.get('side_marks', []):                                   # dark rectangles on a side wall of one layer
        L = body[mk['layer']]; poly = world(shape_outline(outline, inset_mm=float(cfg_layer(cfg, mk['layer']).get('inset_mm', 0))))
        w_, h_ = mk['size_mm']; yc = L['y0_mm'] + mk.get('height_frac', 0.5) * (L['y1_mm'] - L['y0_mm'])
        axis, sign = {'front': (1, 1), 'back': (1, -1), 'right': (0, 1), 'left': (0, -1)}[mk['side']]
        other = 1 - axis; c = (mk.get('along_frac', 0.5) - 0.5) * (W if other == 0 else D)
        a_, b_ = poly, np.roll(poly, -1, 0)                         # where the wall is, at this position along the side
        cross = (a_[:, other] - c) * (b_[:, other] - c) <= 0
        t_ = (c - a_[cross, other]) / np.where(b_[cross, other] == a_[cross, other], 1, b_[cross, other] - a_[cross, other])
        hits = a_[cross, axis] + t_ * (b_[cross, axis] - a_[cross, axis])
        edge = (hits.max() if sign > 0 else hits.min()) + sign * 0.06
        q = np.zeros((4, 3)); q[:, 1] = [yc - h_ / 2, yc - h_ / 2, yc + h_ / 2, yc + h_ / 2]
        q[:, 0 if other == 0 else 2] = [c - w_ / 2, c + w_ / 2, c + w_ / 2, c - w_ / 2]; q[:, 0 if axis == 0 else 2] = edge
        nv = np.zeros(3); nv[0 if axis == 0 else 2] = sign
        m = mat_of(glb, mk.get('name', 'mark'), mk.get('material'), {'color': (0.05, 0.05, 0.05), 'roughness': 0.5})
        glb.mesh(mk.get('name', 'mark'), [(m, (q, np.tile(nv, (4, 1)), face_up(q, np.array([[0, 1, 2], [0, 2, 3]], np.uint32), nv), None))])

    size = glb.save(out / 'model.glb', {'units': 'metres', 'up': '+Y', 'front': '+Z', 'template': 'slab', 'size_mm': [round(W, 1), round(top_y, 1), round(D, 1)]})
    cv2.imwrite(str(out / 'top_rectified.jpg'), rect)
    ov = rect.copy(); px = lambda p: np.round((p + margin) * ppm).astype(np.int32)
    cv2.polylines(ov, [px(outline)], True, (0, 255, 0), 2)
    for f in feats:
        cv2.circle(ov, tuple(px(f['xz'][None])[0]), int(f['diameter_mm'] / 2 * ppm), (0, 0, 255), 2)
    cv2.imwrite(str(out / 'top_overlay.jpg'), ov)
    return {'template': 'slab', 'size_mm': {'width': round(W, 1), 'depth': round(D, 1), 'height': round(top_y, 1)},
            'depth_from_photo': top.depth_assumed, 'focal_px': top.focal and round(top.focal), 'outline_points': len(outline), 'layers': layers,
            'features': {g['name']: sum(f['group'] == g['name'] for f in feats) for g in cfg.get('features', [])},
            'features_snapped': snapped, 'features_not_snapped': [f['group'] for f in feats if 'snap_mm' not in f and cfg_group(cfg, f['group']).get('snap', True)],
            'feature_list': [{'group': f['group'], 'x_mm': round(float(f['xz'][0]), 2), 'z_mm': round(float(f['xz'][1]), 2),
                              'moved_mm': f.get('snap_mm'), 'nearest_circle_mm': f.get('nearest_circle_mm')} for f in feats],
            'triangles': glb.tris, 'bytes': size}


cfg_group = lambda cfg, name: next(g for g in cfg['features'] if g['name'] == name)
cfg_layer = lambda cfg, name: next(L for L in cfg['layers'] if L['name'] == name)


# ------------------------------------------------------------------ commands
def cmd_grid(a):
    im = cv2.imread(a[0]); H, W = im.shape[:2]
    box = [float(v) for v in a[2:6]] if len(a) >= 6 else [0, 0, 1, 1]
    hp = int(a[6]) if len(a) >= 7 else 1200
    c = im[int(box[1] * H):int(box[3] * H), int(box[0] * W):int(box[2] * W)]
    c = cv2.resize(c, None, fx=hp / c.shape[0], fy=hp / c.shape[0], interpolation=cv2.INTER_AREA)
    span = max(box[2] - box[0], box[3] - box[1]); step = 0.1 if span > 0.6 else 0.05 if span > 0.25 else 0.02
    for k in np.arange(0, 1.0001, step / 2):
        major = abs(k / step - round(k / step)) < 1e-6
        for ax, (lo, hi, n) in enumerate(((box[0], box[2], c.shape[1]), (box[1], box[3], c.shape[0]))):
            if not lo <= k <= hi: continue
            p = int((k - lo) / (hi - lo) * (n - 1)); col = (0, 255, 255) if major else (0, 150, 150)
            cv2.line(c, (p, 0), (p, c.shape[0]), col, 1) if ax == 0 else cv2.line(c, (0, p), (c.shape[1], p), col, 1)
            if major:
                org = (p + 3, 14) if ax == 0 else (3, p - 4)
                cv2.putText(c, f'{k:.2f}', org, cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 0), 3)
                cv2.putText(c, f'{k:.2f}', org, cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 255), 1)
    cv2.imwrite(a[1], c, [cv2.IMWRITE_JPEG_QUALITY, 85]); print(f'photo {W}x{H}, grid image {c.shape[1]}x{c.shape[0]}, lines every {step / 2:g}')


def cmd_build(a):
    cfg_path = Path(a[0]).resolve(); out = Path(a[a.index('--out') + 1]); out.mkdir(parents=True, exist_ok=True)
    cfg = json.loads(cfg_path.read_text())
    if cfg['template'] == 'slab':
        rep = build_slab(cfg, cfg_path.parent, out)
    else:
        raise SystemExit(f"unknown template {cfg['template']!r} (this version has only 'slab')")
    rep['config'] = str(cfg_path)
    (out / 'report.json').write_text(json.dumps(rep, indent=1, ensure_ascii=False))
    print(json.dumps({k: v for k, v in rep.items() if k not in ('layers', 'config', 'feature_list')}, ensure_ascii=False))
    far = [f for f in rep.get('feature_list', []) if (f['moved_mm'] or 0) > 2.5]
    if far:
        print('moved more than 2.5 mm by the circle search (check top_overlay.jpg):', json.dumps(far))


def cmd_check(a):
    out = Path(a[0]).resolve(); rep = json.loads((out / 'report.json').read_text())
    cfg_path = Path(rep['config']); cfg = json.loads(cfg_path.read_text())
    views = cfg.get('views') or [{'name': 'top', 'az': 0, 'el': 89.9, 'up': [0, 0, -1]}, {'name': 'front', 'az': 0, 'el': 15}, {'name': 'oblique', 'az': 35, 'el': 30}]
    (out / 'views.json').write_text(json.dumps(views))
    r = subprocess.run(['node', str(HERE / 'render.cjs'), str(out / 'model.glb'), str(out), str(out / 'views.json')], capture_output=True, text=True, cwd=HERE)
    print(r.stdout.strip() or r.stderr.strip()[-600:])
    if r.returncode: raise SystemExit(1)
    Hh, rows = 520, []
    fit = lambda im: cv2.resize(im, (int(im.shape[1] * Hh / im.shape[0]), Hh), interpolation=cv2.INTER_AREA)
    cells = []
    for v in views:
        rd = fit(cv2.imread(str(out / f"{v['name']}.png")))
        if v.get('photo'):
            ph = fit(cv2.imread(str(cfg_path.parent / v['photo'])))
            cells.append(np.hstack([ph, np.full((Hh, 6, 3), 255, np.uint8), rd]))
        else:
            cells.append(rd)
    wmax = max(c.shape[1] for c in cells) * 2 + 16
    row = []
    for c in cells:
        if row and sum(x.shape[1] for x in row) + c.shape[1] + 16 > wmax:
            rows.append(row); row = []
        row.append(c)
    rows.append(row)
    canvas = []
    for row in rows:
        line = np.hstack([np.hstack([c, np.full((Hh, 16, 3), 255, np.uint8)]) for c in row])
        canvas.append(cv2.copyMakeBorder(line, 0, 12, 0, wmax + 32 - line.shape[1], cv2.BORDER_CONSTANT, value=(255, 255, 255)))
    cv2.imwrite(str(out / 'compare.jpg'), np.vstack(canvas), [cv2.IMWRITE_JPEG_QUALITY, 86])
    print('compare.jpg: each cell is photo | render, in the order', [v['name'] for v in views])


if __name__ == '__main__':
    cmds = {'grid': cmd_grid, 'build': cmd_build, 'check': cmd_check}
    if len(sys.argv) < 3 or sys.argv[1] not in cmds:
        raise SystemExit(__doc__)
    cmds[sys.argv[1]](sys.argv[2:])
