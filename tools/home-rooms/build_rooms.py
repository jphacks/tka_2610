#!/usr/bin/env python3
"""家（中央のリビング hub 10×10 m の 1 部屋。出入口なし）の建物を、開発用の GLB で書き出す。

- 書き出し先: backend/static/models/rooms/hub.glb
- 以前は左・右・前の 3 部屋（8×8 m）もあり、hub の西・東・北の出入口でつながっていた。今は hub だけで、出入口もふさいでいる。
  部屋を戻すときは、下の ROOMS と HUB_WALL_AT_OPEN に部屋を足し、hub の doors に出入口の向きを足す（git の履歴に前の値がある）
- **開発用のシェル**です。本番品質の GLB は別に納品してもらい、同じ名前で差し替えます（仕様は docs/house-assets.md）。
- キット v1（MemoryMuseum_Home）の build_assets.py を kit/tools/ に同梱し、その形の関数（bevel_box・arch_band）、
  材質、GLB の書き出し（Writer）を使います。幅木・回り縁・開口の枠とアーチ・角の柱はキットと同じ寸法です。
  テクスチャは作り直さず、kit/assets/textures の画像をそのまま埋め込みます（キットの --reuse-textures と同じ）。
- キットの room_instances() は使わず、同じ寸法で並べ直しています（理由は README.md の「キット v1 から使っているもの・変えたところ」）。
- 実行方法は README.md を見てください。確認は check_rooms.py（Python の標準ライブラリだけで動く）。

座標: メートル、Y が上、床の上面が y = 0。部屋ごとに部屋の中心を原点にして書き出し、回転はしない。
アプリは GLB を部屋の origin（hub (0,0)）へ平行移動して置く。
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
KIT = HERE / 'kit'
REPO = HERE.parents[1]
OUT_DIR = REPO / 'backend' / 'static' / 'models' / 'rooms'

# キットの build_assets.py は、読み込んだときに assets/modules などのフォルダを作る。ここでは使わないので、空なら消す
_KIT_DIRS = [KIT / 'assets' / 'modules', KIT / 'assets' / 'scenes']
_EXISTED = {p: p.exists() for p in _KIT_DIRS}
sys.path.insert(0, str(KIT / 'tools'))
import numpy as np  # noqa: E402
import build_assets as kit  # noqa: E402

for _p in _KIT_DIRS:
    if not _EXISTED[_p] and _p.is_dir() and not any(_p.iterdir()):
        _p.rmdir()

# ---------- 寸法（docs/house-assets.md と同じ） ----------

H = 4.2  # 壁の高さ（キットは 3.2。積み上げの建物で壁が低く見えないよう、天井の高い部屋にした）
T = 0.24  # 壁の厚さ
HT = T / 2
LOWER = 0.92  # 下の壁（wall_lower）の高さ。これより上は wall_upper（手前の壁のカットで隠れる）
POST_TOP = H - 0.02  # 角の柱の高さ。柱頭の上面が壁の上面と同じ高さで重なってちらつくので、壁より少し低くする
BAY = 3.0  # 開口 1 か所の区画の幅（キットの portal_arch_3m）
R = 1.05  # 開口の半幅（有効幅 2.10 m）
SPRING = 1.55  # アーチの起点の高さ
DOOR_TOP = SPRING + R  # 開口の高さ（アーチの頂点）2.60 m
JAMB_X = R + 0.0725  # 枠（jamb）の中心。枠は x = 1.05〜1.195 で、開口の内側には出ない
FLOOR_T = 0.025  # 床の仕上げ（role: floor）の厚さ
BASE_T = 0.2  # 床の下の土台（role: foundation）まで含めた厚さ

# 部屋。open は壁を作らない側（hub の壁と共有する）。doors は開口を開ける壁。cutaway は手前の壁のカットで隠す壁
ROOMS = {
    'hub': {'size': (10.0, 10.0), 'open': None, 'doors': (), 'cutaway': ('south', 'east')},
}
# 部屋の開いた側をふさいでいる hub の壁（隣の部屋が無いので空）
HUB_WALL_AT_OPEN: dict[str, str] = {}
# hub の共有の壁 → 外側の面が見える部屋
SHARED = {side: rid for rid, side in HUB_WALL_AT_OPEN.items()}

# 壁の向き。キットの room_instances と同じで、壁の局所座標は x が壁に沿う向き、+z が部屋の内側
SIDE_ANGLE = {'north': 0.0, 'south': math.pi, 'east': -math.pi / 2, 'west': math.pi / 2}
SIDES = ('north', 'south', 'east', 'west')

# 幅木と回り縁の断面（キットの wall_1m と同じ）。(名前, 高さ, 厚さ, 中心の高さ, 壁の中心からの距離, 角の丸み)
TRIM_LOWER = [('Baseboard', 0.17, 0.047, 0.085, 0.134, 0.008), ('Basecap', 0.027, 0.061, 0.177, 0.138, 0.005)]
TRIM_UPPER = [('Crown', 0.095, 0.073, H - 0.08, 0.14, 0.008), ('Cornice', 0.034, 0.094, H - 0.015, 0.143, 0.006)]


def side_pos(side, w, d):
    """壁の中心線の中心（部屋の座標）"""
    return {'north': (0.0, 0.0, -d / 2 - HT), 'south': (0.0, 0.0, d / 2 + HT),
            'east': (w / 2 + HT, 0.0, 0.0), 'west': (-w / 2 - HT, 0.0, 0.0)}[side]


def end_side(side, sign):
    """壁の局所 x の +端（sign=1）・−端（sign=−1）が、どの向きの壁とつながるか"""
    v = kit.matrix((0, 0, 0), SIDE_ANGLE[side])[:3, :3] @ np.array([sign, 0.0, 0.0])
    if abs(v[0]) > abs(v[2]):
        return 'east' if v[0] > 0 else 'west'
    return 'south' if v[2] > 0 else 'north'


def protrude(off, t):
    """飾り（幅木など）が壁の面から出ている量"""
    return off + t / 2 - HT


def sink(off, t):
    """飾りが壁の中に入り込んでいる量"""
    return HT - (off - t / 2)


def extent(room, side, sign, kind, off=0.0, t=0.0):
    """壁の局所 x の端の位置（絶対値）。

    重なってちらつく面を作らないための決まり：
      - 壁本体：南北の壁は外の角まで（内寸の半分 + 壁厚）、東西の壁は南北の壁の内側の面まで
      - 内側の飾り：南北は内寸いっぱい、東西は南北の飾りの面で止める
      - 外側の飾り：南北は外の角を回り込むところまで、東西は南北の飾りの裏の面で止める
      - 開いた側（hub の壁と接する側）：本体は内寸まで、飾りは hub の壁の飾りの面で止める
    """
    w, d = room['size']
    ns = side in ('north', 'south')
    a = (w if ns else d) / 2
    closed = end_side(side, sign) != room['open']
    if kind in ('body', 'footing'):
        return a + T if (ns and closed) else a
    p, s = protrude(off, t), sink(off, t)
    if not closed:
        return a - p
    if kind == 'inner':
        return a if ns else a - p
    if kind == 'outer':
        return a + T + p if ns else a + T - s
    raise ValueError(kind)


def runs(room, side, kind, off=0.0, t=0.0):
    """壁の局所 x の区間のリスト。開口のある壁は、真ん中の 3 m（BAY）を抜く"""
    lo, hi = -extent(room, side, -1, kind, off, t), extent(room, side, 1, kind, off, t)
    if side in room['doors']:
        return [(lo, -BAY / 2), (BAY / 2, hi)]
    return [(lo, hi)]


# ---------- 形 ----------

def plain_box(size, pos=(0.0, 0.0, 0.0), tile=(1.0, 1.0)):
    """角を丸めない箱（床・土台用。床の上面を完全に平らにするため）。UV はキットの bevel_box と同じ決まり（箱の中心から、m / tile）"""
    h = np.array(size, dtype=float) / 2
    ps, ns, uv, fs = [], [], [], []
    for axis in range(3):
        o = [k for k in range(3) if k != axis]
        for sign in (-1, 1):
            n = np.zeros(3)
            n[axis] = sign
            quad = []
            for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                p = np.zeros(3)
                p[axis] = sign * h[axis]
                p[o[0]] = a * h[o[0]]
                p[o[1]] = b * h[o[1]]
                quad.append(p)
            start = len(ps)
            for p in quad:
                ps.append(p)
                ns.append(n)
                if axis == 1:
                    uv.append([p[0] / tile[0], p[2] / tile[1]])
                elif axis == 2:
                    uv.append([p[0] / tile[0], p[1] / tile[1]])
                else:
                    uv.append([p[2] / tile[0], p[1] / tile[1]])
            order = [[0, 1, 2], [0, 2, 3]]
            if np.dot(np.cross(quad[1] - quad[0], quad[2] - quad[0]), n) < 0:
                order = [f[::-1] for f in order]
            fs += [[start + k for k in f] for f in order]
    return kit.Mesh(np.array(ps) + np.array(pos, dtype=float), np.array(ns), np.array(uv), np.array(fs, dtype=int))


def ear_clip(poly):
    """反時計回りの単純な多角形を三角形に分ける（耳切り法）"""
    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    def inside(p, a, b, c):
        return cross(a, b, p) >= -1e-12 and cross(b, c, p) >= -1e-12 and cross(c, a, p) >= -1e-12

    idx = list(range(len(poly)))
    tris = []
    while len(idx) > 3:
        for k in range(len(idx)):
            i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            a, b, c = poly[i0], poly[i1], poly[i2]
            if cross(a, b, c) <= 1e-12:
                continue
            if any(inside(poly[j], a, b, c) for j in idx if j not in (i0, i1, i2)):
                continue
            tris.append((i0, i1, i2))
            idx.pop(k)
            break
        else:
            raise RuntimeError('ear clipping failed')
    tris.append(tuple(idx))
    return tris


def polygon_area(poly):
    return sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(poly, poly[1:] + poly[:1])) / 2


def portal_upper_mesh(z0=-HT, z1=HT):
    """開口のある区画の上の壁（y = 0.92〜3.2、アーチの穴あき）。z = z0〜z1（共有の壁は厚さの半分ずつに分ける）。

    UV は壁と同じ決まり：表と裏は (x, y − 2.06)（上の壁の中心の高さを引く。theme.ts の wall_upper）。
    アーチの裏（下から見える面）は (面に沿った長さ, z)。法線はアーチの部分だけなめらかにする。
    """
    pts = [(BAY / 2, LOWER), (BAY / 2, H), (-BAY / 2, H), (-BAY / 2, LOWER), (-R, LOWER), (-R, SPRING)]
    pts += [(R * math.cos(t), SPRING + R * math.sin(t)) for t in np.linspace(math.pi, 0, 49)[1:-1]]
    pts += [(R, SPRING), (R, LOWER)]
    assert polygon_area(pts) > 0, 'portal profile must be counter-clockwise'
    tris = ear_clip(pts)
    tri_area = sum(abs(polygon_area([pts[i] for i in t])) for t in tris)
    assert abs(tri_area - polygon_area(pts)) < 1e-9, (tri_area, polygon_area(pts))

    def on_arch(p):
        return p[1] >= SPRING - 1e-9 and abs(math.hypot(p[0], p[1] - SPRING) - R) < 1e-9

    ps, ns, uv, fs = [], [], [], []
    for z, nz in ((z1, 1.0), (z0, -1.0)):
        start = len(ps)
        for x, y in pts:
            ps.append((x, y, z))
            ns.append((0.0, 0.0, nz))
            uv.append((x, y - (LOWER + (H - LOWER) / 2)))
        for t in tris:
            fs.append([start + k for k in (t if nz > 0 else t[::-1])])
    s = 0.0
    for i, a in enumerate(pts):
        b = pts[(i + 1) % len(pts)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dx, dy)
        flat = (dy / length, -dx / length, 0.0)
        arch = on_arch(a) and on_arch(b)
        start = len(ps)
        for p, along in ((a, s), (b, s + length)):
            n = (-p[0] / R, -(p[1] - SPRING) / R, 0.0) if arch else flat
            for z in (z0, z1):
                ps.append((p[0], p[1], z))
                ns.append(n)
                uv.append((along, z))
        a0, a1, b0, b1 = start, start + 1, start + 2, start + 3
        fs += [[a0, b0, b1], [a0, b1, a1]]
        s += length
    return kit.Mesh(np.array(ps, dtype=float), np.array(ns, dtype=float), np.array(uv, dtype=float), np.array(fs, dtype=int))


# ---------- 部品（キットの ASSETS に登録して、Writer.instance で書き出す） ----------

def merge(meshes):
    return kit.merge(meshes)


def component(name, mesh, material, role, face_room=None):
    """キットの component に、共有の壁の部屋側の面の印（faceRoom）を足したもの"""
    part = kit.component(name, mesh, material, role)
    if face_room:
        part['extras']['faceRoom'] = face_room
    return part


def wall_boxes(lo, hi, z0=-HT, z1=HT):
    """壁本体の 1 区間（下の壁と上の壁）。角は丸めない（継ぎ目に溝やちらつきを作らないため）。
    UV は壁の決まり（区間の中心から u = x − 中心、v = y − 0.46 / y − 2.06）"""
    length, cx, zc, zt = hi - lo, (lo + hi) / 2, (z0 + z1) / 2, z1 - z0
    return (plain_box((length, LOWER, zt), (cx, LOWER / 2, zc)),
            plain_box((length, H - LOWER, zt), (cx, LOWER + (H - LOWER) / 2, zc)))


def split_at(lo, hi, cut):
    """区間 lo〜hi を ±cut で分ける"""
    pts = sorted({lo, hi} | {c for c in (-cut, cut) if lo < c < hi})
    return list(zip(pts, pts[1:]))


def shared_half(side):
    """hub の共有の壁に接する部屋の、壁に沿う向きの内寸の半分（部屋の origin は壁の中心の延長上にある）"""
    w, d = ROOMS[SHARED[side]]['size']
    return (w if side in ('north', 'south') else d) / 2


_DOOR_MESHES = {}


def door_meshes():
    """開口の部品の形（3 か所で同じ形を使い回す。GLB の中では 1 つのメッシュを共有する）"""
    if _DOOR_MESHES:
        return _DOOR_MESHES
    side_w = BAY / 2 - R
    trim_lower, trim_upper = [], []
    for face in (-1, 1):
        for sx in (-1, 1):
            trim_lower.append(kit.bevel_box((0.145, LOWER, 0.058), 0.008, (sx * JAMB_X, LOWER / 2, face * 0.15)))
            trim_upper.append(kit.bevel_box((0.145, SPRING - LOWER, 0.058), 0.008,
                                            (sx * JAMB_X, LOWER + (SPRING - LOWER) / 2, face * 0.15)))
            trim_lower.append(kit.bevel_box((0.19, 0.20, 0.076), 0.007, (sx * JAMB_X, 0.10, face * 0.157)))
            trim_lower.append(kit.bevel_box((0.27, 0.17, 0.047), 0.007, (sx * 1.365, 0.085, face * 0.134)))
            trim_lower.append(kit.bevel_box((0.27, 0.027, 0.061), 0.005, (sx * 1.365, 0.177, face * 0.138)))
        trim_upper.append(kit.arch_band(R, R + 0.145, SPRING, 0.052).transformed(kit.matrix((0, 0, face * 0.15))))
        trim_upper.append(kit.bevel_box((BAY, 0.095, 0.073), 0.008, (0, H - 0.08, face * 0.14)))
        trim_upper.append(kit.bevel_box((BAY, 0.034, 0.094), 0.006, (0, H - 0.015, face * 0.143)))

    def lower_half(z0, z1):
        return merge([plain_box((side_w, LOWER, z1 - z0), (sx * (R + side_w / 2), LOWER / 2, (z0 + z1) / 2)) for sx in (-1, 1)])

    _DOOR_MESHES.update({
        'wall_lower_in': lower_half(0, HT), 'wall_lower_out': lower_half(-HT, 0),
        'wall_upper_in': portal_upper_mesh(0, HT), 'wall_upper_out': portal_upper_mesh(-HT, 0),
        'trim_lower': merge(trim_lower), 'trim_upper': merge(trim_upper),
        'floor': plain_box((BAY, FLOOR_T, T), (0, -FLOOR_T / 2, 0), tile=(2, 2)),
        'foundation': plain_box((BAY, BASE_T - FLOOR_T, T), (0, -FLOOR_T - (BASE_T - FLOOR_T) / 2, 0)),
    })
    return _DOOR_MESHES


def build_door_asset(side):
    """hub の 1 か所の開口（3 m の区画）。キットの portal_arch_3m と同じ形を、カットと壁紙の切り替えに合わせて分けたもの。

    キットとの違い：
      - 壁を下（〜0.92 m）と上に分ける。枠とアーチも 0.92 m で分ける（手前の壁のカットで上だけ隠れる）
      - 壁は厚さの半分ずつに分け、隣の部屋側の半分に faceRoom を付ける（隣の部屋の壁紙を当てられるように）
      - 真鍮の細い縁（Metal_Brass）は入れない（材質を 4 つに保つ）。区画の幅木に笠木（Basecap）を足す
      - 開口の床（壁の厚さ 0.24 m の帯、区画の幅 3 m）を入れる。床の上面は y = 0
    """
    m = door_meshes()
    room = SHARED[side]
    parts = [
        component('Door_Wall_Lower', m['wall_lower_in'], 'Wall_Plaster', 'wall_lower'),
        component('Door_Wall_Upper', m['wall_upper_in'], 'Wall_Plaster', 'wall_upper'),
        component('Door_Wall_Lower_Room', m['wall_lower_out'], 'Wall_Plaster', 'wall_lower', room),
        component('Door_Wall_Upper_Room', m['wall_upper_out'], 'Wall_Plaster', 'wall_upper', room),
        component('Door_Trim_Lower', m['trim_lower'], 'Trim_Oak', 'trim_lower'),
        component('Door_Trim_Upper', m['trim_upper'], 'Trim_Oak', 'trim_upper'),
        component('Door_Floor', m['floor'], 'Floor_Oak', 'floor'),
        component('Door_Foundation', m['foundation'], 'Foundation', 'foundation'),
    ]
    kit.asset(f'hub_door_{side}', parts, [BAY, H, 0.39], 'wall', 'architecture', label=f'hub {side} doorway (dev)')


def build_corner_post_asset():
    """角の柱。キットの corner_post と同じ断面（柱 0.14 m 角・足 0.19×0.20 m・柱頭 0.21×0.14 m）。

    キットとの違い：高さを壁より 2 cm 低くする（壁の上面と柱頭の上面が重ならないように）。
    柱の上下の端は足と柱頭の中に収める（キットは柱と柱頭の上面が同じ高さで、上から見るとちらつく）。
    """
    col_lo, col_hi = 0.10, POST_TOP - 0.07
    parts = [
        component('Oak_Column', kit.bevel_box((0.14, col_hi - col_lo, 0.14), 0.012, (0, (col_lo + col_hi) / 2, 0)), 'Trim_Oak', 'trim'),
        component('Foot', kit.bevel_box((0.19, 0.20, 0.19), 0.007, (0, 0.10, 0)), 'Trim_Oak', 'trim'),
        component('Capital', kit.bevel_box((0.21, 0.14, 0.21), 0.008, (0, POST_TOP - 0.07, 0)), 'Trim_Oak', 'trim'),
    ]
    kit.asset('corner_post_318', parts, [0.21, POST_TOP, 0.21], 'floor', 'architecture', label='Oak corner post (dev)')


def build_floor_asset(rid, room):
    w, d = room['size']
    parts = [
        component('Floor', plain_box((w, FLOOR_T, d), (0, -FLOOR_T / 2, 0), tile=(2, 2)), 'Floor_Oak', 'floor'),
        component('Floor_Foundation', plain_box((w, BASE_T - FLOOR_T, d), (0, -FLOOR_T - (BASE_T - FLOOR_T) / 2, 0)),
                  'Foundation', 'foundation'),
    ]
    kit.asset(f'{rid}_floor', parts, [w, BASE_T, d], 'floor', 'architecture', label=f'{rid} floor (dev)')


def build_side_asset(rid, room, side):
    """1 辺の壁（開口のところは抜く）。役割ごとに 1 メッシュにまとめる（描画の回数を減らすため）。

    hub の共有の壁（西・東・北）は、壁本体を厚さの半分ずつに分け、隣の部屋の中から見える範囲の外側の半分を
    別のメッシュ（*_Room、extras.faceRoom = 隣の部屋）にする。部屋の外から見える残りは hub のまま。
    """
    face_room = SHARED.get(side) if rid == 'hub' else None
    wall_lower, wall_upper, room_lower, room_upper, footing = [], [], [], [], []
    for lo, hi in runs(room, side, 'body'):
        if not face_room:
            lower, upper = wall_boxes(lo, hi)
            wall_lower.append(lower)
            wall_upper.append(upper)
            continue
        lower, upper = wall_boxes(lo, hi, 0, HT)  # hub の中から見える半分
        wall_lower.append(lower)
        wall_upper.append(upper)
        half = shared_half(side)
        for s0, s1 in split_at(lo, hi, half):
            lower, upper = wall_boxes(s0, s1, -HT, 0)
            inside = abs((s0 + s1) / 2) < half
            (room_lower if inside else wall_lower).append(lower)
            (room_upper if inside else wall_upper).append(upper)
    for lo, hi in runs(room, side, 'footing'):
        footing.append(plain_box((hi - lo, BASE_T, T), ((lo + hi) / 2, -BASE_T / 2, 0)))
    trims = {}
    for role, profiles in (('trim_lower', TRIM_LOWER), ('trim_upper', TRIM_UPPER)):
        trims[role] = []
        for _, h, t, y, off, r in profiles:
            for face, kind in ((1, 'inner'), (-1, 'outer')):
                for lo, hi in runs(room, side, kind, off, t):
                    trims[role].append(kit.bevel_box((hi - lo, h, t), r, ((lo + hi) / 2, y, face * off)))
    parts = [
        component('Wall_Lower', merge(wall_lower), 'Wall_Plaster', 'wall_lower'),
        component('Wall_Upper', merge(wall_upper), 'Wall_Plaster', 'wall_upper'),
    ]
    if face_room:
        parts += [
            component('Wall_Lower_Room', merge(room_lower), 'Wall_Plaster', 'wall_lower', face_room),
            component('Wall_Upper_Room', merge(room_upper), 'Wall_Plaster', 'wall_upper', face_room),
        ]
    parts += [
        component('Trim_Lower', merge(trims['trim_lower']), 'Trim_Oak', 'trim_lower'),
        component('Trim_Upper', merge(trims['trim_upper']), 'Trim_Oak', 'trim_upper'),
        component('Wall_Foundation', merge(footing), 'Foundation', 'foundation'),
    ]
    length = extent(room, side, -1, 'body') + extent(room, side, 1, 'body')
    kit.asset(f'{rid}_wall_{side}', parts, [round(length, 4), H, T], 'wall', 'architecture', label=f'{rid} {side} wall (dev)')


# ---------- 書き出し ----------

def door_info(side):
    return {'side': side, 'offset': 0.0, 'clearWidth': round(2 * R, 4), 'height': round(DOOR_TOP, 4), 'bay': BAY}


def root_extras(rid, room):
    w, d = room['size']
    extras = {
        'roomId': rid,
        'dimensionsMeters': [w, H, d],
        'devShell': True,
        'wallThickness': T,
        'wallHeight': H,
        'floorTopY': 0.0,
        'cutaway': list(room['cutaway']),
        'source': 'tools/home-rooms/build_rooms.py (MemoryMuseum_Home kit v1)',
    }
    if room['doors']:
        extras['doors'] = [door_info(s) for s in room['doors']]
    if rid == 'hub':
        extras['sharedWalls'] = [{'side': s, 'faceRoom': r} for s, r in SHARED.items()]
    if room['open']:
        extras['openSide'] = room['open']
    return extras


def write_room(rid, room, tex):
    w, d = room['size']
    wr = kit.Writer(tex)
    wr.j['asset']['generator'] = 'MemoryMuseum home-rooms dev shell (tools/home-rooms/build_rooms.py, kit v1)'
    extras = root_extras(rid, room)
    wr.j['scenes'][0]['name'] = rid
    wr.j['scenes'][0]['extras'] = extras
    root = wr.node({'name': f'{rid}__shell', 'extras': extras})
    wr.instance(f'{rid}_floor', name=f'{rid}__floor', parent=root, extras={'roomId': rid})
    for side in SIDES:
        if side == room['open']:
            # 開いた側には壁を作らない。hub の壁がこの部屋の 4 面目になる。
            # 印のノードだけ置く（形は無い）。cutaway は hub のその壁と同じにする：
            # home/cutaway.ts は「両側の壁がカットされる角の柱」を隠すので、hub の東の壁（カットされる）に接する
            # right の南西の柱が、カットした手前の角に 1 本だけ立ち残らないようにするため
            hub_side = HUB_WALL_AT_OPEN[rid]
            wr.node({'name': f'{rid}__open_{side}', 'extras': {
                'roomId': rid, 'side': side, 'open': True,
                'cutaway': hub_side in ROOMS['hub']['cutaway'], 'sharedWith': f'hub/{hub_side}'}}, root)
            continue
        cut = side in room['cutaway']
        idx = wr.instance(f'{rid}_wall_{side}', name=f'{rid}__wall_{side}', pos=side_pos(side, w, d),
                          rot=SIDE_ANGLE[side], parent=root, extras={'roomId': rid, 'side': side, 'cutaway': cut})
        if side in room['doors']:
            wr.instance(f'hub_door_{side}', name=f'{rid}__wall_{side}__door', parent=idx,
                        extras={'roomId': rid, 'side': side, 'cutaway': cut, 'door': door_info(side)})
    for sz, ns in ((-1, 'n'), (1, 's')):
        for sx, ew in ((1, 'e'), (-1, 'w')):
            wr.instance('corner_post_318', name=f'{rid}__corner_{ns}{ew}', pos=(sx * (w / 2 - 0.025), 0, sz * (d / 2 - 0.025)),
                        parent=root, extras={'roomId': rid, 'side': 'corner'})
    path = OUT_DIR / f'{rid}.glb'
    wr.save(path)
    return path, len(wr.j['nodes']), len(wr.j['meshes'])


def main():
    tex = json.loads((KIT / 'config' / 'materials.json').read_text())
    print('Modelling kit v1 parts...', flush=True)
    kit.build_assets()
    for side in ROOMS['hub']['doors']:
        build_door_asset(side)
    build_corner_post_asset()
    for rid, room in ROOMS.items():
        build_floor_asset(rid, room)
        for side in SIDES:
            if side != room['open']:
                build_side_asset(rid, room, side)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for rid, room in ROOMS.items():
        path, nodes, meshes = write_room(rid, room, tex)
        shown = path.relative_to(REPO) if path.is_relative_to(REPO) else path
        print(f'{shown}: {path.stat().st_size} bytes, {nodes} nodes, {meshes} meshes', flush=True)


if __name__ == '__main__':
    main()
