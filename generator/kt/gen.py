"""kt gen: a free-form (curved) object as a generated mesh.

  kt gen --photo main=IMG_1.jpg@0,70 [--photo key=P@yaw[,pitch] ...] --size 16,6.6,10.6 [--out DIR]

1. The first photo is cut out (rembg, hands removed) and Hunyuan3D-2.1 (shape only, local GPU; set up with
   setup_gen.ps1 or setup_gen.sh; NVIDIA CUDA, Apple silicon MPS or CPU) generates the shape from it, in a
   separate Python (kt/hy3d_worker.py).
2. Orientation and size come only from measurements. Hunyuan3D puts the object in its own resting pose
   (y up), not in the photo's camera frame (checked on the controller: the photo from above matches the
   generated shape seen from +y). So the generated frame is kept, and only the axis assignment is chosen: of
   the 24 quarter-turn rotations, the one whose bounding box is proportioned most like --size (ties: the
   smallest rotation, i.e. the generator's own pose). Then each axis is scaled to --size and the model is put
   on the ground; the per-axis scale is reported (1.0 = the generated proportions already matched).
3. Materials, one AI call (Claude Code, kt.design.ask):
   --material regions (default, kt/paint.py): a camera is fitted to each photo's cut-out, the photos are projected
   onto the shape, the surface is grouped by colour and candidate marks (symbols, text) are found; the AI gives
   each region a material and keeps the real marks; material borders are moved onto nearby creases.
   --material one: the AI sees the photos and the grey shape from 7 directions and gives one material.
   Reflections and the room's light are not baked in either way. Colours are sRGB, written as linear glTF factors.
Outputs model.glb, compare.jpg, render_hero.png, views.jpg, report.json (timings, AI cost, scale per axis,
GLB checks; with regions also paint/: camera fits over the photos, regions, marks, paint.json). The silhouette
IoU against Katachi's own camera fit is not measured; paint.json records each photo's fitted-camera IoU.
"""
from __future__ import annotations
import json
import os
import subprocess
import sys
import time
from itertools import product
from pathlib import Path

import cv2
import numpy as np

MATERIAL_SYSTEM = ('You decide the material of a 3D model from photos of the real object. '
                   'Answer only through the JSON schema. Be concise.')
MATERIAL_TASK = """Image 1: the photos of the object. Image 2: the 3D shape that was generated from them, seen
from 7 directions in a neutral grey. Decide the material of the whole model (one material): the base colour of
the object's surface (sRGB 0..1) as it would look under neutral white light, roughness and metallic. The photos
contain the room's light (reflections, the lamp's colour): judge the surface itself. The model is shown under
studio light without a room to reflect, so metallic above about 0.5 looks much darker than the photos.
Also say in one sentence how well the shape matches the photos (notes)."""
MATERIAL_SCHEMA = {
    'type': 'object',
    'properties': {'object': {'type': 'string'},
                   'color_rgb': {'type': 'array', 'items': {'type': 'number'}, 'minItems': 3, 'maxItems': 3},
                   'roughness': {'type': 'number'}, 'metallic': {'type': 'number'}, 'notes': {'type': 'string'}},
    'required': ['object', 'color_rgb', 'roughness', 'metallic', 'notes'],
}


# ------------------------------------------------------------------ generator environment
def home() -> Path:
    return Path(os.environ.get('KT_HY3D_HOME') or Path.home() / '.cache' / 'katachi-tools' / 'hy3d')


def gen_python() -> Path:
    return home() / 'venv' / 'Scripts' / 'python.exe' if os.name == 'nt' else home() / 'venv' / 'bin' / 'python'


def available() -> bool:
    return gen_python().is_file() and (home() / 'Hunyuan3D-2.1' / 'hy3dshape').is_dir()


def device() -> str:
    """$KT_HY3D_DEVICE, else the Apple silicon GPU (MPS) on macOS and CUDA elsewhere."""
    return os.environ.get('KT_HY3D_DEVICE') or ('mps' if sys.platform == 'darwin' else 'cuda')


# Generation steps / surface resolution when not given. MPS is several times slower per step than a desktop
# NVIDIA GPU (a published M4 Pro run: 7.6 s per step), so it gets fewer steps and a coarser surface grid.
DEFAULTS = {'cuda': {'steps': 50, 'octree': 384}, 'mps': {'steps': 30, 'octree': 256}, 'cpu': {'steps': 30, 'octree': 256}}


