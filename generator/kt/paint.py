"""Materials for a generated mesh (kt gen --material regions): the program projects the photos onto the shape,
groups its surface and finds candidate marks; one AI call decides the material of each group and which marks
are real. Same split as `box --look ai`: the program measures, the AI judges, the program builds.

1. Cameras: for each photo a perspective camera is fitted to its cut-out with Katachi's camera registration
   (silhouette only, a local search around the photo's yaw / pitch). For the photos other than the main one the
   four quarter-turn yaw offsets are tried first, since the routing AI's directions can be off. A silhouette
   cannot tell the top from the underside of a symmetric object, so the main photo (the one the shape was
   generated from) colours every triangle it sees; the other photos only colour what it does not see, best
   fit first.
2. Projection: the mesh is drawn into each photo (nearest triangle per pixel, far-to-near), so every visible
   triangle gets the mean colour of the photo pixels it covers, inside the cut-out only (no background, no hand).
3. Light changes slowly over a surface, a printed mark changes sharply. The triangle colours are smoothed over
   the mesh before grouping (k-means in CIELAB, majority smoothing, small pieces absorbed, unseen triangles take
   their neighbours' region), so the groups follow materials and broad light, not marks. Marks are found in the
   sharp part of each photo (photo minus its blur, inside the cut-out): connected spots that stand out from the
   photo's own noise (3 x its robust spread, at least one just-noticeable colour difference).
4. One AI call sees the photos, the photo colours on the shape, the numbered regions and the numbered marks. It
   gives every region a material (light, i.e. reflections, highlights and shadows, gets the material of the
   surface it lies on) and lists the marks that are real (printed symbols, text, logos, labels) with their colour.
5. Borders between different materials move onto nearby creases of the shape (minimum cut: cutting a smooth surface
   is expensive, cutting at a crease is cheap), since the photo and the generated shape never match exactly.
6. Output: each region a plain PBR material; around the kept marks the triangles carry a texture = the region's
   material colour with the marks painted in (flat colour, or the photo's detail for multi-coloured print),
   mapped from the photo that coloured them. Reflections are not baked in anywhere.
The program holds no object knowledge and no thresholds fitted to examples. MAX_REGIONS / MAX_MARKS are display
limits (how many numbered items the AI is shown); the *_SCALE values are sizes as a share of the object's size.
"""
from __future__ import annotations
import json
import math
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np

MAX_REGIONS = 6          # numbered regions shown to the AI (display limit)
MAX_MARKS = 24           # numbered mark candidates shown to the AI, all photos together (display limit)
FIT_RESOLUTION = 192     # silhouette size for the camera fit (Katachi allows 64..384)
DETAIL_SCALE = 0.012     # blur sigma for the detail image, share of the object's diagonal in the photo
JOIN_SCALE = 0.003       # gaps inside one mark (strokes of a symbol) closed up to this, share of the diagonal
MIN_MARK_SCALE = 0.006   # marks smaller than this (side of a square, share of the diagonal) are noise
MAX_MARK_SHARE = 0.05    # a spot larger than this share of the object is a region, not a mark
JND = 2.3                # just-noticeable colour difference (CIELAB delta E)
SMOOTH_SCALE = 0.04      # smoothing radius of the triangle colours before grouping, share of the model's diagonal
SNAP_SCALE = 0.05        # how far a material border may move to reach a crease (photo-to-shape misfit), share of the diagonal
CREASE_SCALE = 0.015     # radius at which creases are measured, share of the diagonal
MIN_PIECE = 0.002        # pieces of a region smaller than this share of the surface join their surroundings
TEXTURE_MAX = 2048       # longest side of a mark texture

SYSTEM = ('You decide the materials of a 3D model from photos of the real object. '
          'Answer only through the JSON schema. Be concise.')
TASK = """Image 1: the photos of the object. Image 2: the 3D shape that was generated from them, with the photo
colours projected onto it by a program (the first view is from the main photo's camera). Where a photo is slightly
misaligned, colours bleed over edges; surfaces no photo saw took the colour of their neighbours.
Image 3: the same views with the surface split into numbered regions (false colours; the numbers are region ids).
The program grouped smoothed colours, so a region is a broad area of one colour or one kind of light; small marks
(printed symbols, text, logos) are not regions of their own.
Image 4 (if present): the photos with candidate marks outlined and numbered (red = darker, blue = brighter than
their surroundings). Candidates are spots that differ sharply from their surroundings: real marks, but also
reflections, glare, shadows, dust, shape edges and seams.
1. regions: for every region the material: the base colour of the surface (sRGB 0..1) as it looks under neutral
   white light, roughness and metallic, and what the region is. A region can be a real part (a cap, a body, a
   different material) or only light on a surface (a reflection, a highlight, a shadow, a colour cast): light gets
   the material of the surface it lies on. Regions that are the same material must get exactly the same values,
   or the model shows patches. The model is shown under studio light without a room to reflect, so metallic above
   about 0.5 looks much darker than the photos.
2. marks: list only the candidates that are real marks printed on or set into the surface (symbols, text, logos,
   labels, small parts of another colour) and should be reproduced; leave out reflections, glare, shadows, dust,
   shape edges, holes and seams (the shape already has those), and anything you are unsure about. color_rgb: the
   mark's own colour under white light. photo_detail: true only for a multi-coloured or very fine print (a picture,
   small text) that one colour cannot reproduce; the photo's detail is then used on top of the region's material.
Measurements (area in % of the surface or, for marks, of the object in that photo; seen = share the photos saw;
colour = mean photo colour, sRGB 0..1; lightness_spread = spread of CIELAB L* inside the region; contrast = mean
CIELAB difference from the surroundings; pieces = separate patches; normal = mean surface direction, y up):"""
_COL = {'type': 'array', 'items': {'type': 'number'}, 'minItems': 3, 'maxItems': 3}
SCHEMA = {
    'type': 'object',
    'properties': {
        'object': {'type': 'string'},
        'regions': {'type': 'array', 'items': {'type': 'object', 'properties': {
            'id': {'type': 'integer'}, 'what': {'type': 'string'}, 'color_rgb': _COL,
            'roughness': {'type': 'number'}, 'metallic': {'type': 'number'}},
            'required': ['id', 'what', 'color_rgb', 'roughness', 'metallic']}},
        'marks': {'type': 'array', 'items': {'type': 'object', 'properties': {
            'id': {'type': 'integer'}, 'what': {'type': 'string'}, 'color_rgb': _COL, 'photo_detail': {'type': 'boolean'}},
            'required': ['id', 'what', 'color_rgb', 'photo_detail']}},
        'notes': {'type': 'string'}},
    'required': ['object', 'regions', 'marks', 'notes'],
}
PALETTE = [(230, 25, 75), (60, 180, 75), (0, 130, 200), (245, 130, 48), (145, 30, 180), (70, 240, 240),
           (240, 50, 230), (210, 245, 60), (250, 190, 212), (0, 128, 128), (170, 110, 40), (128, 0, 0)]  # RGB


