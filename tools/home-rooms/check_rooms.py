#!/usr/bin/env python3
"""4 部屋の建物 GLB（backend/static/models/rooms/*.glb）の作りを確かめる。Python の標準ライブラリだけで動く。

開発用シェルにも、納品された本番の GLB にも使える（docs/house-assets.md のチェックリストを機械で見る部分）。

  python3 tools/home-rooms/check_rooms.py [GLB のフォルダ]

見ること：
  - 1 つずつ：ノード名・extras（roomId・side・cutaway・role）・材質名・角の柱・壁と床の UV の決まり・大きさ（AABB）
  - 開口：hub の開口（有効幅 2.10 m・高さ 2.60 m）の中に、形が 1 つも無い（隣の部屋の GLB も置いて調べる）
  - 床：hub の中から開口をくぐって隣の部屋まで、床（role: floor）が y = 0 で切れ目なく続く。開口の下の帯は hub の床
  - 開いた側：6×6 の部屋の hub 側に、壁も柱以外の形も無い
  - 共有の壁：6×6 の部屋の形が hub の壁の中へ入り込んでいない（角の柱の足・柱頭だけは壁に少し埋まる）
  - ちらつき：家全体で、同じ平面・同じ向きの面が重なっているところが無い（z-fighting）
"""
from __future__ import annotations

import json
import math
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_DIR = REPO / 'backend' / 'static' / 'models' / 'rooms'

H = 3.2
T = 0.24
R = 1.05
SPRING = 1.55
ORIGINS = {'hub': (0.0, 0.0), 'left': (-7.24, 0.0), 'right': (7.24, 0.0), 'front': (0.0, -7.24)}
EXPECT = {
    'hub': {'size': (8.0, 8.0), 'open': None, 'doors': ('west', 'east', 'north'), 'cutaway': {'south', 'east'}},
    'left': {'size': (6.0, 6.0), 'open': 'east', 'doors': (), 'cutaway': {'south'}},
    'right': {'size': (6.0, 6.0), 'open': 'west', 'doors': (), 'cutaway': {'south', 'east'}},
    'front': {'size': (6.0, 6.0), 'open': 'south', 'doors': (), 'cutaway': {'east'}},
}
# hub のどの壁の開口が、どの部屋へつながるか
DOOR_TO_ROOM = {'west': 'left', 'east': 'right', 'north': 'front'}
HUB_WALL_AT_OPEN = {'left': 'west', 'right': 'east', 'front': 'north'}
SIDES = ('north', 'south', 'east', 'west')
ROLES = {'floor', 'foundation', 'wall_lower', 'wall_upper', 'trim_lower', 'trim_upper', 'trim'}
MATERIALS = {'Wall_Plaster', 'Floor_Oak', 'Trim_Oak', 'Foundation'}
UV_CENTER = {'wall_lower': 0.46, 'wall_upper': 2.06}

failures: list[str] = []


def check(ok, message):
    if not ok:
        failures.append(message)
    return ok


# ---------- GLB を読む ----------

