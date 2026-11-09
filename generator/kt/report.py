"""Timing, automatic quality checks, comparison sheets and report.json."""
from __future__ import annotations
import json
import shutil
import time
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw

IOU_WARN = 0.80
EDGE_WARN = 0.60


class Timer:
    def __init__(self):
        self.t0 = time.perf_counter(); self.last = self.t0; self.stages = {}

    def mark(self, name):
        now = time.perf_counter()
        self.stages[name] = round(now - self.last, 2); self.last = now
        print(f'  [{self.stages[name]:6.2f}s] {name}', flush=True)

    def total(self):
        return round(time.perf_counter() - self.t0, 2)


def _font(size=18):
    from .fonts import ui_font
    return ui_font(size)


def compare_sheet(ws, glb: Path, out: Path, cell=384):
    """Each photo (object outline in green) above a render of the model from the same yaw/pitch."""
    from katachi.render import render_glb
    views = {k: p for k, p in ws.photos.items() if p.mask is not None}
    tmp = out.parent / '_compare_views'
    # a level photo (template faces at pitch 0) is shown from slightly above; other directions as they are
    render_glb(glb, tmp, size=cell, views=tuple(views),
               camera_specs={k: {'angles': (p.yaw, max(p.pitch, 4.0) if abs(p.pitch) < 10 else p.pitch)} for k, p in views.items()})
    cols = []
    for key, p in views.items():
        photo = Image.open(p.source).convert('RGB')
        arr = np.asarray(photo).copy()
        contours, _ = cv2.findContours(p.mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(arr, contours, -1, (0, 220, 0), max(2, photo.width // 250))
        photo = Image.fromarray(arr); photo.thumbnail((cell, int(cell * 4 / 3)))
        render = Image.open(tmp / f'{key}.png').convert('RGB').resize((cell, cell))
        col = Image.new('RGB', (cell, int(cell * 4 / 3) + cell + 26), 'white')
        col.paste(photo, ((cell - photo.width) // 2, 0)); col.paste(render, (0, int(cell * 4 / 3)))
        ImageDraw.Draw(col).text((4, col.height - 24), key, fill='black', font=_font())
        cols.append(col)
    sheet = Image.new('RGB', (len(cols) * (cell + 8), cols[0].height), 'white')
    for i, c in enumerate(cols):
        sheet.paste(c, (i * (cell + 8), 0))
    sheet.save(out, quality=88)
    shutil.rmtree(tmp, ignore_errors=True)
    return out


def hero_render(glb: Path, out: Path, angles=(30, 16), size=768):
    from katachi.render import render_glb
    tmp = out.parent / '_hero'
    render_glb(glb, tmp, size=size, views=('hero',), camera_specs={'hero': {'angles': angles}})
    (tmp / 'hero.png').replace(out)
    shutil.rmtree(tmp, ignore_errors=True)


RESIDUE_WARN = 0.003      # skin blobs touching a texture's border, share of the texture (orange spine text ~0.001)


def border_skin_blobs(bgr, min_share=0.001) -> float:
    """Share of skin-coloured blobs that touch the texture border: a finger left on the face enters from
    its edge. Lettering/illustrations inside the face do not count."""
    from .segment import skin_like
    sk = cv2.morphologyEx(skin_like(bgr).astype(np.uint8), cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    h, w = sk.shape; b = max(2, int(0.02 * min(h, w)))
    border = np.zeros((h, w), bool); border[:b] = border[-b:] = True; border[:, :b] = border[:, -b:] = True
    n, lab, st, _ = cv2.connectedComponentsWithStats(sk)
    tot = sum(st[i, cv2.CC_STAT_AREA] for i in range(1, n)
              if st[i, cv2.CC_STAT_AREA] >= min_share * h * w and ((lab == i) & border).any())
    return float(tot / (h * w))


def finger_residue(out: Path) -> dict:
    """border_skin_blobs per photo texture used by the recipe (material id -> share)."""
    f = Path(out) / 'scene.json'
    if not f.exists():
        return {}
    scene = json.loads(f.read_text(encoding='utf-8'))
    res = {}
    for m in scene.get('materials', []):
        tid = m.get('image_id')
        hits = list((Path(out) / 'inputs').glob(f'*/texture_regions/{tid}/texture.png')) if tid else []
        if hits:
            a = cv2.cvtColor(np.asarray(Image.open(hits[0]).convert('RGB')), cv2.COLOR_RGB2BGR)
            res[m['id']] = round(border_skin_blobs(a), 4)
    return res


def quality_checks(ws, build: dict, plan, residue: dict | None = None) -> dict:
    """Automatic gates. IoU is 2D silhouette consistency between the photo mask and the model,
    NOT 3D reconstruction accuracy."""
    warnings = list(plan.warnings)
    v = build['validation']
    errors = v.get('errors') or []
    by_id = {p.image_id: k for k, p in ws.photos.items()}
    views = {}
    for item in build['metrics'].get('views', []):
        key = by_id.get(item.get('image_id'), item.get('image_id'))
        views[key] = round(float(item.get('iou', 0)), 3)
    info_only = set(plan.extra.get('iou_informational', []))
    judged = {k: x for k, x in views.items() if k not in info_only}
    worst = min(judged.values()) if judged else None
    if worst is not None and worst < IOU_WARN:
        warnings.append(f'silhouette IoU {worst} < {IOU_WARN} in view(s) {[k for k, x in judged.items() if x == worst]}: check compare.jpg')
    for k, p in ws.photos.items():
        if p.mask_info.get('touches_border'):
            warnings.append(f'{k}: object touches the photo border {p.mask_info["touches_border"]} (may be cut off)')
        if p.mask_info.get('skin_removed_fraction', 0) > 0.01:
            warnings.append(f'{k}: hand/finger pixels removed ({p.mask_info["skin_removed_fraction"]:.1%} of the mask); check compare.jpg')
    for mat, share in (residue or {}).items():
        if share > RESIDUE_WARN:
            warnings.append(f'{mat}: skin-coloured patch at the edge of the texture ({share:.1%}) - a finger may be left on '
                            'the face; check compare.jpg, or add a second photo with the fingers elsewhere')
    return {'glb_errors': errors, 'glb_warnings': v.get('warnings') or [], 'triangles': v.get('triangles'),
            'finger_residue_by_texture': residue or {},
            'silhouette_iou_by_view': views, 'silhouette_iou_worst': worst,
            'silhouette_iou_informational_views': sorted(info_only),
            'silhouette_note': '2D silhouette consistency (photo mask vs model), NOT 3D accuracy',
            'masks_auto_confirmed': True, 'warnings': warnings,
            'status': 'error' if errors else ('warning' if warnings else 'ok')}


def finish(ws, plan, build, timer, out: Path, template: str, args_dict: dict) -> dict:
    out = Path(out)
    shutil.copy2(build['glb'], out / 'model.glb')
    compare_sheet(ws, build['glb'], out / 'compare.jpg')
    hero_render(build['glb'], out / 'render_hero.png', angles=plan.extra.get('hero_angles', (30, 16)))
    timer.mark('compare sheet + hero render')
    qa = quality_checks(ws, build, plan, finger_residue(out))
    dims = build['validation'].get('bounds')
    report = {
        'template': template, 'title': plan.title, 'inputs': {k: str(p.path) for k, p in ws.photos.items()},
        'arguments': args_dict, 'size_m': (np.array(dims[1]) - np.array(dims[0])).round(4).tolist() if dims else None,
        'quality': qa, 'notes': plan.notes, 'timings_s': timer.stages, 'total_s': timer.total(),
        'run_folder': str(build['root']), 'live_api_calls': 1 if plan.extra.get('ai') else 0, 'ai_call': plan.extra.get('ai'),
        'outputs': {'model': str(out / 'model.glb'), 'compare': str(out / 'compare.jpg'), 'hero': str(out / 'render_hero.png'),
                    'scene': str(out / 'scene.json')},
    }
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2, default=str), encoding='utf-8')
    print(f"\n== {template}: {qa['status'].upper()}  total {report['total_s']} s  size(m) {report['size_m']}")
    print(f"   silhouette IoU (2D, not 3D accuracy): {qa['silhouette_iou_by_view']}")
    for w in qa['warnings']:
        print(f'   WARN {w}')
    if qa['glb_errors']:
        print(f"   ERROR GLB: {qa['glb_errors']}")
    print(f'   -> {out}')
    return report
