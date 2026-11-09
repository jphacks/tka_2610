"""--look ai: the program measures, one AI call decides, the program builds.

Photo textures carry the room's light (a reflection on a lid, the desk next to a thin side). Here a face
is built as a material unless it carries print, and its logo / feet / labels become parts. What cannot
be measured from a photo -- which colour is the material itself and which is the lamp, metal or
plastic, which marks are features and which are reflections, whether a face's print must be kept --
is decided by one AI call that sees the photos and the measurements. The code holds no object
knowledge and no thresholds for these decisions; geometry (size, corner rounding, mark outlines and
positions) comes only from the measurements.

The AI call goes through Claude Code in print mode (`claude -p`, no tools, structured JSON output), so
the user's Claude Code login is used; no API key is needed. Cost and time are recorded in the report.
"""
from __future__ import annotations
import base64
import json
import os
import shutil
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import cv2
import numpy as np
from shapely.geometry import Polygon
from shapely.geometry.polygon import orient
from shapely.validation import make_valid

from . import inspect as ki

MAX_MARKS = 12      # largest marks per face shown to the AI (a printed face has many; it keeps its photo anyway)
DECAL = 0.02          # cm, thickness of a printed mark (it sits 0.015 cm proud of the face)
PANEL = 0.01          # cm, thickness of a photo panel on a printed face
FACE_KEYS = ('front', 'back')
EDGE_KEYS = ('side', 'side2')

SYSTEM = ('You decide how to build a 3D model from photos and measurements made by a program. '
          'Answer only through the JSON schema. Be concise.')

TASK = """The photos show one object. A program measured it and will build it as a slab of W x H x T cm:
the front face (W x H) faces the camera at yaw 0, the back face is behind it, the thin sides go around.
Geometry comes from the measurements; you decide what the measurements cannot tell:

1. body: the colour of the material itself (sRGB 0..1), roughness and metallic. The photos contain the
   room's light: reflections and the colour of the lamp. Measured colour candidates are given (median,
   darker half, and corrected with a white reference when one was found); choose the material's colour:
   the base colour that, under neutral white light, looks like the object in the photos. The model is shown
   under studio light without a room to reflect, so metallic above about 0.5 looks much darker than the
   photos; give metal its look with a moderate metallic and a low roughness instead. When a white reference
   was found and reads close to white, the photo's exposure is about right: reflections only brighten a
   surface, so its darker half is then usually close to the material's own colour.
2. corner_radius_cm: rounding of the outline corners of the front/back faces. Measured per corner;
   use the measurement unless it is clearly wrong (say why in notes).
3. edge_round_cm: rounding of the edges between the front/back faces and the sides (0 = sharp, <= T/2).
4. back_color_rgb: colour of the back face's material (repeat the body colour if it is the same).
5. faces_use_photo: faces (front, back, and the sides side / side2 if photographed) that carry print or
   pictures that must be reproduced as an image (e.g. a printed cover or spine). Leave out plain faces: they
   are built as the material, so reflections disappear. A side whose strip image is not the object's side
   (the program found something else) must not be listed.
6. marks: measured marks are numbered in the face images (red = darker, blue = brighter than the
   surface). Choose those that are real features of the object and how to build each: "print" (flat
   colour on the face), "raised" (sticks out by height_cm), "recess" (shown as a flat dark area). Leave out
   reflections, shadows, fingers, dust, and marks you are unsure about. Marks on a face listed in
   faces_use_photo are already in the image: do not list them. copies_at_face_cm: when the same feature
   appears again on the face but was not measured cleanly there (lit by a reflection, cut into pieces), list
   one clean measurement and give the centre of each other occurrence, read on the rulers of the face image
   ([x from the image's left edge, y from its top edge] in cm, as the rulers show); otherwise []. Prefer this
   over listing a badly measured piece. A copy that would land on a mark you listed is skipped.
7. seam: if the side photos show a line all around the sides (two layers, e.g. a lid on a base), give
   present=true, its position as a fraction of the thickness measured from the back face, its width and
   colour; otherwise present=false. Side measurements give lines across the strip measured from strip side 1
   (which of the strip's long sides is the front face is not known: judge from the photos).

Coordinates in the measurements: cm; for marks, centre_centred_cm = [x from the face centre in model
coordinates, y up from the bottom edge]. The back face's x is already mirrored into model coordinates.
"""


