"""box: books, boxes, cards — a cuboid with the photographed faces pasted on.

Faces are found by straight-edge quad detection (no rembg needed). A face whose corner lies outside
the photo is recovered from the known width:height and an assumed phone focal length; the unseen
strip is filled with the neighbouring plain colour. Thickness can be estimated from a spine photo.
"""
from __future__ import annotations
from concurrent.futures import ProcessPoolExecutor
import cv2
import numpy as np
from PIL import Image
from scipy.optimize import least_squares

from ..engine import BuildPlan, RegionSpec
from ..lighting import flatten_face, glare_fraction, describe_flatten
from ..hands import remove_hands_on_face
from ..fusion import fuse_face_photos
from katachi.images import sanitize_image
from pathlib import Path
from .. import quad_detect as qd

J = 0.04          # cm, cover / panel thickness
GLARE_GLOSSY = 0.002   # share of blob-sized specular highlights that marks a glossy cover (O'Reilly jacket 0.0048, kraft 0)
EDGE_MARGIN = 0.003
FACES = {  # key: (yaw, pitch, detector)
    'front': (0, 0, 'face'), 'back': (180, 0, 'face'), 'side': (-90, 0, 'strip'), 'side2': (90, 0, 'strip'), 'top': (0, 89, 'face')}


def add_args(p):
    multi = ' (several photos allowed: the first is used, the others fill what a finger or glare hides in it)'
    p.add_argument('--front', required=True, nargs='+', help='front face' + multi)
    p.add_argument('--back', nargs='+', help='back face' + multi)
    p.add_argument('--side', '--spine', dest='side', nargs='+', help='left side / book spine (camera on the left of the front)' + multi)
    p.add_argument('--side2', nargs='+', help='right side (box only)')
    p.add_argument('--top', nargs='+', help='top face (box only)')
    p.add_argument('--size', required=True, help='WxH or WxHxT in mm, e.g. 183x233 or 183x233x22')
    p.add_argument('--kind', choices=['book', 'box'], default='book')
    p.add_argument('--corners', help='JSON {face: [[x,y]x4]} manual corners (TL,TR,BR,BL normalised)')
    p.add_argument('--edge-inset', type=float, default=0.008, help='sample faces this fraction inside their edges')
    p.add_argument('--finish', choices=['auto', 'matte', 'glossy'], default='auto',
                   help='surface finish; auto = glossy when the photos show specular highlights')
    p.add_argument('--hands', choices=['remove', 'keep'], default='remove',
                   help='remove a hand/fingers that reach onto a face from its edge (inpainted from the cover)')
    p.add_argument('--lighting', choices=['flatten', 'keep'], default='flatten',
                   help='flatten: remove shadows/gradients baked into the photos (default); keep: raw pixels')
    p.add_argument('--look', choices=['photo', 'ai'], default='photo',
                   help='photo: every face is the perspective-corrected photo (no AI). ai: the program measures the '
                        'faces and sides, one AI call (Claude Code, no API key) decides materials, which marks are parts '
                        'and which faces keep their print; plain faces become materials, so reflections are not baked in')
    p.add_argument('--ai-model', default='sonnet', help='model for --look ai (Claude Code model name)')
    p.add_argument('--spine-trim', type=float, default=0.0,
                   help='trim each long edge of the spine photo by this fraction, for rounded spines whose photo '
                        'repeats the cover edges (e.g. 0.1); default 0 = no trim')


# ------------------------------------------------------------------ geometry helpers (from make_book.py)
def homography(corners):
    return cv2.getPerspectiveTransform(np.float32([[0, 0], [1, 0], [1, 1], [0, 1]]), np.float32(corners))


def apply_h(h, pts):
    return cv2.perspectiveTransform(np.float32(pts).reshape(-1, 1, 2), h).reshape(-1, 2)


def _line(a, b):
    d = np.asarray(b, float) - np.asarray(a, float)
    return np.asarray(a, float), d / np.linalg.norm(d)


def _dist(p, line):
    a, d = line
    return float((np.asarray(p) - a) @ np.array([-d[1], d[0]]))


