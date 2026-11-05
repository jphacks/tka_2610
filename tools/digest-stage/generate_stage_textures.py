#!/usr/bin/env python3
"""シアター (期間をえらんで振り返る) の舞台の、手描き風テクスチャを作る。

家・木・低木・丘・地面・空を、紙の地・筆のむら・ガッシュ調の筆あとで描く。
絵柄はすべてこのスクリプトの手続きで作り、外部の画像は使わない (シード固定で毎回同じ結果)。
色は memoria の色 (web/src/styles/tokens.css) に合わせている。

出力: backend/static/stage/
  - textures/*.jpg     : 各小物・地面・空・紙の凹凸 (法線)
  - stage.json         : 小物ごとの輪郭 (0..1 の多角形)・大きさ・厚み・裏と縁の色。
                         Web はこの輪郭で板を押し出すので、絵と形が必ず一致する

使い方 (tools/digest-stage で):
  python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
  .venv/bin/python generate_stage_textures.py
"""
from __future__ import annotations

import json
import math
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'backend' / 'static' / 'stage'
TEX = OUT / 'textures'

# memoria の色を、絵の具らしく少しだけ濃く・濁らせたもの
INK = '#3E6178'
PAPER = '#FFFCF7'
SKY = '#CBE8F7'
PEACH = '#F4C3AE'
SUN = '#F6DC9A'
SAGE = '#BCD5B0'
GREEN = '#5F8F74'
BLUE = '#6E98B5'
DEEP_BLUE = '#426780'
TERRACOTTA = '#D9906F'
CREAM = '#F5EEDF'
BARK = '#9C7458'


# =============================
# 筆と紙 (どの絵にも使う道具)
# =============================

def rgb(value):
    value = value.lstrip('#')
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def mix(a, b, t):
    ca, cb = rgb(a), rgb(b)
    return '#%02x%02x%02x' % tuple(round(x * (1 - t) + y * t) for x, y in zip(ca, cb))


def noise(w, h, rng, cell):
    aw, ah = max(2, round(w / cell)), max(2, round(h / cell))
    small = (rng.random((ah, aw)) * 255).astype(np.uint8)
    return np.asarray(Image.fromarray(small).resize((w, h), Image.Resampling.BICUBIC), dtype=np.float32) / 255 - .5


