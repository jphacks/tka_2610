"""bottle: squeeze bottles / containers whose oval cross-section changes with height (+ optional cap).

Width comes from the front (and back) silhouette, depth from the side silhouette(s), and the
front/back shift of the cross-section (e.g. a squeezed dent) from the side views. The body is a
`loft` of 22 elliptical sections; a cap is detected as a differently coloured band at the top.
"""
from __future__ import annotations
import numpy as np
from PIL import Image
import cv2

from ..engine import BuildPlan, RegionSpec
from ..hands import remove_hands_on_face
from ..lighting import flatten_face, describe_flatten
from ..measure import Profile, detect_cap, body_color, deskew_photo
from ..segment import object_mask

LEVELS = np.array([0.0, 0.006, 0.015, 0.03, 0.05, 0.08, 0.12, 0.17, 0.22, 0.28, 0.33, 0.38, 0.43, 0.48,
                   0.53, 0.58, 0.64, 0.70, 0.76, 0.82, 0.86, 0.885]) / 0.885
BASE_ROUNDING = {0: 0.62, 1: 0.80, 2: 0.92}      # rounded base: small flat footprint


def add_args(p):
    p.add_argument('--front', required=True, help='photo facing the wide side')
    p.add_argument('--side', required=True, help='photo of the narrow side (camera on the right of the object)')
    p.add_argument('--back', help='optional photo of the back')
    p.add_argument('--side2', help='optional photo of the other narrow side')
    p.add_argument('--height-cm', type=float, required=True, help='overall height including the cap')
    p.add_argument('--cap', choices=['auto', 'none', 'plain', 'ribbed'], default='auto')
    p.add_argument('--exponent', type=float, default=0.9, help='cross-section shape: 1 ellipse, <1 boxier')
    p.add_argument('--print', dest='print_mode', choices=['photo', 'none'], default='photo',
                   help='photo: project the front/back photos onto the body (labels, drawings, embossing shade); none: one colour')
    p.add_argument('--lighting', choices=['flatten', 'keep'], default='flatten')
    p.add_argument('--hands', choices=['remove', 'keep'], default='remove')


def bottle_controls(sections, t_top, has_cap, span=0.15):
    """Bounded scale controls for local fitting: width and depth of the lower and upper body, and the
    front/back bend. Value 1 reproduces the measured recipe. The neck under a cap is left alone."""
    H = sections[-1]['center'][1] or 1.0
    body = [i for i, sct in enumerate(sections) if not (has_cap and sct['center'][1] >= (t_top - 0.03) * H / max(t_top, 1e-6) * t_top)]
    lower = [i for i in body if sections[i]['center'][1] < 0.5 * H]
    upper = [i for i in body if sections[i]['center'][1] >= 0.5 * H]
    ctrls = []
    for name, field, key, idx in (('width_lower', 'loft_width', 'width', lower), ('width_upper', 'loft_width', 'width', upper),
                                  ('depth_lower', 'loft_depth', 'depth', lower), ('depth_upper', 'loft_depth', 'depth', upper)):
        tg = [{'part_id': 'body', 'field': field, 'index': i, 'coefficient': round(sections[i][key], 4)} for i in idx if sections[i][key] > 1e-4]
        if tg:
            ctrls.append({'name': name, 'minimum': 1 - span, 'maximum': 1 + span, 'value': 1.0, 'targets': tg})
    bend = [{'part_id': 'body', 'field': 'loft_center_z', 'index': i, 'coefficient': round(sections[i]['center'][2], 4)}
            for i in body if abs(sections[i]['center'][2]) > 1e-3]
    if bend:
        ctrls.append({'name': 'bend', 'minimum': 0.0, 'maximum': 2.0, 'value': 1.0, 'targets': bend[:64]})
    return ctrls