def recover_clipped(corners, clipped, img_size, face_mm):
    """One side on the image border: fit a camera pose to the 3 real sides with the known face aspect."""
    if not clipped:
        return np.array(corners), 'none'
    if len(clipped) > 1:
        raise ValueError(f'more than one side outside the photo ({clipped}); retake with the whole face visible')
    W, H = img_size
    px = np.array(corners) * [W, H]
    side = ['top', 'right', 'bottom', 'left'].index(clipped[0])
    cidx = {side, (side + 1) % 4}
    kidx = [i for i in range(4) if i not in cidx]
    adj = {(side + 1) % 4: _line(px[(side + 1) % 4], px[(side + 2) % 4]), side: _line(px[(side + 3) % 4], px[side])}
    fw, fh = face_mm
    obj = np.array([[0, 0, 0], [fw, 0, 0], [fw, fh, 0], [0, fh, 0]], float)
    f = 0.72 * max(W, H)
    K = np.array([[f, 0, W / 2], [0, f, H / 2], [0, 0, 1]])
    proj = lambda p: cv2.projectPoints(obj, p[:3], p[3:], K, None)[0].reshape(-1, 2)

    def res(p):
        c = proj(p)
        return np.array([*(c[kidx[0]] - px[kidx[0]]), *(c[kidx[1]] - px[kidx[1]])] + [_dist(c[i], adj[i]) for i in cidx])

    _, rv, tv = cv2.solvePnP(obj, px.astype(np.float64), K, None, flags=cv2.SOLVEPNP_IPPE)
    sol = least_squares(res, np.r_[rv.ravel(), tv.ravel()])
    return proj(sol.x) / [W, H], f'pose-fit (max residual {np.abs(sol.fun).max():.1f}px, f={f:.0f}px assumed)'


def inset_quad(corners, u0, u1, v0, v1):
    """Image quad of the face sub-rectangle [u0,u1]x[v0,v1] (perspective-correct)."""
    return apply_h(homography(corners), [[u0, v0], [u1, v0], [u1, v1], [u0, v1]])


def coverage_inside_frame(corners):
    h = homography(corners)
    lo, hi = EDGE_MARGIN, 1 - EDGE_MARGIN
    inside = lambda pts: bool(((pts >= lo) & (pts <= hi)).all())
    edge_in = lambda p, q: inside(apply_h(h, [p, q]))
    u0, u1, v0, v1 = 0.0, 1.0, 0.0, 1.0
    for _ in range(3):
        while not edge_in((u1, v0), (u1, v1)) and u1 > 0.5: u1 -= 0.002
        while not edge_in((u0, v0), (u0, v1)) and u0 < 0.5: u0 += 0.002
        while not edge_in((u0, v0), (u1, v0)) and v0 < 0.5: v0 += 0.002
        while not edge_in((u0, v1), (u1, v1)) and v1 > 0.5: v1 -= 0.002
    pts = apply_h(h, [[u0, v0], [u1, v0], [u1, v1], [u0, v1]])
    if not inside(pts):
        raise ValueError('could not find a face region inside the photo')
    return [round(u0, 4), round(u1, 4), round(v0, 4), round(v1, 4)], np.clip(pts, 0, 1)


def estimate_thickness(strip, img_size, height_mm):
    W, H = img_size
    tl, tr, br, bl = np.array(strip) * [W, H]
    width_mid = np.linalg.norm(((tl + bl) / 2) - ((tr + br) / 2))
    length = (np.linalg.norm(bl - tl) + np.linalg.norm(br - tr)) / 2
    return height_mm * width_mid / length


def rect(x0, x1, y0, y1):
    return [[round(x0, 4), round(y0, 4)], [round(x1, 4), round(y0, 4)], [round(x1, 4), round(y1, 4)], [round(x0, 4), round(y1, 4)]]