# ------------------------------------------------------------------ cameras
def _geometry(points, faces):
    from katachi.camera import ProjectionGeometry

    @dataclass(frozen=True)
    class Geometry(ProjectionGeometry):        # Katachi's landmark lookup reads .parts; a bare mesh has none
        parts: tuple = ()
    return Geometry(np.asarray(points, float), np.asarray(faces, np.int64))


def _reference(mask_path, yaw, pitch, camera=None):
    return SimpleNamespace(mask_path=str(mask_path), frame=None, camera=camera, yaw_deg=float(yaw),
                           pitch_deg=float(np.clip(pitch, -89.9, 89.9)), landmarks=[])


def _iou(geom, camera, mask_small):
    from katachi.camera import rasterize_silhouette
    from katachi.metrics import silhouette_score
    h, w = mask_small.shape
    return silhouette_score(rasterize_silhouette(geom, camera, None, [w, h]), mask_small)['iou']


def fit_camera(geom, mask_path, yaw, pitch, try_quarter_turns=False) -> dict:
    """Perspective camera for one photo, fitted to its cut-out (Katachi: initialize_camera + register_camera)."""
    from PIL import Image
    from katachi.camera import initialize_camera, register_camera
    from katachi.view_schema import CameraFitConfig
    with Image.open(mask_path) as im:
        W, H = im.size
        s = FIT_RESOLUTION / max(W, H)
        small = np.array(im.convert('L').resize((max(16, round(W * s)), max(16, round(H * s))), Image.NEAREST)) > 127
    tried = {}
    for off in ((0, 90, 180, 270) if try_quarter_turns else (0,)):
        y = (yaw + off + 180) % 360 - 180
        cam = initialize_camera(geom, _reference(mask_path, y, pitch), 'perspective')
        tried[off] = (round(_iou(geom, cam, small), 3), cam)
    off = max(tried, key=lambda k: (tried[k][0], -min(k, 360 - k)))
    start = tried[off][1]
    cfg = CameraFitConfig(max_evaluations=160, resolution=FIT_RESOLUTION, time_limit_seconds=40, angle_radius_deg=20)
    cam, info = register_camera(geom, _reference(mask_path, start.yaw_deg, start.pitch_deg, start), cfg)
    return {'camera': cam, 'iou': round(float(info['final']['iou']), 3), 'iou_start': tried[off][0],
            'yaw_offset_deg': off, 'tried_offsets_iou': {k: v[0] for k, v in tried.items()},
            'yaw_deg': round(cam.yaw_deg, 1), 'pitch_deg': round(cam.pitch_deg, 1), 'roll_deg': round(cam.roll_deg, 1),
            'status': info.get('status')}


# ------------------------------------------------------------------ drawing (nearest triangle per pixel)
def face_ids(px, depth, faces, size) -> np.ndarray:
    """Triangle index per pixel (-1 = none), drawn far to near. px: (N, 2) pixel coordinates; depth: distance
    from the camera (larger = farther)."""
    w, h = size
    img = np.zeros((h, w), np.int32)
    tri = np.round(np.asarray(px)[faces] * 16).astype(np.int32)
    for f in np.argsort(-np.asarray(depth)[faces].mean(1)):
        cv2.fillConvexPoly(img, tri[f], int(f) + 1, shift=4)
    return img - 1


def photo_uv(geom, camera, size):
    """Vertex positions in the photo, as fractions of its width / height (y down), and their depth."""
    from katachi.camera import project_world
    from katachi.view_schema import ImageFrame
    pr = project_world(geom.points, camera, ImageFrame.identity(list(size)))
    return pr.uv, pr.depth


def lab_image(bgr):
    return cv2.cvtColor(bgr.astype(np.float32) / 255, cv2.COLOR_BGR2LAB)


def lab_to_rgb(lab) -> np.ndarray:
    lab = np.asarray(lab, np.float32).reshape(-1, 1, 3)
    return np.clip(cv2.cvtColor(lab, cv2.COLOR_LAB2RGB).reshape(-1, 3), 0, 1)


def rgb_to_lab(rgb) -> np.ndarray:
    rgb = np.asarray(rgb, np.float32).reshape(-1, 1, 3)
    return cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB).reshape(-1, 3)