def run_worker(image: Path, out_mesh: Path, settings: dict, timeout=3600) -> dict:
    """Hunyuan3D-2.1 in its own Python; returns the worker's JSON (timings, faces, GPU memory)."""
    if not available():
        script = '.\\setup_gen.ps1' if os.name == 'nt' else './setup_gen.sh'
        raise SystemExit(f'the shape generator is not set up ({home()}); run {script} (about 11-12 GB)')
    dev = device()
    settings = {**DEFAULTS[dev], **{k: v for k, v in settings.items() if v is not None}}
    # -I: the worker sits next to kt/inspect.py etc.; isolated mode keeps its folder (and PYTHONPATH) off sys.path
    cmd = [str(gen_python()), '-I', str(Path(__file__).with_name('hy3d_worker.py')), '--code', str(home() / 'Hunyuan3D-2.1'),
           '--image', str(image), '--out', str(out_mesh), '--device', dev]
    for k, v in settings.items():
        cmd += [f'--{k.replace("_", "-")}', str(v)]
    env = dict(os.environ, HY3DGEN_MODELS=str(home() / 'models'), PYTHONUTF8='1')
    if dev == 'mps':          # operations MPS lacks run on the CPU; no fixed cap below the machine's memory
        env.setdefault('PYTORCH_ENABLE_MPS_FALLBACK', '1')
        env.setdefault('PYTORCH_MPS_HIGH_WATERMARK_RATIO', '0.0')
    t0 = time.perf_counter()
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', env=env, timeout=timeout)
    wall = round(time.perf_counter() - t0, 2)
    lines = [ln for ln in p.stdout.splitlines() if ln.startswith('{')]
    if p.returncode != 0 or not lines:
        raise SystemExit(f'shape generation failed (exit {p.returncode}):\n{p.stderr[-1500:]}')
    res = json.loads(lines[-1])
    res['wall_s'] = wall
    return res


# ------------------------------------------------------------------ geometry (measurement only)
def proportion_error(extent, size):
    """How far the box proportions are from the given size (scale-free: spread of the log ratios)."""
    r = np.log(np.maximum(extent, 1e-9) / np.asarray(size, float))
    return float(np.abs(r - r.mean()).sum())


def quarter_turns():
    """The 24 rotations that map the axes onto the axes, with their rotation angle (degrees)."""
    out = []
    for perm in ((0, 1, 2), (0, 2, 1), (1, 0, 2), (1, 2, 0), (2, 0, 1), (2, 1, 0)):
        for signs in product((1, -1), repeat=3):
            R = np.zeros((3, 3))
            for i, (j, sg) in enumerate(zip(perm, signs)):
                R[i, j] = sg
            if np.linalg.det(R) > 0:
                out.append((R, float(np.degrees(np.arccos(np.clip((np.trace(R) - 1) / 2, -1, 1))))))
    return out


def choose_axes(points, size):
    """The quarter-turn rotation whose axis-aligned box is proportioned most like `size`; errors equal to two
    decimals count as a tie and the smaller rotation wins (the generator's own pose first)."""
    scored = [(round(proportion_error(np.ptp(points @ R.T, 0), size), 2), ang, R) for R, ang in quarter_turns()]
    err, ang, R = min(scored, key=lambda t: (t[0], t[1]))
    return R, ang, err, round(proportion_error(np.ptp(points, 0), size), 3)


def place(mesh, size_cm):
    """Generator frame -> model frame (axis assignment), scaled per axis to size_cm (x, y, z), on the ground, in metres."""
    m = mesh.copy()
    hull = m.convex_hull.vertices if len(m.vertices) > 2000 else m.vertices
    R, ang, err, err0 = choose_axes(np.asarray(hull), size_cm)
    m.apply_transform(_h(R))
    lo, hi = m.bounds
    scale = np.asarray(size_cm, float) / 100 / (hi - lo)
    m.apply_translation(-(lo + hi) / 2)
    m.vertices = m.vertices * scale
    m.apply_translation([0, -m.bounds[0][1], 0])
    rel = scale / np.exp(np.log(scale).mean())
    info = {'rotation_deg': round(ang, 1), 'rotation_matrix': R.astype(int).tolist(),
            'proportion_error_generated': err0, 'proportion_error_chosen': err,
            'scale_per_axis_relative': [round(float(v), 3) for v in rel],
            'note': 'scale_per_axis_relative: 1.0 = the generated proportions already matched --size on that axis'}
    return m, info


