"""In-process Katachi build: the same steps as katachi/job_worker.py, without the HTTP server
(and therefore without the server's per-upload GrabCut). Produces the standard run folder
(final/model.glb, validation.json, mesh_quality.json, metrics.json, preview/ ...)."""
from __future__ import annotations
import hashlib
import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import cv2
import numpy as np

from katachi.images import sanitize_image, normalized_reference_with_frame, save_mask
from katachi.texture_regions import TextureRegionRequest, register_region, asset_catalog_record
from katachi.schema import RunConfig, SceneSpec, Camera
from katachi.view_schema import ImageFrame
from katachi.metrics import Reference
from katachi.runtime import run_pipeline


@dataclass
class Photo:
    key: str
    path: Path
    yaw: float = 0.0
    pitch: float = 0.0
    image_id: str = ''
    folder: Path | None = None
    size: tuple = (0, 0)                 # sanitized (w, h)
    mask: np.ndarray | None = None
    frame: dict | None = None
    mask_info: dict = field(default_factory=dict)
    regions: dict = field(default_factory=dict)

    @property
    def source(self) -> Path:
        return self.folder / 'source.png'


@dataclass
class RegionSpec:
    photo: str
    name: str
    label: str
    quad: list                           # 4 x [x, y] normalised, TL TR BR BL
    output_size: tuple


@dataclass
class BuildPlan:
    title: str
    height_m: float
    scene_fn: Callable[[dict], dict]     # {region name: {'id', 'path'}} -> scene dict
    regions: list = field(default_factory=list)
    texture_size: int = 1024
    notes: list = field(default_factory=list)
    warnings: list = field(default_factory=list)
    extra: dict = field(default_factory=dict)


class Workspace:
    def __init__(self, out: Path):
        self.out = Path(out)
        self.inputs = self.out / 'inputs'
        self.inputs.mkdir(parents=True, exist_ok=True)
        self.photos: dict[str, Photo] = {}

    def add_photo(self, key: str, path: Path, yaw=0.0, pitch=0.0) -> Photo:
        data = Path(path).read_bytes()
        iid = 'image_' + hashlib.sha256(key.encode() + data).hexdigest()[:12]
        folder = self.inputs / iid
        source = folder / 'source.png'
        info = sanitize_image(data, source)        # always fresh: templates may straighten this copy in place
        w, h = info['width'], info['height']
        p = Photo(key, Path(path), float(yaw), float(pitch), iid, folder, (w, h))
        self.photos[key] = p
        return p

    def set_mask(self, key: str, mask: np.ndarray, info: dict | None = None):
        p = self.photos[key]
        if mask.shape != (p.size[1], p.size[0]):
            raise ValueError(f'mask size {mask.shape} differs from image {p.size}')
        mask = mask.astype(bool)
        save_mask(mask, p.folder / 'mask.png')
        im, nmask, _box, frame = normalized_reference_with_frame(p.source, mask)
        im.save(p.folder / 'normalized.png')
        save_mask(nmask, p.folder / 'normalized_mask.png')
        p.mask, p.frame, p.mask_info = mask, frame.model_dump(), info or {}

    def polygon_mask(self, key: str, polygon, grow=8) -> np.ndarray:
        w, h = self.photos[key].size
        m = np.zeros((h, w), np.uint8)
        pts = (np.clip(np.asarray(polygon, float), 0, 1) * [w, h]).round().astype(np.int32)
        cv2.fillPoly(m, [pts], 1)
        if grow:
            m = cv2.dilate(m, np.ones((2 * grow + 1,) * 2, np.uint8))
        return m.astype(bool)

    def register(self, spec: RegionSpec) -> dict:
        p = self.photos[spec.photo]
        req = TextureRegionRequest.model_validate({
            'label': spec.label, 'quad': [[float(x), float(y)] for x, y in spec.quad],
            'output_size': [int(spec.output_size[0]), int(spec.output_size[1])], 'reviewed': True})
        rec = register_region(p.folder, p.image_id, req)
        rec['path'] = str(p.folder / 'texture_regions' / rec['id'] / 'texture.png')
        p.regions[spec.name] = rec
        return rec

    def execute(self, plan: BuildPlan, render_size=768, timer=None) -> dict:
        textures = {}
        for spec in plan.regions:
            rec = self.register(spec)
            textures[spec.name] = {'id': rec['id'], 'path': rec['path']}
        if timer:
            timer.mark('texture regions')
        scene = plan.scene_fn(textures)
        spec = SceneSpec.model_validate(scene)
        (self.out / 'scene.json').write_text(json.dumps(scene, ensure_ascii=False, indent=2), encoding='utf-8')
        records = [r for p in self.photos.values() for r in p.regions.values()]
        assets = {r['id']: Path(r['path']) for r in records}
        catalog = [asset_catalog_record({k: v for k, v in r.items() if k != 'path'}) for r in records]
        refs = []
        for p in self.photos.values():
            if p.mask is None:
                continue
            refs.append(Reference(p.image_id, p.folder / 'normalized.png', p.folder / 'normalized_mask.png', p.yaw, p.pitch,
                                  camera=Camera(yaw_deg=p.yaw, pitch_deg=p.pitch),
                                  frame=ImageFrame.model_validate(p.frame) if p.frame else None))
        # masks_reviewed: the masks were confirmed automatically by this tool (stated in report.json);
        # Katachi evaluates silhouettes only against confirmed masks (runtime.py: eval_refs).
        fit = int(plan.extra.get('local_fit', 0))
        config = RunConfig(mode='recipe', local_fit=fit > 0, local_evaluations=max(0, min(160, fit)),
                           texture_size=plan.texture_size, render_size=render_size, masks_reviewed=bool(refs))
        root = self.out / 'runs' / time.strftime('%Y%m%d-%H%M%S')
        run_pipeline(root, config, spec, refs, [], plan.height_m, assets=assets, asset_catalog=catalog, image_coordinates=[])
        if timer:
            timer.mark('katachi build (run_pipeline)')
        final = root / 'final'
        result = json.loads((root / 'result.json').read_text(encoding='utf-8'))
        metrics = json.loads((final / 'metrics.json').read_text(encoding='utf-8')) if (final / 'metrics.json').exists() else {}
        validation = json.loads((final / 'validation.json').read_text(encoding='utf-8'))
        return {'root': root, 'final': final, 'glb': final / 'model.glb', 'scene': scene, 'result': result,
                'metrics': metrics, 'validation': validation, 'textures': textures}
