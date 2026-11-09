"""Remove a hand that holds the work from a flat face before its texture is cut.

Two steps, usable separately (multi-photo fusion reuses the detector):
  detect_hand(bgr, quad)        -> hole mask (hand + its shadow/outline) on the face, info
  fill_hole(bgr, quad, hole)    -> inpainted from face pixels only (rectified face, ink never a source)
remove_hands_on_face(path, quad) runs both on the workspace copy of a photo.

Detection (kt.hand_detect): a per-photo skin model seeded by the hand outside the face, plus the hand's
cast shadow on flat faces. Nothing on the face is taken when the face itself is skin-coloured.
"""
from __future__ import annotations
import os
import cv2
import numpy as np
from PIL import Image

from .segment import skin_like

MIN_SHARE = 0.002            # ignore specks
MAX_SHARE = 0.5              # a 'hand' covering more of the face than this is the face itself


def face_mask(shape, quad) -> np.ndarray:
    h, w = shape[:2]
    face = np.zeros((h, w), np.uint8)
    cv2.fillPoly(face, [(np.clip(np.asarray(quad, float), 0, 1) * [w, h]).round().astype(np.int32)], 1)
    return face


def detect_hand(bgr, quad, shadow=True) -> tuple[np.ndarray | None, dict]:
    """Hole mask (bool, photo-sized) covering hand pixels on the face plus their shadow/soft outline.

    Detection is kt.hand_detect: a skin model fitted to this photo's hand outside the face (seeds), the
    face's own colours as the alternative, and (shadow=True, flat faces) the hand's cast shadow and contact
    line. Curved faces (bottle prints) pass shadow=False: their own shading next to a hand looks like one."""
    from .hand_detect import detect_parts
    face = face_mask(bgr.shape, quad)
    area = int(face.sum())
    if area == 0:
        return None, {'applied': False, 'reason': 'empty face'}
    size = int(np.sqrt(area))
    inside = face.astype(bool)
    dbg = {}
    found = detect_parts(bgr, quad, shadow=shadow, debug=dbg) & inside
    if found.sum() < MIN_SHARE * area:
        why = 'no hand on the face'
        if dbg.get('self_strict', 0) > 0.05:
            why = f'face colours look like skin ({dbg["self_strict"]:.0%}); only the hand outside the face is known'
        return None, {'applied': False, 'reason': why}
    if found.sum() > MAX_SHARE * area:
        return None, {'applied': False, 'reason': f'{found.sum() / area:.0%} of the face looks like a hand: '
                                                  "more likely the face's own colour; left untouched"}
    grow = max(5, size // 120) | 1
    hole = cv2.dilate(found.astype(np.uint8), np.ones((grow, grow), np.uint8)).astype(bool) & inside   # soft edge
    f = dbg.get('face')
    hand_share = float(dbg['hand'].sum() / max(1, f.sum())) if f is not None and 'hand' in dbg else float(found.sum() / area)
    shadow_share = float(dbg['shadow'].sum() / max(1, f.sum())) if f is not None and 'shadow' in dbg else 0.0
    return hole, {'applied': True, 'hand_share': round(hand_share, 4), 'shadow_share': round(shadow_share, 4),
                  'filled_share': round(float(hole.sum() / area), 4), 'skin_model': bool(dbg.get('use_colour'))}


INK_DE = 14.0                # colour distance from the local background that counts as ink (letters, rules)
# how a hole is filled when no other photo shows it: 'paper' (always available), 'lama' (paper fill plus the
# LaMa network where an illustration runs into the hole; needs the model, see kt.lama), or 'auto' (lama when
# the model is installed). Set by `kt --fill`. Holes smaller than LAMA_MIN_SHARE of the face always get paper:
# the network brings nothing measurable there and costs ~3 s.
FILL_METHOD = os.environ.get('KT_FILL', 'auto')
LAMA_MIN_SHARE = 0.02          # hand bench: LaMa helped on 3-6% holes, made no difference on 1.4-2.7%


def _lab(bgr):
    l = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    l[..., 0] *= 100 / 255; l[..., 1:] -= 128
    return l


def _odd(v):
    v = int(round(v))
    return v + 1 - v % 2


def _cover_geometry(quad, shape):
    """Upright rectangle of the face and the homography rect -> photo (OpenCV pixel-centre convention)."""
    h, w = shape[:2]
    q = np.clip(np.asarray(quad, float), 0, 1) * [w, h]
    W = max(2, int(round((np.linalg.norm(q[1] - q[0]) + np.linalg.norm(q[2] - q[3])) / 2)))
    H = max(2, int(round((np.linalg.norm(q[3] - q[0]) + np.linalg.norm(q[2] - q[1])) / 2)))
    rect = np.array([[0, 0], [W, 0], [W, H], [0, H]], np.float32)
    M = cv2.getPerspectiveTransform(rect, q.astype(np.float32))
    t = np.array([[1, 0, 0.5], [0, 1, 0.5], [0, 0, 1]]); ti = np.array([[1, 0, -0.5], [0, 1, -0.5], [0, 0, 1]])
    return W, H, ti @ M @ t, q


def _background(cover, hole, frac=0.04):
    """Ink-free background of an upright face image (median filter ~4% of the face size) and its window."""
    H, W = hole.shape
    k = max(5, _odd(frac * np.sqrt(H * W)))
    return cv2.medianBlur(cv2.inpaint(cover, hole.astype(np.uint8), 3, cv2.INPAINT_TELEA), k), k


def _paper_fill(cover, hole, bg, k, radius=3):
    """Fill `hole` of an upright face image with its paper: ink (letters, rules, line art: pixels that differ
    from the ink-free background) near the hole is inpainted together with it, so it is never a source.
    Strokes touching the hole end at its edge instead of being smeared across it as grey streaks."""
    ink = (np.linalg.norm(_lab(cover) - _lab(bg), axis=2) > INK_DE) & ~hole
    near = cv2.dilate(hole.astype(np.uint8), np.ones((4 * k + 1,) * 2, np.uint8)).astype(bool)
    ink = cv2.dilate((ink & near).astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    # Telea, not Navier-Stokes: NS has no bias on perfectly flat synthetic paper (Telea +3) but follows the
    # lighting gradients of real covers worse (hand bench end-to-end dE 5.35 Telea vs 5.64 NS)
    filled = cv2.inpaint(cover, (hole | ink).astype(np.uint8), radius, cv2.INPAINT_TELEA)
    out = cover.copy(); out[hole] = filled[hole]
    return out


def fill_hole(bgr, quad, hole, method=None, stats=None) -> np.ndarray:
    """Inpaint `hole` from face pixels only. The face is rectified to an upright rectangle first, so the
    image border is the face edge: nothing outside the face (where the rest of the hand is) can be a
    source. Ink near the hole is not a source either (_paper_fill). Only hole pixels inside the face are
    written. (Hand bench: mean colour error in the hand area 8.0 -> 5.2 vs painting the outside with the
    cover colour + Telea.) method: 'paper' or 'lama' (default FILL_METHOD); stats receives what was used."""
    W, H, M, q = _cover_geometry(quad, bgr.shape)
    face = face_mask(bgr.shape, quad).astype(bool)
    hole = hole & face
    if not hole.any():
        return bgr.copy()
    cover = cv2.warpPerspective(bgr, M, (W, H), flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP, borderMode=cv2.BORDER_REPLICATE)
    hole_r = cv2.warpPerspective(hole.astype(np.uint8) * 255, M, (W, H), flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP,
                                 borderMode=cv2.BORDER_REPLICATE) > 0
    bg, k = _background(cover, hole_r)
    filled = _paper_fill(cover, hole_r, bg, k)
    method = method or FILL_METHOD
    used = 'paper'
    if method in ('lama', 'auto') and hole_r.mean() < LAMA_MIN_SHARE:
        used = 'paper (small hole)'
    elif method in ('lama', 'auto'):
        from . import lama
        if lama.available():
            filled, used = lama.hybrid_fill(cover, hole_r, filled, bg, k, _lab)
        elif method == 'lama':
            used = f'paper (LaMa model not found at {lama.model_path()})'
    if stats is not None:
        stats['fill'] = used
    back = cv2.warpPerspective(filled, M, (bgr.shape[1], bgr.shape[0]), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    out = bgr.copy()
    out[hole] = back[hole]
    return out


def remove_hands_on_face(source_png, quad, shadow=True) -> dict:
    bgr = cv2.cvtColor(np.asarray(Image.open(source_png).convert('RGB')), cv2.COLOR_RGB2BGR)
    hole, info = detect_hand(bgr, quad, shadow=shadow)
    if hole is None:
        return info
    st = {}
    out = fill_hole(bgr, quad, hole, stats=st)
    info.update(st)
    Image.fromarray(cv2.cvtColor(out, cv2.COLOR_BGR2RGB)).save(source_png)
    inside = face_mask(bgr.shape, quad).astype(bool)
    info['skin_left_share'] = round(float((skin_like(out) & inside).sum() / max(1, inside.sum())), 4)
    return info
