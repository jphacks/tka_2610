"""Pipeline: config + photo -> model.glb, report.json, overlay.jpg."""
import json
import time
from pathlib import Path

import cv2
import numpy as np

from . import layers as layers_mod
from . import mesh as meshlib
from . import rectify as rect
from . import segment as seg
from . import texture as tex
from .glbwriter import GLB

GENERATOR = 'flat-art-glb'
ROUGHNESS = 0.93
LAYER_GAP_MM = 0.05

DEFAULTS = {
    'mode': 'layers',
    'min_piece_mm2': 150.0,
    'primary_share': 0.35,
    'color_max_dist': 22.0,
    'piece_texture': 'auto',          # auto | photo | flat
    'flat_tolerance': 12.0,
    'hidden_grow_mm': 8.0,
    'hidden_keep_in_mm': 2.5,
    'texture_factor': 2.0,
}


def load_config(path):
    path = Path(path)
    cfg = json.loads(path.read_text(encoding='utf-8'))
    for k, v in DEFAULTS.items():
        cfg.setdefault(k, v)
    cfg.setdefault('sheet', {})
    cfg['sheet'].setdefault('thickness_mm', 0.27)
    photo = Path(cfg['photo'])
    if not photo.is_absolute():
        photo = (path.parent / photo)
    cfg['_photo_path'] = photo.resolve()
    if cfg['mode'] not in ('layers', 'plane'):
        raise ValueError('mode must be "layers" or "plane"')
    if 'colors' not in cfg or cfg.get('backing') not in cfg['colors']:
        raise ValueError('config needs "colors" and a "backing" colour name that is one of them')
    if cfg['mode'] == 'layers':
        for g in cfg.get('stack', []):
            for c in g:
                if c not in cfg['colors']:
                    raise ValueError('stack colour %r is not in "colors"' % c)
    return cfg


# ---------------------------------------------------------------- steps
def detect_sheet(photo, clf, cfg, warnings):
    """Returns (Rectifier, paper mask in the photo, sheet info dict)."""
    h, w = photo.shape[:2]
    labels, _ = clf.classify(photo)
    backing = labels == clf.index(cfg['backing'])
    paper = rect.sheet_mask(backing)
    info = {}
    if cfg['sheet'].get('corners'):
        quad = np.array(cfg['sheet']['corners'], float).reshape(4, 2) * [w - 1, h - 1]
        info['corners_source'] = 'config'
    else:
        quad, sides = rect.fit_sheet_quad(paper)
        info['corners_source'] = 'detected'
        info['edge_fit'] = sides
        for k, s in sides.items():
            if s.get('fallback'):
                warnings.append('sheet edge "%s": too few boundary samples, used a rough estimate' % k)
    info['orientation'] = rect.sheet_orientation(quad)
    if cfg['sheet'].get('size_mm'):
        size = rect.oriented_size(cfg['sheet']['size_mm'], quad)
        info.update(size_mm=list(size), size_guessed=False)
    else:
        name, s, aspect = rect.guess_sheet_size(quad)
        size = rect.oriented_size(s, quad)
        info.update(size_mm=list(size), size_guessed=True, size_guess=name, measured_aspect=round(aspect, 3))
        warnings.append('sheet size guessed as %s %s mm from the aspect ratio %.3f; set sheet.size_mm'
                        % (name, list(size), aspect))
    info['corners_px'] = [[round(float(x), 1), round(float(y), 1)] for x, y in quad]
    r = rect.Rectifier(quad, size, photo.shape)
    nat = r.native_px_per_mm()
    info['photo_px_per_mm'] = {'median': round(nat[0], 3), 'min': round(nat[1], 3), 'max': round(nat[2], 3)}
    inside = np.zeros((h, w), np.uint8)
    cv2.fillConvexPoly(inside, np.round(quad).astype(np.int32), 1)
    if info['corners_source'] == 'config':
        # Corners given by the config are the sheet: everything inside them is paper. The backing-colour blob would
        # drop parts of the sheet that a stroke or a piece cuts off from the rest (e.g. a line across a rectified
        # picture from edge to edge), and those parts would be inpainted away.
        paper = inside.astype(bool)
    out_of_frame = 1.0 - float(r.warp(np.full((h, w), 255, np.uint8), 1.0)[1].mean())
    info['unseen_fraction'] = round(out_of_frame, 4)
    if out_of_frame > 0.002:
        warnings.append('%.1f%% of the sheet is outside the photo; filled by inpainting' % (100 * out_of_frame))
    return r, paper, info