def _norm_silhouette(mask, n=96):
    """The mask cropped to its bounding box, padded to a square (aspect kept) and resized: shape only."""
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return np.zeros((n, n), bool)
    crop = mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1].astype(np.uint8)
    h, w = crop.shape; s = max(h, w)
    pad = np.zeros((s, s), np.uint8); pad[(s - h) // 2:(s - h) // 2 + h, (s - w) // 2:(s - w) // 2 + w] = crop
    return cv2.resize(pad * 255, (n, n), interpolation=cv2.INTER_AREA) > 127


def align_view_yaw(glb: Path, photo_mask, yaw, pitch):
    """Which way round the photo looks at the generated shape. The routing AI's yaw is relative to what it calls
    the object's front, the generator has its own front; of yaw + 0/90/180/270 the one whose rendered outline
    (orthographic) matches the photo's cut-out best is taken. Returns (offset_deg, outline agreement per offset)."""
    import shutil
    import tempfile
    from katachi.render import render_glb
    tmp = Path(tempfile.mkdtemp(prefix='kt_view_'))
    try:
        views = {f'o{k}': ((yaw + k) % 360, pitch) for k in (0, 90, 180, 270)}
        render_glb(Path(glb), tmp, size=256, views=tuple(views), transparent=True,
                   camera_specs={v: {'angles': a} for v, a in views.items()})
        ref = _norm_silhouette(np.asarray(photo_mask, bool))
        scores = {}
        for v in views:
            rgba = cv2.imread(str(tmp / f'{v}.png'), cv2.IMREAD_UNCHANGED)
            sil = _norm_silhouette(rgba[..., 3] > 0)
            scores[int(v[1:])] = round(float((sil & ref).sum() / max((sil | ref).sum(), 1)), 3)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    best = max(scores, key=lambda k: (scores[k], -min(k, 360 - k)))
    return best, scores


def _h(R):
    T = np.eye(4); T[:3, :3] = R
    return T


def with_material(mesh, rgb, roughness, metallic):
    import trimesh
    m = mesh.copy()
    rgba = (np.clip(list(rgb) + [1.0], 0, 1) * 255).round().astype(np.uint8)
    mat = trimesh.visual.material.PBRMaterial(name='body', baseColorFactor=rgba, roughnessFactor=float(np.clip(roughness, 0, 1)),
                                              metallicFactor=float(np.clip(metallic, 0, 1)), doubleSided=False)
    m.visual = trimesh.visual.TextureVisuals(material=mat)
    return m


def export_glb(mesh, path: Path, rgb=None):
    """GLB with unit vertex normals. rgb (sRGB 0..1): written as the material's exact linear baseColorFactor, as
    Katachi's own GLB writer does (glTF factors are linear)."""
    import trimesh
    from .paint import srgb_to_linear, write_glb
    mesh.fix_normals()
    n = mesh.vertex_normals
    mesh.vertex_normals = n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
    factors = {'body': srgb_to_linear([*np.clip(rgb, 0, 1), 1.0])} if rgb is not None else {}
    return write_glb(trimesh.Scene(mesh), Path(path), factors)


def material_one(ws, placed, grey, size_cm, out, ai_model):
    """--material one: one AI call sees the photos and the grey shape from 7 directions; one material for all."""
    from .inspect import views_sheet, _imread
    from . import design
    views = views_sheet(grey, out / 'gen' / 'shape_views.jpg', size=320)
    sheet = design._row([design._label(_imread(p.source), k) for k, p in ws.photos.items()], 480)
    imgs = [design._jpeg_b64(sheet, 1400), design._jpeg_b64(_imread(views), 1600)]
    text = MATERIAL_TASK + f'\n\nThe object is {size_cm[0]:g} x {size_cm[1]:g} x {size_cm[2]:g} cm (width x height x depth).'
    (out / 'ai_request.txt').write_text(text, encoding='utf-8')
    dec, meta = design.ask(imgs, text, model=ai_model, cwd=out, schema=MATERIAL_SCHEMA, system=MATERIAL_SYSTEM)
    glb = export_glb(with_material(placed, dec['color_rgb'], dec['roughness'], dec['metallic']), out / 'model.glb', dec['color_rgb'])
    return glb, dec, meta, {'mode': 'one'}


def material_regions(ws, placed, size_cm, out, ai_model, timer):
    """--material regions (kt/paint.py): photos projected onto the shape, regions and mark candidates measured,
    one AI call gives each region a material and picks the real marks; borders moved onto nearby creases."""
    from .inspect import _imread
    from . import design, paint
    keys = list(ws.photos)
    photos = [{'key': k, 'image': p.source, 'mask': p.folder / 'mask.png', 'yaw': p.yaw, 'pitch': p.pitch} for k, p in ws.photos.items()]
    res = paint.analyse(placed, photos, out / 'paint', keys[0])
    timer.mark('cameras + projection + regions + marks')
    sheet = design._row([design._label(_imread(p.source), k) for k, p in ws.photos.items()], 480)
    imgs = [design._jpeg_b64(sheet, 1400), design._jpeg_b64(res['colours_img'], 1600), design._jpeg_b64(res['regions_img'], 1600)]
    if res['marks_img'] is not None:
        imgs.append(design._jpeg_b64(res['marks_img'], 1800))
    text = (paint.request_text(res) + f'\n\nThe object is {size_cm[0]:g} x {size_cm[1]:g} x {size_cm[2]:g} cm '
            '(width x height x depth).')
    (out / 'ai_request.txt').write_text(text, encoding='utf-8')
    dec, meta = design.ask(imgs, text, model=ai_model, cwd=out, schema=paint.SCHEMA, system=paint.SYSTEM)
    timer.mark('AI material (1 call)')
    mats, kept, missing = paint.materials(dec, res['stats'], res['marks'])
    res['labels'], moved = paint.snap_borders(res['mesh'], res['labels'], mats, res['source'] >= 0)
    scene, factors = paint.build_scene(res, mats, kept)
    glb = paint.write_glb(scene, out / 'model.glb', factors)
    info = {'mode': 'regions', **res['report'], 'kept_marks': sorted(kept), 'regions_missing_in_answer': missing,
            'border_moved_share': moved, 'folder': str(out / 'paint')}
    return glb, dec, meta, info


# ------------------------------------------------------------------ the command
def build(photos: dict, size_cm, out: Path, settings: dict, ai_model='sonnet', title=None, render_size=768,
          material='regions') -> dict:
    import trimesh
    from .engine import Workspace
    from .report import Timer, compare_sheet, hero_render
    from .segment import object_mask
    from .inspect import views_sheet, _imread
    from . import design
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    timer = Timer()
    ws = Workspace(out)
    keys = list(photos)
    for k, (path, yaw, pitch) in photos.items():
        ws.add_photo(k, Path(path), yaw, pitch)
    for k in keys:
        m, info = object_mask(ws.photos[k].source)
        ws.set_mask(k, m, info)
    timer.mark('photos + cut-outs (rembg)')
    main = ws.photos[keys[0]]
    bgr = _imread(main.source)
    alpha = (main.mask * 255).astype(np.uint8)
    ys, xs = np.nonzero(main.mask)
    pad = int(0.05 * max(np.ptp(xs), np.ptp(ys)))
    y0, y1 = max(0, ys.min() - pad), min(bgr.shape[0], ys.max() + pad + 1)
    x0, x1 = max(0, xs.min() - pad), min(bgr.shape[1], xs.max() + pad + 1)
    rgba = np.dstack([bgr, alpha])[y0:y1, x0:x1]
    gdir = out / 'gen'; gdir.mkdir(exist_ok=True)
    cutout = gdir / 'input.png'
    cv2.imencode('.png', rgba)[1].tofile(str(cutout))
    raw = gdir / 'raw.glb'
    worker = run_worker(cutout, raw, settings)
    timer.mark('shape generation (Hunyuan3D-2.1)')
    mesh = trimesh.load(raw, force='mesh', process=False)
    placed, pose = place(mesh, size_cm)
    grey = out / 'gen' / 'shape_grey.glb'
    export_glb(with_material(placed, [0.6, 0.6, 0.6], 0.6, 0.0), grey)
    offset, agreement = align_view_yaw(grey, main.mask, main.yaw, main.pitch)
    for p in ws.photos.values():                     # the photos keep their directions relative to each other
        p.yaw = (p.yaw + offset + 180) % 360 - 180
    pose.update({'view_yaw_offset_deg': offset, 'main_view_outline_agreement': agreement,
                 'outline_note': 'shape-only agreement of the main photo cut-out and the model outline seen from yaw + offset '
                                 '(bounding-box normalised, orthographic); used to line up the comparison views, not a 3D accuracy'})
    timer.mark('orient + scale')
    if material == 'regions':
        glb, dec, meta, paint_info = material_regions(ws, placed, size_cm, out, ai_model, timer)
    else:
        glb, dec, meta, paint_info = material_one(ws, placed, grey, size_cm, out, ai_model)
        timer.mark('AI material (1 call)')
    (out / 'ai_decision.json').write_text(json.dumps({'decision': dec, 'call': meta}, ensure_ascii=False, indent=1), encoding='utf-8')
    from katachi.glb import validate_glb
    from katachi.mesh_audit import independently_read_glb
    try:
        val = validate_glb(glb)
    except Exception as e:                                    # report, do not hide
        val = {'errors': [f'validator failed: {e}'], 'warnings': []}
    ind = independently_read_glb(glb)
    compare_sheet(ws, glb, out / 'compare.jpg')
    hero_render(glb, out / 'render_hero.png', angles=(30, 20), size=render_size)
    views_sheet(glb, out / 'views.jpg', {k: (str(p.path), p.yaw, p.pitch) for k, p in ws.photos.items()})
    timer.mark('checks + compare sheet + renders')
    errors = list(val.get('errors') or []) + list(ind.get('errors') or [])
    report = {
        'template': 'gen', 'title': title or dec.get('object'), 'inputs': {k: str(p.path) for k, p in ws.photos.items()},
        'arguments': {'photos': {k: list(v) for k, v in photos.items()}, 'size_cm': list(size_cm), 'settings': settings,
                      'ai_model': ai_model, 'material': material},
        'size_m': (np.ptp(np.asarray(val['bounds']), 0)).round(4).tolist() if val.get('bounds') else None,
        'quality': {'glb_errors': errors, 'glb_warnings': val.get('warnings') or [], 'triangles': val.get('triangles'),
                    'independent_read': ind, 'silhouette_iou': 'not measured (generated mesh; no Katachi camera fit)',
                    'status': 'error' if errors else 'ok'},
        'generator': worker, 'pose': pose, 'material': dec, 'paint': paint_info, 'notes': [dec.get('notes', '')],
        'timings_s': timer.stages, 'total_s': timer.total(), 'live_api_calls': 1, 'ai_call': meta,
        'outputs': {'model': str(glb), 'compare': str(out / 'compare.jpg'), 'hero': str(out / 'render_hero.png'),
                    'views': str(out / 'views.jpg')},
        'license': 'shape by Tencent Hunyuan3D 2.1 (Tencent Hunyuan 3D 2.1 Community License)',
    }
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2, default=str), encoding='utf-8')
    g = worker['timings_s']
    print(f"\n== gen: {report['quality']['status'].upper()}  total {report['total_s']} s  size(m) {report['size_m']}")
    print(f"   generator: load {g['load_model']} s, generate {g['generate']} s, post {g['postprocess']} s, "
          f"{worker['faces']} faces, GPU {worker['max_gpu_memory_gb']} GB")
    print(f"   pose: rotation {pose['rotation_deg']} deg, scale per axis {pose['scale_per_axis_relative']}")
    if material == 'regions':
        print(f"   AI: {meta['model']} {meta['wall_s']} s {meta['cost_usd']} USD; {len(dec['regions'])} regions, "
              f"{len(paint_info['kept_marks'])} of {len(paint_info['marks'])} marks kept, border moved {paint_info['border_moved_share']}")
    else:
        print(f"   AI: {meta['model']} {meta['wall_s']} s {meta['cost_usd']} USD; material {dec['color_rgb']} r{dec['roughness']} m{dec['metallic']}")
    for e in errors:
        print(f'   ERROR GLB: {e}')
    print(f'   -> {out}')
    return report