def panels(prefix, art, plain, u_rng, v_rng, cov, transform):
    """Art panel over the observed coverage + plain panels for the unobserved remainder (local XY face)."""
    x_lo, x_hi = u_rng; y_lo, y_hi = v_rng
    u0, u1, v0, v1 = cov
    X = lambda u: x_lo + (x_hi - x_lo) * u
    Y = lambda v: y_hi - (y_hi - y_lo) * v
    out = [{'id': f'{prefix}_art', 'geometry': {'kind': 'extrusion', 'outline': rect(X(u0), X(u1), Y(v1), Y(v0)), 'depth': J},
            'material': art, 'transform': transform, 'uv_mode': 'planar_xy', 'confidence': 0.75}]
    rest = []
    if v0 > 1e-4: rest.append(('top', rect(X(0), X(1), Y(v0), Y(0))))
    if v1 < 1 - 1e-4: rest.append(('bottom', rect(X(0), X(1), Y(1), Y(v1))))
    if u0 > 1e-4: rest.append(('ustart', rect(X(0), X(u0), Y(v1), Y(v0))))
    if u1 < 1 - 1e-4: rest.append(('uend', rect(X(u1), X(1), Y(v1), Y(v0))))
    for name, o in rest:
        out.append({'id': f'{prefix}_unobserved_{name}', 'geometry': {'kind': 'extrusion', 'outline': o, 'depth': J},
                    'material': plain, 'transform': transform, 'inferred': True, 'confidence': 0.5})
    return out


def _detect(job):
    key, path, kind = job
    r = qd.detect_strip(path) if kind == 'strip' else qd.detect_face(path)
    return key, r


def _detect_safe(job):
    try:
        return _detect(job)
    except ValueError:
        return job[0], None