def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def trs(node):
    if 'matrix' in node:
        m = node['matrix']
        return [[m[c * 4 + r] for c in range(4)] for r in range(4)]
    t = node.get('translation', [0, 0, 0])
    x, y, z, w = node.get('rotation', [0, 0, 0, 1])
    s = node.get('scale', [1, 1, 1])
    r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
         [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
         [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    return [[r[i][0] * s[0], r[i][1] * s[1], r[i][2] * s[2], t[i]] for i in range(3)] + [[0, 0, 0, 1]]


IDENTITY = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]


class Glb:
    def __init__(self, path: Path, rid: str):
        self.path, self.rid = path, rid
        b = path.read_bytes()
        self.bytes = len(b)
        magic, version, length = struct.unpack_from('<III', b, 0)
        assert magic == 0x46546C67 and version == 2 and length == len(b), 'not a GLB 2.0 file'
        jlen, jtype = struct.unpack_from('<II', b, 12)
        assert jtype == 0x4E4F534A
        self.j = json.loads(b[20:20 + jlen])
        blen, btype = struct.unpack_from('<II', b, 20 + jlen)
        assert btype == 0x004E4942
        self.bin = b[28 + jlen:28 + jlen + blen]
        self.nodes = []  # (index, node, world matrix, parent index)
        self.meshes = []  # mesh instances
        scene = self.j['scenes'][self.j.get('scene', 0)]
        self.scene = scene
        for root in scene['nodes']:
            self._walk(root, IDENTITY, None, [])

    def accessor(self, index):
        a = self.j['accessors'][index]
        v = self.j['bufferViews'][a['bufferView']]
        comps = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}[a['type']]
        fmt = {5126: 'f', 5125: 'I', 5123: 'H', 5121: 'B'}[a['componentType']]
        size = struct.calcsize('<' + fmt)
        assert v.get('byteStride', size * comps) == size * comps, 'interleaved buffers are not supported here'
        flat = struct.unpack_from('<%d%s' % (a['count'] * comps, fmt), self.bin, v.get('byteOffset', 0) + a.get('byteOffset', 0))
        if comps == 1:
            return list(flat)
        return [flat[k:k + comps] for k in range(0, len(flat), comps)]

    def _walk(self, index, parent_m, parent, ancestors):
        node = self.j['nodes'][index]
        m = mat_mul(parent_m, trs(node))
        self.nodes.append((index, node, m, parent))
        chain = ancestors + [node]
        if 'mesh' in node:
            side_node = next((n for n in reversed(chain) if 'side' in n.get('extras', {})), None)
            for prim in self.j['meshes'][node['mesh']]['primitives']:
                pos = self.accessor(prim['attributes']['POSITION'])
                nrm = self.accessor(prim['attributes']['NORMAL']) if 'NORMAL' in prim['attributes'] else None
                uv = self.accessor(prim['attributes']['TEXCOORD_0']) if 'TEXCOORD_0' in prim['attributes'] else None
                ind = self.accessor(prim['indices']) if 'indices' in prim else list(range(len(pos)))
                world = [(m[0][0] * p[0] + m[0][1] * p[1] + m[0][2] * p[2] + m[0][3],
                          m[1][0] * p[0] + m[1][1] * p[1] + m[1][2] * p[2] + m[1][3],
                          m[2][0] * p[0] + m[2][1] * p[1] + m[2][2] * p[2] + m[2][3]) for p in pos]
                material = self.j['materials'][prim['material']]['name'] if 'material' in prim else None
                self.meshes.append({
                    'name': node.get('name', ''), 'path': '/'.join(n.get('name', '?') for n in chain),
                    'role': node.get('extras', {}).get('role'), 'material': material,
                    'faceRoom': node.get('extras', {}).get('faceRoom'),
                    'side': side_node.get('extras', {}).get('side') if side_node else None,
                    'local': pos, 'normal': nrm, 'uv': uv, 'world': world,
                    'tris': [(ind[k], ind[k + 1], ind[k + 2]) for k in range(0, len(ind), 3)],
                })
        for child in node.get('children', []):
            self._walk(child, m, index, chain)

    def triangles(self, offset=(0.0, 0.0)):
        """(p0, p1, p2, mesh) を家の座標で返す（offset = 部屋の origin (x, z)）"""
        ox, oz = offset
        out = []
        for mesh in self.meshes:
            w = [(p[0] + ox, p[1], p[2] + oz) for p in mesh['world']]
            for a, b, c in mesh['tris']:
                out.append((w[a], w[b], w[c], mesh))
        return out


# ---------- 幾何の小道具 ----------

def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def bary_hit(p2, a, b, c):
    """2D の点 p2 が三角形 abc（2D）の中にあれば重み (wa, wb, wc)、無ければ None"""
    d = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
    if abs(d) < 1e-14:
        return None
    wa = ((b[1] - c[1]) * (p2[0] - c[0]) + (c[0] - b[0]) * (p2[1] - c[1])) / d
    wb = ((c[1] - a[1]) * (p2[0] - c[0]) + (a[0] - c[0]) * (p2[1] - c[1])) / d
    wc = 1 - wa - wb
    if wa < -1e-9 or wb < -1e-9 or wc < -1e-9:
        return None
    return wa, wb, wc