def plan(args, ws, timer) -> BuildPlan:
    for key, path, yaw in (('front', args.front, 0), ('side', args.side, 90), ('back', args.back, 180), ('side2', args.side2, -90)):
        if path:
            ws.add_photo(key, path, yaw)
    timer.mark('sanitize photos')
    tilts, prof = {}, {}
    for key, p in ws.photos.items():
        mask, info = object_mask(p.source)
        mask, occ, angle = deskew_photo(p.source, mask, info.get('_occluded'))
        tilts[key] = round(angle, 2)
        prof[key] = Profile(mask, occluded=occ)
        # reference mask for the silhouette check = cleaned outline (hand gaps interpolated)
        ws.set_mask(key, prof[key].to_mask(mask.shape), info)
    timer.mark('segmentation (rembg) + deskew + outline')

    H = float(args.height_cm)
    front_bgr = cv2.cvtColor(np.asarray(Image.open(ws.photos['front'].source).convert('RGB')), cv2.COLOR_RGB2BGR)
    notes, warnings = [], []
    cap = None if args.cap == 'none' else detect_cap(front_bgr, ws.photos['front'].mask, prof['front'])
    if args.cap in ('plain', 'ribbed') and cap is None:
        warnings.append('cap requested but no differently coloured top band was found; cap height assumed 12%')
        cap = {'t_bottom': 0.88, 'cap_rgb': [0.8, 0.1, 0.1], 'body_rgb': None}
    t_top = min(1.0, cap['t_bottom'] + 0.009) if cap else 1.0

    widths = [k for k in ('front', 'back') if k in prof]
    sides = [k for k in ('side', 'side2') if k in prof]
    # Views where a hand hid part of the outline are less reliable: weight them down.
    occl = {k: ws.photos[k].mask_info.get('skin_removed_fraction', 0.0) for k in prof}
    wt = {k: 1.0 / (1.0 + 20.0 * occl[k]) for k in prof}
    clean_sides = [k for k in sides if occl[k] < 0.03]
    if len(sides) == 2 and len(clean_sides) == 1:
        notes.append(f'side views disagree in reliability (hand removed {occl}); depth taken from {clean_sides[0]}')
    zsign = {'side': -1.0, 'side2': 1.0}      # camera at +X: image right is -Z; camera at -X: image right is +Z
    sections = []
    for i, lv in enumerate(LEVELS):
        t = lv * t_top
        tt = max(t, 0.02)                                # bottom rows are the rounded base edge
        w = float(np.average([prof[k].at(tt)[0] for k in widths], weights=[wt[k] for k in widths]))
        if len(clean_sides) == len(sides):
            d = float(min(prof[k].at(tt)[0] for k in sides))   # a rotated side view only over-estimates depth
        elif clean_sides:
            d = float(prof[clean_sides[0]].at(tt)[0])
        else:
            d = float(np.average([prof[k].at(tt)[0] for k in sides], weights=[wt[k] for k in sides]))
        z = float(np.average([zsign[k] * prof[k].at(tt)[1] for k in sides], weights=[wt[k] for k in sides]))
        if i in BASE_ROUNDING:
            w *= BASE_ROUNDING[i]; d *= BASE_ROUNDING[i]
        if cap and t >= t_top - 0.03:                     # neck under a cap is round
            w = d = (w + d) / 2
        sections.append({'center': [0.0, round(t * H, 4), round(z * H, 4)], 'width': round(w * H, 4), 'depth': round(d * H, 4)})

    body_rgb = body_color(front_bgr, ws.photos['front'].mask)
    parts = [{'id': 'body', 'geometry': {'kind': 'loft', 'sections': sections, 'exponent': args.exponent},
              'material': 'body', 'confidence': 0.7}]
    materials = [{'id': 'body', 'color': [*np.round(body_rgb, 3).tolist(), 1], 'roughness': 0.3}]
    if cap:
        cap_bottom = cap['t_bottom'] * H
        cap_h = H - cap_bottom
        cap_w = []
        for k in widths + sides:
            ts = np.linspace(cap['t_bottom'] + 0.15 * (1 - cap['t_bottom']), 0.97, 8)
            cap_w.append(np.median([prof[k].at(t)[0] for t in ts]))
        cap_r = max(float(np.median(cap_w)) * H / 2, sections[-1]['width'] / 2 * 1.02)
        materials.append({'id': 'cap', 'color': [*np.round(cap['cap_rgb'], 3).tolist(), 1], 'roughness': 0.32})
        if args.cap == 'ribbed':
            ring = cap_h * 0.82
            parts += [{'id': 'cap_ring', 'geometry': {'kind': 'gear', 'radius': round(cap_r, 4), 'teeth': 44, 'depth': round(ring, 4)},
                       'material': 'cap', 'transform': {'translation': [0, round(cap_bottom + ring / 2, 4), 0], 'rotation_deg': [-90, 0, 0]}},
                      {'id': 'cap_top', 'geometry': {'kind': 'cylinder', 'radius': round(cap_r * 0.97, 4), 'height': round(cap_h - ring, 4), 'bevel': 0.1},
                       'material': 'cap', 'transform': {'translation': [0, round(cap_bottom + ring, 4), 0]}}]
        else:
            parts.append({'id': 'cap', 'geometry': {'kind': 'cylinder', 'radius': round(cap_r, 4), 'height': round(cap_h, 4),
                                                     'bevel': round(min(0.15, cap_r * 0.1), 4)},
                          'material': 'cap', 'transform': {'translation': [0, round(cap_bottom, 4), 0]}})
        notes.append(f'cap detected from the colour band: top {1 - cap["t_bottom"]:.1%} of the height')
    if len(sides) == 1:
        notes.append('one side photo: front/back shift of the cross-section from a single view')
    notes.append(f'photos straightened by (deg): {tilts}')
    notes.append('outline rows interpolated next to removed hands: ' +
                 str({k: pr.interpolated_rows for k, pr in prof.items()}) + '; outward spikes clipped: ' +
                 str({k: pr.clipped_rows for k, pr in prof.items()}))
    assumptions = [
        f'レシピ単位は cm。全高 {H:g} cm は入力値。',
        '幅は正面' + ('・背面' if 'back' in prof else '') + '、厚みは側面の輪郭から測定（遠近の影響は未補正）。',
        '表面のしわ・浮き出しは形状にしていない（模様の陰影としてのみ写る）。胴体の地の色は写真の中央値。',
    ]

    controls = bottle_controls(sections, t_top, bool(cap))

    # ---- print: the front/back photos projected onto the body (labels, drawings, embossing shade)
    regions, prints = [], {}
    if args.print_mode == 'photo':
        zmax = max(sct['center'][2] + sct['depth'] / 2 for sct in sections)
        zmin = min(sct['center'][2] - sct['depth'] / 2 for sct in sections)
        reach = (zmax - zmin) + 1.0
        for key, label, z, rot in (('front', '正面の模様', zmax + 0.5, None), ('back', '背面の模様', zmin - 0.5, [0, 180, 0])):
            if key not in prof:
                continue
            ph = ws.photos[key]
            ys = [sct['center'][1] for sct in sections]; hs = [sct['width'] / 2 for sct in sections]
            model_half = lambda t, ys=ys, hs=hs: float(np.interp(t * H, ys, hs)) / H
            quad, outline = print_region(prof[key], ph.size, t_top, H, model_half)
            if quad is None:
                continue
            if args.hands == 'remove':
                hd = remove_hands_on_face(ph.source, quad, shadow=False)   # curved: own shading is not a shadow
                if hd.get('applied'):
                    notes.append(f'{key} print: hand/fingers removed ({hd["hand_share"]:.1%}; fill: {hd.get("fill", "paper")})')
            if args.lighting == 'flatten':
                notes.append(f'{key} print: ' + describe_flatten(flatten_face(ph.source, quad)))
            qpx = np.asarray(quad) * ph.size
            out_w = int(min(2048, max(64, np.linalg.norm(qpx[1] - qpx[0]) * 1.2)))
            out_h = int(min(2048, max(64, np.linalg.norm(qpx[3] - qpx[0]) * 1.2)))
            regions.append(RegionSpec(key, f'{key}_print', label, np.round(quad, 5).tolist(), (out_w, out_h)))
            tf = {'translation': [0, 0, round(z, 4)]}
            if rot:
                tf['rotation_deg'] = rot
            prints[key] = {'outline': outline, 'transform': tf, 'reach': reach}
        if prints:
            assumptions.append('胴体の模様は正面・背面の写真を正面・背面から投影したもの（側面に回り込む部分は単色）。撮影時の光沢は残ることがある。')

    def print_parts(tex, shrink, offset):
        out_parts, out_mats = [], []
        for key, pr in prints.items():
            name = f'{key}_print'
            if name not in tex:
                continue
            outline = [[round(x * shrink, 4), y] for x, y in pr['outline']]
            out_parts.append({'id': name, 'geometry': {'kind': 'surface_patch', 'target': 'body', 'outline': outline,
                                                        'max_distance': round(pr['reach'] + 1.0, 4), 'offset': offset, 'thickness': 0,
                                                        'resolution': 64, 'max_stretch': 4},
                              'material': name, 'transform': pr['transform'], 'confidence': 0.6})
            out_mats.append({'id': name, 'color': [1, 1, 1, 1], 'roughness': 0.3, 'image_id': tex[name]['id']})
        return out_parts, out_mats

    def scene_fn(tex):
        base = {'schema_version': '1.0', 'title': args.title or 'Bottle', 'height_m': H / 100, 'seed': 1, 'controls': controls,
                'assumptions': assumptions, 'materials': materials, 'parts': parts}
        if not prints:
            return base
        # the body colour must match the (corrected) print at its border, or the patch outline shows as a seam
        edge_cols = []
        for key in prints:
            t = tex.get(f'{key}_print')
            if t:
                a = np.asarray(Image.open(t['path']).convert('RGBA')).astype(np.float32)
                hh, ww = a.shape[:2]; b = max(2, int(0.04 * min(hh, ww)))
                band = np.concatenate([a[:, :b].reshape(-1, 4), a[:, -b:].reshape(-1, 4)])
                band = band[band[:, 3] > 200][:, :3] / 255
                if len(band):
                    edge_cols.append(np.median(band, 0))
        if edge_cols:
            col = np.round(np.mean(edge_cols, 0), 3).tolist()
            base['materials'] = [dict(m, color=[*col, 1]) if m['id'] == 'body' else m for m in materials]
            notes.append(f'body colour matched to the print border {col}')
        from katachi.schema import SceneSpec
        from katachi.geometry import compile_scene
        for shrink, offset in ((1.0, 0.06), (1.0, 0.12), (0.85, 0.12), (0.7, 0.12)):   # must pass Katachi's surface checks
            pp, pm = print_parts(tex, shrink, offset)
            cand = dict(base, parts=parts + pp, materials=base['materials'] + pm)
            try:
                for quality in ('draft', 'high'):            # the build also makes a low-resolution preview
                    compile_scene(SceneSpec.model_validate(cand), quality)
                notes.append(f'print projected at {shrink:.0%} of the width, {offset * 10:.1f} mm above the body')
                return cand
            except ValueError as exc:
                last = str(exc)[:160]
        warnings.append(f'photo print dropped (surface_patch checks failed: {last}); body is one colour')
        return base

    timer.mark('measure + recipe')
    return BuildPlan(title=args.title or 'Bottle', height_m=H / 100, scene_fn=scene_fn, notes=notes, warnings=warnings,
                     regions=regions, texture_size=2048 if regions else 1024, extra={'hero_angles': (30, 16)})