def detail_image(lab, mask, sigma):
    """The sharp part of a photo (CIELAB): photo minus its blur, the blur taken inside the cut-out only."""
    m = mask.astype(np.float32)
    blur = cv2.GaussianBlur(lab * m[..., None], (0, 0), sigma)
    wts = cv2.GaussianBlur(m, (0, 0), sigma)[..., None]
    return np.where(m[..., None] > 0, lab - blur / np.maximum(wts, 1e-6), 0)


# ------------------------------------------------------------------ regions on the mesh
def adjacency(mesh):
    from scipy.sparse import coo_matrix
    a = np.asarray(mesh.face_adjacency)
    F = len(mesh.faces)
    i, j = np.r_[a[:, 0], a[:, 1]], np.r_[a[:, 1], a[:, 0]]
    return coo_matrix((np.ones(len(i)), (i, j)), shape=(F, F)).tocsr()


def smooth_values(A, values, weights, steps):
    """Weighted neighbour averaging over the mesh (`steps` rounds); triangles with weight 0 take what flows in."""
    v = np.asarray(values, float) * weights[:, None]
    w = np.asarray(weights, float).copy()
    norm = 1.0 / (np.asarray(A.sum(1)).ravel() + 1)
    for _ in range(steps):
        v = (A @ v + v) * norm[:, None]
        w = (A @ w + w) * norm
    return v / np.maximum(w, 1e-12)[:, None], w > 0


def kmeans(X, w, k, iters=40, seed=0):
    """Weighted k-means (k-means++ start, fixed seed). Returns labels and centres."""
    rng = np.random.default_rng(seed)
    p = w / w.sum()
    C = [X[rng.choice(len(X), p=p)]]
    for _ in range(1, k):
        d = np.min(((X[:, None] - np.asarray(C)[None]) ** 2).sum(-1), 1) * w
        if d.sum() <= 0:
            break
        C.append(X[rng.choice(len(X), p=d / d.sum())])
    C = np.asarray(C, float)
    for _ in range(iters):
        lab = np.argmin(((X[:, None] - C[None]) ** 2).sum(-1), 1)
        new = np.array([np.average(X[lab == j], 0, w[lab == j]) if w[lab == j].sum() > 0 else C[j] for j in range(len(C))])
        if np.allclose(new, C, atol=1e-4):
            break
        C = new
    return np.argmin(((X[:, None] - C[None]) ** 2).sum(-1), 1), C


def _vote(A, labels, k, keep_self=True):
    """Per triangle, the label most common among its neighbours (and itself); unlabelled (-1) do not vote."""
    one = np.zeros((len(labels), k))
    ok = labels >= 0
    one[np.flatnonzero(ok), labels[ok]] = 1
    votes = A @ one + (one if keep_self else 0)
    best = votes.argmax(1)
    has = votes.max(1) > 0
    if keep_self:            # a tie keeps the triangle's own label
        own = np.where(ok, labels, 0)
        tie = ok & (votes[np.arange(len(labels)), own] >= votes.max(1))
        best = np.where(tie, own, best)
    return np.where(has, best, -1)


def _flood(A, labels, k):
    for _ in range(len(labels)):
        todo = labels < 0
        if not todo.any():
            break
        fill = _vote(A, labels, k, keep_self=False)
        new = np.where(todo & (fill >= 0), fill, labels)
        if np.array_equal(new, labels):
            break
        labels = new
    return labels


def _pieces(A, labels):
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components
    coo = A.tocoo()
    same = labels[coo.row] == labels[coo.col]
    S = coo_matrix((np.ones(same.sum()), (coo.row[same], coo.col[same])), shape=A.shape)
    return connected_components(S, directed=False)[1]


def segment(mesh, A, colour_lab, seen, k=MAX_REGIONS):
    """Regions numbered 1.. by area: k-means of the smoothed colours of the seen triangles (weighted by area),
    majority smoothing, small pieces absorbed by their surroundings, unseen triangles flooded from neighbours."""
    area = np.asarray(mesh.area_faces)
    steps = max(1, int(round((SMOOTH_SCALE * np.linalg.norm(np.ptp(mesh.vertices, 0)) / max(np.sqrt(area.mean() * 2), 1e-12)) ** 2)))
    smooth, _ = smooth_values(A, colour_lab, area * seen, min(steps, 400))
    idx = np.flatnonzero(seen)
    k = int(min(k, max(1, len(idx))))
    lab0, _ = kmeans(smooth[idx], area[idx], k)
    labels = np.full(len(area), -1)
    labels[idx] = lab0
    for _ in range(3):
        labels = np.where(labels >= 0, _vote(A, labels, k), -1)
    labels = _flood(A, labels, k)
    total = area.sum()
    for _ in range(3):                                # small pieces join what surrounds them
        comp = _pieces(A, labels)
        small = np.bincount(comp, weights=area)[comp] < MIN_PIECE * total
        if not small.any():
            break
        labels = _flood(A, np.where(small, -1, labels), k)
    labels[labels < 0] = 0
    order = np.argsort([-area[labels == j].sum() for j in range(k)])
    remap = np.empty(k, int)
    remap[order] = np.arange(1, k + 1)
    labels = remap[labels]
    return labels, [r for r in range(1, k + 1) if (labels == r).any()], steps


