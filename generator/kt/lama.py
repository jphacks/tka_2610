"""LaMa inpainting (big-lama, Apache-2.0) for the parts of a hand hole where an illustration or a large
shape runs into it. Plain paper and lettering keep the paper fill (kt.hands), which is cleaner there.

Adopted from bench/variants/hand_fill_hybrid.py:hybrid_bg (fill bench, oracle holes: mean dE 5.22 with
the paper fill alone -> 4.73). The network runs only when the paper fill would extend something that is
not paper; otherwise the result is identical to the paper fill and costs nothing extra.

Model: lama_fp32.onnx from https://huggingface.co/Carve/LaMa-ONNX (208 MB, fixed 1x3x512x512 input),
looked up at $KT_LAMA_ONNX, else ~/.cache/katachi-tools/lama/lama_fp32.onnx. Without it, available() is
False and callers use the paper fill.
"""
from __future__ import annotations
import os
from pathlib import Path

import cv2
import numpy as np

SIZE = 512
LO, HI, DIL = 6.0, 12.0, 0.5      # paper-fill departure from the lit paper colour (dE) mapped to LaMa weight 0..1
MAX_ASPECT = 3.0                  # the net sees the face squeezed to 512x512: not for spines and other strips
WEIGHT_SIDE = 512                 # the weight map is smooth: computed at most this many pixels on the long side
RUN_MIN = float(os.environ.get('KT_LAMA_RUN_MIN', 0.5))   # run the net only if some hole pixel would be mostly LaMa
_sess = None


def model_path() -> Path:
    return Path(os.environ.get('KT_LAMA_ONNX') or Path.home() / '.cache' / 'katachi-tools' / 'lama' / 'lama_fp32.onnx')


def available() -> bool:
    return model_path().is_file()


def _session():
    global _sess
    if _sess is None:
        import onnxruntime as ort
        so = ort.SessionOptions()
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        # more threads is slower on hybrid CPUs (i7-13700F: 6-8 threads ~3 s, 16 ~7.6 s, 24 ~20 s)
        so.intra_op_num_threads = int(os.environ.get('KT_LAMA_THREADS', 6))
        # the export leaves the batch dimension free; pinning it folds ~15k shape nodes (session 20 s -> 2 s)
        so.add_free_dimension_override_by_name('batch', 1)
        _sess = ort.InferenceSession(str(model_path()), so, providers=['CPUExecutionProvider'])
    return _sess


def _lama_512(bgr512, hole512):
    rgb = cv2.cvtColor(bgr512, cv2.COLOR_BGR2RGB).astype(np.float32) / 255
    m = hole512.astype(np.float32)[None, None]
    img = rgb.transpose(2, 0, 1)[None] * (1 - m)
    out = _session().run(None, {'image': img, 'mask': m})[0][0].transpose(1, 2, 0)
    if out.max() <= 1.5:
        out = out * 255
    return cv2.cvtColor(np.clip(out, 0, 255).astype(np.uint8), cv2.COLOR_RGB2BGR)