def side_frame(side, w, d):
    """hub の壁の座標系：(壁の中心線の中心, 壁に沿う向き u, 部屋の内側への向き n)"""
    return {
        'north': ((0.0, -d / 2 - T / 2), (1.0, 0.0), (0.0, 1.0)),
        'south': ((0.0, d / 2 + T / 2), (-1.0, 0.0), (0.0, -1.0)),
        'east': ((w / 2 + T / 2, 0.0), (0.0, 1.0), (-1.0, 0.0)),
        'west': ((-w / 2 - T / 2, 0.0), (0.0, -1.0), (1.0, 0.0)),
    }[side]


def to_frame(p, frame):
    (cx, cz), (ux, uz), (nx, nz) = frame
    dx, dz = p[0] - cx, p[2] - cz
    return (dx * ux + dz * uz, p[1], dx * nx + dz * nz)


def rays_across(tris, frame, samples, n_range):
    """壁の面に垂直な光線（u, y を固定し n を n_range で動かす）が当たる三角形の数"""
    lo_n, hi_n = n_range
    local = []
    umin = min(s[0] for s in samples) - 0.01
    umax = max(s[0] for s in samples) + 0.01
    ymax = max(s[1] for s in samples) + 0.01
    for a, b, c, mesh in tris:
        la, lb, lc = to_frame(a, frame), to_frame(b, frame), to_frame(c, frame)
        us, ys, ns = (la[0], lb[0], lc[0]), (la[1], lb[1], lc[1]), (la[2], lb[2], lc[2])
        if max(us) < umin or min(us) > umax or min(ys) > ymax or max(ys) < 0 or max(ns) < lo_n or min(ns) > hi_n:
            continue
        local.append((la, lb, lc, min(us), max(us), min(ys), max(ys), mesh))
    hits = []
    for u, y in samples:
        for la, lb, lc, u0, u1, y0, y1, mesh in local:
            if u < u0 or u > u1 or y < y0 or y > y1:
                continue
            w = bary_hit((u, y), (la[0], la[1]), (lb[0], lb[1]), (lc[0], lc[1]))
            if w is None:
                continue
            n = w[0] * la[2] + w[1] * lb[2] + w[2] * lc[2]
            if lo_n <= n <= hi_n:
                hits.append((u, y, n, mesh['path'], mesh['role'], mesh))
    return hits


def top_hits(tris, points, ceiling=1.0):
    """各点 (x, z) の真上 ceiling から下ろした光線が最初に当たる面 (y, mesh)。当たらなければ None"""
    xs = [p[0] for p in points]
    zs = [p[1] for p in points]
    box = (min(xs) - 0.01, max(xs) + 0.01, min(zs) - 0.01, max(zs) + 0.01)
    cand = []
    for a, b, c, mesh in tris:
        if min(a[1], b[1], c[1]) > ceiling:
            continue
        x0, x1 = min(a[0], b[0], c[0]), max(a[0], b[0], c[0])
        z0, z1 = min(a[2], b[2], c[2]), max(a[2], b[2], c[2])
        if x1 < box[0] or x0 > box[1] or z1 < box[2] or z0 > box[3]:
            continue
        cand.append((a, b, c, x0, x1, z0, z1, mesh))
    def hit(x, z):
        best = None
        for a, b, c, x0, x1, z0, z1, mesh in cand:
            if x < x0 or x > x1 or z < z0 or z > z1:
                continue
            w = bary_hit((x, z), (a[0], a[2]), (b[0], b[2]), (c[0], c[2]))
            if w is None:
                continue
            y = w[0] * a[1] + w[1] * b[1] + w[2] * c[1]
            if y <= ceiling + 1e-9 and (best is None or y > best[0] + 1e-9):
                best = (y, mesh)
        return best

    out = []
    for x, z in points:
        best = hit(x, z)
        # 部品の継ぎ目のちょうど上の点は、float32 の丸め（1 µm 未満のすき間）で外れることがある。少しずらして調べ直す
        for dx, dz in ((1e-6, 0), (-1e-6, 0), (0, 1e-6), (0, -1e-6)):
            if best is not None:
                break
            best = hit(x + dx, z + dz)
        out.append(best)
    return out