def region_stats(mesh, labels, regions, A, colour_lab, seen) -> list:
    area = np.asarray(mesh.area_faces)
    total = area.sum()
    comp = _pieces(A, labels)
    out = []
    for r in regions:
        m = labels == r
        sm = m & seen
        wts = area[sm]
        lab = np.average(colour_lab[sm], 0, wts) if wts.sum() > 0 else np.array([50., 0, 0])
        n = (np.asarray(mesh.face_normals)[m] * area[m, None]).sum(0)
        n = n / max(np.linalg.norm(n), 1e-12)
        out.append({'id': int(r), 'area_pct': round(100 * area[m].sum() / total, 2),
                    'seen_pct': round(100 * area[sm].sum() / max(area[m].sum(), 1e-12), 1),
                    'colour_rgb': [round(float(v), 3) for v in lab_to_rgb(lab)[0]],
                    'lightness_spread': round(float(np.sqrt(np.average((colour_lab[sm, 0] - lab[0]) ** 2, weights=wts))), 1) if wts.sum() > 0 else None,
                    'pieces': int(len(np.unique(comp[m]))), 'normal': [round(float(v), 2) for v in n]})
    return out


# ------------------------------------------------------------------ marks (candidates for the AI)
def find_marks(det, lab, area, diag_px) -> list:
    """Connected spots of the detail image that stand out from the photo's own noise, inside `area` (the pixels
    whose triangles this photo colours). Each: its pixel mask, polarity, size, contrast, colour."""
    mag = np.linalg.norm(det, axis=2)
    v = mag[area]
    if v.size < 100:
        return []
    noise = 1.4826 * float(np.median(np.abs(v - np.median(v))))
    raw = (mag > max(3 * noise, JND)) & area
    j = max(1, int(round(JOIN_SCALE * diag_px)))
    joined = cv2.morphologyEx(raw.astype(np.uint8), cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * j + 1,) * 2)) & area
    n, cc, st, _ = cv2.connectedComponentsWithStats(joined.astype(np.uint8), connectivity=8)
    lo, hi = (MIN_MARK_SCALE * diag_px) ** 2, MAX_MARK_SHARE * area.sum()
    out = []
    for i in range(1, n):
        a = int(st[i, cv2.CC_STAT_AREA])
        if a < lo or a > hi:
            continue
        x, y, w, h = (int(t) for t in st[i, :4])
        comp = (cc[y:y + h, x:x + w] == i) & raw[y:y + h, x:x + w]     # the mark's own pixels (strokes), not the gaps
        if not comp.any():
            continue
        d = det[y:y + h, x:x + w][comp]
        out.append({'box': (x, y, w, h), 'comp': comp, 'area_px': a,
                    'polarity': 'brighter' if d[:, 0].mean() > 0 else 'darker',
                    'contrast': round(float(np.linalg.norm(d, axis=1).mean()), 1),
                    'colour_rgb': [round(float(c), 3) for c in lab_to_rgb(lab[y:y + h, x:x + w][comp].mean(0))[0]],
                    'elongation': round(float(max(w, h) / max(1, min(w, h))), 1)})
    return out


def marks_image(views, marks, order):
    """The photos (cropped to the object) with the candidate marks outlined and numbered."""
    tiles = []
    for k in order:
        mk = [m for m in marks if m['photo'] == k]
        if not mk:
            continue
        v = views[k]
        img = v['bgr'].copy()
        for m in mk:
            x, y, w, h = m['box']
            full = np.zeros(img.shape[:2], np.uint8)
            full[y:y + h, x:x + w] = m['comp']
            cs, _ = cv2.findContours(full, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
            cv2.drawContours(img, cs, -1, (0, 0, 255) if m['polarity'] == 'darker' else (255, 128, 0), 2)
        x0, y0, x1, y1 = v['box']
        crop = img[y0:y1, x0:x1].copy()
        s = 900 / max(crop.shape[:2])
        crop = cv2.resize(crop, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
        for m in mk:
            x, y, w, h = m['box']
            px, py = int((x + w + 2 - x0) * s), int((y - y0) * s) + 6
            for col, th in (((255, 255, 255), 5), ((0, 0, 0), 2)):
                cv2.putText(crop, str(m['id']), (px, py), cv2.FONT_HERSHEY_SIMPLEX, 0.7, col, th)
        cv2.putText(crop, k, (8, 30), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 0, 0), 2)
        tiles.append(crop)
    if not tiles:
        return None
    h = max(t.shape[0] for t in tiles)
    return np.hstack([np.pad(t, ((0, h - t.shape[0]), (0, 8), (0, 0)), constant_values=255) for t in tiles])


# ------------------------------------------------------------------ pictures for the AI and the report
def _basis(yaw, pitch):                       # katachi.render.camera_basis (legacy yaw / pitch views)
    a, b = math.radians(yaw), math.radians(pitch)
    fwd = np.array([math.sin(a) * math.cos(b), math.sin(b), math.cos(a) * math.cos(b)])
    right = np.cross([0, 1, 0], fwd)
    right /= np.linalg.norm(right)
    return right, np.cross(fwd, right), fwd


def ortho_ids(points, faces, yaw, pitch, size=420, margin=0.06):
    right, up, fwd = _basis(yaw, pitch)
    P = np.asarray(points) - np.asarray(points).mean(0)
    xy = np.stack([P @ right, -(P @ up)], 1)
    lo, hi = xy.min(0), xy.max(0)
    s = size * (1 - 2 * margin) / max((hi - lo).max(), 1e-12)
    px = (xy - (lo + hi) / 2) * s + size / 2
    return face_ids(px, -(P @ fwd), faces, (size, size))


def shade(mesh, ids, face_rgb, light_dir):
    n = np.asarray(mesh.face_normals)
    lam = 0.45 + 0.55 * np.clip(n @ (np.asarray(light_dir) / np.linalg.norm(light_dir)), 0, 1)
    img = np.full(ids.shape + (3,), 255, np.uint8)
    m = ids >= 0
    img[m] = np.clip(np.asarray(face_rgb)[ids[m]] * lam[ids[m], None] * 255, 0, 255).astype(np.uint8)
    return img                                       # RGB


def number_regions(img_rgb, ids, labels, regions):
    out = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2BGR)
    lab_img = np.where(ids >= 0, labels[np.maximum(ids, 0)], 0)
    for r in regions:
        n, cc, st, cen = cv2.connectedComponentsWithStats((lab_img == r).astype(np.uint8))
        if n <= 1:
            continue
        j = 1 + int(np.argmax(st[1:, cv2.CC_STAT_AREA]))
        if st[j, cv2.CC_STAT_AREA] < 0.002 * ids.size:
            continue
        ys, xs = np.nonzero(cv2.erode((cc == j).astype(np.uint8), np.ones((9, 9), np.uint8)) | 0)
        if not len(xs):
            ys, xs = np.nonzero(cc == j)
        k = np.argmin((xs - cen[j][0]) ** 2 + (ys - cen[j][1]) ** 2)    # a pixel of the blob near its centre
        x, y = int(xs[k]), int(ys[k])
        s = max(0.6, ids.shape[0] / 600)
        for col, th in (((255, 255, 255), max(3, int(5 * s))), ((0, 0, 0), max(2, int(2 * s)))):
            cv2.putText(out, str(r), (x - int(9 * s), y + int(9 * s)), cv2.FONT_HERSHEY_SIMPLEX, s, col, th)
    return out