def piece_window(mask, ppm, pad_mm, w_mm, h_mm):
    ys, xs = np.nonzero(mask)
    x0 = max(0.0, xs.min() / ppm - pad_mm)
    y0 = max(0.0, ys.min() / ppm - pad_mm)
    x1 = min(w_mm, (xs.max() + 1) / ppm + pad_mm)
    y1 = min(h_mm, (ys.max() + 1) / ppm + pad_mm)
    return (x0, y0, x1 - x0, y1 - y0)


def mask_fn(mask, ppm):
    m = mask.astype(np.float32)

    def f(window, out_ppm):
        return rect.resample_field(m, ppm, window, out_ppm, border_value=0) > 0.5
    return f


def overlay_image(rect_img, ppm, pieces, unseen, out_path, label_scale=1.0):
    """Rectified photo at ~2 px/mm with piece outlines, names and layers."""
    f = min(1.0, 2.0 / ppm)
    vis = cv2.resize(np.clip(rect_img, 0, 255).astype(np.uint8), None, fx=f, fy=f, interpolation=cv2.INTER_AREA)
    if unseen is not None and unseen.any():
        u = cv2.resize(unseen.astype(np.uint8), (vis.shape[1], vis.shape[0]), interpolation=cv2.INTER_NEAREST) > 0
        vis[u] = (0.5 * vis[u] + 0.5 * np.array([255, 0, 255])).astype(np.uint8)
    cols = [(0, 200, 255), (255, 0, 200), (0, 255, 0), (255, 255, 0), (0, 0, 255)]
    for p in pieces:
        m = cv2.resize(p['mask'].astype(np.uint8), (vis.shape[1], vis.shape[0]), interpolation=cv2.INTER_NEAREST)
        cs, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        col = cols[(p['layer'] - 1) % len(cols)]
        cv2.drawContours(vis, cs, -1, (0, 0, 0), 4)
        cv2.drawContours(vis, cs, -1, col, 2)
    for p in pieces:
        ys, xs = np.nonzero(p['visible'])
        cx, cy = int(xs.mean() * f), int(ys.mean() * f)
        txt = '%s L%d' % (p['name'], p['layer'])
        s = 0.5 * label_scale * max(1.0, vis.shape[1] / 700)
        (tw, th), _ = cv2.getTextSize(txt, cv2.FONT_HERSHEY_SIMPLEX, s, 2)
        org = (int(np.clip(cx - tw / 2, 2, vis.shape[1] - tw - 2)), cy)
        cv2.putText(vis, txt, org, cv2.FONT_HERSHEY_SIMPLEX, s, (0, 0, 0), 5, cv2.LINE_AA)
        cv2.putText(vis, txt, org, cv2.FONT_HERSHEY_SIMPLEX, s, (255, 255, 255), 2, cv2.LINE_AA)
    cv2.imwrite(str(out_path), vis, [cv2.IMWRITE_JPEG_QUALITY, 88])


class _Counter:
    def __init__(self):
        self.tris = 0

    def add(self, tri):
        self.tris += len(tri)
        return tri