def _lama_whole(cover, hole):
    """The whole (rectified) face at 512x512: the face is the only context the network sees."""
    H, W = hole.shape
    small = cv2.resize(cover, (SIZE, SIZE), interpolation=cv2.INTER_AREA)
    hs = cv2.resize(hole.astype(np.uint8), (SIZE, SIZE), interpolation=cv2.INTER_AREA) > 0
    hs = cv2.dilate(hs.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    return cv2.resize(_lama_512(small, hs), (W, H), interpolation=cv2.INTER_CUBIC)


def _paper_colour(bg_lab, valid):
    """Most common ink-free colour of the face (Lab), refined around the histogram mode."""
    px = bg_lab[valid]
    q = np.floor(px / 4).astype(np.int32)
    key = (q[:, 0] + 64) * 65536 + (q[:, 1] + 64) * 256 + (q[:, 2] + 64)
    vals, counts = np.unique(key, return_counts=True)
    m = vals[counts.argmax()]
    centre = (np.array([m // 65536, (m // 256) % 256, m % 256]) - 64) * 4 + 2
    near = np.linalg.norm(px - centre, axis=1) < 6
    return px[near].mean(0) if near.any() else centre


def _paper_map(hole, bg, pc, lab, tol=15.0, side=256):
    """Smooth map of the paper colour under the actual lighting (low resolution, interpolated)."""
    H, W = hole.shape
    s = min(1.0, side / max(H, W))
    small = cv2.resize(bg, (max(1, int(W * s)), max(1, int(H * s))), interpolation=cv2.INTER_AREA)
    hs = cv2.resize(hole.astype(np.uint8), small.shape[1::-1], interpolation=cv2.INTER_NEAREST)
    hs = cv2.dilate(hs, np.ones((3, 3), np.uint8)).astype(bool)
    notpaper = (np.linalg.norm(lab(small) - pc, axis=2) > tol) | hs
    if notpaper.all():
        return None
    m = cv2.GaussianBlur(cv2.inpaint(small, notpaper.astype(np.uint8), 3, cv2.INPAINT_TELEA), (0, 0), 2)
    return cv2.resize(m, (W, H), interpolation=cv2.INTER_LINEAR)


def lama_weight(cover, hole, bg, k, lab):
    """0 where the hole would simply get (locally lit) paper, 1 where an illustration or panel runs into it.
    Judged on a Telea fill of the ink-free cover, so lettering at the hole edge does not trigger the net.
    Computed at <= WEIGHT_SIDE px (the map is blurred anyway) and scaled back."""
    H, W = hole.shape
    s = min(1.0, WEIGHT_SIDE / max(H, W))
    if s < 1.0:
        size = (max(1, int(W * s)), max(1, int(H * s)))
        hs = cv2.resize(hole.astype(np.uint8), size, interpolation=cv2.INTER_AREA) > 0
        w = lama_weight(cv2.resize(cover, size, interpolation=cv2.INTER_AREA), hs,
                        cv2.resize(bg, size, interpolation=cv2.INTER_AREA), max(3, k * s), lab)
        return cv2.resize(w, (W, H), interpolation=cv2.INTER_LINEAR)
    pc = _paper_colour(lab(bg), ~hole)
    pm = _paper_map(hole, bg, pc, lab)
    ref = lab(pm) if pm is not None else pc
    fb = cv2.inpaint(bg, hole.astype(np.uint8), 3, cv2.INPAINT_TELEA)
    w = np.clip((np.linalg.norm(lab(fb) - ref, axis=2) - LO) / (HI - LO), 0, 1).astype(np.float32)
    r = max(1, int(DIL * k))
    w = cv2.dilate(w, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1,) * 2))
    return cv2.GaussianBlur(w, (0, 0), max(1.0, k / 4))


def hybrid_fill(cover, hole, paper_filled, bg, k, lab):
    """Blend LaMa into the paper fill where the paper fill would extend something that is not paper.
    Returns (filled cover, note on what was used)."""
    H, W = hole.shape
    if max(H, W) / max(1, min(H, W)) > MAX_ASPECT:
        return paper_filled, 'paper (strip-shaped face)'
    w = lama_weight(cover, hole, bg, k, lab)
    if w[hole].max() < RUN_MIN:                 # paper (and lettering) or only a faint blend: not worth ~3 s
        return paper_filled, 'paper (no illustration at the hole)'
    b = _lama_whole(cover, hole).astype(np.float32)
    mix = b * w[..., None] + paper_filled.astype(np.float32) * (1 - w[..., None])
    out = cover.copy()
    out[hole] = np.clip(mix[hole], 0, 255).round().astype(np.uint8)
    return out, f'lama (mostly LaMa on {(w[hole] > 0.5).mean():.0%} of the hole, blended elsewhere)'