def _col():
    return {'type': 'array', 'items': {'type': 'number'}, 'minItems': 3, 'maxItems': 3}


SCHEMA = {
    'type': 'object',
    'properties': {
        'object': {'type': 'string'},
        'body': {'type': 'object', 'properties': {
            'color_rgb': _col(), 'roughness': {'type': 'number'}, 'metallic': {'type': 'number'},
            'corner_radius_cm': {'type': 'number'}, 'edge_round_cm': {'type': 'number'}},
            'required': ['color_rgb', 'roughness', 'metallic', 'corner_radius_cm', 'edge_round_cm']},
        'back_color_rgb': _col(),
        'faces_use_photo': {'type': 'array', 'items': {'type': 'string', 'enum': list(FACE_KEYS) + list(EDGE_KEYS)}},
        'marks': {'type': 'array', 'items': {'type': 'object', 'properties': {
            'face': {'type': 'string', 'enum': list(FACE_KEYS)}, 'id': {'type': 'integer'}, 'what': {'type': 'string'},
            'build': {'type': 'string', 'enum': ['print', 'raised', 'recess']}, 'height_cm': {'type': 'number'},
            'copies_at_face_cm': {'type': 'array', 'items': {'type': 'array', 'items': {'type': 'number'}, 'minItems': 2, 'maxItems': 2}},
            'color_rgb': _col(), 'roughness': {'type': 'number'}, 'metallic': {'type': 'number'}},
            'required': ['face', 'id', 'build', 'color_rgb', 'roughness', 'metallic']}},
        'seam': {'type': 'object', 'properties': {
            'present': {'type': 'boolean'}, 'from_back_fraction': {'type': 'number'}, 'width_cm': {'type': 'number'},
            'color_rgb': _col()}, 'required': ['present']},
        'notes': {'type': 'string'},
    },
    'required': ['object', 'body', 'back_color_rgb', 'faces_use_photo', 'marks', 'seam', 'notes'],
}


# ------------------------------------------------------------------ measurements
def fine_detail_share(res) -> float:
    """% of the face (outside its marks) with fine detail: print and texture have it, a reflection or a
    shadow (smooth changes of light) does not. Information for the AI, not a decision."""
    rect = ki._imread(res['rectified']); ppc = res['pixels_per_cm']; m = res['margin_cm']; W, H = res['size_cm']
    sx = -1.0 if res['facing'] == 'back' else 1.0
    L = ki.lab(rect)[..., 0]
    ins = min(0.6, 0.1 * min(W, H))
    inner = np.zeros(L.shape, bool)
    inner[int((m + ins) * ppc):int((m + H - ins) * ppc), int((m + ins) * ppc):int((m + W - ins) * ppc)] = True
    marks = np.zeros(L.shape, np.uint8)
    for mk in res['marks']:
        pts = np.array([[(sx * x + W / 2 + m) * ppc, (H - y + m) * ppc] for x, y in mk['outline_centred_cm']], np.int32)
        cv2.fillPoly(marks, [pts], 1)
    marks = cv2.dilate(marks, np.ones((max(3, int(0.3 * ppc)),) * 2, np.uint8)).astype(bool)
    sel = inner & ~marks
    d = L - cv2.GaussianBlur(L, (0, 0), 0.25 * ppc)
    return round(float((np.abs(d[sel]) > 6).mean() * 100), 2) if sel.any() else 0.0


