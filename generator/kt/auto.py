"""kt auto: one command for any object. The program measures the photos, one AI call chooses how to build it
(a template that fits the object, or the shape generator for anything else), and that route runs.

  kt auto <photo folder | photos...> --size 16,10.6,6.6 [--out DIR] [--ai-model sonnet]

--size: the known dimensions in cm, 1 to 3 numbers in any order; the AI assigns them to the route's arguments.
The code holds no rule for which object goes where: the AI decides from the photos and the measurements
(rectangle detection, cut-out shape). A decision that does not validate stops with its reason; nothing is
rerouted silently. Outputs: route_decision.json, then the chosen route's outputs (model.glb, report.json ...)
in the same folder; report.json gets an 'auto' section with the routing call and the total time.
"""
from __future__ import annotations
import json
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

from . import design

SYSTEM = ('You choose how a program builds a 3D model of an object from its photos. '
          'Answer only through the JSON schema. Be concise.')

ROUTES = """Routes (choose exactly one and fill only its block):
- box: an object made of flat rectangular faces: a book, a box, a closed laptop, a card. Built from the detected
  rectangular faces; plain faces become materials, printed faces keep their print. Needs: front = photo of the
  largest face taken square-on; optional back (the opposite face), side (left side, a thin strip), side2 (right
  side); size_mm = [W, H, T]: W = the front face's side that runs horizontally in the front photo, H = the
  vertical one (the measurement width_to_height_in_photo of the front photo's rectangle tells which is longer
  there: below 1 = taller than wide), T the thickness, or 0 if it is not known (it is then estimated from the
  side photo); kind = "book" (printed covers around a page block) or "box".
- flat: a thin flat sheet: a drawing, a card, a paper cut-out. One photo square-on; width_cm, height_cm,
  thickness_mm.
- bottle: a container that stands upright with a body that is roughly symmetric left-right (bottle, tube, jar),
  photographed from the side at about eye level: front (required), side (required, 90 degrees turned), back and
  side2 optional; height_cm. print: "photo" only when the body carries a printed label or picture that must be
  reproduced (the front/back photos are then projected onto the body, with their reflections, wrinkles and hand
  shadows); "none" when the body is one plain colour (it is then built as that material, clean). cap: the closure
  as seen in the photos: "ribbed" (grooves around it), "plain", "none", or "auto" (detected from the colour band).
- revolve: an object with rotational symmetry around a vertical axis (cup, vase, plate), one photo from the side
  at about eye level; height_cm.
- generate: anything else, especially curved or free-form objects (controllers, toys, shoes, tools, figures).
  An image-to-3D model generates the shape from ONE photo: choose the photo that shows most of the 3D form
  (an oblique view that shows the top and the sides is better than a straight-on view). Model axes: x = width,
  y = up as the object normally rests, z = toward the object's front. Give that photo's camera direction:
  yaw (0 = camera in front of the object, 90 = on its right, 180 = behind, -90 = on its left) and pitch (0 = level,
  60 = from above at 60 degrees, 89 = straight down, negative = from below). size_cm = [x, y, z]. others: the
  remaining photos with their camera directions (used only for comparison images).
Use only file names from the list. The measurements are evidence; decide by looking at the photos."""


def _arr(n, typ='number'):
    return {'type': 'array', 'items': {'type': typ}, 'minItems': n, 'maxItems': n}


SCHEMA = {
    'type': 'object',
    'properties': {
        'object': {'type': 'string'}, 'route': {'type': 'string', 'enum': ['box', 'flat', 'bottle', 'revolve', 'generate']},
        'reason': {'type': 'string'},
        'box': {'type': 'object', 'properties': {
            'front': {'type': 'string'}, 'back': {'type': 'string'}, 'side': {'type': 'string'}, 'side2': {'type': 'string'},
            'size_mm': _arr(3), 'kind': {'type': 'string', 'enum': ['book', 'box']}}, 'required': ['front', 'size_mm', 'kind']},
        'flat': {'type': 'object', 'properties': {
            'photo': {'type': 'string'}, 'width_cm': {'type': 'number'}, 'height_cm': {'type': 'number'},
            'thickness_mm': {'type': 'number'}}, 'required': ['photo', 'width_cm', 'height_cm', 'thickness_mm']},
        'bottle': {'type': 'object', 'properties': {
            'front': {'type': 'string'}, 'side': {'type': 'string'}, 'back': {'type': 'string'}, 'side2': {'type': 'string'},
            'height_cm': {'type': 'number'}, 'print': {'type': 'string', 'enum': ['photo', 'none']},
            'cap': {'type': 'string', 'enum': ['auto', 'ribbed', 'plain', 'none']}},
            'required': ['front', 'side', 'height_cm', 'print', 'cap']},
        'revolve': {'type': 'object', 'properties': {'photo': {'type': 'string'}, 'height_cm': {'type': 'number'}},
                    'required': ['photo', 'height_cm']},
        'generate': {'type': 'object', 'properties': {
            'photo': {'type': 'string'}, 'yaw': {'type': 'number'}, 'pitch': {'type': 'number'}, 'size_cm': _arr(3),
            'others': {'type': 'array', 'items': {'type': 'object', 'properties': {
                'photo': {'type': 'string'}, 'yaw': {'type': 'number'}, 'pitch': {'type': 'number'}},
                'required': ['photo', 'yaw', 'pitch']}}}, 'required': ['photo', 'yaw', 'pitch', 'size_cm']},
    },
    'required': ['object', 'route', 'reason'],
}


