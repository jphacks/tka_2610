"""flat: drawings, cards, paper cut-outs — a thin panel with the photographed artwork on its face.

rect mode: a rectangular sheet is detected (four corners) and perspective-corrected.
cutout mode: the object's outline (rembg) is kept; the panel follows that outline.
"""
from __future__ import annotations
import cv2
import numpy as np
from PIL import Image

from ..engine import BuildPlan, RegionSpec
from ..segment import object_mask
from ..lighting import flatten_face, glare_fraction, describe_flatten
from ..hands import remove_hands_on_face
from ..fusion import fuse_face_photos
from katachi.images import sanitize_image
from pathlib import Path
from .. import quad_detect as qd


def add_args(p):
    p.add_argument('--photo', required=True, nargs='+',
                   help='front view, as square-on as possible. Several photos of the same sheet may be given: the first '
                        'is used, the others fill what a finger or glare hides in it (rect mode)')
    p.add_argument('--width-cm', type=float, help='real width (give both width and height for an exact aspect, e.g. A4)')
    p.add_argument('--height-cm', type=float)
    p.add_argument('--thickness-mm', type=float, default=1.5)
    p.add_argument('--mode', choices=['auto', 'rect', 'cutout'], default='auto')
    p.add_argument('--back-color', default='0.93,0.92,0.89', help='r,g,b 0..1 for the unseen back')
    p.add_argument('--lighting', choices=['flatten', 'keep'], default='flatten',
                   help='flatten: remove shadows/gradients on the plain paper background (skipped automatically '
                        'when the work has no dominant plain background); keep: raw pixels')
    p.add_argument('--finish', choices=['auto', 'matte', 'glossy'], default='auto')
    p.add_argument('--hands', choices=['remove', 'keep'], default='remove')


def _order(pts):
    return qd._order(np.asarray(pts, float))


def outline_from_alpha(alpha: np.ndarray, max_points=200):
    """Outer contour (+ large holes) of the opaque area, simplified, in pixel coords."""
    m = (alpha > 127).astype(np.uint8)
    contours, hier = cv2.findContours(m, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_NONE)
    if not contours:
        raise ValueError('artwork has no opaque area')
    outer_i = int(np.argmax([cv2.contourArea(c) for c in contours]))
    def simplify(c):
        peri = cv2.arcLength(c, True)
        eps = 0.0015 * peri
        while True:
            a = cv2.approxPolyDP(c, eps, True).reshape(-1, 2)
            if len(a) <= max_points:
                return a
            eps *= 1.3
    outer = simplify(contours[outer_i])
    area = cv2.contourArea(contours[outer_i])
    holes = [simplify(c) for i, c in enumerate(contours)
             if hier[0][i][3] == outer_i and cv2.contourArea(c) > 0.01 * area][:8]
    return outer, holes


