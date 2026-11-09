"""--ui: also register the work in the running Katachi web app (slower: the server segments every upload).

The web app receives the corrected workspace copy of each photo (hands removed, lighting flattened,
deskewed), so its texture regions match the local build; the original photos stay untouched."""
from __future__ import annotations
import base64
import io
import time

import cv2
import httpx
import numpy as np
from PIL import Image


def _client(base, transport=None):
    c = httpx.Client(base_url=base, timeout=180, transport=transport)
    try:
        c.headers['x-katachi-session'] = c.get('/api/config').raise_for_status().json()['session_token']
    except httpx.HTTPError as exc:
        raise SystemExit(f'Katachi server not reachable at {base}: start it first ({exc})')
    return c


def publish(ws, plan, server='http://127.0.0.1:8765', transport=None) -> dict:
    c = _client(server, transport)
    pid = c.post('/api/projects', json={'title': plan.title}).raise_for_status().json()['id']
    ids = {}
    for key, p in ws.photos.items():
        # upload the corrected workspace photo, not the original: the corrections happen before regions are cut
        with open(p.source, 'rb') as fh:
            rec = c.post(f'/api/projects/{pid}/images', files={'file': (p.path.stem + '.png', fh, 'image/png')}).raise_for_status().json()
        ids[key] = rec['id']
        mask = p.mask if p.mask is not None else np.ones((p.size[1], p.size[0]), bool)
        if mask.shape != (rec['height'], rec['width']):
            mask = cv2.resize(mask.astype(np.uint8), (rec['width'], rec['height']), interpolation=cv2.INTER_NEAREST).astype(bool)
        buf = io.BytesIO(); Image.fromarray(mask.astype(np.uint8) * 255).save(buf, 'PNG')
        c.put(f'/api/projects/{pid}/images/{rec["id"]}/mask', json={
            'png_base64': base64.b64encode(buf.getvalue()).decode(), 'reviewed': True,
            'camera': {'yaw_deg': p.yaw, 'pitch_deg': p.pitch}}).raise_for_status()
    textures = {}
    for spec in plan.regions:
        body = {'label': spec.label, 'quad': spec.quad, 'output_size': list(spec.output_size), 'reviewed': True}
        rec = c.post(f'/api/projects/{pid}/images/{ids[spec.photo]}/texture-regions', json=body).raise_for_status().json()
        textures[spec.name] = {'id': rec['id'], 'path': ws.photos[spec.photo].regions[spec.name]['path']}
    scene = plan.scene_fn(textures)
    r = c.post('/api/jobs', json={'project_id': pid, 'scene': scene, 'height_m': scene['height_m'],
                                  'config': {'mode': 'recipe', 'local_fit': False, 'texture_size': plan.texture_size}})
    if r.status_code != 200:
        raise SystemExit(f'web UI job rejected: {r.status_code} {r.text[:800]}')
    jid = r.json()['id']
    status = 'queued'
    for _ in range(600):
        status = c.get(f'/api/jobs/{jid}').json().get('status')
        if status not in ('queued', 'running', 'pending'):
            break
        time.sleep(1)
    return {'project_id': pid, 'job_id': jid, 'status': status, 'url': server}