# ---------------------------------------------------------------- main entry
def build(config_path, out_dir, log=print):
    t0 = time.time()
    cfg = load_config(config_path)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    warnings = []
    photo = rect.load_photo(cfg['_photo_path'])

    # 1. colours and sheet
    clf = seg.ColorClassifier.fit(photo, cfg['colors'], max_dist=cfg['color_max_dist'])
    r, paper_photo, sheet = detect_sheet(photo, clf, cfg, warnings)
    W, H = r.w_mm, r.h_mm
    T = float(cfg['sheet']['thickness_mm'])
    native = sheet['photo_px_per_mm']['median']
    A = float(cfg.get('analysis_px_per_mm') or np.clip(round(2 * native, 1), 2.0, 4.0))
    log('sheet %.0f x %.0f mm (%s), photo %.2f px/mm, analysis %.1f px/mm'
        % (W, H, 'guessed' if sheet['size_guessed'] else 'given', native, A))

    # 2. analysis raster
    rect_img, seen = r.warp(photo, A)
    paper = r.warp_mask(paper_photo, A) & seen
    labels, _ = clf.classify(rect_img)
    bi = clf.index(cfg['backing'])
    backing_ok = rect.erode(labels == bi, 1.5 * A) & paper

    pieces, dropped = [], []
    if cfg['mode'] == 'layers':
        pieces, dropped = seg.extract_pieces(labels, clf.names, cfg.get('stack', []), paper, A,
                                             cfg['min_piece_mm2'], cfg['primary_share'])
        layers_mod.assign_layers(pieces, A)
        layers_mod.complete_hidden(pieces, A, hull_grow_mm=cfg['hidden_grow_mm'],
                                   keep_in_mm=cfg['hidden_keep_in_mm'])
        if not pieces:
            warnings.append('no pieces found; check "colors" sample points and "stack"')
        if dropped:
            warnings.append('%d small component(s) dropped (< min_piece_mm2)' % len(dropped))
    pieces_union = np.zeros(labels.shape, bool)
    for p in pieces:
        pieces_union |= p['mask']
    unknown_frac = float(((labels == seg.UNKNOWN) & paper & ~pieces_union).sum()) / max(1, int(paper.sum()))
    if cfg['mode'] == 'layers' and unknown_frac > 0.05:
        warnings.append('%.0f%% of the sheet matches no colour; add sample points' % (100 * unknown_frac))

    # 3. appearance
    app = tex.Appearance.estimate(rect_img, A, backing_ok & ~rect.dilate(pieces_union, 1.0 * A))
    wref = cfg.get('white_reference')
    wb_info = None
    if wref:
        wi = clf.index(wref)
        wmask = rect.erode(labels == wi, 1.0 * A) & paper
        if wmask.sum() > 50:
            corr = app.correct(rect_img, (0, 0, W, H), A)
            wb = app.set_white(np.median(corr[wmask], axis=0))
            wb_info = [round(float(v), 3) for v in wb[::-1]]
        else:
            warnings.append('white_reference %r: too few pixels, no white balance' % wref)
    rect_corr = app.correct(rect_img, (0, 0, W, H), A)

    # 4. geometry + textures
    glb = GLB(GENERATOR)
    sampler = glb.sampler(False)
    cnt = _Counter()
    root = glb.group_node('flat_artwork', extras={
        'units': 'metres', 'sheet_mm': [W, H], 'mode': cfg['mode'], 'up': '+Y', 'front': '+Z'})

    def material(name, color_bgr=None, tex_bytes=None, factor=1.0):
        if tex_bytes is not None:
            ti = glb.texture(tex_bytes, 'image/jpeg', name, sampler)
            return glb.material(name, base_tex=ti, roughness=ROUGHNESS)
        lin = tex.srgb_to_linear(np.clip(np.asarray(color_bgr, float)[::-1] * factor, 0, 255))
        return glb.material(name, base_factor=lin, roughness=ROUGHNESS)

    # backing texture
    bppm = tex.texture_ppm((0, 0, W, H), native, cfg['texture_factor'])
    bimg, bseen = r.warp(photo, bppm, interp=cv2.INTER_CUBIC)
    bimg = app.correct(bimg, (0, 0, W, H), bppm)
    paper_b = r.warp_mask(paper_photo, bppm)
    if cfg['mode'] == 'layers':
        bvalid_a = backing_ok & ~rect.dilate(pieces_union, 1.5 * A)
        bvalid = mask_fn(bvalid_a, A)((0, 0, W, H), bppm) & bseen & paper_b
    else:
        bvalid = bseen & rect.erode(paper_b, 0.5 * bppm)
    bfill = tex.normconv_fill(bimg, bvalid, tex.fill_sigmas(bppm, 60.0))
    bfill = np.clip(bfill, 0, 255).astype(np.uint8)
    back_col = tex.median_color(bfill, bvalid) if bvalid.any() else np.array([200, 200, 200])
    m_front = material('backing_front', tex_bytes=tex.encode_jpg(bfill, 88))
    m_back = material('backing_back', back_col, factor=0.95)
    slab = meshlib.extrude(meshlib.rectangle(W, H), -T, 0.0, W, H)
    tp, tn, tt = slab['top']
    uv = np.stack([slab['top_xy'][:, 0] / W, slab['top_xy'][:, 1] / H], 1)
    bp, bn, bt = meshlib.merge(slab['bottom'], slab['side'])
    glb.mesh_node('backing_sheet', [glb.primitive(m_front, tp, cnt.add(tt), tn, uv0=uv),
                                    glb.primitive(m_back, bp, cnt.add(bt), bn)], parent=root,
                  extras={'role': 'backing', 'thickness_mm': T})

    piece_reports = []
    for p in sorted(pieces, key=lambda q: (q['layer'], q['group'])):
        ring = meshlib.mask_polygon(p['mask'], A)
        if ring is None:
            warnings.append('%s: no outline, skipped' % p['name'])
            continue
        z0 = (p['layer'] - 1) * (T + LAYER_GAP_MM) + LAYER_GAP_MM
        z1 = z0 + T
        ex = meshlib.extrude(ring, z0, z1, W, H)
        window = piece_window(p['mask'], A, 2.0, W, H)
        tppm = tex.texture_ppm(window, native, cfg['texture_factor'])
        upper = [q for q in pieces if q['layer'] > p['layer'] and p['name'] in q.get('below', [])]
        cover = np.zeros(labels.shape, bool)
        for q in upper:
            cover |= q['visible']
        own = [clf.index(c) for c in p['colors']]

        def rim_keep(raw, own=own):
            return np.isin(clf.classify(raw)[0], own)
        timg, tvalid, tpiece = tex.piece_texture(photo, r, app, mask_fn(p['mask'], A), mask_fn(cover, A),
                                                 window, tppm, rim_keep_fn=rim_keep)
        mode = cfg['piece_texture']
        interior = rect.erode(tpiece, 1.0 * tppm) & tvalid
        if interior.sum() < 20:
            interior = tvalid
        flat = (mode == 'flat') or (mode == 'auto' and tex.is_uniform(timg, interior, cfg['flat_tolerance']))
        col = tex.median_color(timg, interior)
        if flat:
            m_top = material(p['name'], col)
            uvp = None
        else:
            m_top = material(p['name'], tex_bytes=tex.encode_jpg(timg, 88))
            xy = ex['top_xy']
            uvp = np.stack([(xy[:, 0] - window[0]) / window[2], (xy[:, 1] - window[1]) / window[3]], 1)
        m_edge = material(p['name'] + '_edge', col, factor=0.9)
        tp, tn, tt = ex['top']
        ep, en, et = meshlib.merge(ex['bottom'], ex['side'])
        prims = [glb.primitive(m_top, tp, cnt.add(tt), tn, uv0=uvp), glb.primitive(m_edge, ep, cnt.add(et), en)]
        glb.mesh_node(p['name'], prims, parent=root,
                      extras={'group': p['group'], 'colors': p['colors'], 'layer': p['layer']})
        xs, ys = ring[:, 0], ring[:, 1]
        piece_reports.append({
            'name': p['name'], 'group': p['group'], 'colors': p['colors'], 'layer': p['layer'],
            'on_top_of': p.get('below', []),
            'bbox_mm': [round(float(xs.min()), 1), round(float(ys.min()), 1),
                        round(float(xs.max()), 1), round(float(ys.max()), 1)],
            'area_mm2': round(abs(meshlib.signed_area(ring)), 1),
            'hidden_area_mm2': p.get('hidden_mm2', 0.0),
            'appearance': 'flat_color' if flat else 'photo_texture',
            'color_srgb': [int(round(v)) for v in col[::-1]],
            'texture_px': None if flat else [int(timg.shape[1]), int(timg.shape[0])],
            'triangles': int(len(tt) + len(et)),
        })

    glb_path = out / 'model.glb'
    size = glb.save(glb_path)

    # 5. overlay + report
    overlay_image(rect_corr, A, pieces, ~seen, out / 'overlay.jpg')
    report = {
        'tool': GENERATOR, 'mode': cfg['mode'], 'photo': str(cfg['_photo_path']),
        'photo_size_px': [int(photo.shape[1]), int(photo.shape[0])],
        'sheet': dict(sheet, thickness_mm=T),
        'analysis_px_per_mm': A,
        'backing_texture_px': [int(bfill.shape[1]), int(bfill.shape[0])],
        'white_balance_rgb': wb_info,
        'color_prototypes_lab': clf.describe(),
        'unknown_fraction': round(unknown_frac, 4),
        'pieces': piece_reports,
        'dropped_components': dropped,
        'glb': {'file': 'model.glb', 'bytes': int(size), 'triangles': cnt.tris},
        'seconds': round(time.time() - t0, 1),
        'warnings': warnings,
    }
    (out / 'report.json').write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding='utf-8')
    log('wrote %s (%.2f MB, %d triangles, %d pieces) in %.1f s'
        % (glb_path, size / 1e6, cnt.tris, len(piece_reports), report['seconds']))
    for w in warnings:
        log('warning: ' + w)
    return report
