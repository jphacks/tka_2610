"""revolve: cups, vases, bowls, plates — round cross-section; one side photo is enough.

The radius at each height is half the silhouette width after straightening the axis. Flat ends seen
slightly from above/below are corrected. --hollow adds an inner wall and floor (open top).
"""
from __future__ import annotations
import numpy as np
from PIL import Image
import cv2

from ..engine import BuildPlan
from ..measure import Profile, body_color, upright, flatten_ends
from ..segment import object_mask


def add_args(p):
    p.add_argument('--photo', required=True, help='side view, camera roughly level with the object')
    p.add_argument('--height-cm', type=float, required=True)
    p.add_argument('--hollow', action='store_true', help='open top with an inner wall (cups, vases, bowls)')
    p.add_argument('--wall-mm', type=float, default=3.0)
    p.add_argument('--floor-mm', type=float, default=4.0)
    p.add_argument('--samples', type=int, default=48)


def radius_profile(mask: np.ndarray, samples: int) -> tuple[np.ndarray, np.ndarray]:
    prof = Profile(upright(mask))
    ts = np.linspace(0, 1, samples)
    w = np.array([prof.at(t)[0] for t in ts])
    w = flatten_ends(w)
    w = np.convolve(np.pad(w, 1, mode='edge'), np.ones(3) / 3, mode='valid')   # light smoothing
    return ts, w / 2


def lathe_points(ts, r, H, hollow=False, wall=0.3, floor=0.4):
    outer = [[round(float(ri * H), 4), round(float(t * H), 4)] for t, ri in zip(ts, r)]
    pts = [[0.0, 0.0]] + outer
    if hollow:
        inner = []
        for t, ri in zip(ts[::-1], r[::-1]):
            y = t * H
            if y < floor:
                break
            inner.append([round(max(float(ri * H) - wall, 0.05), 4), round(float(y), 4)])
        pts += inner + [[0.0, round(floor, 4)]]
    else:
        pts += [[0.0, round(H, 4)]]
    clean = [pts[0]]
    for p in pts[1:]:
        if abs(p[0] - clean[-1][0]) > 1e-6 or abs(p[1] - clean[-1][1]) > 1e-6:
            clean.append(p)
    return clean


def plan(args, ws, timer) -> BuildPlan:
    p = ws.add_photo('side', args.photo, 0)
    timer.mark('sanitize photo')
    mask, info = object_mask(p.source)
    ws.set_mask('side', mask, info)
    timer.mark('segmentation (rembg)')
    H = float(args.height_cm)
    ts, r = radius_profile(mask, args.samples)
    pts = lathe_points(ts, r, H, args.hollow, args.wall_mm / 10, args.floor_mm / 10)
    bgr = cv2.cvtColor(np.asarray(Image.open(p.source).convert('RGB')), cv2.COLOR_RGB2BGR)
    rgb = body_color(bgr, mask)
    title = args.title or 'Revolved object'
    assumptions = [f'レシピ単位は cm。高さ {H:g} cm は入力値。', '断面は真円と仮定し、側面の輪郭の半幅を半径にした。',
                   '色は写真の中央値。模様・取っ手など回転対称でない部分は形状にしていない。']
    if args.hollow:
        assumptions.append(f'内側は見えないため、壁厚 {args.wall_mm:g} mm・底厚 {args.floor_mm:g} mm と仮定した。')

    # one radius scale for the whole profile (separate lower/upper scales made a step that failed the
    # closed-surface check); the lathe allows at most 64 targets per control, so sample the profile
    tg = [{'part_id': 'body', 'field': 'lathe_radius', 'index': i, 'coefficient': r} for i, (r, y) in enumerate(pts) if r > 1e-3]
    if len(tg) > 64:
        keep = np.linspace(0, len(tg) - 1, 64).round().astype(int)
        tg = [tg[i] for i in keep]
    ctrls = [{'name': 'radius_scale', 'minimum': 0.85, 'maximum': 1.15, 'value': 1.0, 'targets': tg}] if tg else []

    def scene_fn(_t):
        return {'schema_version': '1.0', 'title': title, 'height_m': H / 100, 'seed': 1, 'controls': ctrls, 'assumptions': assumptions,
                'materials': [{'id': 'body', 'color': [*np.round(rgb, 3).tolist(), 1], 'roughness': 0.4}],
                'parts': [{'id': 'body', 'geometry': {'kind': 'lathe', 'profile': pts}, 'material': 'body', 'confidence': 0.7}]}

    timer.mark('measure + recipe')
    return BuildPlan(title=title, height_m=H / 100, scene_fn=scene_fn, notes=[f'{len(pts)} lathe profile points'],
                     extra={'hero_angles': (30, 22)})