def measure_faces(ws, full, size_cm, out_dir) -> dict:
    """inspect.measure_face on each face photo (rectified with the template's corners)."""
    def one(k):
        r = ki.measure_face(ws.photos[k].source, size_cm, out_dir / k, corners=np.asarray(full[k]).tolist(),
                            facing='back' if k == 'back' else 'front')
        inside = [bool(0 <= x <= 1 and 0 <= y <= 1) for x, y in full[k]]
        names = ['top_left', 'top_right', 'bottom_right', 'bottom_left']
        r['corner_radius_by_corner_cm'] = {n: r['corner_rounding'][n].get('radius_cm') for n, ok in zip(names, inside) if ok}
        r['fine_detail_pct'] = fine_detail_share(r)
        r['orientation_ok'] = abs(r['size_cm'][0] - size_cm[0]) < 1e-6
        return k, r
    keys = [k for k in FACE_KEYS if k in full]
    with ThreadPoolExecutor(max_workers=max(1, len(keys))) as ex:
        return dict(ex.map(one, keys))


def measure_edges(ws, strips, length_thickness, out_dir) -> dict:
    """inspect.measure_edge on each side photo, between the ends of the template's detected strip
    (strips: normalised corners per photo key)."""
    def one(k):
        size = np.array(ws.photos[k].size, float)
        q = np.asarray(strips[k], float) * size
        a, b = (q[0] + q[1]) / 2, (q[3] + q[2]) / 2          # mid-points of the two short sides
        if np.linalg.norm(q[1] - q[0]) > np.linalg.norm(q[3] - q[0]):
            a, b = (q[0] + q[3]) / 2, (q[1] + q[2]) / 2
        L, T = length_thickness[k]
        try:
            return k, ki.measure_edge(ws.photos[k].source, L, T, out_dir / k, ends=[*(a / size).tolist(), *(b / size).tolist()])
        except Exception as e:                                   # a side photo is optional information
            return k, {'error': str(e)}
    keys = [k for k in EDGE_KEYS if k in strips]
    with ThreadPoolExecutor(max_workers=max(1, len(keys))) as ex:
        return dict(ex.map(one, keys))


# ------------------------------------------------------------------ the AI call
def claude_exe() -> str:
    env = os.environ.get('KT_CLAUDE')
    if env:
        return env
    w = shutil.which('claude')
    if not w:
        raise SystemExit('--look ai needs Claude Code (`claude` on PATH, or KT_CLAUDE=path)')
    exe = Path(w).parent / 'node_modules' / '@anthropic-ai' / 'claude-code' / 'bin' / 'claude.exe'
    return str(exe) if exe.exists() else w


def _jpeg_b64(img, long_side):
    s = min(1.0, long_side / max(img.shape[:2]))
    if s < 1:
        img = cv2.resize(img, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
    return base64.b64encode(cv2.imencode('.jpg', img, [cv2.IMWRITE_JPEG_QUALITY, 85])[1]).decode()


def ask(images: list, text: str, model='sonnet', cwd=None, timeout=240, schema=None, system=None):
    """One Claude call (no tools) with images (base64 JPEG) and a JSON schema (default: the slab design
    schema of this module). Returns (decision, meta)."""
    content = [{'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/jpeg', 'data': b}} for b in images]
    content.append({'type': 'text', 'text': text})
    msg = {'type': 'user', 'message': {'role': 'user', 'content': content}}
    cmd = [claude_exe(), '-p', '--model', model, '--tools', '', '--input-format', 'stream-json',
           '--output-format', 'stream-json', '--verbose', '--no-session-persistence', '--strict-mcp-config',
           '--disable-slash-commands', '--setting-sources', '', '--system-prompt', system or SYSTEM,
           '--json-schema', json.dumps(schema or SCHEMA)]
    t0 = time.perf_counter()
    p = subprocess.run(cmd, input=json.dumps(msg) + '\n', capture_output=True, text=True, encoding='utf-8',
                       cwd=str(cwd) if cwd else None, timeout=timeout)
    wall = round(time.perf_counter() - t0, 2)
    result = None
    for line in p.stdout.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get('type') == 'result':
            result = ev
    if result is None or result.get('is_error') or not result.get('structured_output'):
        tail = (result or {}).get('result') or p.stderr[-500:] or p.stdout[-500:]
        raise SystemExit(f'AI call failed (exit {p.returncode}): {tail}')
    u = result.get('usage') or {}
    meta = {'model': next(iter(result.get('modelUsage') or {model: 0})), 'wall_s': wall,
            'api_s': round((result.get('duration_api_ms') or 0) / 1000, 2), 'cost_usd': result.get('total_cost_usd'),
            'input_tokens': u.get('input_tokens', 0) + u.get('cache_creation_input_tokens', 0) + u.get('cache_read_input_tokens', 0),
            'output_tokens': u.get('output_tokens')}
    return result['structured_output'], meta


