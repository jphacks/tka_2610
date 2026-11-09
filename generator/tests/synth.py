"""Synthetic 'photos' with known ground truth, rendered by Katachi itself (VTK) or drawn with PIL."""
from __future__ import annotations
import json
from pathlib import Path
import cv2
import numpy as np
from PIL import Image, ImageDraw

from katachi.schema import SceneSpec
from katachi.geometry import compile_scene
from katachi.glb import export_glb
from katachi.render import render_glb

VASE = [[0, 0], [3.0, 0], [3.4, 1.0], [4.2, 4.0], [4.4, 7.0], [3.6, 10.0], [2.2, 12.5], [1.9, 14.0], [2.4, 15.0], [0, 15.0]]


def render_photo(scene: dict, out_png: Path, yaw=0, pitch=4, size=900, bg=(232, 228, 220)):
    """Render a scene from (yaw, pitch) onto a plain background: a stand-in for a phone photo."""
    out_png = Path(out_png); out_png.parent.mkdir(parents=True, exist_ok=True)
    compiled = compile_scene(SceneSpec.model_validate(scene), 'high')
    glb = out_png.with_suffix('.glb')
    export_glb(compiled, glb)
    tmp = out_png.parent / ('_r_' + out_png.stem)
    render_glb(glb, tmp, size=size, views=('v',), camera_specs={'v': {'angles': (yaw, pitch)}}, transparent=True)
    rgba = Image.open(tmp / 'v.png').convert('RGBA')
    canvas = Image.new('RGBA', (size, int(size * 4 / 3)), (*bg, 255))
    canvas.alpha_composite(rgba, (0, (canvas.height - size) // 2))
    canvas.convert('RGB').save(out_png, quality=95)
    return out_png


def vase_scene(color=(0.25, 0.45, 0.75)):
    return {'schema_version': '1.0', 'title': 'synthetic vase', 'height_m': 0.15, 'seed': 1, 'controls': [], 'assumptions': [],
            'materials': [{'id': 'm', 'color': [*color, 1], 'roughness': 0.5}],
            'parts': [{'id': 'vase', 'geometry': {'kind': 'lathe', 'profile': VASE}, 'material': 'm'}]}


def drawing_photo(out_png: Path, cutout=True, size=(1200, 1600), shadow=False):
    """A child's drawing (heart cut-out or rectangular sheet) lying on a wooden table, mild perspective."""
    W, H = 800, 600
    art = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(art)
    if cutout:
        pts = [(400 + 300 * (16 * np.sin(t) ** 3) / 16, 300 - 270 * (13 * np.cos(t) - 5 * np.cos(2 * t) - 2 * np.cos(3 * t) - np.cos(4 * t)) / 17)
               for t in np.linspace(0, 2 * np.pi, 200)]
        d.polygon(pts, fill=(245, 240, 228, 255))
    else:
        d.rectangle([0, 0, W - 1, H - 1], fill=(245, 240, 228, 255))
    d.ellipse([300, 180, 500, 380], fill=(240, 120, 40, 255))           # sun
    d.line([(180, 420), (620, 420)], fill=(40, 140, 60, 255), width=18)   # grass
    d.text((330, 450), 'MAYO', fill=(30, 30, 160, 255))
    bg = Image.new('RGB', size, (150, 105, 70))                          # table
    noise = (np.random.default_rng(0).normal(0, 6, (size[1], size[0], 1))).astype(np.int16)
    bg = Image.fromarray(np.clip(np.asarray(bg, np.int16) + noise, 0, 255).astype(np.uint8))
    src = np.float32([[0, 0], [W, 0], [W, H], [0, H]])
    dst = np.float32([[250, 520], [960, 480], [1000, 1010], [210, 1050]])
    M = cv2.getPerspectiveTransform(src, dst)
    warped = cv2.warpPerspective(np.asarray(art), M, size, flags=cv2.INTER_LINEAR, borderValue=(0, 0, 0, 0))
    a = warped[..., 3:4] / 255.0
    out = np.asarray(bg) * (1 - a) + warped[..., :3] * a
    if shadow:                                                           # a soft phone shadow from the left
        out = out * np.linspace(0.55, 1.0, size[0])[None, :, None]
    out = out.clip(0, 255).astype(np.uint8)
    Path(out_png).parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(out).save(out_png, quality=95)
    return out_png, {'art_size_px': (W, H), 'aspect': W / H}


LABEL_ID = 'texture_0123456789ab'


def label_png(path: Path, size=(600, 400)):
    """A colourful printed label: stripes, a disc and lettering (ground truth artwork)."""
    W, H = size
    im = Image.new('RGB', size, (250, 246, 236))
    d = ImageDraw.Draw(im)
    for i, c in enumerate([(220, 40, 40), (40, 90, 200), (240, 180, 30)]):
        d.rectangle([0, 30 + i * 40, W, 50 + i * 40], fill=c)
    d.ellipse([W // 2 - 90, 170, W // 2 + 90, 350], fill=(30, 140, 70))
    d.rectangle([W // 2 - 150, 360, W // 2 + 150, 390], fill=(20, 20, 20))
    im.save(path)
    return path


def labeled_bottle_scene():
    prof = [(0.0, 3.2, 2.0), (0.6, 3.6, 2.3), (3.0, 4.0, 2.6), (8.0, 4.0, 2.6), (11.0, 3.6, 2.4), (13.0, 2.4, 2.0), (14.2, 1.6, 1.6), (14.8, 1.5, 1.5)]
    sections = [{'center': [0.0, y, 0.0], 'width': w * 2, 'depth': d * 2} for y, w, d in prof]
    outline = [[-2.6, 3.0], [2.6, 3.0], [2.6, 9.0], [-2.6, 9.0]]
    return {'schema_version': '1.0', 'title': 'synthetic labeled bottle', 'height_m': 0.17, 'seed': 1, 'controls': [], 'assumptions': [],
            'materials': [{'id': 'plastic', 'color': [0.92, 0.9, 0.86, 1], 'roughness': 0.4},
                          {'id': 'cap', 'color': [0.15, 0.35, 0.75, 1], 'roughness': 0.35},
                          {'id': 'label', 'color': [1, 1, 1, 1], 'roughness': 0.6, 'image_id': LABEL_ID}],
            'parts': [{'id': 'body', 'geometry': {'kind': 'loft', 'sections': sections, 'exponent': 1.0}, 'material': 'plastic'},
                      {'id': 'cap', 'geometry': {'kind': 'cylinder', 'radius': 1.6, 'height': 2.2, 'bevel': 0.1}, 'material': 'cap',
                       'transform': {'translation': [0, 14.8, 0]}},
                      {'id': 'label', 'geometry': {'kind': 'surface_patch', 'target': 'body', 'outline': outline, 'max_distance': 8.0,
                                                   'offset': 0.06, 'thickness': 0, 'resolution': 64, 'max_stretch': 4},
                       'material': 'label', 'transform': {'translation': [0, 0, 4.0]}}]}


def labeled_bottle_photos(out_dir: Path, size=900, bg=(232, 228, 220)):
    """Front/side/back/side2 'photos' of the labeled bottle + the GLB used as ground truth."""
    out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True)
    lab = label_png(out_dir / 'label.png')
    compiled = compile_scene(SceneSpec.model_validate(labeled_bottle_scene()), 'high')
    glb = out_dir / 'truth.glb'
    export_glb(compiled, glb, assets={LABEL_ID: lab}, texture_size=1024)
    views = {'front': 0, 'side': 90, 'back': 180, 'side2': -90}
    render_glb(glb, out_dir / '_r', size=size, views=tuple(views), camera_specs={k: {'angles': (v, 4)} for k, v in views.items()}, transparent=True)
    paths = {}
    for k in views:
        rgba = Image.open(out_dir / '_r' / f'{k}.png').convert('RGBA')
        canvas = Image.new('RGBA', (size, int(size * 4 / 3)), (*bg, 255))
        canvas.alpha_composite(rgba, (0, (canvas.height - size) // 2))
        paths[k] = out_dir / f'{k}.jpg'
        canvas.convert('RGB').save(paths[k], quality=95)
    return paths, glb