def print_region(prof: Profile, size, t_top, H, model_half, cover=0.85, samples=40):
    """Axis-aligned photo region over the body (below the cap) and the matching patch outline in recipe
    units (x centred on the axis, y from the base). Only the central `cover` of each row's width is used:
    the sides turn away from the camera and would be stretched."""
    w_px, h_px = size
    ts = np.linspace(0.07, t_top - 0.015, samples)      # above the rounded base
    rows = [prof.at(t) for t in ts]                      # (width / height, centre offset / height)
    # never wider than the modelled body at that height (rays must hit it), and only its central part
    half = np.minimum(np.array([r[0] for r in rows]) / 2, [model_half(t) for t in ts]) * cover
    if half.max() <= 0:
        return None, None
    y_top_px = prof.row(ts[-1]); y_bot_px = prof.row(ts[0])
    axis_px = prof.c_bot + (prof.c_top - prof.c_bot) * float(np.mean(ts))
    hw_px = half.max() * prof.height_px
    quad = [[(axis_px - hw_px) / w_px, y_top_px / h_px], [(axis_px + hw_px) / w_px, y_top_px / h_px],
            [(axis_px + hw_px) / w_px, y_bot_px / h_px], [(axis_px - hw_px) / w_px, y_bot_px / h_px]]
    if min(min(q) for q in quad) < 0 or max(max(q) for q in quad) > 1:
        return None, None
    right = [[round(float(hw * H), 4), round(float(t * H), 4)] for hw, t in zip(half, ts)]
    left = [[-x, y] for x, y in reversed(right)]
    # the outline's bounding box must equal the texture's: pin the widest row to +-max on both sides
    return quad, right + left