def _crop_box(mask, pad=0.04):
    ys, xs = np.nonzero(mask)
    p = int(pad * max(np.ptp(xs), np.ptp(ys)))
    return max(0, xs.min() - p), max(0, ys.min() - p), min(mask.shape[1], xs.max() + p + 1), min(mask.shape[0], ys.max() + p + 1)


def _fit_tile(img, size):
    ys, xs = np.nonzero((img < 250).any(2))
    if len(xs):
        pad = 12
        img = img[max(0, ys.min() - pad):ys.max() + pad, max(0, xs.min() - pad):xs.max() + pad]
    s = size / max(img.shape[:2])
    img = cv2.resize(img, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
    c = np.full((size, size, 3), 255, np.uint8)
    y0, x0 = (size - img.shape[0]) // 2, (size - img.shape[1]) // 2
    c[y0:y0 + img.shape[0], x0:x0 + img.shape[1]] = img
    return c


VIEWS = ((35, 25), (215, 25), (125, -40))        # besides the main photo's own view


# ------------------------------------------------------------------ the whole analysis
def analyse(mesh, photos: list, out_dir: Path, main_key: str) -> dict:
    """photos: [{'key', 'image' (source png), 'mask' (png), 'yaw', 'pitch'}]. Writes fit overlays, region and mark
    pictures and paint.json to out_dir; returns what the AI call and build_scene need."""
    from PIL import Image
    from katachi.camera import camera_basis
    from kt.inspect import _imread
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    mesh = mesh.copy()
    mesh.fix_normals()                                # outward normals for the shading (face order is kept)
    pts, faces = np.asarray(mesh.vertices, float), np.asarray(mesh.faces, np.int64)
    geom = _geometry(pts, faces)
    with ThreadPoolExecutor(max_workers=len(photos)) as ex:
        fits = dict(zip([p['key'] for p in photos], ex.map(
            lambda p: fit_camera(geom, p['mask'], p['yaw'], p['pitch'], try_quarter_turns=p['key'] != main_key), photos)))
    order = [main_key] + sorted((p['key'] for p in photos if p['key'] != main_key), key=lambda k: -fits[k]['iou'])
    byk = {p['key']: p for p in photos}
    F = len(faces)
    source = np.full(F, -1)
    colour = np.zeros((F, 3))
    views = {}
    for n, k in enumerate(order):
        p, f = byk[k], fits[k]
        img = _imread(p['image'])
        with Image.open(p['mask']) as im:             # cv2.imread cannot open non-ASCII paths on Windows
            mask = np.array(im.convert('L')) > 127
        h, w = mask.shape
        uv, depth = photo_uv(geom, f['camera'], (w, h))
        ids = face_ids(uv * [w, h], depth, faces, (w, h))
        lab = lab_image(img)
        box = _crop_box(mask)
        sel = (ids >= 0) & mask
        count = np.bincount(ids[sel], minlength=F).astype(float)
        sums = np.stack([np.bincount(ids[sel], weights=lab[..., c][sel], minlength=F) for c in range(3)], 1)
        take = (count > 0) & (source < 0)
        source[take] = n
        colour[take] = sums[take] / count[take, None]
        f['triangles_seen'] = int((count > 0).sum())
        f['triangles_coloured'] = int(take.sum())
        views[k] = {'n': n, 'ids': ids, 'uv': uv, 'lab': lab, 'bgr': img, 'mask': mask, 'box': box}
        over = img.copy()                             # fit check: the model's outline over the photo
        edge = cv2.morphologyEx((ids >= 0).astype(np.uint8), cv2.MORPH_GRADIENT, np.ones((5, 5), np.uint8)) > 0
        over[edge] = (0, 0, 255)
        cv2.imencode('.jpg', over, [cv2.IMWRITE_JPEG_QUALITY, 85])[1].tofile(str(out_dir / f'fit_{k}.jpg'))
    # marks: in each photo, on the pixels whose triangles that photo coloured
    marks = []
    for k in order:
        v = views[k]
        x0, y0, x1, y1 = v['box']
        diag = math.hypot(x1 - x0, y1 - y0)
        v['detail'] = detail_image(v['lab'], v['mask'], DETAIL_SCALE * diag)
        own = v['mask'] & (v['ids'] >= 0) & (source[np.maximum(v['ids'], 0)] == v['n'])
        area_px = max(int(own.sum()), 1)
        for m in find_marks(v['detail'], v['lab'], own, diag):
            m.update(photo=k, area_pct=round(100 * m['area_px'] / area_px, 3))
            marks.append(m)
    marks.sort(key=lambda m: -m['contrast'] * math.sqrt(m['area_px']))
    marks = marks[:MAX_MARKS]
    for i, m in enumerate(marks, 1):
        m['id'] = i
    seen = source >= 0
    A = adjacency(mesh)
    labels, regions, steps = segment(mesh, A, colour, seen)
    stats = region_stats(mesh, labels, regions, A, colour, seen)
    face_rgb = np.zeros((F, 3))
    face_rgb[seen] = lab_to_rgb(colour[seen])
    for s in stats:                                   # unseen triangles are shown in their region's mean colour
        face_rgb[(labels == s['id']) & ~seen] = s['colour_rgb']
    false_rgb = np.array([PALETTE[(r - 1) % len(PALETTE)] for r in range(1, max(regions) + 1)], float) / 255
    region_rgb = false_rgb[labels - 1]
    mv = views[main_key]
    x0, y0, x1, y1 = mv['box']
    _, _, back = camera_basis(fits[main_key]['camera'])
    pics = [(mv['ids'][y0:y1, x0:x1], back + np.array([0, .6, 0]))]
    for yaw, pitch in VIEWS:
        r, u, fw = _basis(yaw, pitch)
        pics.append((ortho_ids(pts, faces, yaw, pitch), fw + u * .6 + r * .3))
    tiles_c, tiles_r = [], []
    for ids, light in pics:
        tiles_c.append(_fit_tile(cv2.cvtColor(shade(mesh, ids, face_rgb, light), cv2.COLOR_RGB2BGR), 420))
        tiles_r.append(_fit_tile(number_regions(shade(mesh, ids, region_rgb, light), ids, labels, regions), 420))
    colours_img, regions_img = np.hstack(tiles_c), np.hstack(tiles_r)
    mk_img = marks_image(views, marks, order)
    for name, im in (('photo_colours', colours_img), ('regions', regions_img), ('marks', mk_img)):
        if im is not None:
            cv2.imencode('.jpg', im, [cv2.IMWRITE_JPEG_QUALITY, 90])[1].tofile(str(out_dir / f'{name}.jpg'))
    mark_info = [{x: m[x] for x in ('id', 'photo', 'polarity', 'area_pct', 'contrast', 'colour_rgb', 'elongation')} for m in marks]
    report = {'cameras': {k: {x: v for x, v in f.items() if x != 'camera'} for k, f in fits.items()},
              'colour_order': order, 'seen_pct': round(100 * float(np.asarray(mesh.area_faces)[seen].sum() / mesh.area), 1),
              'smoothing_steps': steps, 'regions': stats, 'marks': mark_info,
              'note': 'cameras: perspective, fitted to each photo cut-out (silhouette IoU) - a provisional 2D registration, '
                      'not a calibrated camera. The main photo colours what it sees; the others fill the rest. Regions: '
                      'k-means of mesh-smoothed photo colours (CIELAB). Marks: spots of the photo detail above its noise.'}
    (out_dir / 'paint.json').write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding='utf-8')
    return {'mesh': mesh, 'labels': labels, 'regions': regions, 'stats': stats, 'marks': marks, 'mark_info': mark_info,
            'report': report, 'source': source, 'order': order, 'views': views,
            'colours_img': colours_img, 'regions_img': regions_img, 'marks_img': mk_img}