def poly_area(poly):
    if len(poly) < 3:
        return 0.0
    return abs(sum(poly[k][0] * poly[(k + 1) % len(poly)][1] - poly[(k + 1) % len(poly)][0] * poly[k][1] for k in range(len(poly)))) / 2


def clip_poly(poly, clipper):
    """凸多角形 poly を凸多角形 clipper（反時計回り）で切った多角形"""
    def inside(p, a, b):
        return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]) >= -1e-12

    def intersect(p, q, a, b):
        x1, y1, x2, y2 = p[0], p[1], q[0], q[1]
        x3, y3, x4, y4 = a[0], a[1], b[0], b[1]
        den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        if abs(den) < 1e-18:
            return q
        t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
        return (x1 + t * (x2 - x1), y1 + t * (y2 - y1))

    out = list(poly)
    for i in range(len(clipper)):
        a, b = clipper[i], clipper[(i + 1) % len(clipper)]
        src, out = out, []
        if not src:
            break
        for j in range(len(src)):
            p, q = src[j], src[(j + 1) % len(src)]
            if inside(q, a, b):
                if not inside(p, a, b):
                    out.append(intersect(p, q, a, b))
                out.append(q)
            elif inside(p, a, b):
                out.append(intersect(p, q, a, b))
    return out


PLANE_STEP = 1e-4  # 同じ平面とみなす距離（0.1 mm。隣の刻みも比べるので、だいたい 0.2 mm まで）


def coplanar_overlaps(tris, min_area=1e-6):
    """同じ平面・同じ向きで重なっている三角形の組（z-fighting になる）。

    見えない重なりは数えない：
      - 床に接している下向きの面（下向き・高さ 1 cm 未満。床が不透明なので、どこからも見えない）
      - 重なった所が、同じ平面で逆を向いた面にすき間なく覆われている（部品どうしが背中合わせに接している所）
    """
    buckets = {}
    for t in tris:
        a, b, c, mesh = t
        n = cross(sub(b, a), sub(c, a))
        length = math.sqrt(dot(n, n))
        if length < 2e-9:
            continue
        n = (n[0] / length, n[1] / length, n[2] / length)
        if n[1] < -0.5 and max(a[1], b[1], c[1]) < 0.01:
            continue
        key = (round(n[0], 3) + 0.0, round(n[1], 3) + 0.0, round(n[2], 3) + 0.0)
        dkey = round(dot(n, a) / PLANE_STEP)
        buckets.setdefault(key, {}).setdefault(dkey, []).append(t)

    def project(items, keep):
        return [([(p[keep[0]], p[keep[1]]) for p in (a, b, c)], mesh) for (a, b, c, mesh) in items]

    def ccw(pts):
        area2 = sum(pts[k][0] * pts[(k + 1) % len(pts)][1] - pts[(k + 1) % len(pts)][0] * pts[k][1] for k in range(len(pts)))
        return pts if area2 > 0 else pts[::-1]

    def covered(region, key, dkey, keep):
        """region（反時計回り）のうち、同じ平面で逆を向いた面に覆われている割合"""
        opposite = buckets.get((-key[0] + 0.0, -key[1] + 0.0, -key[2] + 0.0), {})
        total = 0.0
        for nd in (-dkey - 1, -dkey, -dkey + 1):
            for pts, _ in project(opposite.get(nd, []), keep):
                total += poly_area(clip_poly(region, ccw(pts)))
        return total / max(poly_area(region), 1e-12)

    found = []
    for key, planes in buckets.items():
        axis = max(range(3), key=lambda k: abs(key[k]))
        keep = [k for k in range(3) if k != axis]
        for dkey, items in planes.items():
            group = project(items, keep)
            # 同じ刻みどうしと、1 つ上の刻み（丸めの境目をまたいだもの）
            for other, same in ((group, True), (project(planes.get(dkey + 1, []), keep), False)):
                for i, (pa, ma) in enumerate(group):
                    ax0, ax1 = min(p[0] for p in pa), max(p[0] for p in pa)
                    ay0, ay1 = min(p[1] for p in pa), max(p[1] for p in pa)
                    for j in range(i + 1 if same else 0, len(other)):
                        pb, mb = other[j]
                        if max(p[0] for p in pb) <= ax0 or min(p[0] for p in pb) >= ax1:
                            continue
                        if max(p[1] for p in pb) <= ay0 or min(p[1] for p in pb) >= ay1:
                            continue
                        region = clip_poly(ccw(pa), ccw(pb))
                        area = poly_area(region)
                        if area > min_area and covered(ccw(region), key, dkey, keep) < 0.98:
                            flat = max(abs(v) for v in key) > 0.999
                            found.append((round(area, 7), ma['path'], mb['path'], key, round(dkey * PLANE_STEP, 4), flat))
    return found