def _label(img, text):
    img = img.copy()
    cv2.rectangle(img, (0, 0), (min(img.shape[1], 18 * len(text) + 12), 34), (255, 255, 255), -1)
    cv2.putText(img, text, (6, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 0), 2)
    return img


def _row(imgs, height):
    tiles = [cv2.resize(i, (max(1, int(i.shape[1] * height / i.shape[0])), height), interpolation=cv2.INTER_AREA) for i in imgs]
    return np.hstack([np.pad(t, ((0, 0), (0, 8), (0, 0)), constant_values=255) for t in tiles])


def request(ws, faces, edges, size_cm) -> tuple[list, str, dict]:
    """Images (all photos; faces with numbered marks; side strips) and the measurements as text."""
    photos = _row([_label(ki._imread(p.source), k) for k, p in ws.photos.items()], 480)
    imgs = [_jpeg_b64(photos, 1400)]
    if faces:
        imgs.append(_jpeg_b64(_row([_label(ki._imread(r['marks_image']), f'{k} face') for k, r in faces.items()], 900), 1400))
    strips = [_label(ki._imread(r['image']), k) for k, r in edges.items() if 'image' in r]
    if strips:
        imgs.append(_jpeg_b64(_row(strips, 900), 1000))
    keep = ('id', 'polarity', 'area_cm2', 'centre_centred_cm', 'bbox_cm', 'equivalent_diameter_cm', 'circularity',
            'solidity', 'contrast', 'colour_rgb')
    data = {'size_cm': {'W': size_cm[0], 'H': size_cm[1], 'T': size_cm[2]},
            'faces': {k: {'photo': Path(ws.photos[k].path).name, 'corner_radius_by_corner_cm': r['corner_radius_by_corner_cm'],
                          'colour': r['colour'], 'fine_detail_pct_outside_marks': r['fine_detail_pct'],
                          'orientation_matches_size': r['orientation_ok'],
                          'marks': [{x: mk[x] for x in keep} for mk in r['marks'][:MAX_MARKS]]} for k, r in faces.items()},
            'sides': {k: ({'error': r['error']} if 'error' in r else
                          {'photo': Path(ws.photos[k].path).name, 'length_cm': r['length_cm'], 'thickness_cm': r['thickness_cm'],
                           'lines_across_from_strip_side_1': r['seams'],
                           'marks': [{x: mk[x] for x in ('id', 'polarity', 'from_end_a_cm', 'length_cm', 'width_cm',
                                                          'across_fraction_from_side_1', 'contrast', 'colour_rgb')} for mk in r['marks']]})
                      for k, r in edges.items()}}
    legend = ('Image 1: all photos (labels = slot: front, back, side = left side, side2 = right side). '
              'Image 2: each face rectified to its real size, marks numbered. '
              + ('Image 3: the side strips straightened (end A at the top, strip side 1 on the left).' if strips else ''))
    return imgs, f'{TASK}\n{legend}\n\nMeasurements:\n{json.dumps(data, ensure_ascii=False)}', data