def request_text(res) -> str:
    return TASK + '\n' + json.dumps({'regions': res['stats'], 'marks': res['mark_info']}, ensure_ascii=False)


def materials(decision: dict, stats: list, marks: list) -> tuple[dict, dict, list]:
    """Region materials {id: {'rgb', 'roughness', 'metallic'}} and kept marks {id: {'rgb', 'photo_detail'}} from the
    AI's answer. A region the AI left out takes the material of the largest region it did give (reported)."""
    got = {int(r['id']): r for r in decision.get('regions', [])}
    ids = [s['id'] for s in stats]
    given = [i for i in ids if i in got]
    if not given:
        raise SystemExit('the AI gave no region materials')
    fallback = got[min(given)]                       # regions are numbered by area: smallest id = largest given
    mats = {}
    for i in ids:
        r = got.get(i, fallback)
        mats[i] = {'rgb': tuple(round(float(np.clip(v, 0, 1)), 3) for v in r['color_rgb']),
                   'roughness': round(float(np.clip(r['roughness'], 0, 1)), 3),
                   'metallic': round(float(np.clip(r['metallic'], 0, 1)), 3)}
    known = {m['id'] for m in marks}
    kept = {int(m['id']): {'rgb': tuple(float(np.clip(v, 0, 1)) for v in m['color_rgb']), 'photo_detail': bool(m['photo_detail'])}
            for m in decision.get('marks', []) if int(m['id']) in known}
    return mats, kept, [i for i in ids if i not in got]