def paper(w, h, color, seed, amount=1.0):
    """紙に塗った絵の具のむら。大きなむら・中くらいのむら・細かい粒・刷毛の向き"""
    rng = np.random.default_rng(seed)
    value = noise(w, h, rng, 150) * 16 + noise(w, h, rng, 40) * 8 + noise(w, h, rng, 6) * 3.5
    value += rng.normal(0, .8, (h, w)).astype(np.float32)
    strokes = rng.random((max(3, h // 6), max(3, w // 60))) * 255
    value += (np.asarray(Image.fromarray(strokes.astype(np.uint8)).resize((w, h), Image.Resampling.BICUBIC),
                         dtype=np.float32) / 255 - .5) * 5
    base = np.asarray(rgb(color), dtype=np.float32)
    arr = np.clip(base[None, None, :] + (value * amount)[:, :, None] * np.array([1.0, .98, .9]), 0, 255)
    return Image.fromarray(arr.astype(np.uint8), 'RGB')


def fill(im, color, seed, polygon=None, ellipse=None, amount=1.0, blur=.7):
    mask = Image.new('L', im.size, 0)
    d = ImageDraw.Draw(mask)
    if polygon is not None:
        d.polygon(polygon, fill=255)
    if ellipse is not None:
        d.ellipse(ellipse, fill=255)
    im.paste(paper(*im.size, color, seed, amount), (0, 0), mask.filter(ImageFilter.GaussianBlur(blur)))


def bezier(a, b, c, d, n=50):
    out = []
    for t in np.linspace(0, 1, n):
        u = 1 - t
        out.append((u ** 3 * a[0] + 3 * u * u * t * b[0] + 3 * u * t * t * c[0] + t ** 3 * d[0],
                    u ** 3 * a[1] + 3 * u * u * t * b[1] + 3 * u * t * t * c[1] + t ** 3 * d[1]))
    return out


def stroke(im, points, color, width, seed, opacity=225, blur=.45):
    """筆圧が変わるガッシュの筆あと。両端は細く、かすれる"""
    pad = math.ceil(width) + 4
    x0 = max(0, math.floor(min(p[0] for p in points)) - pad)
    y0 = max(0, math.floor(min(p[1] for p in points)) - pad)
    x1 = min(im.width, math.ceil(max(p[0] for p in points)) + pad)
    y1 = min(im.height, math.ceil(max(p[1] for p in points)) + pad)
    if x1 - x0 < 2 or y1 - y0 < 2:
        return
    size = (x1 - x0, y1 - y0)
    mask = Image.new('L', size, 0)
    d = ImageDraw.Draw(mask)
    phase = random.Random(seed).uniform(0, math.tau)
    pts = [(x - x0, y - y0) for x, y in points]
    for i in range(len(pts) - 1):
        t = (i + .5) / max(1, len(pts) - 1)
        pressure = (.3 + .7 * math.sin(math.pi * t) ** .5) * (1 + .1 * math.sin(t * 13 + phase))
        ww = max(1, int(width * pressure))
        d.line([pts[i], pts[i + 1]], fill=255, width=ww)
        r = ww * .48
        d.ellipse((pts[i][0] - r, pts[i][1] - r, pts[i][0] + r, pts[i][1] + r), fill=255)
    rng = np.random.default_rng(seed + 9000)
    tooth = np.clip(.95 + noise(*size, rng, 5) * .4 + rng.normal(0, .03, (size[1], size[0])), .6, 1)
    alpha = np.asarray(mask.filter(ImageFilter.GaussianBlur(blur)), dtype=np.float32) * tooth * (opacity / 255)
    im.paste(paper(*size, color, seed + 9001, .8), (x0, y0), Image.fromarray(np.clip(alpha, 0, 255).astype(np.uint8), 'L'))


def dab(im, x, y, r, color, seed, opacity=220, squash=1.0, angle=0.0):
    """筆先を置いた、まるい点 (葉・花びら・雲)。少しゆがんだ楕円に紙の粒をのせる"""
    rr = random.Random(seed)
    size = int(r * 2.6) + 6
    mask = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(mask)
    c = size / 2
    pts = []
    for i in range(24):
        a = math.tau * i / 24
        k = 1 + rr.uniform(-.12, .12)
        px, py = math.cos(a) * r * k, math.sin(a) * r * squash * k
        pts.append((c + px * math.cos(angle) - py * math.sin(angle), c + px * math.sin(angle) + py * math.cos(angle)))
    d.polygon(pts, fill=255)
    rng = np.random.default_rng(seed + 7000)
    tooth = np.clip(.92 + noise(size, size, rng, 4) * .35, .6, 1)
    alpha = np.asarray(mask.filter(ImageFilter.GaussianBlur(max(.6, r * .08))), dtype=np.float32) * tooth * (opacity / 255)
    x0, y0 = int(x - c), int(y - c)
    im.paste(paper(size, size, color, seed + 7001, .7), (x0, y0), Image.fromarray(np.clip(alpha, 0, 255).astype(np.uint8), 'L'))


def outline_stroke(im, polygon, color, width, seed, opacity=150):
    """輪郭を、途切れがちな細い線でなぞる (板の縁の鉛筆線)"""
    rr = random.Random(seed)
    n = len(polygon)
    i = 0
    while i < n:
        run = rr.randint(6, 16)
        seg = [polygon[(i + k) % n] for k in range(run + 1)]
        stroke(im, seg, color, width * rr.uniform(.7, 1.15), seed + i, opacity)
        i += run + rr.randint(0, 2)


# =============================
# 輪郭 (0..1、y は上向き) と画像座標の変換
# =============================

def to_px(points, w, h):
    return [(x * w, (1 - y) * h) for x, y in points]


def polar_blob(cx, cy, rx, ry, lobes, depth, phase, a0, a1, n=72):
    """ふくらみ (lobes 個) のある丸い形の、角度 a0 から a1 までの点"""
    out = []
    for i in range(n + 1):
        a = a0 + (a1 - a0) * i / n
        r = 1 + depth * math.cos(lobes * a + phase)
        out.append((cx + math.cos(a) * rx * r, cy + math.sin(a) * ry * r))
    return out


def tree_outline(cx, cy, rx, ry, lobes, depth, phase, trunk_half, trunk_top):
    """幹 + まるい葉の輪郭。葉の下側で幹につなぐ"""
    gap = math.asin(min(.95, trunk_half / rx))
    a0 = -math.pi / 2 + gap
    a1 = 3 * math.pi / 2 - gap
    crown = polar_blob(cx, cy, rx, ry, lobes, depth, phase, a0, a1)
    return [(cx - trunk_half, 0), (cx + trunk_half, 0), (cx + trunk_half, min(trunk_top, crown[0][1])),
            *crown, (cx - trunk_half, min(trunk_top, crown[-1][1]))]


def round_poly(points, soft=.18, n=6):
    """角を少し丸めた多角形 (手で切った板の角)"""
    out = []
    for i, v in enumerate(points):
        p, q = points[i - 1], points[(i + 1) % len(points)]
        a = (v[0] * (1 - soft) + p[0] * soft, v[1] * (1 - soft) + p[1] * soft)
        b = (v[0] * (1 - soft) + q[0] * soft, v[1] * (1 - soft) + q[1] * soft)
        for t in np.linspace(0, 1, n):
            u = 1 - t
            out.append((u * u * a[0] + 2 * u * t * v[0] + t * t * b[0], u * u * a[1] + 2 * u * t * v[1] + t * t * b[1]))
    return out


def save(im, name, quality=88):
    TEX.mkdir(parents=True, exist_ok=True)
    path = TEX / f'{name}.jpg'
    im.convert('RGB').save(path, quality=quality, optimize=True, progressive=True)
    print(f'{name}.jpg {im.width}x{im.height} {path.stat().st_size // 1024} KB', flush=True)
    return f'textures/{name}.jpg'


# =============================
# 窓・扉 (家の部品)
# =============================

def window_round(im, cx, cy, r, seed, frame=CREAM, glass=SKY):
    im_d = (cx - r, cy - r, cx + r, cy + r)
    fill(im, frame, seed, ellipse=im_d)
    g = r * .74
    fill(im, glass, seed + 1, ellipse=(cx - g, cy - g, cx + g, cy + g), amount=.7)
    stroke(im, [(cx - g * .9, cy), (cx + g * .9, cy)], frame, r * .14, seed + 2)
    stroke(im, [(cx, cy - g * .9), (cx, cy + g * .9)], frame, r * .14, seed + 3)
    stroke(im, [(cx - g * .5, cy - g * .45), (cx - g * .15, cy - g * .7)], '#ffffff', r * .1, seed + 4, 160)


def window_square(im, box, seed, frame=CREAM, glass=SKY, sill=None):
    x0, y0, x1, y1 = box
    fill(im, frame, seed, polygon=round_poly([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], .12))
    m = (x1 - x0) * .13
    fill(im, glass, seed + 1, polygon=[(x0 + m, y0 + m), (x1 - m, y0 + m), (x1 - m, y1 - m), (x0 + m, y1 - m)], amount=.7)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    stroke(im, [(cx, y0 + m), (cx, y1 - m)], frame, m * .9, seed + 2)
    stroke(im, [(x0 + m, cy), (x1 - m, cy)], frame, m * .9, seed + 3)
    if sill:
        stroke(im, [(x0 - m * .6, y1 + m * .4), (x1 + m * .6, y1 + m * .4)], sill, m * 1.3, seed + 4)


def window_arch(im, box, seed, frame=CREAM, glass=SKY):
    x0, y0, x1, y1 = box
    w = x1 - x0
    arch = [(x0, y1), (x1, y1)] + [(x0 + w / 2 + math.cos(a) * w / 2, y0 + w / 2 - math.sin(a) * w / 2)
                                   for a in np.linspace(0, math.pi, 24)]
    fill(im, frame, seed, polygon=arch)
    m = w * .14
    inner = [(x0 + m, y1 - m), (x1 - m, y1 - m)] + [(x0 + w / 2 + math.cos(a) * (w / 2 - m), y0 + w / 2 - math.sin(a) * (w / 2 - m))
                                                    for a in np.linspace(0, math.pi, 24)]
    fill(im, glass, seed + 1, polygon=inner, amount=.7)
    stroke(im, [(x0 + w / 2, y0 + m), (x0 + w / 2, y1 - m)], frame, m * .8, seed + 2)


def door(im, box, color, seed, knob=SUN):
    x0, y0, x1, y1 = box
    w = x1 - x0
    shape = [(x0, y1), (x1, y1)] + [(x0 + w / 2 + math.cos(a) * w / 2, y0 + w / 2 - math.sin(a) * w / 2)
                                    for a in np.linspace(0, math.pi, 24)]
    fill(im, color, seed, polygon=shape)
    for k in (1, 2):
        x = x0 + w * k / 3
        stroke(im, [(x, y0 + w * .35), (x, y1 - w * .1)], mix(color, INK, .25), w * .05, seed + k, 150)
    r = w * .07
    fill(im, knob, seed + 5, ellipse=(x1 - w * .25 - r, (y0 + y1) / 2 + w * .3 - r, x1 - w * .25 + r, (y0 + y1) / 2 + w * .3 + r))


# =============================
# 小物ごとの絵
# =============================

PROPS: list[dict] = []


def prop(name, kind, outline, width, height, depth, back, edge, texture):
    PROPS.append({
        'name': name, 'kind': kind, 'texture': texture,
        'width': width, 'height': height, 'depth': depth,
        'back': back, 'edge': edge,
        'outline': [[round(x, 4), round(y, 4)] for x, y in outline],
    })


def house_peach():
    """桃色の壁に水色の三角屋根。丸い窓とアーチの扉、窓辺の花"""
    w, h = 768, 1024
    outline = round_poly([(.06, 0), (.94, 0), (.94, .58), (1, .58), (.5, 1), (0, .58), (.06, .58)], .1)
    im = paper(w, h, PEACH, 101)
    roof = to_px([(-.05, .55), (1.05, .55), (.5, 1.02)], w, h)
    fill(im, BLUE, 102, polygon=roof)
    rr = random.Random(103)
    # 屋根の、うろこのような瓦
    for row in range(7):
        y = .6 + row * .057
        half = (1 - (y - .55) / .45) * .5
        n = max(2, int(half * 18))
        for k in range(n):
            x = .5 - half + (k + .5) * 2 * half / n
            px, py = x * w, (1 - y) * h
            stroke(im, [(px - 22, py - 6), (px, py + 8), (px + 22, py - 6)], mix(BLUE, '#ffffff', .25), 7, 104 + row * 40 + k, 170)
    stroke(im, to_px([(.0, .575), (1., .575)], w, h), mix(BLUE, INK, .4), 16, 120)
    # 画像の座標 (上から) で、屋根は 0〜0.44、壁は 0.44〜1
    window_round(im, .5 * w, .26 * h, 62, 130, glass=SUN)
    window_square(im, (.13 * w, .55 * h, .41 * w, .74 * h), 140, glass='#A9D2EA', sill=TERRACOTTA)
    for k in range(7):
        dab(im, .14 * w + k * 30, .775 * h, 12, rr.choice(['#E8726B', SUN, '#F59FB0', '#ffffff']), 150 + k)
    door(im, (.56 * w, .56 * h, .83 * w, .995 * h), GREEN, 160)
    for k in range(40):
        x, y = rr.uniform(.08, .92) * w, rr.uniform(.45, .99) * h
        dab(im, x, y, rr.uniform(3, 6), mix(PEACH, '#ffffff', .4), 170 + k, 70, angle=rr.uniform(0, 3))
    outline_stroke(im, to_px(outline, w, h), mix(PEACH, INK, .45), 4, 180)
    prop('house_peach', 'house', outline, 1.7, 2.3, .19, '#E8B39E', '#F7D7C8', save(im, 'house_peach'))


def house_sage():
    """細長いセージ色の家。斜めじまの屋根と煙突、縦にならぶ窓"""
    w, h = 640, 1024
    outline = round_poly([(0, 0), (1, 0), (1, .72), (.8, .832), (.8, .97), (.68, .97), (.68, .9), (.5, 1), (0, .72)], .08)
    im = paper(w, h, SAGE, 201)
    fill(im, mix(SAGE, GREEN, .35), 202, polygon=to_px([(.66, .8), (.82, .8), (.82, 1), (.66, 1)], w, h))
    fill(im, TERRACOTTA, 203, polygon=to_px([(-.05, .7), (1.05, .7), (.5, 1.03)], w, h))
    rr = random.Random(204)
    for k in range(14):
        x = -.1 + k * .09
        stroke(im, to_px([(x, .7), (x + .18, .95)], w, h), mix(TERRACOTTA, '#ffffff', .3), 10, 205 + k, 140)
    stroke(im, to_px([(0, .705), (1, .705)], w, h), mix(TERRACOTTA, INK, .35), 14, 220)
    # 画像の座標 (上から) で、屋根は 0〜0.29、壁は 0.29〜1
    window_round(im, .5 * w, .19 * h, 40, 230, frame=CREAM, glass=SUN)
    for row, top in enumerate((.36, .56)):
        for col, left in enumerate((.16, .58)):
            window_square(im, (left * w, top * h, (left + .26) * w, (top + .13) * h), 240 + row * 20 + col * 10,
                          glass='#A9D2EA', sill=CREAM)
    door(im, (.36 * w, .76 * h, .64 * w, .995 * h), DEEP_BLUE, 290)
    for k in range(60):
        x, y = rr.uniform(.04, .96) * w, rr.uniform(.3, .99) * h
        stroke(im, [(x, y), (x + rr.uniform(-3, 3), y + rr.uniform(12, 26))], mix(SAGE, GREEN, .25), 3, 300 + k, 70)
    outline_stroke(im, to_px(outline, w, h), mix(SAGE, INK, .45), 4, 280)
    prop('house_sage', 'house', outline, 1.15, 2.75, .19, '#A9C79C', '#D6E6CC', save(im, 'house_sage'))


def house_butter():
    """横に広い、たまご色の家。まるい青い屋根と、しま模様の日よけ"""
    w, h = 1024, 768
    dome = [(.5 + math.cos(a) * .52, .52 + math.sin(a) * .46) for a in np.linspace(0, math.pi, 40)]
    outline = [(.04, 0), (.96, 0), (.96, .52)] + dome[1:-1] + [(.04, .52)]
    im = paper(w, h, SUN, 301)
    fill(im, DEEP_BLUE, 302, polygon=to_px([(-.02, .5)] + dome + [(1.02, .5)], w, h))
    for k in range(9):
        a = math.pi * (k + .5) / 9
        top = (.5 + math.cos(a) * .5, .52 + math.sin(a) * .44)
        stroke(im, to_px([(.5 + (top[0] - .5) * .25, .54), top], w, h), mix(DEEP_BLUE, SKY, .45), 9, 303 + k, 150)
    stroke(im, to_px([(.02, .525), (.98, .525)], w, h), mix(DEEP_BLUE, INK, .4), 15, 320)
    for k, x in enumerate((.12, .66)):
        window_arch(im, (x * w, .2 * h, (x + .2) * w, .52 * h), 330 + k * 10)
        # しま模様の日よけ
        for s in range(5):
            sx = (x - .01 + s * .044) * w
            fill(im, TERRACOTTA if s % 2 == 0 else CREAM, 350 + k * 10 + s,
                 polygon=[(sx, .17 * h), (sx + .044 * w, .17 * h), (sx + .05 * w, .23 * h), (sx + .006 * w, .23 * h)])
    door(im, (.41 * w, .5 * h, .57 * w, .995 * h), TERRACOTTA, 370)
    window_round(im, .5 * w, .27 * h, 34, 380, glass=SKY)
    rr = random.Random(390)
    for k in range(50):
        dab(im, rr.uniform(.05, .95) * w, rr.uniform(.55, .99) * h, rr.uniform(3, 6), mix(SUN, '#ffffff', .5), 400 + k, 70)
    outline_stroke(im, to_px(outline, w, h), mix(SUN, INK, .45), 4, 395)
    prop('house_butter', 'house', outline, 2.35, 1.75, .21, '#E9CB82', '#FAEBC4', save(im, 'house_butter'))


def house_tower():
    """白い塔。とがった紺の屋根に星の点、細いアーチ窓"""
    w, h = 512, 1024
    outline = round_poly([(.12, 0), (.88, 0), (.88, .72), (1, .72), (.5, 1), (0, .72), (.12, .72)], .08)
    im = paper(w, h, CREAM, 501)
    fill(im, DEEP_BLUE, 502, polygon=to_px([(-.04, .7), (1.04, .7), (.5, 1.03)], w, h))
    rr = random.Random(503)
    for k in range(18):
        y = rr.uniform(.74, .95)
        half = (1 - (y - .7) / .3) * .45
        dab(im, (.5 + rr.uniform(-half, half)) * w, (1 - y) * h, rr.uniform(4, 7), SUN, 504 + k, 230)
    stroke(im, to_px([(0, .71), (1, .71)], w, h), mix(DEEP_BLUE, INK, .4), 14, 530)
    for k in range(7):
        y = .05 + k * .095
        stroke(im, to_px([(.13, y), (.87, y + .01)], w, h), mix(CREAM, BLUE, .25), 6, 540 + k, 110)
    window_arch(im, (.36 * w, .3 * h, .64 * w, .48 * h), 560, glass=SKY)
    window_arch(im, (.4 * w, .56 * h, .6 * w, .68 * h), 570, glass=SUN)
    door(im, (.34 * w, .82 * h, .66 * w, .995 * h), BLUE, 580)
    outline_stroke(im, to_px(outline, w, h), mix(CREAM, INK, .45), 4, 590)
    prop('house_tower', 'house', outline, .95, 2.9, .18, '#E4DCCB', '#FBF7EE', save(im, 'house_tower'))


def leafy_crown(im, outline_px, colors, seed, count, size):
    rr = random.Random(seed)
    xs = [p[0] for p in outline_px]
    ys = [p[1] for p in outline_px]
    mask = Image.new('L', im.size, 0)
    ImageDraw.Draw(mask).polygon(outline_px, fill=255)
    m = np.asarray(mask)
    placed = 0
    tries = 0
    while placed < count and tries < count * 8:
        tries += 1
        x, y = rr.uniform(min(xs), max(xs)), rr.uniform(min(ys), max(ys))
        if m[int(min(im.height - 1, y)), int(min(im.width - 1, x))] == 0:
            continue
        dab(im, x, y, rr.uniform(size * .6, size), rr.choice(colors), seed + placed, rr.randint(150, 235),
            squash=rr.uniform(.5, 1), angle=rr.uniform(-.9, .9))
        placed += 1


def tree_round():
    """まるい葉の木。いろいろな緑の葉を重ねる"""
    w, h = 640, 896
    outline = tree_outline(.5, .62, .46, .35, 5, .05, .4, .065, .3)
    im = paper(w, h, mix(SAGE, GREEN, .45), 601)
    fill(im, BARK, 602, polygon=to_px([(.43, 0), (.57, 0), (.55, .45), (.45, .45)], w, h))
    fill(im, mix(SAGE, GREEN, .45), 6020, polygon=to_px(polar_blob(.5, .62, .46, .35, 5, .05, .4, 0, math.tau), w, h))
    leafy_crown(im, to_px(polar_blob(.5, .62, .44, .33, 5, .05, .4, 0, math.tau), w, h),
                [SAGE, mix(SAGE, GREEN, .5), GREEN, mix(GREEN, INK, .2), '#D8E6B8'], 603, 260, 22)
    outline_stroke(im, to_px(outline, w, h), mix(GREEN, INK, .4), 4, 690)
    prop('tree_round', 'tree', outline, 1.55, 2.2, .14, '#7FA68B', '#B9D3AE', save(im, 'tree_round'))


def tree_blossom():
    """もこもこの葉に、桃色の花が咲く木"""
    w, h = 640, 896
    outline = tree_outline(.5, .63, .47, .34, 3, .12, .9, .06, .3)
    im = paper(w, h, '#CFE3BE', 701)
    fill(im, BARK, 702, polygon=to_px([(.44, 0), (.56, 0), (.54, .45), (.46, .45)], w, h))
    fill(im, '#CFE3BE', 7020, polygon=to_px(polar_blob(.5, .63, .47, .34, 3, .12, .9, 0, math.tau), w, h))
    leafy_crown(im, to_px(polar_blob(.5, .63, .45, .32, 3, .12, .9, 0, math.tau), w, h),
                ['#CFE3BE', SAGE, mix(SAGE, GREEN, .3)], 703, 150, 20)
    leafy_crown(im, to_px(polar_blob(.5, .63, .42, .3, 3, .12, .9, 0, math.tau), w, h),
                [PEACH, '#F59FB0', '#FBE3DA', '#ffffff'], 704, 120, 10)
    outline_stroke(im, to_px(outline, w, h), mix(GREEN, INK, .4), 4, 790)
    prop('tree_blossom', 'tree', outline, 1.6, 2.15, .14, '#A9C79C', '#E2EDD6', save(im, 'tree_blossom'))


def tree_cone():
    """三段の三角の木。段ごとにぎざぎざの筆あと"""
    w, h = 512, 1024
    tiers = [(.12, .62), (.22, .47), (.3, .33)]
    outline = [(.44, 0), (.56, 0), (.56, .12), (.96, .12), (.68, .42), (.86, .42), (.6, .7), (.76, .7), (.5, 1),
               (.24, .7), (.4, .7), (.14, .42), (.32, .42), (.04, .12), (.44, .12)]
    outline = round_poly(outline, .07)
    im = paper(w, h, GREEN, 801)
    fill(im, BARK, 802, polygon=to_px([(.44, 0), (.56, 0), (.56, .2), (.44, .2)], w, h))
    rr = random.Random(803)
    for t, (y0, height) in enumerate([(.12, .3), (.42, .28), (.7, .3)]):
        for k in range(12):
            y = y0 + k * height / 12
            half = (1 - (y - y0) / height) * (.46 - t * .1)
            stroke(im, to_px([(.5 - half, y), (.5, y + .03), (.5 + half, y)], w, h),
                   rr.choice([mix(GREEN, SAGE, .5), mix(GREEN, '#ffffff', .2), mix(GREEN, INK, .25)]), 7, 810 + t * 20 + k, 150)
    del tiers
    outline_stroke(im, to_px(outline, w, h), mix(GREEN, INK, .45), 4, 890)
    prop('tree_cone', 'tree', outline, 1.2, 2.6, .14, '#4F7B62', '#8FB59C', save(im, 'tree_cone'))


def tree_poplar():
    """背の高いたまご形の木。縦の筆あと"""
    w, h = 448, 1024
    outline = tree_outline(.5, .6, .4, .4, 2, .04, 1.2, .07, .22)
    im = paper(w, h, '#C9D98F', 901)
    fill(im, BARK, 902, polygon=to_px([(.43, 0), (.57, 0), (.55, .3), (.45, .3)], w, h))
    fill(im, '#C9D98F', 9020, polygon=to_px(polar_blob(.5, .6, .4, .4, 2, .04, 1.2, 0, math.tau), w, h))
    rr = random.Random(903)
    for k in range(90):
        a = rr.uniform(0, math.tau)
        r = math.sqrt(rr.uniform(0, 1)) * .85
        x, y = .5 + math.cos(a) * .38 * r, .6 + math.sin(a) * .37 * r
        stroke(im, to_px([(x, y - .03), (x + rr.uniform(-.01, .01), y + .035)], w, h),
               rr.choice(['#B3C978', '#DCE6A8', mix(GREEN, '#C9D98F', .5)]), 9, 904 + k, 160)
    outline_stroke(im, to_px(outline, w, h), mix(GREEN, INK, .4), 4, 990)
    prop('tree_poplar', 'tree', outline, .95, 2.4, .13, '#AFC277', '#E3EBBE', save(im, 'tree_poplar'))


def shrub():
    """ころんとした低木に、小さな花"""
    w, h = 768, 448
    top = polar_blob(.5, .02, .48, .9, 4, .08, 0, 0, math.pi)
    outline = [(.04, 0), (.96, 0)] + top[1:-1]
    im = paper(w, h, mix(SAGE, GREEN, .35), 1001)
    leafy_crown(im, to_px(outline, w, h), [SAGE, mix(SAGE, GREEN, .5), GREEN], 1002, 140, 18)
    rr = random.Random(1003)
    for k in range(16):
        dab(im, rr.uniform(.15, .85) * w, rr.uniform(.2, .8) * h, 7, rr.choice(['#ffffff', SUN, '#F59FB0']), 1004 + k, 230)
    outline_stroke(im, to_px(outline, w, h), mix(GREEN, INK, .4), 4, 1090)
    prop('shrub', 'shrub', outline, 1.3, .75, .13, '#7FA68B', '#B9D3AE', save(im, 'shrub'))


def hill(name, base, bands, seed, wid, hei):
    """なだらかな丘。畑のような色の帯を重ねる"""
    w, h = 1024, 640
    top = bezier((0, .28), (.22, 1.05), (.6, .98), (1, .38), 60)
    outline = [(0, 0), (1, 0)] + list(reversed(top))
    im = paper(w, h, base, seed)
    rr = random.Random(seed + 1)
    for k, color in enumerate(bands):
        y = .12 + k * .16
        curve = bezier((-.05, y), (.3, y + .18 + rr.uniform(-.05, .05)), (.7, y + .1), (1.05, y + .05), 50)
        lower = [(x, yy - .14) for x, yy in reversed(curve)]
        fill(im, color, seed + 10 + k, polygon=to_px(curve + lower, w, h), amount=.9)
        for s in range(14):
            x = rr.uniform(0, 1)
            stroke(im, to_px([(x, y + .02), (x + .04, y + .1)], w, h), mix(color, INK, .15), 4, seed + 40 + k * 20 + s, 90)
    for k in range(10):
        x, y = rr.uniform(.15, .85), rr.uniform(.2, .6)
        dab(im, x * w, (1 - y) * h, 12, mix(GREEN, INK, .15), seed + 100 + k, 200, squash=.8, angle=math.pi / 2)
    outline_stroke(im, to_px(outline, w, h), mix(base, INK, .4), 4, seed + 200)
    prop(name, 'hill', outline, wid, hei, .15, mix(base, INK, .15), mix(base, '#ffffff', .35), save(im, name))


def ground():
    """地面。つなぎ目の無い、クリーム色の紙に薄い緑の筆あと (くり返して貼る)"""
    size = 1024
    rr = random.Random(1201)
    rng = np.random.default_rng(1202)
    x = np.arange(size, dtype=np.float32)[None, :] * (math.tau / size)
    y = np.arange(size, dtype=np.float32)[:, None] * (math.tau / size)
    field = np.zeros((size, size), dtype=np.float32)
    for _ in range(24):
        kx, ky = rr.randint(-8, 8), rr.randint(-8, 8)
        if not kx and not ky:
            kx = 1
        field += np.sin(kx * x + ky * y + rr.uniform(0, math.tau)) / (1 + math.hypot(kx, ky) * .5)
    field /= max(.001, float(np.std(field)))
    base = np.asarray(rgb('#F3EFD8'), dtype=np.float32)
    sage = np.asarray(rgb('#D9E6C4'), dtype=np.float32)
    t = np.clip(.5 + field * .22, 0, 1)[:, :, None]
    arr = base * (1 - t) + sage * t + rng.normal(0, 1.1, (size, size, 1))
    big = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), 'RGB')
    # つなぎ目が出ないよう 3x3 に並べて描き、真ん中を切り出す
    tile = Image.new('RGB', (size * 3, size * 3))
    for i in range(3):
        for j in range(3):
            tile.paste(big, (i * size, j * size))
    marks = Image.new('RGB', (size, size))
    strokes = []
    for k in range(70):
        sx, sy = rr.uniform(0, size), rr.uniform(0, size)
        length = rr.uniform(40, 120)
        a = rr.uniform(-.5, .5) + (math.pi / 2 if k % 3 == 0 else 0)
        color = rr.choice(['#E6EBCB', '#D3E2BD', '#F7F2DE', '#E9E2C3'])
        strokes.append((sx, sy, length, a, color, rr.uniform(8, 22), 1210 + k))
    for k in range(260):
        sx, sy = rr.uniform(0, size), rr.uniform(0, size)
        strokes.append((sx, sy, rr.uniform(6, 12), -math.pi / 2 + rr.uniform(-.4, .4), rr.choice(['#B9CFA3', '#A9C493', '#C9D8B0']), 2.4, 1400 + k))
    for sx, sy, length, a, color, width, seed in strokes:
        for ox in (-size, 0, size):
            for oy in (-size, 0, size):
                x0, y0 = sx + size + ox, sy + size + oy
                if not (size - 200 < x0 < 2 * size + 200 and size - 200 < y0 < 2 * size + 200):
                    continue
                pts = [(x0, y0), (x0 + math.cos(a) * length / 2, y0 + math.sin(a) * length / 2), (x0 + math.cos(a) * length, y0 + math.sin(a) * length)]
                stroke(tile, pts, color, width, seed, 120)
    marks = tile.crop((size, size, 2 * size, 2 * size))
    save(marks, 'ground', 86)


def sky():
    """空。上は水色、地平に向かってクリーム色へ。斜めの刷毛と、やわらかな雲"""
    w, h = 1536, 1024
    rng = np.random.default_rng(1301)
    t = np.linspace(0, 1, h, dtype=np.float32)[:, None, None] ** 1.3
    top = np.asarray(rgb('#A9D4EE'), dtype=np.float32)
    bottom = np.asarray(rgb('#EAF4F4'), dtype=np.float32)
    pigment = noise(w, h, rng, 200) * 10 + noise(w, h, rng, 40) * 4 + rng.normal(0, .5, (h, w)).astype(np.float32)
    im = Image.fromarray(np.clip(top * (1 - t) + bottom * t + pigment[:, :, None], 0, 255).astype(np.uint8), 'RGB')
    rr = random.Random(1302)
    for k in range(70):
        x, y = rr.uniform(-.1, 1) * w, rr.uniform(0, 1) * h
        length = rr.uniform(.1, .3) * w
        a = rr.uniform(-.3, .15)
        pts = bezier((x, y), (x + math.cos(a) * length * .3, y + math.sin(a) * length * .3 - 20),
                     (x + math.cos(a) * length * .7, y + math.sin(a) * length * .7 + 20), (x + math.cos(a) * length, y + math.sin(a) * length), 40)
        yy = min(1, max(0, y / h)) ** 1.3
        base = top * (1 - yy) + bottom * yy
        delta = np.array([rr.uniform(10, 28), rr.uniform(6, 16), rr.uniform(-2, 6)]) * (1 if k % 3 else -.6)
        color = '#%02x%02x%02x' % tuple(int(v) for v in np.clip(base + delta, 0, 255))
        stroke(im, pts, color, rr.uniform(20, 60), 1310 + k, rr.randint(40, 80), blur=1.4)
    for c in range(5):
        cx, cy = (.1 + c * .2 + rr.uniform(-.05, .05)) * w, rr.uniform(.15, .45) * h
        for k in range(9):
            dab(im, cx + rr.uniform(-110, 110), cy + rr.uniform(-30, 25), rr.uniform(30, 55), '#FFFDF8', 1400 + c * 20 + k, rr.randint(150, 210), squash=.55)
    save(im, 'sky', 88)


def paint_normal():
    """板の表面の、紙と絵の具のこまかな凹凸 (法線マップ)"""
    size = 512
    rng = np.random.default_rng(1501)
    height = .5 + noise(size, size, rng, 60) * .05 + noise(size, size, rng, 4) * .12 + rng.normal(0, .01, (size, size))
    height = np.asarray(Image.fromarray((np.clip(height, 0, 1) * 255).astype(np.uint8), 'L').filter(ImageFilter.GaussianBlur(.4)), dtype=np.float32) / 255
    dx = (np.roll(height, -1, 1) - np.roll(height, 1, 1)) * 2.6
    dy = (np.roll(height, -1, 0) - np.roll(height, 1, 0)) * 2.6
    n = np.stack([-dx, dy, np.ones_like(dx)], 2)
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    save(Image.fromarray(np.clip((n * .5 + .5) * 255, 0, 255).astype(np.uint8), 'RGB'), 'paint_normal', 92)


def main():
    house_peach()
    house_sage()
    house_butter()
    house_tower()
    tree_round()
    tree_blossom()
    tree_cone()
    tree_poplar()
    shrub()
    hill('hill_patch', '#CFE0B4', [SAGE, SUN, '#B8D19E', mix(SUN, SAGE, .5)], 1101, 5.2, 2.6)
    hill('hill_far', '#B7CFE0', [mix(SKY, BLUE, .3), '#C8DCE8', mix(BLUE, SAGE, .4)], 1151, 6.0, 2.4)
    ground()
    sky()
    paint_normal()
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = {
        'version': 1,
        'ground': 'textures/ground.jpg',
        'sky': 'textures/sky.jpg',
        'paint_normal': 'textures/paint_normal.jpg',
        'props': PROPS,
    }
    (OUT / 'stage.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    total = sum(p.stat().st_size for p in TEX.glob('*.jpg'))
    print(f'stage.json  props={len(PROPS)}  textures total {total // 1024} KB')


if __name__ == '__main__':
    main()
