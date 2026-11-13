"""Validate a built GLB, render it headlessly and write compare.jpg."""
import json
import shutil
import subprocess
from pathlib import Path

import cv2
import numpy as np

TOOL_DIR = Path(__file__).resolve().parent.parent
RENDER_DIR = TOOL_DIR / 'render'


def _node():
    node = shutil.which('node')
    if not node:
        raise RuntimeError('node is not installed (needed for validation and rendering)')
    if not (TOOL_DIR / 'node_modules' / 'three').exists():
        raise RuntimeError('run "npm install" in %s first' % TOOL_DIR.name)
    return node


def validate(glb_path):
    """Run gltf-validator; returns its JSON summary (dict)."""
    p = subprocess.run([_node(), str(RENDER_DIR / 'validate.mjs'), str(glb_path)],
                       capture_output=True, text=True, cwd=TOOL_DIR)
    try:
        return json.loads(p.stdout)
    except json.JSONDecodeError:
        raise RuntimeError('validator failed: %s' % (p.stderr.strip() or p.stdout.strip()))


def render(glb_path, out_dir, timeout=300):
    """Render front.png and oblique.png into out_dir; returns model info (dict)."""
    p = subprocess.run([_node(), str(RENDER_DIR / 'render.cjs'), str(glb_path), str(out_dir)],
                       capture_output=True, text=True, cwd=TOOL_DIR, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError('render failed: %s' % (p.stderr.strip() or p.stdout.strip()))
    return json.loads(p.stdout.strip().splitlines()[-1])


def photo_crop(photo, corners_px, margin=0.02):
    q = np.asarray(corners_px, float)
    h, w = photo.shape[:2]
    x0, y0 = q.min(0)
    x1, y1 = q.max(0)
    mx, my = margin * (x1 - x0), margin * (y1 - y0)
    x0, y0 = int(max(0, x0 - mx)), int(max(0, y0 - my))
    x1, y1 = int(min(w, x1 + mx)), int(min(h, y1 + my))
    return photo[y0:y1, x0:x1]


def compose(images, labels, height=900):
    tiles = []
    for img, lab in zip(images, labels):
        f = height / img.shape[0]
        t = cv2.resize(img, (max(1, int(round(img.shape[1] * f))), height), interpolation=cv2.INTER_AREA)
        bar = np.full((40, t.shape[1], 3), 255, np.uint8)
        cv2.putText(bar, lab, (10, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (40, 40, 40), 2, cv2.LINE_AA)
        tiles.append(np.vstack([bar, t]))
        tiles.append(np.full((height + 40, 8, 3), 255, np.uint8))
    return np.hstack(tiles[:-1])


def check(out_dir, log=print):
    out = Path(out_dir).resolve()
    glb = out / 'model.glb'
    report = json.loads((out / 'report.json').read_text(encoding='utf-8'))
    v = validate(glb)
    (out / 'validation.json').write_text(json.dumps(v, indent=1), encoding='utf-8')
    log('gltf-validator %s: %d errors, %d warnings, %d infos'
        % (v.get('validatorVersion'), v['errors'], v['warnings'], v['infos']))
    for m in v.get('messages', []):
        if m['severity'] in ('error', 'warning'):
            log('  [%s] %s %s %s' % (m['severity'], m['code'], m.get('pointer', ''), m['message']))
    info = render(glb, out)
    log('rendered front.png, oblique.png (%d meshes, %d triangles)' % (info['meshes'], info['triangles']))
    photo = cv2.imread(report['photo'], cv2.IMREAD_COLOR)
    if photo is None:
        raise RuntimeError('cannot read the photo recorded in report.json')
    crop = photo_crop(photo, report['sheet']['corners_px'])
    imgs = [crop, cv2.imread(str(out / 'front.png')), cv2.imread(str(out / 'oblique.png'))]
    cv2.imwrite(str(out / 'compare.jpg'), compose(imgs, ['photo', 'render: front', 'render: oblique']),
                [cv2.IMWRITE_JPEG_QUALITY, 88])
    log('wrote %s' % (out / 'compare.jpg'))
    return v['errors'] == 0