def snap_borders(mesh, labels, mats, seen) -> tuple[np.ndarray, float]:
    """Move the borders between different materials onto nearby creases of the shape. The generated shape and the
    photo never match exactly, so a projected colour border lands a little off the edge between two parts (a cap
    and a body). For every pair of materials that touch, a minimum cut over their triangles (alpha-beta swap):
    cutting between two triangles costs their shared edge length x cos(dihedral angle) (cheap at a crease, full
    price on a smooth surface); a triangle a photo saw leaving its material costs its area / (SNAP_SCALE x diagonal).
    Returns the new labels and the share of the surface that changed material."""
    from scipy.sparse import csr_matrix
    from scipy.sparse.csgraph import breadth_first_order, maximum_flow
    key = {r: (m['rgb'], m['roughness'], m['metallic']) for r, m in mats.items()}
    names = sorted(set(key.values()))
    if len(names) < 2:
        return labels, 0.0
    lut = np.zeros(max(mats) + 1, int)
    for r in mats:
        lut[r] = names.index(key[r])
    group = lut[labels]
    adj = np.asarray(mesh.face_adjacency)
    ev = np.asarray(mesh.vertices)[np.asarray(mesh.face_adjacency_edges)]
    area = np.asarray(mesh.area_faces)
    diag = np.linalg.norm(np.ptp(mesh.vertices, 0))
    # crease strength at the scale of the misfit: how far a triangle's normal is from the mean normal around it
    # (a generated surface rounds every edge over several triangles, so one dihedral angle does not show it)
    A = adjacency(mesh)
    nf = np.asarray(mesh.face_normals)
    hops = CREASE_SCALE * diag / max(np.sqrt(area.mean() * 2), 1e-12)
    nbar, _ = smooth_values(A, nf, np.ones(len(nf)), max(1, int(round(hops ** 2))))
    nbar /= np.maximum(np.linalg.norm(nbar, axis=1, keepdims=True), 1e-12)
    crease = 1 - np.clip(np.einsum('ij,ij->i', nf, nbar), -1, 1)
    ce = np.maximum(crease[adj[:, 0]], crease[adj[:, 1]])
    w_edge = np.linalg.norm(ev[:, 0] - ev[:, 1], axis=1) * np.maximum(1 - ce / max(np.percentile(ce, 99), 1e-9), 0.02)
    alpha = 1.0 / (SNAP_SCALE * diag)
    unary = area * alpha * seen                     # triangles no photo saw have no say
    scale = 1e5 / max(w_edge.max(), unary.max())
    new = group.copy()
    pairs = {}
    for a, b in zip(group[adj[:, 0]], group[adj[:, 1]]):
        if a != b:
            pairs[(min(a, b), max(a, b))] = pairs.get((min(a, b), max(a, b)), 0) + 1
    for (ga, gb), _ in sorted(pairs.items(), key=lambda kv: -kv[1]):
        idx = np.flatnonzero((new == ga) | (new == gb))
        local = -np.ones(len(group), int)
        local[idx] = np.arange(len(idx))
        n = len(idx)
        s, t = n, n + 1
        e = (local[adj[:, 0]] >= 0) & (local[adj[:, 1]] >= 0)
        i, j, c = local[adj[e, 0]], local[adj[e, 1]], np.maximum(1, np.round(w_edge[e] * scale)).astype(np.int32)
        u = np.round(unary[idx] * scale).astype(np.int32)
        orig = group[idx]                             # the projected colours are the data, not the previous swaps
        rows = np.r_[i, j, np.full(n, s), np.arange(n)]
        cols = np.r_[j, i, np.arange(n), np.full(n, t)]
        caps = np.r_[c, c, np.where(orig == ga, u, 0), np.where(orig == gb, u, 0)]
        G = csr_matrix((caps, (rows, cols)), shape=(n + 2, n + 2))
        flow = maximum_flow(G, s, t).flow
        resid = (G - flow).tocsr()
        resid.data[resid.data < 0] = 0
        resid.eliminate_zeros()
        reach = breadth_first_order(resid, s, directed=True, return_predecessors=False)
        side_a = np.zeros(n + 2, bool)
        side_a[reach] = True
        new[idx] = np.where(side_a[:n], ga, gb)
    changed = float(area[new != group].sum() / area.sum())
    if not changed:
        return labels, 0.0
    # back to region ids: a triangle that changed material takes the most common region of that material nearby
    out = labels.copy()
    moved = np.flatnonzero(new != group)
    for g in np.unique(new[moved]):
        regs = [r for r in mats if names.index(key[r]) == g]
        biggest = max(regs, key=lambda r: area[labels == r].sum())
        out[moved[new[moved] == g]] = biggest
    return out, round(changed, 4)