# ------------------------------------------------------------------ measurements
def measure_photo(path: Path, work: Path) -> dict:
    """Generic evidence: does the photo show straight-edged rectangles, and what does the cut-out look like."""
    import cv2
    from . import quad_detect as qd
    from .inspect import _upright_copy, _imread
    from .segment import object_mask
    from katachi.images import sanitize_image
    res = {}
    up = _upright_copy(path, work)
    size_px = _imread(up).shape[1::-1]                                     # (w, h); non-ASCII paths are fine
    for name, fn in (('rectangle', qd.detect_face), ('strip', qd.detect_strip)):
        try:
            r = fn(up)
            q = np.asarray(r.corners, float) * size_px                                # TL TR BR BL, pixels
            across = (np.linalg.norm(q[1] - q[0]) + np.linalg.norm(q[2] - q[3])) / 2
            down = (np.linalg.norm(q[3] - q[0]) + np.linalg.norm(q[2] - q[1])) / 2
            res[name] = {'edge_support': r.notes[0] if r.notes else '', 'outside_photo_sides': r.clipped_sides,
                         'width_to_height_in_photo': round(float(across / max(down, 1e-6)), 2)}
        except ValueError as e:
            res[name] = {'found': False, 'why': str(e)[:80]}
    src = work / f'_{path.stem}_src.png'
    if not src.exists():
        sanitize_image(path.read_bytes(), src)
    m, info = object_mask(src)
    if m.any():
        cs, _ = cv2.findContours(m.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        c = max(cs, key=cv2.contourArea)
        (_, _), (w, h), _ = cv2.minAreaRect(c)
        hull = cv2.contourArea(cv2.convexHull(c))
        res['cutout'] = {'area_share': round(float(m.mean()), 3), 'elongation': round(float(max(w, h) / max(1.0, min(w, h))), 2),
                         'solidity': round(float(cv2.contourArea(c) / max(hull, 1)), 3),
                         'rectangularity': round(float(cv2.contourArea(c) / max(w * h, 1)), 3),
                         'touches_border': info.get('touches_border', [])}
    return res


def photo_list(inputs) -> list[Path]:
    from .photos import resolve_folder, PHOTO_EXT
    out = []
    for p in map(Path, inputs):
        out += resolve_folder(p) if p.is_dir() else [p] if p.suffix.lower() in PHOTO_EXT else []
    if not out:
        raise SystemExit('kt auto: no photos found')
    return out


# ------------------------------------------------------------------ decision -> command line
def to_argv(dec: dict, files: dict, out: Path, ai_model: str) -> list[str]:
    """The chosen route as kt arguments. Raises ValueError with the reason when the decision is incomplete."""
    route = dec.get('route')
    d = dec.get(route) or {}
    if not d:
        raise ValueError(f'route {route!r} chosen but its block is missing')

    def f(key, required=True):
        name = (d.get(key) or '').strip()
        if not name:
            if required:
                raise ValueError(f'{route}.{key} missing')
            return None
        if name not in files:
            raise ValueError(f'{route}.{key}: {name!r} is not one of the photos')
        return str(files[name])

    def pos(key):
        v = d.get(key)
        if not isinstance(v, (int, float)) or v <= 0:
            raise ValueError(f'{route}.{key} must be a positive number (got {v!r})')
        return f'{v:g}'

    o = ['--out', str(out)]
    if route == 'box':
        size = d.get('size_mm') or []
        if len(size) != 3 or min(size[:2]) <= 0 or size[2] < 0:
            raise ValueError(f'box.size_mm must be [W, H, T] with W, H > 0 and T >= 0 (got {size!r})')
        if size[2] == 0 and not f('side', False):
            raise ValueError('box: the thickness is unknown (T = 0) and there is no side photo to estimate it from')
        argv = ['box', '--front', f('front')]
        for k in ('back', 'side', 'side2'):
            if f(k, False):
                argv += [f'--{k}', f(k, False)]
        dims = size if size[2] > 0 else size[:2]                       # WxH: the template estimates T from the side
        return argv + ['--size', 'x'.join(f'{v:g}' for v in dims), '--kind', d.get('kind', 'box'),
                       '--look', 'ai', '--ai-model', ai_model] + o
    if route == 'flat':
        return ['flat', '--photo', f('photo'), '--width-cm', pos('width_cm'), '--height-cm', pos('height_cm'),
                '--thickness-mm', pos('thickness_mm')] + o
    if route == 'bottle':
        argv = ['bottle', '--front', f('front'), '--side', f('side')]
        for k in ('back', 'side2'):
            if f(k, False):
                argv += [f'--{k}', f(k, False)]
        look = []
        if d.get('print') in ('photo', 'none'):
            look += ['--print', d['print']]
        if d.get('cap') in ('auto', 'ribbed', 'plain', 'none'):
            look += ['--cap', d['cap']]
        return argv + ['--height-cm', pos('height_cm')] + look + o
    if route == 'revolve':
        return ['revolve', '--photo', f('photo'), '--height-cm', pos('height_cm')] + o
    if route == 'generate':
        size = d.get('size_cm') or []
        if len(size) != 3 or min(size) <= 0:
            raise ValueError(f'generate.size_cm must be three positive numbers (got {size!r})')
        argv = ['gen', '--photo', f"main={f('photo')}@{d['yaw']:g},{d['pitch']:g}"]
        for i, other in enumerate(d.get('others') or []):
            name = other.get('photo', '')
            if name in files and name != d.get('photo'):
                argv += ['--photo', f"p{i + 1}={files[name]}@{other.get('yaw', 0):g},{other.get('pitch', 0):g}"]
        return argv + ['--size', ','.join(f'{v:g}' for v in size), '--ai-model', ai_model] + o
    raise ValueError(f'unknown route {route!r}')


# ------------------------------------------------------------------ the command
def run(inputs, size_cm, out=None, ai_model='sonnet') -> int:
    from .cli import main as kt_main
    from .photos import contact_sheet
    from .inspect import _imread
    t0 = time.perf_counter()
    photos = photo_list(inputs)
    first = photos[0]
    out = Path(out) if out else (first.parent.parent if first.parent.name.lower() == 'jpg' else first.parent) / '3d_auto'
    out.mkdir(parents=True, exist_ok=True)
    work = out / 'route'; work.mkdir(exist_ok=True)
    print(f'kt auto -> {out}  ({len(photos)} photos)')
    sheet = contact_sheet(photos, work / 'sheet.jpg')
    with ThreadPoolExecutor(max_workers=min(4, len(photos))) as ex:
        meas = dict(zip([p.name for p in photos], ex.map(lambda p: measure_photo(p, work), photos)))
    t_meas = time.perf_counter()
    text = (f'Photos: {[p.name for p in photos]} (image 1 shows them in this order, numbered).\n'
            f'Known dimensions (cm, any order): {list(size_cm)}.\n\n{ROUTES}\n\n'
            f'Measurements per photo:\n{json.dumps(meas, ensure_ascii=False)}')
    (work / 'ai_request.txt').write_text(text, encoding='utf-8')
    dec, meta = design.ask([design._jpeg_b64(_imread(sheet), 1600)], text, model=ai_model, cwd=out, schema=SCHEMA, system=SYSTEM)
    t_ai = time.perf_counter()
    files = {p.name: p for p in photos}
    record = {'decision': dec, 'call': meta, 'measurements': meas,
              'timings_s': {'measure': round(t_meas - t0, 2), 'ai_route': round(t_ai - t_meas, 2)}}
    try:
        argv = to_argv(dec, files, out, ai_model)
    except ValueError as e:
        record['error'] = str(e)
        (out / 'route_decision.json').write_text(json.dumps(record, ensure_ascii=False, indent=1), encoding='utf-8')
        print(f'   route decision is not usable: {e}\n   AI said: {dec.get("route")} / {dec.get("reason")}')
        return 2
    record['argv'] = argv
    (out / 'route_decision.json').write_text(json.dumps(record, ensure_ascii=False, indent=1), encoding='utf-8')
    print(f"   [{record['timings_s']['measure']:6.2f}s] measure photos\n   [{record['timings_s']['ai_route']:6.2f}s] "
          f"AI route: {dec['route']} ({dec.get('object')}) - {dec.get('reason')}\n   kt {' '.join(argv[:1])} ...")
    rc = kt_main(argv)
    rep_path = out / 'report.json'
    if rep_path.exists():
        rep = json.loads(rep_path.read_text(encoding='utf-8'))
        route_cost = (rep.get('ai_call') or {}).get('cost_usd') or 0
        rep['auto'] = {'route': dec['route'], 'object': dec.get('object'), 'reason': dec.get('reason'), 'router_call': meta,
                       'router_timings_s': record['timings_s'], 'total_s': round(time.perf_counter() - t0, 2),
                       'ai_cost_usd_total': round((meta.get('cost_usd') or 0) + route_cost, 4)}
        rep_path.write_text(json.dumps(rep, ensure_ascii=False, indent=2, default=str), encoding='utf-8')
        print(f"== auto: route {dec['route']}, total {rep['auto']['total_s']} s, AI {rep['auto']['ai_cost_usd_total']} USD")
    return rc
