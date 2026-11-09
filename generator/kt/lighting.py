"""Remove baked-in lighting (phone/hand shadows, gradients) from a flat face before its texture is cut.

Shadows scale a surface's brightness but barely change its chromaticity (the ratios R:G:B). So the
plain background of the face (paper, cover stock) is identified by its chromaticity, not by being
bright: designs in other colours, large ink areas and full-bleed artwork are excluded from the
illumination estimate instead of being mistaken for shadows. The illumination measured on the
background cells is interpolated across the rest of the face and divided out, bringing shadowed
areas up to the well-lit level. If no background colour covers enough of the face (full-bleed
artwork, photos), nothing is changed. Only the workspace copy of the photo is modified.
"""
from __future__ import annotations
import cv2
import numpy as np
from PIL import Image

GAIN_RANGE = (0.6, 1.8)
MIN_BACKGROUND_SHARE = 0.35      # below this the face has no dominant plain background: skip
CHROMA_TOL = 0.018               # rg-chromaticity distance that still counts as the background colour


def _homography(corners_px):
    return cv2.getPerspectiveTransform(np.float32([[0, 0], [1, 0], [1, 1], [0, 1]]), np.float32(corners_px))


def glare_fraction(source_png, quad) -> float:
    """Share of near-white, colourless pixels inside the quad: specular highlights of a glossy cover."""
    img = np.asarray(Image.open(source_png).convert('RGB'))
    h, w = img.shape[:2]
    m = np.zeros((h, w), np.uint8)
    cv2.fillPoly(m, [(np.clip(np.asarray(quad, float), 0, 1) * [w, h]).round().astype(np.int32)], 1)
    inside = m.astype(bool)
    if not inside.any():
        return 0.0
    a = img.astype(int)
    hi = ((a.min(2) >= 242) & ((a.max(2) - a.min(2)) <= 18) & inside).astype(np.uint8)
    # highlights are soft blobs; white lettering/icons are thin strokes: keep only blob-sized regions
    k = max(5, int(0.012 * np.sqrt(inside.sum())) | 1)
    blobs = cv2.morphologyEx(hi, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
    return float(blobs[inside].mean())


def background_mask(rect: np.ndarray):
    """Pixels whose chromaticity matches the dominant background colour of the face.
    Returns (mask, chromaticity, share)."""
    s = rect.sum(2) + 1e-6
    chrom = np.stack([rect[..., 0] / s, rect[..., 1] / s], -1)          # intensity-invariant r, g
    lum = rect @ np.array([0.299, 0.587, 0.114], np.float32)
    usable = lum > 0.12 * np.percentile(lum, 99)                         # chromaticity of near-black is noise
    hist, xe, ye = np.histogram2d(chrom[usable][:, 0], chrom[usable][:, 1], bins=60, range=[[0, 1], [0, 1]])
    hist = cv2.GaussianBlur(hist.astype(np.float32), (0, 0), 1.0)
    i, j = np.unravel_index(int(np.argmax(hist)), hist.shape)
    c0 = np.array([(xe[i] + xe[i + 1]) / 2, (ye[j] + ye[j + 1]) / 2])
    near = usable & (np.linalg.norm(chrom - c0, axis=-1) < CHROMA_TOL)
    if near.any():                                                       # refine the centre on its members
        c0 = chrom[near].mean(0)
        near = usable & (np.linalg.norm(chrom - c0, axis=-1) < CHROMA_TOL)
    return near, c0, float(near.mean())


def illumination_grid(lum, bg, cells=12, min_fill=0.15):
    """Median background luminance per cell; cells without enough background are NaN."""
    h, w = lum.shape
    ny = max(3, int(round(cells * h / max(h, w)))); nx = max(3, int(round(cells * w / max(h, w))))
    grid = np.full((ny, nx), np.nan, np.float32)
    for j in range(ny):
        for i in range(nx):
            sl = (slice(j * h // ny, (j + 1) * h // ny), slice(i * w // nx, (i + 1) * w // nx))
            b = bg[sl]
            if b.mean() >= min_fill:
                grid[j, i] = np.median(lum[sl][b])
    return grid


def _fill_nan(grid):
    """Inverse-distance fill of unknown cells from the known ones."""
    known = np.argwhere(~np.isnan(grid))
    vals = grid[~np.isnan(grid)]
    out = grid.copy()
    for j, i in np.argwhere(np.isnan(grid)):
        d2 = ((known - [j, i]) ** 2).sum(1).astype(float)
        wts = 1 / (d2 + 1e-6) ** 1.5
        out[j, i] = float((wts * vals).sum() / wts.sum())
    return out


def flatten_face(source_png, quad, cells=12, out_size=320, mask=None) -> dict:
    """Divide out smooth illumination inside `quad` (normalised TL,TR,BR,BL) of the photo, in place.
    `mask` (photo-sized bool) limits the background estimate to the object, e.g. a paper cut-out on a table."""
    img = np.asarray(Image.open(source_png).convert('RGB')).astype(np.float32)
    h, w = img.shape[:2]
    q = np.clip(np.asarray(quad, float), 0, 1) * [w, h]
    side_w = (np.linalg.norm(q[1] - q[0]) + np.linalg.norm(q[2] - q[3])) / 2
    side_h = (np.linalg.norm(q[3] - q[0]) + np.linalg.norm(q[2] - q[1])) / 2
    s = out_size / max(side_w, side_h)
    rw, rh = max(8, int(side_w * s)), max(8, int(side_h * s))
    Hq = _homography(q)                                   # unit square -> photo pixels
    to_rect = np.diag([rw, rh, 1.0]) @ np.linalg.inv(Hq)  # photo pixels -> rectified pixels
    rect = cv2.warpPerspective(img, to_rect, (rw, rh), flags=cv2.INTER_AREA)
    lum = rect @ np.array([0.299, 0.587, 0.114], np.float32)
    bg, c0, share = background_mask(rect)
    if mask is not None:
        inside = cv2.warpPerspective(mask.astype(np.uint8), to_rect, (rw, rh), flags=cv2.INTER_NEAREST).astype(bool)
        bg, c0, share = background_mask(np.where(inside[..., None], rect, 0))
        bg &= inside
        share = float(bg.sum() / max(1, inside.sum()))
    info = {'background_share': round(share, 3), 'background_chromaticity': [round(float(v), 3) for v in c0]}
    if share < MIN_BACKGROUND_SHARE:
        info.update(applied=False, reason=f'no dominant plain background ({share:.0%} < {MIN_BACKGROUND_SHARE:.0%})')
        return info
    grid = illumination_grid(lum, bg, cells)
    if np.isnan(grid).mean() > 0.75:
        info.update(applied=False, reason='background too sparse to map the illumination')
        return info
    grid = _fill_nan(grid)
    bgmap = cv2.resize(grid, (rw, rh), interpolation=cv2.INTER_CUBIC)
    bgmap = cv2.GaussianBlur(bgmap, (0, 0), sigmaX=max(rw, rh) / cells / 2)
    target = float(np.percentile(grid, 90))              # bring shadowed parts up to the well-lit level
    gain_rect = np.clip(target / np.maximum(bgmap, 1.0), *GAIN_RANGE).astype(np.float32)
    gain = cv2.warpPerspective(gain_rect, np.linalg.inv(to_rect), (w, h), flags=cv2.INTER_LINEAR,
                               borderMode=cv2.BORDER_CONSTANT, borderValue=1.0)
    m = np.zeros((h, w), np.uint8)
    cv2.fillPoly(m, [q.round().astype(np.int32)], 255)
    feather = cv2.GaussianBlur(m.astype(np.float32) / 255, (0, 0), sigmaX=3)
    gain = 1 + (gain - 1) * feather
    Image.fromarray(np.clip(img * gain[..., None], 0, 255).astype(np.uint8)).save(source_png)
    inside = gain[m > 0]
    info.update(applied=True, gain_min=round(float(inside.min()), 3), gain_max=round(float(inside.max()), 3),
                illumination_spread=round(float(grid.max() / max(grid.min(), 1)), 3))
    return info


def describe_flatten(info: dict) -> str:
    if not info.get('applied'):
        return f"lighting kept as photographed: {info.get('reason')}"
    return (f"shadows/gradients flattened on the {info['background_share']:.0%} background "
            f"(gain {info['gain_min']}-{info['gain_max']}, illumination spread x{info['illumination_spread']})")