# ------------------------------------------------------------------ building the recipe
def rounded_rect(w, h, r, n=8):
    """Counter-clockwise rounded rectangle, x centred, y from 0 to h."""
    r = max(0.0, min(r, 0.45 * min(w, h)))
    if r < 1e-3:
        return [[-w / 2, 0], [w / 2, 0], [w / 2, h], [-w / 2, h]]
    pts = []
    for cx, cy, a0 in ((w / 2 - r, r, -90), (w / 2 - r, h - r, 0), (-w / 2 + r, h - r, 90), (-w / 2 + r, r, 180)):
        for k in range(n + 1):
            a = np.radians(a0 + 90 * k / n)
            pts.append([cx + r * np.cos(a), cy + r * np.sin(a)])
    return _dedupe(pts)


def _dedupe(pts, eps=1e-4):
    out = []
    for p in pts:
        p = [round(float(p[0]), 4), round(float(p[1]), 4)]
        if not out or abs(p[0] - out[-1][0]) > eps or abs(p[1] - out[-1][1]) > eps:
            out.append(p)
    if len(out) > 1 and abs(out[0][0] - out[-1][0]) <= eps and abs(out[0][1] - out[-1][1]) <= eps:
        out.pop()
    return out


def clean_outline(pts, clip=None, max_pts=190):
    """A valid, simple, counter-clockwise outline (largest piece), clipped to `clip`; None if nothing is left."""
    if len(pts) < 3:
        return None
    g = Polygon(pts)
    if not g.is_valid:
        g = make_valid(g)
    if clip is not None:
        g = g.intersection(Polygon(clip))
    polys = [g] if g.geom_type == 'Polygon' else [x for x in getattr(g, 'geoms', []) if x.geom_type == 'Polygon']
    if not polys:
        return None
    g = max(polys, key=lambda x: x.area)
    if g.area < 1e-3:
        return None
    g = Polygon(g.exterior)                                     # holes of a mark are not kept
    tol = 0.005
    while len(g.exterior.coords) - 1 > max_pts:
        g = g.simplify(tol); tol *= 1.5
    g = orient(g, 1.0)
    out = _dedupe(list(g.exterior.coords))
    return out if len(out) >= 3 and Polygon(out).is_valid else None


def _safe_bevel(outline, b):
    """The largest of b, b/2, b/4 that Katachi accepts for this outline, else 0. Same test as
    katachi.bevel.rounded_extrusion (every inset step of the bevel must keep the outline one valid piece
    inside the original), at its finest quality setting (7 steps)."""
    poly = orient(Polygon(outline), 1.0)
    span = max(poly.bounds[2] - poly.bounds[0], poly.bounds[3] - poly.bounds[1])
    def ok(v):
        for t in np.linspace(0, np.pi / 2, 8)[1:]:
            raw = poly.buffer(-v * (1 - np.cos(t)) if t < np.pi / 2 - 1e-9 else -v, quad_segs=8, join_style='round')
            if (raw.is_empty or raw.geom_type != 'Polygon' or not raw.is_valid or len(raw.interiors) != len(poly.interiors)
                    or not poly.buffer(span * 1e-12).covers(raw)):
                return False
        return True
    for v in (b, b / 2, b / 4):
        if v < 1e-3:
            break
        if ok(v * 1.02):
            return round(v, 4)
    return 0.0


def _clamp01(v):
    return [round(float(np.clip(x, 0, 1)), 4) for x in v]