# ---------- 1 つの GLB ----------

def check_single(g: Glb):
    rid = g.rid
    exp = EXPECT[rid]
    w, d = exp['size']
    print(f'== {rid}.glb ==')
    tri_count = sum(len(m['tris']) for m in g.meshes)
    print(f'  bytes {g.bytes}, nodes {len(g.j["nodes"])}, meshes {len(g.j["meshes"])}, mesh nodes {len(g.meshes)}, '
          f'triangles {tri_count}, images {len(g.j.get("images", []))}')
    allp = [p for m in g.meshes for p in m['world']]
    lo = [round(min(p[k] for p in allp), 4) for k in range(3)]
    hi = [round(max(p[k] for p in allp), 4) for k in range(3)]
    print(f'  AABB (room-local) min {lo} max {hi}')

    # ノード名と extras
    roots = g.scene['nodes']
    check(len(roots) == 1, f'{rid}: scene must have exactly one root node')
    root = g.j['nodes'][roots[0]]
    rx = root.get('extras', {})
    check(root.get('name') == f'{rid}__shell', f'{rid}: root node name {root.get("name")!r}')
    check(rx.get('roomId') == rid and rx.get('dimensionsMeters') == [w, H, d] and rx.get('devShell', False) in (True, False),
          f'{rid}: root extras {rx}')
    check(g.scene.get('extras', {}).get('roomId') == rid, f'{rid}: scene extras roomId')
    names = [g.j['nodes'][c].get('name', '') for c in root.get('children', [])]
    bad = [n for n in names if not n.startswith(f'{rid}__')]
    check(not bad, f'{rid}: child nodes without room prefix {bad}')
    walls = {}
    opens = {}
    corners = []
    for index, node, m, parent in g.nodes:
        e = node.get('extras', {})
        if e.get('side') == 'corner':
            corners.append((node.get('name'), round(m[0][3], 4), round(m[2][3], 4)))
        elif e.get('side') in SIDES and parent == roots[0]:
            if e.get('open'):
                opens[e['side']] = e
            else:
                check(isinstance(e.get('cutaway'), bool), f'{rid}: {node.get("name")} has no boolean cutaway')
                walls[e['side']] = e
    expected_walls = {s for s in SIDES if s != exp['open']}
    check(set(walls) == expected_walls, f'{rid}: wall sides {sorted(walls)} expected {sorted(expected_walls)}')
    cut = {s for s, e in walls.items() if e.get('cutaway')}
    check(cut == exp['cutaway'], f'{rid}: cutaway walls {sorted(cut)} expected {sorted(exp["cutaway"])}')
    print(f'  walls {sorted(walls)}; cutaway {sorted(cut)}', end='')
    if exp['open']:
        mark = opens.get(exp['open'])
        check(mark is not None, f'{rid}: open-side marker {exp["open"]} missing')
        if mark:
            hub_cut = HUB_WALL_AT_OPEN[rid] in EXPECT['hub']['cutaway']
            check(mark.get('cutaway') == hub_cut, f'{rid}: open marker cutaway {mark.get("cutaway")} expected {hub_cut}')
            print(f'; open side {exp["open"]} (marker cutaway={mark.get("cutaway")})', end='')
    print()
    exp_corners = {(round(sx * (w / 2 - 0.025), 4), round(sz * (d / 2 - 0.025), 4)) for sx in (-1, 1) for sz in (-1, 1)}
    got_corners = {(x, z) for _, x, z in corners}
    check(len(corners) == 4 and got_corners == exp_corners, f'{rid}: corner posts {corners}')
    print(f'  corner posts {len(corners)}: ' + ', '.join(f'{n} ({x}, {z})' for n, x, z in sorted(corners)))

    roles = {}
    for mesh in g.meshes:
        roles.setdefault(mesh['role'], 0)
        roles[mesh['role']] += 1
        check(mesh['role'] in ROLES, f'{rid}: mesh {mesh["path"]} role {mesh["role"]!r}')
        if mesh['faceRoom'] is not None:
            ok = rid == 'hub' and mesh['side'] in DOOR_TO_ROOM and mesh['faceRoom'] == DOOR_TO_ROOM[mesh['side']] \
                and mesh['role'] in UV_CENTER
            check(ok, f'{rid}: unexpected faceRoom {mesh["faceRoom"]!r} on {mesh["path"]}')
        check(mesh['material'] in MATERIALS, f'{rid}: mesh {mesh["path"]} material {mesh["material"]!r}')
    print('  roles ' + ', '.join(f'{k}×{v}' for k, v in sorted(roles.items())) +
          '; materials ' + ', '.join(sorted({m['material'] for m in g.meshes})))
    face = sorted({(m['side'], m['faceRoom']) for m in g.meshes if m['faceRoom']})
    if rid == 'hub':
        check(face == sorted((s, DOOR_TO_ROOM[s]) for s in exp['doors']), f'hub: faceRoom meshes {face}')
        print('  faceRoom (room side of the shared walls): ' + ', '.join(f'{s} -> {r}' for s, r in face))

    # UV の決まり（theme.ts）：壁の表と裏は v = y − 中心（下 0.46・上 2.06）、床の上面は 1 UV = 2 m
    uv_bad = 0
    for mesh in g.meshes:
        if mesh['role'] in UV_CENTER and mesh['uv'] and mesh['normal']:
            c = UV_CENTER[mesh['role']]
            for p, n, uv in zip(mesh['local'], mesh['normal'], mesh['uv']):
                if abs(n[2]) >= 0.99 and abs(uv[1] - (p[1] - c)) > 1e-4:
                    uv_bad += 1
        if mesh['role'] == 'floor' and mesh['uv'] and mesh['normal']:
            offs = {(round(uv[0] - p[0] / 2, 5), round(uv[1] - p[2] / 2, 5))
                    for p, n, uv in zip(mesh['local'], mesh['normal'], mesh['uv']) if n[1] >= 0.99}
            if len(offs) != 1:
                uv_bad += 1
    check(uv_bad == 0, f'{rid}: {uv_bad} vertices break the wall/floor UV convention')
    print(f'  UV convention (walls v = y - 0.46 / 2.06, floor 2 m per UV): {"ok" if uv_bad == 0 else f"{uv_bad} bad"}')

    # 開いた側：壁も柱以外の形も無い
    if exp['open']:
        frame = side_frame(exp['open'], w, d)
        along = (exp['size'][0] if exp['open'] in ('north', 'south') else exp['size'][1]) / 2 - 0.15
        samples = [(-along + 2 * along * i / 40, 0.02 + (H - 0.04) * k / 40) for i in range(41) for k in range(41)]
        hits = rays_across(g.triangles(), frame, samples, (-0.7, 0.5))
        check(not hits, f'{rid}: {len(hits)} hits on the open side, e.g. {[h[:5] for h in hits[:3]]}')
        print(f'  open side {exp["open"]}: {len(samples)} rays across |u| <= {along:.2f}, 0.02 <= y <= 3.18 -> {len(hits)} hits')