def mark_texture(view, labels, mats, marks, kept):
    """Texture for one photo (cropped to the object): each pixel the material colour of the region under it, with
    the kept marks painted in (flat colour, or region colour + the photo's detail), edges softened by one pixel.
    Outside the cut-out the nearest inside colour, so slightly misaligned UVs do not pick up the background."""
    x0, y0, x1, y1 = view['box']
    ids = view['ids'][y0:y1, x0:x1]
    inside = view['mask'][y0:y1, x0:x1] & (ids >= 0)
    lut = np.zeros((max(mats) + 1, 3), np.float32)
    for r, m in mats.items():
        lut[r] = rgb_to_lab(m['rgb'])[0]
    base = lut[np.where(ids >= 0, labels[np.maximum(ids, 0)], min(mats))]
    lab = base.copy()
    det = view['detail'][y0:y1, x0:x1]
    for m in marks:
        if m['id'] not in kept or m['photo'] != view['key']:
            continue
        x, y, w, h = m['box']
        full = np.zeros(ids.shape, np.float32)
        full[y - y0:y - y0 + h, x - x0:x - x0 + w] = m['comp']
        a = cv2.GaussianBlur(cv2.dilate(full, np.ones((3, 3), np.uint8)), (0, 0), 0.8)[..., None]
        paint_lab = base + det if kept[m['id']]['photo_detail'] else rgb_to_lab(kept[m['id']]['rgb'])[0]
        lab = lab * (1 - a) + paint_lab * a
    rgb = (lab_to_rgb(lab.reshape(-1, 3)).reshape(lab.shape) * 255).round().astype(np.uint8)
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    bgr[~inside] = 0
    filled = cv2.inpaint(bgr, (~inside).astype(np.uint8) * 255, 3, cv2.INPAINT_TELEA) if (~inside).any() else bgr
    s = min(1.0, TEXTURE_MAX / max(filled.shape[:2]))
    if s < 1:
        filled = cv2.resize(filled, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
    return cv2.cvtColor(filled, cv2.COLOR_BGR2RGB)


def build_scene(res, mats: dict, kept: dict):
    """A trimesh Scene: one plain mesh per distinct material, and per photo with kept marks one textured mesh per
    finish for the triangles under (and next to) those marks. Vertex normals come from the whole mesh, so seams
    between the pieces do not show in the shading."""
    import trimesh
    from PIL import Image
    m, labels, source, order, views = res['mesh'], res['labels'], res['source'], res['order'], res['views']
    vn = np.asarray(m.vertex_normals)
    vn = vn / np.maximum(np.linalg.norm(vn, axis=1, keepdims=True), 1e-12)
    V, Fc = np.asarray(m.vertices), np.asarray(m.faces)
    scene = trimesh.Scene()
    factors = {}

    def add(sel, name, mat, uv_fn=None, image=None):
        f = Fc[sel]
        if not len(f):
            return
        used = np.unique(f)
        sub = trimesh.Trimesh(V[used], np.searchsorted(used, f), vertex_normals=vn[used], process=False)
        pbr = trimesh.visual.material.PBRMaterial(
            name=name, baseColorFactor=np.array([255, 255, 255, 255] if image is not None else
                                                [*(round(c * 255) for c in mat['rgb']), 255], np.uint8),
            baseColorTexture=image, roughnessFactor=mat['roughness'], metallicFactor=mat['metallic'], doubleSided=False)
        sub.visual = trimesh.visual.TextureVisuals(material=pbr, **({'uv': uv_fn(used)} if uv_fn else {}))
        scene.add_geometry(sub, node_name=name, geom_name=name)
        factors[name] = [1.0, 1.0, 1.0, 1.0] if image is not None else srgb_to_linear([*mat['rgb'], 1.0])

    textured = np.zeros(len(Fc), bool)
    per_photo = {}
    for k in order:
        v = views[k]
        mk = [x for x in res['marks'] if x['photo'] == k and x['id'] in kept]
        if not mk:
            continue
        cover = np.zeros(v['mask'].shape, np.uint8)
        for x in mk:
            bx, by, bw, bh = x['box']
            cover[by:by + bh, bx:bx + bw] |= x['comp'].astype(np.uint8)
        cover = cv2.dilate(cover, np.ones((7, 7), np.uint8)).astype(bool) & (v['ids'] >= 0)
        sel = np.zeros(len(Fc), bool)
        sel[np.unique(v['ids'][cover])] = True
        sel &= source == v['n']
        if sel.any():
            per_photo[k] = sel
            textured |= sel
    groups = {}
    for r, mt in mats.items():
        groups.setdefault((mt['rgb'], mt['roughness'], mt['metallic']), []).append(r)
    for (rgb, rough, metal), regs in sorted(groups.items(), key=lambda g: min(g[1])):
        add(np.isin(labels, regs) & ~textured, f'regions_{"_".join(map(str, regs))}', {'rgb': rgb, 'roughness': rough, 'metallic': metal})
    for k, sel_k in per_photo.items():
        v = dict(views[k], key=k)
        x0, y0, x1, y1 = v['box']
        h, w = v['mask'].shape
        image = Image.fromarray(mark_texture(v, labels, mats, res['marks'], kept))

        def uv_fn(used, v=v, x0=x0, y0=y0, x1=x1, y1=y1, w=w, h=h):
            px = v['uv'][used] * [w, h]
            return np.stack([(px[:, 0] - x0) / (x1 - x0), 1 - (px[:, 1] - y0) / (y1 - y0)], 1)   # UV origin bottom-left
        finish = {}
        for r, mt in mats.items():                    # one textured mesh per photo and finish (the texture is shared)
            finish.setdefault((mt['roughness'], mt['metallic']), []).append(r)
        for (rough, metal), regs in finish.items():
            add(sel_k & np.isin(labels, regs), f'marks_{k}_regions_{"_".join(map(str, regs))}',
                {'roughness': rough, 'metallic': metal}, uv_fn, image)
    return scene, factors


def srgb_to_linear(rgba):
    """glTF baseColorFactor is linear; colours here (and the AI's) are sRGB, as in Katachi's own GLB writer."""
    a = np.asarray(rgba[:3], float)
    return np.where(a <= .04045, a / 12.92, ((a + .055) / 1.055) ** 2.4).tolist() + [float(rgba[3])]


def write_glb(scene, path, factors: dict):
    """Export the scene and set each material's baseColorFactor to its exact linear value (trimesh keeps colours
    as 8-bit, which loses dark colours once they are linear)."""
    import struct
    data = scene.export(file_type='glb', include_normals=True)
    magic, version, _ = struct.unpack_from('<III', data, 0)
    jlen, jtype = struct.unpack_from('<II', data, 12)
    js = json.loads(data[20:20 + jlen])
    rest = data[20 + jlen:]
    for mat in js.get('materials', []):
        f = factors.get(mat.get('name'))
        if f is not None:
            mat.setdefault('pbrMetallicRoughness', {})['baseColorFactor'] = [round(float(x), 6) for x in f]
    jb = json.dumps(js, separators=(',', ':')).encode()
    jb += b' ' * (-len(jb) % 4)
    Path(path).write_bytes(struct.pack('<III', magic, version, 20 + len(jb) + len(rest)) + struct.pack('<II', len(jb), jtype) + jb + rest)
    return Path(path)

