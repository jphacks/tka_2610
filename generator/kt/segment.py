"""Object masks: rembg (local AI background removal) + removal of hands/fingers + hole filling.

The rembg model (isnet-general-use, ~179 MB) is downloaded once to ~/.rembg and runs fully locally.
Masks are cached by image content so re-runs are instant.
"""
from __future__ import annotations
import hashlib
from pathlib import Path
import cv2
import numpy as np
from PIL import Image

MODEL = 'isnet-general-use'
CACHE = Path.home() / '.cache' / 'katachi-tools' / 'masks'
_session = None


def _get_session():
    global _session
    if _session is None:
        from rembg import new_session
        _session = new_session(MODEL)
    return _session


def rembg_alpha(path: Path) -> np.ndarray:
    data = Path(path).read_bytes()
    key = hashlib.sha256(data).hexdigest()[:32]
    cached = CACHE / f'{key}_{MODEL}.png'
    if cached.exists():
        return np.asarray(Image.open(cached).convert('L'))
    from rembg import remove
    im = Image.open(path).convert('RGB')
    alpha = remove(im, session=_get_session(), only_mask=True)
    CACHE.mkdir(parents=True, exist_ok=True)
    alpha.save(cached)
    return np.asarray(alpha.convert('L'))


def largest_component(mask: np.ndarray) -> np.ndarray:
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), connectivity=8)
    if n <= 1:
        return mask.astype(bool)
    return lab == 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))


def fill_holes(mask: np.ndarray) -> np.ndarray:
    """Fill only enclosed holes (glare spots), keeping real concavities such as handles' gaps."""
    from scipy.ndimage import binary_fill_holes
    return binary_fill_holes(mask.astype(bool))


def skin_like(bgr: np.ndarray) -> np.ndarray:
    """Skin in CIELAB: moderate redness (a*) with yellowness (b*) not much larger than the redness.
    Measured on the sample photos: skin a* 8-10 / b* 0-15; cream plastic (even shaded) a* -4..+1 / b* 14-26;
    red cap a* 54; wood-like colours have b* far above a* and are excluded by the b*-1.4a* term."""
    lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(float)
    L = lab[..., 0] * 100 / 255
    a = lab[..., 1] - 128
    b = lab[..., 2] - 128
    return (a >= 5) & (a <= 30) & (b >= -6) & (b <= 32) & (b - 1.4 * a < 12) & (L >= 25) & (L <= 92)


def touching_border(mask: np.ndarray, tol=0.01) -> list[str]:
    h, w = mask.shape
    out = []
    for name, line, length in (('top', mask[0], w), ('bottom', mask[-1], w), ('left', mask[:, 0], h), ('right', mask[:, -1], h)):
        if line.sum() > tol * length:
            out.append(name)
    return out


def object_mask(source_png: Path, remove_skin: str = 'auto') -> tuple[np.ndarray, dict]:
    """Foreground mask of the photographed object at the resolution of `source_png`."""
    bgr = cv2.cvtColor(np.asarray(Image.open(source_png).convert('RGB')), cv2.COLOR_RGB2BGR)
    alpha = rembg_alpha(source_png)
    if alpha.shape != bgr.shape[:2]:
        alpha = cv2.resize(alpha, (bgr.shape[1], bgr.shape[0]), interpolation=cv2.INTER_LINEAR)
    mask = largest_component(alpha > 127)
    info = {'segmentation': f'rembg:{MODEL}', 'skin_removed_fraction': 0.0}
    skin = skin_like(bgr)
    size = int(np.sqrt(mask.sum()))
    core_k = np.ones((max(3, size // 12),) * 2, np.uint8)
    core = cv2.erode(mask.astype(np.uint8), core_k).astype(bool)
    core_skin = float(skin[core].mean()) if core.any() else 0.0
    info['object_skin_like_fraction'] = round(core_skin, 3)
    if remove_skin in ('on', 'auto'):
        # A skin-coloured object (peach cover) is protected: with >= 15% skin in its core, only components
        # that also reach the photo frame (a hand comes with an arm) are candidates, and only if what
        # remains is a non-skin object of reasonable size. Otherwise any skin component entering from
        # outside the object outline is a hand/finger, as before.
        ambiguous = remove_skin == 'auto' and core_skin >= 0.15
        h, w = mask.shape
        m = max(2, int(0.01 * min(h, w)))
        frame = np.zeros_like(mask); frame[:m] = frame[-m:] = True; frame[:, :m] = frame[:, -m:] = True
        sk = cv2.morphologyEx((skin & mask).astype(np.uint8), cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
        n, lab, stats, _ = cv2.connectedComponentsWithStats(sk, connectivity=8)
        background = cv2.dilate((~mask).astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool)
        removed = np.zeros_like(mask)
        for i in range(1, n):
            comp = lab == i
            if stats[i, cv2.CC_STAT_AREA] < 0.002 * mask.sum():
                continue
            if (comp & background).any() and (not ambiguous or (comp & frame).any()):
                removed |= comp                    # a hand/finger enters from outside the object
        if removed.any():
            removed = cv2.dilate(removed.astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool)
            new = mask & ~removed
            new = cv2.morphologyEx(new.astype(np.uint8), cv2.MORPH_OPEN, np.ones((7, 7), np.uint8)).astype(bool)
            new = largest_component(new)
            ok = True
            if ambiguous:
                core_new = cv2.erode(new.astype(np.uint8), core_k).astype(bool)
                rest_skin = float(skin[core_new].mean()) if core_new.any() else 1.0
                ok = new.sum() >= 0.4 * mask.sum() and rest_skin < 0.15
                info['object_skin_like_fraction_without_hand'] = round(rest_skin, 3)
            if ok:
                info['skin_removed_fraction'] = round(float((mask & ~new).sum() / max(1, mask.sum())), 4)
                info['_occluded'] = mask & ~new          # where a hand covered/touched the object outline
                mask = new
    mask = fill_holes(mask)
    info['touches_border'] = touching_border(mask)
    return mask, info