def plain_color(path, cov):
    arr = np.asarray(Image.open(path).convert('RGB'), float) / 255
    u0, u1, v0, v1 = cov or [0, 1, 0, 1]
    k = lambda n: max(4, n // 25)
    if u1 < 1: s = arr[:, -k(arr.shape[1]):]
    elif u0 > 0: s = arr[:, :k(arr.shape[1])]
    elif v1 < 1: s = arr[-k(arr.shape[0]):]
    else: s = arr[:k(arr.shape[0])]
    return [round(float(v), 3) for v in np.median(s.reshape(-1, 3), 0)]


# ------------------------------------------------------------------ plan
def plan(args, ws, timer) -> BuildPlan:
    import json
    dims = [float(v) for v in args.size.lower().split('x')]
    if len(dims) not in (2, 3):
        raise SystemExit('--size must be WxH or WxHxT (mm)')
    given = {k: getattr(args, k) for k in FACES if getattr(args, k, None)}
    if args.kind == 'book':
        given = {k: v for k, v in given.items() if k in ('front', 'back', 'side')}
    extras = {}                       # face -> [(sanitized png, original path)] of additional photos
    for k, paths in given.items():
        yaw, pitch, _ = FACES[k]
        ws.add_photo(k, paths[0], yaw, pitch)
        for i, extra in enumerate(paths[1:], 1):
            src = ws.out / 'extras' / f'{k}_{i}' / 'source.png'
            sanitize_image(Path(extra).read_bytes(), src)
            extras.setdefault(k, []).append((src, Path(extra)))
    timer.mark('sanitize photos')

    manual = json.loads(open(args.corners, encoding='utf-8').read()) if args.corners else {}
    # detect on the original photos (validated there; corners are normalised, so they apply to the sanitized copy)
    jobs = [(k, str(ws.photos[k].path), FACES[k][2]) for k in given if k not in manual]
    jobs += [(f'{k}#{i}', str(orig), FACES[k][2]) for k, lst in extras.items() for i, (_, orig) in enumerate(lst)]
    det = {k: qd.QuadResult(corners=v, method='manual') for k, v in manual.items() if k in given}
    det_extra = {}
    if jobs:
        with ProcessPoolExecutor(max_workers=min(4, len(jobs))) as ex:
            for k, r in ex.map(_detect_safe, jobs):
                if '#' in k:
                    det_extra[k] = r
                elif r is not None:
                    det[k] = r
                else:
                    raise SystemExit(f'{k}: no face found in the photo; pass --corners')
    timer.mark('detect faces (parallel)')

    notes, warnings = [], []
    for k, r in det.items():
        sup = r.notes[0] if r.notes else ''
        nums = [float(x) for x in __import__('re').findall(r'\d\.\d+', sup)]
        if nums and min(nums) < 0.6:
            warnings.append(f'{k}: weak edge support {min(nums):.2f}; check review in compare.jpg or pass --corners')
        notes.append(f'{k}: {r.method}, clipped {r.clipped_sides}')

    W_mm, H_mm = dims[0], dims[1]
    if len(dims) == 3:
        T_mm = dims[2]
    elif 'side' in det:
        T_mm = round(estimate_thickness(det['side'].corners, ws.photos['side'].size, H_mm), 1)
        notes.append(f'thickness {T_mm} mm estimated from the side photo')
    else:
        T_mm = 20.0; warnings.append('thickness unknown: 20 mm assumed (pass WxHxT)')
    face_mm = {'front': (W_mm, H_mm), 'back': (W_mm, H_mm), 'top': (W_mm, T_mm), 'side': (T_mm, H_mm), 'side2': (T_mm, H_mm)}

    if args.look == 'ai':
        if extras:
            warnings.append('extra photos per face are not used with --look ai')
        return _plan_ai(args, ws, timer, det, face_mm, (W_mm, H_mm, T_mm), notes, warnings)

    regions, cov, quads, glare = [], {}, {}, {}
    spine_trim = args.spine_trim
    e = args.edge_inset
    for k, r in det.items():
        p = ws.photos[k]
        if FACES[k][2] == 'face':
            full, how = recover_clipped(r.corners, r.clipped_sides, p.size, face_mm[k])
            cov[k], _ = coverage_inside_frame(full)
            u0, u1, v0, v1 = cov[k]
            e = args.edge_inset   # sample slightly inside the edges: wavy/curled edges otherwise pull in background
            quad = inset_quad(full, u0 + e, u1 - e, v0 + e, v1 - e)
            if how != 'none':
                miss = 1 - (u1 - u0) * (v1 - v0)
                notes.append(f'{k}: hidden corner recovered by {how}; {miss:.0%} of the face is outside the photo (plain fill)')
        else:
            # A rounded spine photo also shows the curve onto the covers. How much depends on the book and
            # could not be measured reliably (correlation and feature matching both failed on real spines),
            # so nothing is trimmed unless the caller passes --spine-trim for this work.
            quad = inset_quad(np.clip(np.array(r.corners), 0, 1), spine_trim, 1 - spine_trim, 0.01, 0.99)
            cov[k] = [0, 1, 0, 1]
            if spine_trim:
                notes.append(f'{k}: long edges trimmed by {spine_trim:.0%} of the strip width (--spine-trim)')
            if r.clipped_sides:
                notes.append(f'{k}: strip reaches the photo border at {r.clipped_sides}; treated as the face end')
        quads[k] = np.clip(quad, 0, 1)
        if FACES[k][2] == 'face':   # specular highlights, measured before any correction, away from the edges
            glare[k] = glare_fraction(p.source, np.clip(inset_quad(full, u0 + 0.05, u1 - 0.05, v0 + 0.05, v1 - 0.05), 0, 1))
        others = []
        for i, (src, orig) in enumerate(extras.get(k, [])):
            r2 = det_extra.get(f'{k}#{i}')
            if r2 is None:
                warnings.append(f'{k}: extra photo {orig.name} ignored (face not found)')
                continue
            if FACES[k][2] == 'face':
                full2, _ = recover_clipped(r2.corners, r2.clipped_sides, p.size, face_mm[k])
                c0, c1, c2, c3 = cov[k]
                q2 = inset_quad(full2, c0 + e, c1 - e, c2 + e, c3 - e)
            else:
                q2 = inset_quad(np.clip(np.array(r2.corners), 0, 1), spine_trim, 1 - spine_trim, 0.01, 0.99)
            others.append((src, q2.tolist()))
        if others and args.hands == 'remove':
            fu = fuse_face_photos(p.source, quads[k], others, use_glare=FACES[k][2] == 'face')
            if fu.get('applied'):
                notes.append(f'{k}: fused with {len(others)} more photo(s): {fu["hole_share"]:.1%} of the face was covered '
                             f'(finger/glare); {fu["from_other_photos"]:.0%} of that taken from the other photo(s), '
                             f'{fu["inpainted_share_of_hole"]:.0%} inpainted')
            else:
                notes.append(f'{k}: {len(others)} more photo(s) given; {fu.get("reason")}')
        elif args.hands == 'remove':
            hd = remove_hands_on_face(p.source, quads[k])
            if hd.get('applied'):
                notes.append(f'{k}: hand/fingers on the face removed and filled from the surrounding cover ({hd["hand_share"]:.1%}; fill: {hd.get("fill", "paper")})')
                if hd['hand_share'] > 0.03:
                    warnings.append(f'{k}: a hand covered {hd["hand_share"]:.1%} of the face; the filled area is a guess '
                                    '(a second photo with the finger elsewhere gives the real pixels), check compare.jpg')
        if args.lighting == 'flatten':
            notes.append(f'{k}: ' + describe_flatten(flatten_face(p.source, quads[k], cells=12 if FACES[k][2] == 'face' else 4)))
        ws.set_mask(k, ws.polygon_mask(k, np.clip(np.array(r.corners), 0, 1)), {'segmentation': 'detected quad'})
        qpx = np.asarray(quad) * p.size
        long_px = max(np.linalg.norm(qpx[3] - qpx[0]), np.linalg.norm(qpx[2] - qpx[1]))
        fw, fh = face_mm[k]
        u0, u1, v0, v1 = cov[k]
        aspect = fw * (u1 - u0) / (fh * (v1 - v0))
        out_h = int(min(2048, max(256, long_px * 1.2)))
        out_w = int(max(16, min(2048, round(out_h * aspect))))
        regions.append(RegionSpec(k, k, {'front': '表', 'back': '裏', 'side': '背/左側面', 'side2': '右側面', 'top': '天面'}[k],
                                  np.round(quad, 5).tolist(), (out_w, out_h)))
    timer.mark('corner recovery + regions planned')

    glossy = args.finish == 'glossy' or (args.finish == 'auto' and max(glare.values(), default=0) >= GLARE_GLOSSY)
    rough = 0.35 if glossy else 0.85
    notes.append(f'finish: {"glossy" if glossy else "matte"} (roughness {rough}; highlight share per face '
                 f'{ {k: round(v, 4) for k, v in glare.items()} }, threshold {GLARE_GLOSSY})')
    W, H, T = W_mm / 10, H_mm / 10, T_mm / 10
    title = args.title or ('Book' if args.kind == 'book' else 'Box')
    assumptions = [f'レシピ単位は cm。{W_mm:g} x {H_mm:g} mm は入力値、厚み {T_mm:g} mm は' + ('入力値。' if len(dims) == 3 else '推定値。'),
                   '各面の模様は写真の画素を遠近補正したもの。写っていない面は無地。',
                   ('撮影時の影・明るさのムラは、紙の地の明るさを基準にならした（色の比率は保持）。' if args.lighting == 'flatten'
                    else '撮影時の光沢・影は画像に残っている。')]

    def scene_fn(tex):
        plain = {k: plain_color(tex[k]['path'], cov[k]) for k in tex}
        default_plain = plain.get('front', [0.85, 0.85, 0.83])
        mats = [{'id': f'{k}_art', 'color': [1, 1, 1, 1], 'roughness': rough, 'image_id': tex[k]['id']} for k in tex]
        mats += [{'id': f'{k}_plain', 'color': [*plain[k], 1], 'roughness': rough} for k in tex]
        mats += [{'id': 'plain', 'color': [*default_plain, 1], 'roughness': rough},
                 {'id': 'page_paper', 'color': [0.90, 0.88, 0.83, 1], 'roughness': 0.9, 'pattern': 'paper', 'pattern_strength': 0.05}]
        parts = []
        zf = T / 2 - J / 2
        if args.kind == 'book':
            parts.append({'id': 'page_block', 'geometry': {'kind': 'rounded_box', 'size': [round(W - J, 4), round(H - 0.004, 4), round(T - 2 * J, 4)], 'bevel': 0.06},
                          'material': 'page_paper', 'transform': {'translation': [round(J / 2, 4), round(H / 2, 4), 0]}, 'inferred': True, 'confidence': 0.55})
            fx = (-W / 2 + J, W / 2); bx = (-W / 2, W / 2 - J)
        else:
            parts.append({'id': 'core', 'geometry': {'kind': 'rounded_box', 'size': [round(W - 2 * J, 4), round(H - 2 * J, 4), round(T - 2 * J, 4)], 'bevel': 0.02},
                          'material': 'plain', 'transform': {'translation': [0, round(H / 2, 4), 0]}, 'inferred': True, 'confidence': 0.5})
            fx = (-W / 2, W / 2); bx = (-W / 2, W / 2)
        layout = {
            'front': (fx, (0, H), {'translation': [0, 0, round(zf, 4)]}),
            'back': (bx, (0, H), {'translation': [0, 0, round(-zf, 4)], 'rotation_deg': [0, 180, 0]}),
            'side': ((-T / 2, T / 2), (0, H), {'translation': [round(-W / 2 + J / 2, 4), 0, 0], 'rotation_deg': [0, -90, 0]}),
            'side2': ((-T / 2 + J, T / 2 - J), (0, H), {'translation': [round(W / 2 - J / 2, 4), 0, 0], 'rotation_deg': [0, 90, 0]}),
            'top': ((-W / 2 + J, W / 2 - J), (-T / 2 + J, T / 2 - J), {'translation': [0, round(H - J / 2, 4), 0], 'rotation_deg': [-90, 0, 0]}),
        }
        for k, (u_rng, v_rng, tf) in layout.items():
            if k in tex:
                parts += panels(k, f'{k}_art', f'{k}_plain', u_rng, v_rng, cov[k], tf)
            elif args.kind == 'book' and k in ('front', 'back', 'side'):
                # no photo for this cover face: plain cover colour instead of exposing the page block
                parts.append({'id': f'{k}_plain', 'geometry': {'kind': 'extrusion', 'outline': rect(*u_rng, *v_rng), 'depth': J},
                              'material': 'plain', 'transform': tf, 'inferred': True, 'confidence': 0.4})
        return {'schema_version': '1.0', 'title': title, 'height_m': round(H_mm / 1000, 4), 'seed': 1, 'controls': [],
                'assumptions': assumptions, 'materials': mats, 'parts': parts}

    return BuildPlan(title=title, height_m=H_mm / 1000, scene_fn=scene_fn, regions=regions, texture_size=2048,
                     notes=notes, warnings=warnings, extra={'hero_angles': (-32, 16) if 'side' in det else (30, 16), 'size_mm': (W_mm, H_mm, T_mm),
                            # narrow side photos are dominated by perspective: their IoU is reported, not judged
                            'iou_informational': [k for k in ('side', 'side2') if k in det]})


# ------------------------------------------------------------------ --look ai
def _plan_ai(args, ws, timer, det, face_mm, dims_mm, notes, warnings) -> BuildPlan:
    """Measure faces and sides, ask one AI call for the decisions, build the recipe from both (kt.design)."""
    import json
    from concurrent.futures import ThreadPoolExecutor
    from .. import design
    W_mm, H_mm, T_mm = dims_mm
    W, H, T = W_mm / 10, H_mm / 10, T_mm / 10
    full, cov = {}, {}
    for k, r in det.items():
        p = ws.photos[k]
        ws.set_mask(k, ws.polygon_mask(k, np.clip(np.array(r.corners), 0, 1)), {'segmentation': 'detected quad'})
        if k in design.FACE_KEYS:
            full[k], how = recover_clipped(r.corners, r.clipped_sides, p.size, face_mm[k])
            cov[k], _ = coverage_inside_frame(full[k])
            if how != 'none':
                notes.append(f'{k}: hidden corner recovered by {how}')
    timer.mark('corner recovery')
    mdir = ws.out / 'measure'
    strips = {k: det[k].corners for k in design.EDGE_KEYS if k in det}
    with ThreadPoolExecutor(max_workers=2) as ex:
        ff = ex.submit(design.measure_faces, ws, full, (W, H), mdir)
        fe = ex.submit(design.measure_edges, ws, strips, {k: (H, T) for k in strips}, mdir)
        faces, edges = ff.result(), fe.result()
    for k, r in faces.items():
        if not r['orientation_ok']:
            warnings.append(f'{k}: the photo shows the face turned by 90 degrees relative to --size; marks may be misplaced')
    timer.mark('measure faces + sides')
    imgs, text, _ = design.request(ws, faces, edges, (W, H, T))
    (ws.out / 'ai_request.txt').write_text(text, encoding='utf-8')
    dec, meta = design.ask(imgs, text, model=args.ai_model, cwd=ws.out)
    (ws.out / 'ai_decision.json').write_text(json.dumps({'decision': dec, 'call': meta}, ensure_ascii=False, indent=1), encoding='utf-8')
    timer.mark('AI decision (1 call)')
    seam = 'yes' if (dec.get('seam') or {}).get('present') else 'no'
    notes.append(f"AI ({meta['model']}): 1 call, {meta['wall_s']} s, {meta['cost_usd']} USD, "
                 f"{meta['input_tokens']} in / {meta['output_tokens']} out tokens; object: {dec.get('object')}")
    notes.append(f"AI: photo kept on {dec.get('faces_use_photo') or 'no face'}; {len(dec.get('marks', []))} marks as parts; "
                 f"seam {seam}; {dec.get('notes', '')}")
    regions = []
    e = args.edge_inset
    for k in dec.get('faces_use_photo', []):
        if k in full:
            u0, u1, v0, v1 = cov[k]
            if (u1 - u0) * (v1 - v0) < 0.999:
                notes.append(f'{k}: {1 - (u1 - u0) * (v1 - v0):.0%} of the face is outside the photo (body colour there)')
            quad = np.clip(inset_quad(full[k], u0 + e, u1 - e, v0 + e, v1 - e), 0, 1)
            aspect = W / H
        elif k in strips:
            trim = args.spine_trim
            quad = np.clip(inset_quad(np.clip(np.array(strips[k]), 0, 1), trim, 1 - trim, 0.01, 0.99), 0, 1)
            aspect = T / H
        else:
            continue
        p = ws.photos[k]
        if args.hands == 'remove':
            hd = remove_hands_on_face(p.source, quad)
            if hd.get('applied'):
                notes.append(f'{k}: hand/fingers on the face removed ({hd["hand_share"]:.1%}; fill: {hd.get("fill", "paper")})')
        if args.lighting == 'flatten':
            notes.append(f'{k}: ' + describe_flatten(flatten_face(p.source, quad, cells=12 if k in full else 4)))
        qpx = quad * p.size
        long_px = max(np.linalg.norm(qpx[3] - qpx[0]), np.linalg.norm(qpx[2] - qpx[1]))
        out_h = int(min(2048, max(256, long_px * 1.2)))
        out_w = int(max(16, min(2048, round(out_h * aspect))))
        regions.append(RegionSpec(k, k, {'front': '表', 'back': '裏', 'side': '左側面', 'side2': '右側面'}[k],
                                  np.round(quad, 5).tolist(), (out_w, out_h)))
    title = args.title or dec.get('object') or 'Object'
    return BuildPlan(title=title, height_m=H_mm / 1000, scene_fn=lambda tex: design.scene(dec, faces, (W, H, T), title, tex, cov),
                     regions=regions, texture_size=2048 if regions else 1024, notes=notes, warnings=warnings,
                     extra={'hero_angles': (30, 16), 'size_mm': (W_mm, H_mm, T_mm), 'ai': meta,
                            'iou_informational': [k for k in ('side', 'side2', 'top') if k in det]})
