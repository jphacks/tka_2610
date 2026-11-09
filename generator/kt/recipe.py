"""kt recipe: build a hand-written (AI-written) Katachi recipe with the same checks and outputs as the templates.

  kt recipe --scene scene.json --photo front=IMG_1.jpg@0 --photo back=IMG_2.jpg@180 [--mask quad|rembg|none]
            [--regions regions.json] --out DIR

- Each --photo is registered at its camera direction (yaw[,pitch] in degrees). With --mask quad (default) the
  outline used for the silhouette check is the detected rectangle of the face; rembg uses the object cut-out
  (unreliable on dark objects); none registers the photo without a silhouette check.
- regions.json (optional): photo textures cut out of the photos, e.g.
    [{"name": "logo", "photo": "front", "corners": "face" | [[x,y] x4 normalised], "output_size": [512, 512]}]
  In scene.json, a material's "image_id": "region:logo" is replaced by the registered texture's id.
"""
from __future__ import annotations
import json
from pathlib import Path

import numpy as np

from .engine import Workspace, BuildPlan, RegionSpec
from .report import Timer, finish
from . import quad_detect as qd
from .inspect import _upright_copy


def parse_photo(spec: str):
    key, rest = spec.split('=', 1)
    if '@' in rest:
        path, ang = rest.rsplit('@', 1)
        parts = [float(v) for v in ang.split(',')]
        yaw, pitch = parts[0], (parts[1] if len(parts) > 1 else 0.0)
    else:
        path, yaw, pitch = rest, 0.0, 0.0
    return key, (path, yaw, pitch)


def build(scene_path, photos: dict, out, mask='quad', regions_path=None, render_size=768, title=None) -> dict:
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    timer = Timer()
    ws = Workspace(out)
    scene = json.loads(Path(scene_path).read_text(encoding='utf-8'))
    quads = {}
    for key, (path, yaw, pitch) in photos.items():
        ws.add_photo(key, Path(path), yaw, pitch)
        if mask == 'none':
            continue
        if mask == 'quad':
            try:
                r = qd.detect_face(_upright_copy(path, out))
                quads[key] = np.clip(np.array(r.corners), 0, 1)
                ws.set_mask(key, ws.polygon_mask(key, quads[key]), {'segmentation': 'detected quad'})
            except ValueError:
                pass                                   # no rectangle: the photo is kept without a silhouette check
        else:
            from .segment import object_mask
            m, info = object_mask(ws.photos[key].source)
            ws.set_mask(key, m, info)
    timer.mark('photos + masks')
    regions = []
    if regions_path:
        for r in json.loads(Path(regions_path).read_text(encoding='utf-8')):
            corners = r['corners']
            if corners == 'face':
                if r['photo'] not in quads:
                    quads[r['photo']] = np.clip(np.array(qd.detect_face(_upright_copy(photos[r['photo']][0], out)).corners), 0, 1)
                corners = quads[r['photo']].tolist()
            regions.append(RegionSpec(r['photo'], r['name'], r.get('label', r['name']), corners, tuple(r.get('output_size', (1024, 1024)))))

    def scene_fn(tex):
        s = json.loads(json.dumps(scene))
        for m in s.get('materials', []):
            iid = m.get('image_id')
            if isinstance(iid, str) and iid.startswith('region:'):
                m['image_id'] = tex[iid.split(':', 1)[1]]['id']
        return s

    plan = BuildPlan(title=title or scene.get('title', 'Recipe'), height_m=float(scene['height_m']), scene_fn=scene_fn,
                     regions=regions, texture_size=2048 if regions else 1024,
                     notes=[f"{len(scene.get('parts', []))} parts (hand-written recipe)"], extra={'hero_angles': (30, 16)})
    build_res = ws.execute(plan, render_size, timer)
    return finish(ws, plan, build_res, timer, out, 'recipe', {'scene': str(scene_path), 'photos': {k: list(v) for k, v in photos.items()}, 'mask': mask})