def plan(args, ws, timer) -> BuildPlan:
    if not (args.width_cm or args.height_cm):
        raise SystemExit('flat: give --width-cm and/or --height-cm')
    p = ws.add_photo('front', args.photo[0], 0)
    timer.mark('sanitize photo')
    mask, info = object_mask(p.source, remove_skin='auto')
    timer.mark('segmentation (rembg)')
    w, h = p.size
    mode, quad, warnings = args.mode, None, []
    if mode in ('auto', 'rect'):
        try:
            r = qd.detect_face(p.path)
            q = np.array(r.corners)
            area_q = cv2.contourArea((q * [w, h]).astype(np.float32))
            sheet = mask
            if info.get('_occluded') is not None:     # paper under a removed hand still belongs to the sheet
                qpoly = np.zeros((h, w), np.uint8)
                cv2.fillPoly(qpoly, [np.round(q * [w, h]).astype(np.int32)], 1)
                sheet = mask | (info['_occluded'] & qpoly.astype(bool))
            ratio = area_q / max(1, sheet.sum())
            if not r.clipped_sides and 0.8 <= ratio <= 1.3:
                mode, quad = 'rect', q
            elif mode == 'rect':
                warnings.append(f'rectangle detection uncertain (area ratio {ratio:.2f}); used anyway')
                mode, quad = 'rect', q
        except ValueError:
            if mode == 'rect':
                raise
    if quad is None:
        mode = 'cutout'
        cs, _ = cv2.findContours(mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        box = cv2.boxPoints(cv2.minAreaRect(max(cs, key=cv2.contourArea)))
        quad = np.clip(_order(box) / [w, h], 0, 1)
    notes = [f'mode: {mode}']
    extra_photos = args.photo[1:]
    if extra_photos and mode == 'rect' and args.hands == 'remove':
        others = []
        for i, extra in enumerate(extra_photos, 1):
            src = ws.out / 'extras' / f'front_{i}' / 'source.png'
            sanitize_image(Path(extra).read_bytes(), src)
            try:
                r2 = qd.detect_face(Path(extra))
            except ValueError:
                warnings.append(f'extra photo {Path(extra).name} ignored (sheet not found)')
                continue
            if r2.clipped_sides:
                warnings.append(f'extra photo {Path(extra).name} ignored (sheet cut by the photo border)')
                continue
            others.append((src, np.clip(np.array(r2.corners), 0, 1).tolist()))
        if others:
            fu = fuse_face_photos(p.source, quad, others, use_glare=True)
            if fu.get('applied'):
                notes.append(f'fused with {len(others)} more photo(s): {fu["hole_share"]:.1%} of the sheet was covered; '
                             f'{fu["from_other_photos"]:.0%} of that taken from the other photo(s)')
    elif extra_photos:
        notes.append('extra photos are used only for rectangular sheets (rect mode); ignored')
    if mode == 'rect' and args.hands == 'remove' and not extra_photos:   # cut-outs already exclude hands via the mask
        hd = remove_hands_on_face(p.source, quad)
        if hd.get('applied'):
            notes.append(f'hand/fingers on the sheet removed and filled from the surrounding paper ({hd["hand_share"]:.1%}; fill: {hd.get("fill", "paper")})')
    glare = glare_fraction(p.source, quad)                 # before any correction
    glossy = args.finish == 'glossy' or (args.finish == 'auto' and glare >= 0.002)
    rough = 0.35 if glossy else 0.85
    notes.append(f'finish: {"glossy" if glossy else "matte"} (roughness {rough}; highlight share {glare:.4f})')
    if args.lighting == 'flatten':
        notes.append(describe_flatten(flatten_face(p.source, quad, mask=None if mode == 'rect' else mask)))
    if mode == 'rect':
        ws.set_mask('front', ws.polygon_mask('front', quad, grow=4), info)
    else:
        ws.set_mask('front', mask, info)
    qpx = quad * [w, h]
    side_w = (np.linalg.norm(qpx[1] - qpx[0]) + np.linalg.norm(qpx[2] - qpx[3])) / 2
    side_h = (np.linalg.norm(qpx[3] - qpx[0]) + np.linalg.norm(qpx[2] - qpx[1])) / 2
    scale = min(2048 / max(side_w, side_h), 1.25)
    out_size = (max(16, int(side_w * scale)), max(16, int(side_h * scale)))
    regions = [RegionSpec('front', 'art', '作品の表面', np.round(quad, 5).tolist(), out_size)]
    t = args.thickness_mm / 10
    back_rgb = [float(v) for v in args.back_color.split(',')]
    title = args.title or 'Flat artwork'

    def scene_fn(tex):
        img = Image.open(tex['art']['path']).convert('RGBA')
        Wp, Hp = img.size
        if args.width_cm and args.height_cm:      # exact real size (a single photo cannot fix the aspect)
            W, Hc = args.width_cm, args.height_cm
        elif args.width_cm:
            W = args.width_cm; Hc = W * Hp / Wp
        else:
            Hc = args.height_cm; W = Hc * Wp / Hp
        to_cm = lambda a: [[round((x / Wp - 0.5) * W, 4), round((1 - y / Hp) * Hc, 4)] for x, y in a]
        if mode == 'rect':
            outline, holes = [[0, 0], [Wp, 0], [Wp, Hp], [0, Hp]], []
        else:
            outline, holes = outline_from_alpha(np.asarray(img)[..., 3])
        geo = {'outline': to_cm(outline), 'holes': [to_cm(hl) for hl in holes]}
        given = '幅・高さとも入力値' if (args.width_cm and args.height_cm) else f'{"幅" if args.width_cm else "高さ"}は入力値、もう一方は写真から推定（1枚の写真では縦横比は確定しない）'
        assumptions = [f'レシピ単位は cm。{given}。',
                       f'厚み {args.thickness_mm:g} mm は入力値。裏面は見えないため無地。', '表面の模様は写真の画素（光・影を含む）。']
        return {'schema_version': '1.0', 'title': title, 'height_m': round(Hc / 100, 5), 'seed': 1, 'controls': [],
                'assumptions': assumptions,
                'materials': [{'id': 'art', 'color': [1, 1, 1, 1], 'roughness': rough, 'image_id': tex['art']['id']},
                              {'id': 'back', 'color': [*back_rgb, 1], 'roughness': 0.9}],
                'parts': [{'id': 'artwork', 'geometry': {'kind': 'extrusion', **geo, 'depth': round(t, 4)}, 'material': 'art',
                           'uv_mode': 'planar_xy', 'confidence': 0.8},
                          {'id': 'back_cover', 'geometry': {'kind': 'extrusion', **geo, 'depth': 0.01}, 'material': 'back',
                           'transform': {'translation': [0, 0, round(-t / 2 - 0.006, 4)]}, 'inferred': True, 'confidence': 0.5}]}

    timer.mark('detect + recipe')
    hgt = (args.height_cm or args.width_cm * side_h / side_w) / 100      # final value is set by scene_fn
    return BuildPlan(title=title, height_m=hgt, scene_fn=scene_fn, regions=regions, texture_size=2048, warnings=warnings,
                     notes=notes, extra={'hero_angles': (22, 10)})