# ---------- 家全体（部屋を origin に置く） ----------

def check_house(glbs):
    print('== house (all rooms at their origins) ==')
    hub = glbs['hub']
    hw, hd = EXPECT['hub']['size']
    hub_tris = hub.triangles(ORIGINS['hub'])
    room_tris = {rid: glbs[rid].triangles(ORIGINS[rid]) for rid in glbs if rid != 'hub'}

    for side in EXPECT['hub']['doors']:
        rid = DOOR_TO_ROOM[side]
        frame = side_frame(side, hw, hd)
        tris = hub_tris + room_tris.get(rid, [])
        # 開口の中（枠の足元の台 0.0225 m を避けて |u| <= 1.02）。壁の厚さの外 0.8 m まで
        samples = []
        for i in range(35):
            u = -1.02 + 2.04 * i / 34
            top = SPRING + math.sqrt(max(0.0, R * R - u * u)) - 0.02
            y = 0.02
            while y <= top:
                samples.append((u, y))
                y += 0.05
        hits = rays_across(tris, frame, samples, (-0.8, 0.8))
        check(not hits, f'door {side}: {len(hits)} hits inside the clear opening, e.g. {[h[:5] for h in hits[:3]]}')
        print(f'  door hub/{side} -> {rid}: {len(samples)} rays through the opening (|u| <= 1.02, y up to the arch - 0.02, '
              f'n -0.8..0.8) -> {len(hits)} hits')

        # 床：hub の中（n = 3.5）から開口をくぐり、隣の部屋の奥（6×6 の部屋の中ほど）まで
        (cx, cz), (ux, uz), (nx, nz) = frame
        rd = EXPECT[rid]['size'][1]
        points, labels = [], []
        for u in (-1.0, -0.5, 0.0, 0.5, 1.0):
            n = 3.5
            while n >= -(T / 2 + rd * 0.75):
                points.append((cx + u * ux + n * nx, cz + u * uz + n * nz))
                labels.append(n)
                n -= 0.02
        res = top_hits(tris, points)
        miss = [labels[i] for i, r in enumerate(res) if r is None]
        not_floor = [(labels[i], r[1]['path']) for i, r in enumerate(res) if r is not None and r[1]['role'] != 'floor']
        off_level = [(labels[i], r[0]) for i, r in enumerate(res) if r is not None and abs(r[0]) > 1e-5]
        strip = [r for i, r in enumerate(res) if r is not None and abs(labels[i]) < T / 2 - 0.005]
        strip_hub = [r for r in strip if r[1]['path'].startswith('hub__') and r[1]['role'] == 'floor']
        check(not miss and not not_floor and not off_level,
              f'door {side}: floor gaps {miss[:3]}, non-floor tops {not_floor[:3]}, off-level {off_level[:3]}')
        check(len(strip) > 0 and len(strip_hub) == len(strip), f'door {side}: strip under the opening is not the hub floor')
        print(f'  floor hub/{side} -> {rid}: {len(points)} downward rays (n 3.5 .. {-(T / 2 + rd * 0.75):.2f}, '
              f'u -1..1) -> gaps {len(miss)}, non-floor {len(not_floor)}, |y| > 1e-5: {len(off_level)}; '
              f'strip under the opening: {len(strip_hub)}/{len(strip)} rays hit the hub floor at y = 0')

    # 共有の壁の面：隣の部屋の中から見える壁の面は faceRoom = その部屋、hub の中から見える面は faceRoom なし
    for side in EXPECT['hub']['doors']:
        rid = DOOR_TO_ROOM[side]
        frame = side_frame(side, hw, hd)
        half = (EXPECT[rid]['size'][0] if side in ('north', 'south') else EXPECT[rid]['size'][1]) / 2
        samples = []
        for i in range(57):
            u = -(half - 0.2) + 2 * (half - 0.2) * i / 56
            for k in range(12):
                y = 0.25 + 0.25 * k
                in_opening = abs(u) < R + 0.2 and (y < SPRING or u * u + (y - SPRING) ** 2 < (R + 0.2) ** 2)
                if not in_opening:
                    samples.append((round(u, 4), y))
        hits = rays_across(hub_tris, frame, samples, (-0.8, 0.8))
        by_sample = {}
        for h in hits:
            by_sample.setdefault((h[0], h[1]), []).append(h)
        bad_room, bad_hub, room_walls = [], [], 0
        for key, hs in by_sample.items():
            near_room = min(hs, key=lambda h: h[2])
            near_hub = max(hs, key=lambda h: h[2])
            if near_room[4] in UV_CENTER:
                room_walls += 1
                if near_room[5]['faceRoom'] != rid:
                    bad_room.append(key)
            if near_hub[4] in UV_CENTER and near_hub[5]['faceRoom'] is not None:
                bad_hub.append(key)
        check(not bad_room and not bad_hub and room_walls > 0,
              f'shared wall {side}: room side not tagged {bad_room[:3]}, hub side tagged {bad_hub[:3]}')
        print(f'  shared wall hub/{side}: {len(samples)} rays; first wall face seen from {rid}: faceRoom={rid} '
              f'{room_walls - len(bad_room)}/{room_walls}; seen from hub: untagged {len(by_sample) - len(bad_hub)}/{len(by_sample)}')

    # 共有の壁：6×6 の部屋の形が hub の壁の外の面（±4.24）より hub 側へ入り込む量
    for rid, tris in room_tris.items():
        side = HUB_WALL_AT_OPEN[rid]
        frame = side_frame(side, hw, hd)
        outer_n = -T / 2  # hub の壁の外の面（n は hub の内側が +）
        worst = {}
        for a, b, c, mesh in tris:
            n = max(to_frame(p, frame)[2] for p in (a, b, c)) - outer_n
            key = 'corner posts' if mesh['path'].split('/')[1].startswith(f'{rid}__corner') else mesh['role']
            worst[key] = max(worst.get(key, -1.0), n)
        for key, v in worst.items():
            if key == 'corner posts':
                check(v < T - 0.05, f'{rid}: corner posts reach through the hub wall ({v:.4f})')
            else:
                check(v <= 1e-6, f'{rid}: {key} enters the hub wall by {v:.4f} m')
        print(f'  {rid} vs hub/{side} outer face: max penetration ' +
              ', '.join(f'{k} {max(v, 0):.4f}' for k, v in sorted(worst.items())))

    # hub の形が外の面（±4.24）からはみ出す量。外側の幅木・回り縁（〜0.07 m）と、開口の枠の足元の台（0.075 m）だけのはず
    out = {}
    for a, b, c, mesh in hub_tris:
        for p in (a, b, c):
            v = max(abs(p[0]), abs(p[2])) - (hw / 2 + T)
            out[mesh['role']] = max(out.get(mesh['role'], -9), v)
    print('  hub beyond its outer faces (4.24): ' + ', '.join(f'{k} {max(v, 0):.4f}' for k, v in sorted(out.items())))
    for role, v in out.items():
        check(v <= 0.0751 if role.startswith('trim') else v <= 1e-6, f'hub: {role} sticks out {v:.4f} m')

    # ちらつき（同じ平面・同じ向きで重なる面）。平らな面（軸に沿った面）は 1 つも重なってはいけない。
    # 角の丸み（bevel）の細い帯は、同じ点から同じ向きに丸め始めると最初の帯が同じ平面に乗る（開口の区画の端で、
    # 壁と回り縁の端がそろう所）。幅 1 mm ほどの帯で、壁の継ぎ目の溝の中なので、1 cm² を超えなければ情報として出すだけにする
    all_tris = hub_tris + [t for tris in room_tris.values() for t in tris]
    found = coplanar_overlaps(all_tris)
    flat = [f for f in found if f[5]]
    bevel = [f for f in found if not f[5]]
    check(not flat, f'{len(flat)} coplanar overlapping flat faces, e.g. {sorted(flat, reverse=True)[:3]}')
    big = [f for f in bevel if f[0] > 1e-4]
    check(not big, f'{len(big)} bevel strips overlap more than 1 cm², e.g. {sorted(big, reverse=True)[:3]}')
    print(f'  coplanar overlapping faces (z-fighting) across {len(all_tris)} triangles: flat faces {len(flat)}; '
          f'bevel strips {len(bevel)} (largest {max([f[0] for f in bevel], default=0) * 1e4:.2f} cm²; informational if < 1 cm²)')


def main():
    folder = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DIR
    glbs = {}
    for rid in EXPECT:
        path = folder / f'{rid}.glb'
        if not check(path.exists(), f'{path} is missing'):
            continue
        glbs[rid] = Glb(path, rid)
        check_single(glbs[rid])
    if 'hub' in glbs:
        check_house(glbs)
    total = sum(g.bytes for g in glbs.values())
    print(f'total {total} bytes ({total / 1e6:.2f} MB) in {len(glbs)} files')
    if failures:
        print(f'FAILED ({len(failures)})')
        for f in failures:
            print('  - ' + f)
        sys.exit(1)
    print('ALL CHECKS PASSED')


if __name__ == '__main__':
    main()