def scene(dec, faces, size_cm, title, tex=None, coverage=None) -> dict:
    """The recipe from the measurements and the AI's decisions. coverage: {face: [u0, u1, v0, v1]} part of a
    face inside its photo; a photo panel covers only that part (the rest shows the body colour)."""
    W, H, T = size_cm
    b = dec['body']
    R = float(np.clip(b['corner_radius_cm'], 0, 0.45 * min(W, H)))
    e = float(np.clip(b['edge_round_cm'], 0, 0.45 * T))
    mat = lambda i, c, r, m: {'id': i, 'color': [*_clamp01(c), 1], 'roughness': round(float(np.clip(r, 0, 1)), 3),
                              'metallic': round(float(np.clip(m, 0, 1)), 3)}
    mats = [mat('body', b['color_rgb'], b['roughness'], b['metallic'])]
    outline = rounded_rect(W, H, R)
    flat = rounded_rect(W - 2 * e, H - 2 * e, max(R - e, 0.0))   # the flat part of a face, inside the edge rounding
    flat = [[x, y + e] for x, y in flat]
    parts = []
    ext = lambda pid, ol, depth, z, m, bevel=0.0, **kw: {
        'id': pid, 'geometry': {'kind': 'extrusion', 'outline': ol, 'depth': round(depth, 4), 'bevel': _safe_bevel(ol, min(bevel, 0.45 * depth))},
        'material': m, 'transform': {'translation': [0, 0, round(z, 4)], **kw.pop('tf', {})}, **kw}
    s = dec.get('seam') or {}
    f = float(s.get('from_back_fraction', 0)) if s.get('present') else 0.0
    g = float(np.clip(s.get('width_cm', 0.05), 0.02, 0.2 * T)) if s.get('present') else 0.0
    if 0.08 < f < 0.92:
        zs = -T / 2 + f * T
        mats.append(mat('seam', s.get('color_rgb', [0.05, 0.05, 0.05]), 0.8, 0))
        lo, hi = zs - g / 2 + T / 2, T / 2 - zs - g / 2                # depths of the back and front layers
        parts.append(ext('body_back', outline, lo, -T / 2 + lo / 2, 'body', e, confidence=0.8))
        parts.append(ext('body_front', outline, hi, T / 2 - hi / 2, 'body', e, confidence=0.8))
        core = rounded_rect(W - 2 * max(e, 0.05), H - 2 * max(e, 0.05), max(R - max(e, 0.05), 0.0))
        core = [[x, y + max(e, 0.05)] for x, y in core]
        parts.append(ext('seam_line', core, g + 0.02, zs, 'seam', 0, confidence=0.6))
    else:
        parts.append(ext('body', outline, T, 0, 'body', e, confidence=0.8))
    back_rgb = dec.get('back_color_rgb') or b['color_rgb']
    if np.abs(np.subtract(back_rgb, b['color_rgb'])).max() > 0.02:
        mats.append(mat('back_face', back_rgb, b['roughness'], b['metallic']))
        parts.append(ext('back_face', flat, 0.01, -T / 2 - 0.003, 'back_face', confidence=0.6))
    for k in dec.get('faces_use_photo', []):
        if tex and k in tex and k in EDGE_KEYS:
            # the straight part of the side, inside the edge rounding; same layout as the photo look (box.py)
            mats.append({'id': f'{k}_photo', 'color': [1, 1, 1, 1], 'roughness': round(float(b['roughness']), 3), 'image_id': tex[k]['id']})
            m_ = max(R, e)
            ol = [[-T / 2 + e, m_], [T / 2 - e, m_], [T / 2 - e, H - m_], [-T / 2 + e, H - m_]]
            sgn = -1 if k == 'side' else 1
            parts.append({'id': f'{k}_print', 'geometry': {'kind': 'extrusion', 'outline': _dedupe(ol), 'depth': PANEL},
                          'material': f'{k}_photo', 'uv_mode': 'planar_xy', 'confidence': 0.7,
                          'transform': {'translation': [round(sgn * (W / 2 + 0.004), 4), 0, 0], 'rotation_deg': [0, 90 * sgn, 0]}})
        elif tex and k in tex:
            mats.append({'id': f'{k}_photo', 'color': [1, 1, 1, 1], 'roughness': round(float(b['roughness']), 3), 'image_id': tex[k]['id']})
            sign = 1 if k == 'front' else -1
            u0, u1, v0, v1 = (coverage or {}).get(k, [0, 1, 0, 1])
            seen = [[-W / 2 + u0 * W, H * (1 - v1)], [-W / 2 + u1 * W, H * (1 - v1)], [-W / 2 + u1 * W, H * (1 - v0)], [-W / 2 + u0 * W, H * (1 - v0)]]
            ol = clean_outline(flat, seen) if (u1 - u0) * (v1 - v0) < 0.999 else flat   # local (photo) coordinates
            if ol is not None:
                parts.append(ext(f'{k}_print', ol, PANEL, sign * (T / 2 + 0.004), f'{k}_photo', uv_mode='planar_xy', confidence=0.75,
                                 tf={'rotation_deg': [0, 180, 0]} if k == 'back' else {}))
    chosen = [mk for mk in dec.get('marks', []) if mk['face'] in faces and mk['face'] not in dec.get('faces_use_photo', [])]
    outlines = {}
    for mk in chosen:
        found = [x for x in faces[mk['face']]['marks'] if x['id'] == mk['id']]
        ol = clean_outline(found[0]['outline_centred_cm'], flat) if found else None
        if ol is not None:
            outlines[(mk['face'], mk['id'])] = ol
    placed = {k: [Polygon(ol) for (f_, _), ol in outlines.items() if f_ == k] for k in FACE_KEYS}
    for mk in chosen:
        k = mk['face']
        if (k, mk['id']) not in outlines:
            continue
        sign = 1 if k == 'front' else -1
        mid = f'mark_{k}_{mk["id"]}'
        mats.append(mat(mid, mk['color_rgb'], mk['roughness'], mk['metallic']))
        shapes = [('', outlines[(k, mk['id'])])]
        src = [x for x in faces[k]['marks'] if x['id'] == mk['id']][0]
        sx = -1.0 if k == 'back' else 1.0                      # face image x -> model x
        for j, c in enumerate(mk.get('copies_at_face_cm') or []):
            dx, dy = sx * (c[0] - src['centre_cm'][0]), -(c[1] - src['centre_cm'][1])
            cp = clean_outline([[x + dx, y + dy] for x, y in outlines[(k, mk['id'])]], flat)
            if cp is None:
                continue
            pc = Polygon(cp)
            if any(pc.intersection(q).area > 0.3 * min(pc.area, q.area) for q in placed[k]):
                continue                                         # a listed mark is already there
            placed[k].append(pc)
            shapes.append((f'_copy{j}', cp))
        for suffix, ol in shapes:
            if mk['build'] == 'raised':
                h = float(np.clip(mk.get('height_cm', 0.1), 0.01, T))
                parts.append(ext(mid + suffix, ol, h, sign * (T / 2 + h / 2 - 0.005), mid, min(0.4 * h, 0.1), confidence=0.6))
            else:
                parts.append(ext(mid + suffix, ol, DECAL, sign * (T / 2 + 0.005), mid, confidence=0.7))
    assumptions = [f'レシピ単位は cm。寸法 {W:g} x {H:g} x {T:g} cm は入力値。角の丸み・模様の形と位置は写真から計測した値。',
                   '素材の色・つや・金属感、模様の作り方（印刷・出っ張り・くぼみ）、写真を貼る面、合わせ目は、'
                   'AI が写真と計測値を見て1回で決めた（ai_decision.json）。',
                   '写真を貼らない面は素材で塗るため、撮影時の映り込みや影はモデルに入らない。']
    return {'schema_version': '1.0', 'title': title, 'height_m': round(H / 100, 5), 'seed': 1, 'controls': [],
            'assumptions': assumptions, 'materials': mats, 'parts': parts}
