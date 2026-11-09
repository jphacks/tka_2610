"""Fuse several photos of the same flat face so that what one photo hides is taken from another.

A finger (or a glare blob) covers a different part of the face in each photo. Every photo is rectified
to the face (with a margin around it), finely aligned to the primary photo (ECC homography on
agreeing pixels) and brightness matched. Where the photos DISAGREE, something covers the face in one
of them; colour is not needed to find it. The covered photo is the one in which the disagreeing patch
continues across the face edge into the area outside the face (a hand comes from outside), or which
is brighter and colourless there (glare), or whose skin detector fired there. The primary's covered
spots are replaced by REAL pixels from a photo where they are clear; spots hidden in every photo are
inpainted. Only the workspace copy of the primary photo is changed.
"""
from __future__ import annotations
import cv2
import numpy as np
from PIL import Image

from .hands import detect_hand, fill_hole, face_mask

RECT_LONG = 1200          # working resolution of the rectified face
MARGIN = 0.07             # rectified canvas extends this fraction beyond each face edge
DIFF_DE = 14.0            # colour difference (CIE76) that counts as disagreement
CONTINUITY_DE = 22.0      # a covering object looks alike on both sides of the face edge
FRINGE_BAND = 0.04        # the primary's soft shadow fringe is searched this far around its hole (share of face size)
FRINGE_DL = 2.5           # ... where it is this much darker (CIE L) than the other photo, with the same colour


def _bgr(path):
    return cv2.cvtColor(np.asarray(Image.open(path).convert('RGB')), cv2.COLOR_RGB2BGR)


def _lab(bgr):
    l = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    l[..., 0] *= 100 / 255; l[..., 1:] -= 128
    return l


def glare_mask(bgr, quad) -> np.ndarray:
    """Specular highlight blobs on the face (near-white, colourless, blob-sized; thin white print excluded)."""
    face = face_mask(bgr.shape, quad).astype(bool)
    a = bgr.astype(int)
    hi = ((a.min(2) >= 242) & ((a.max(2) - a.min(2)) <= 18) & face).astype(np.uint8)
    k = max(5, int(0.012 * np.sqrt(face.sum())) | 1)
    blobs = cv2.morphologyEx(hi, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
    return cv2.dilate(blobs, np.ones((9, 9), np.uint8)).astype(bool) & face


class _Rect:
    """Face rectified onto a canvas with a margin ring; maps photo <-> canvas."""

    def __init__(self, bgr, quad, size_hint=None):
        h, w = bgr.shape[:2]
        q = np.float32(np.asarray(quad, float) * [w, h])
        if size_hint is None:
            sw = (np.linalg.norm(q[1] - q[0]) + np.linalg.norm(q[2] - q[3])) / 2
            sh = (np.linalg.norm(q[3] - q[0]) + np.linalg.norm(q[2] - q[1])) / 2
            s = RECT_LONG / max(sw, sh)
            size_hint = (max(16, int(sw * s)), max(16, int(sh * s)))
        self.fw, self.fh = size_hint
        self.m = int(MARGIN * max(self.fw, self.fh))
        self.W, self.H = self.fw + 2 * self.m, self.fh + 2 * self.m
        m = self.m
        self.M = cv2.getPerspectiveTransform(q, np.float32([[m, m], [m + self.fw, m], [m + self.fw, m + self.fh], [m, m + self.fh]]))
        self.face = np.zeros((self.H, self.W), bool)
        self.face[m:m + self.fh, m:m + self.fw] = True
        self.photo_shape = bgr.shape

    def warp(self, img, nearest=False, border_value=0):
        return cv2.warpPerspective(img, self.M, (self.W, self.H), flags=cv2.INTER_NEAREST if nearest else cv2.INTER_LINEAR,
                                   borderMode=cv2.BORDER_CONSTANT, borderValue=border_value)

    def unwarp(self, img, nearest=False):
        h, w = self.photo_shape[:2]
        return cv2.warpPerspective(img, np.linalg.inv(self.M), (w, h), flags=cv2.INTER_NEAREST if nearest else cv2.INTER_LINEAR)


def _ecc(ref, mov, valid, max_shift=0.02):
    """Homography that maps `mov` onto `ref` for cv2.warpPerspective (no inverse flag). Both are already
    rectified from their own detected corners, so only a small refinement is expected: the ECC result is
    used only if no face corner moves more than `max_shift` of the face size and it lowers the photometric
    difference on `valid`; otherwise identity. Returns (matrix, correlation or None)."""
    s = 0.5
    r = cv2.resize(cv2.cvtColor(ref, cv2.COLOR_BGR2GRAY), None, fx=s, fy=s).astype(np.float32)
    m = cv2.resize(cv2.cvtColor(mov, cv2.COLOR_BGR2GRAY), None, fx=s, fy=s).astype(np.float32)
    v = cv2.resize(valid.astype(np.uint8), (r.shape[1], r.shape[0]), interpolation=cv2.INTER_NEAREST)
    warp = np.eye(3, dtype=np.float32)
    try:
        cc, warp = cv2.findTransformECC(r, m, warp, cv2.MOTION_HOMOGRAPHY,
                                        (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 200, 1e-5), v, 5)
    except cv2.error:
        return np.eye(3), None
    S = np.diag([s, s, 1.0]); Si = np.diag([1 / s, 1 / s, 1.0])
    W = Si @ warp.astype(np.float64) @ S                 # ref coords -> mov coords (ECC convention)
    A = np.linalg.inv(W)                                 # for warpPerspective(mov, A): dst(x) = mov(W x)
    ys, xs = np.nonzero(valid)
    if len(xs) == 0:
        return np.eye(3), None
    box = np.float32([[xs.min(), ys.min()], [xs.max(), ys.min()], [xs.max(), ys.max()], [xs.min(), ys.max()]])
    moved = cv2.perspectiveTransform(box[None], W)[0]
    size = np.sqrt((xs.max() - xs.min()) * (ys.max() - ys.min()))
    if np.linalg.norm(moved - box, axis=1).max() > max_shift * size:
        return np.eye(3), None
    def err(M):
        al = cv2.warpPerspective(m, np.diag([1, 1, 1.0]) if M is None else S @ M @ Si, (r.shape[1], r.shape[0]),
                                 flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)
        d = np.abs(al - r)[v.astype(bool)]
        return float(np.median(d)) + float(np.mean(d))
    if err(A) >= err(None):
        return np.eye(3), None
    return A, float(cc)


def _owner(comp, rp, ro, lab_p, lab_o, face, seeds_p, seeds_o, glare_p, glare_o):
    """Which photo is covered on this disagreeing patch: 'p', 'o' or None."""
    if (comp & glare_p).sum() > 0.3 * comp.sum():
        return 'p'
    if (comp & glare_o).sum() > 0.3 * comp.sum():
        return 'o'
    sp, so = (comp & seeds_p).sum(), (comp & seeds_o).sum()
    if sp > 0.2 * comp.sum() and so == 0:
        return 'p'
    if so > 0.2 * comp.sum() and sp == 0:
        return 'o'
    # continuity across the face edge: the covering object also lies just outside the face
    ring = cv2.dilate(comp.astype(np.uint8), np.ones((25, 25), np.uint8)).astype(bool) & ~face
    if ring.sum() < 20:
        return None
    inner = comp & cv2.dilate(ring.astype(np.uint8), np.ones((25, 25), np.uint8)).astype(bool)
    if inner.sum() < 20:
        inner = comp
    cont = {}
    for key, lab in (('p', lab_p), ('o', lab_o)):
        cont[key] = float(np.linalg.norm(np.median(lab[inner], 0) - np.median(lab[ring], 0)))
    best = min(cont, key=cont.get)
    other = 'o' if best == 'p' else 'p'
    if cont[best] < CONTINUITY_DE and cont[other] > cont[best] + 8:
        return best
    return None


def _seamless(patch, base, got, trusted):
    """Put patch[got] into base without a visible seam: Poisson (gradient-domain) cloning keeps the other
    photo's detail but takes its low-frequency level from the primary around the hole, so local light
    differences between the shots do not outline the patch. Outside the face the boundary is the patch
    itself (zero offset): the background next to a hole on the face edge must not tint it. The same holds
    for the rest of the hole that no other photo could fill (it still shows the hand): only `trusted`
    primary pixels (clean face) set the level."""
    if not got.any():
        return base.copy()
    m = cv2.dilate(got.astype(np.uint8), np.ones((3, 3), np.uint8))
    m[:2] = 0; m[-2:] = 0; m[:, :2] = 0; m[:, -2:] = 0            # seamlessClone needs a margin
    dst = np.where(trusted[..., None], base, patch)
    x, y, w, h = cv2.boundingRect(m)
    try:
        out = cv2.seamlessClone(patch, dst, m * 255, (x + w // 2, y + h // 2), cv2.NORMAL_CLONE)
    except cv2.error:                                               # fall back to a feathered blend
        a = cv2.GaussianBlur(got.astype(np.float32), (0, 0), 2.0)
        a = np.where(got, np.maximum(a, 0.5), a)[..., None]
        return (patch.astype(np.float32) * a + base.astype(np.float32) * (1 - a)).clip(0, 255).astype(np.uint8)
    res = base.copy()
    sel = m.astype(bool)
    res[sel] = out[sel]
    return res


def fuse_face_photos(primary_png, primary_quad, others, use_glare=True, debug=None) -> dict:
    """others: list of (png_path, quad). Edits primary_png in place. debug: dict that receives the canvas masks."""
    P = _bgr(primary_png)
    rp = _Rect(P, primary_quad)
    rect_p = rp.warp(P)
    hand_p, dinfo = detect_hand(P, primary_quad)
    seeds_p = rp.warp((hand_p if hand_p is not None else np.zeros(P.shape[:2], bool)).astype(np.uint8), nearest=True).astype(bool)
    glare_p = rp.warp(glare_mask(P, primary_quad).astype(np.uint8), nearest=True).astype(bool) if use_glare else np.zeros_like(rp.face)
    lab_p = _lab(rect_p)
    hole = seeds_p | glare_p                         # primary's covered spots (canvas coordinates, face only)
    acc = np.zeros(rect_p.shape, np.float32); cnt = np.zeros(rect_p.shape[:2], np.float32)
    whole = np.zeros(rect_p.shape, np.float32)       # the other photos everywhere (boundary values off the face)
    per = []
    for path, quad in others:
        O = _bgr(path)
        ro = _Rect(O, quad, (rp.fw, rp.fh))
        rect_o = ro.warp(O)
        hand_o, _ = detect_hand(O, quad)
        seeds_o = ro.warp((hand_o if hand_o is not None else np.zeros(O.shape[:2], bool)).astype(np.uint8), nearest=True).astype(bool)
        glare_o = ro.warp(glare_mask(O, quad).astype(np.uint8), nearest=True).astype(bool) if use_glare else np.zeros_like(rp.face)
        valid = rp.face & ~cv2.dilate((seeds_p | seeds_o | glare_p | glare_o).astype(np.uint8), np.ones((15, 15), np.uint8)).astype(bool)
        A, cc = _ecc(rect_p, rect_o, valid)
        rect_o = cv2.warpPerspective(rect_o, A, (rp.W, rp.H), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)
        seeds_o = cv2.warpPerspective(seeds_o.astype(np.uint8), A, (rp.W, rp.H), flags=cv2.INTER_NEAREST).astype(bool)
        glare_o = cv2.warpPerspective(glare_o.astype(np.uint8), A, (rp.W, rp.H), flags=cv2.INTER_NEAREST).astype(bool)
        lab_o0 = _lab(rect_o)
        de0 = np.linalg.norm(lab_p - lab_o0, axis=2)
        agree = valid & (de0 < DIFF_DE)
        gain = np.clip(np.median(rect_p[agree].astype(np.float32), 0) / np.maximum(np.median(rect_o[agree].astype(np.float32), 0), 1), 0.7, 1.4) \
            if agree.sum() > 500 else np.ones(3)
        rect_o = np.clip(rect_o.astype(np.float32) * gain, 0, 255).astype(np.uint8)
        lab_o = _lab(rect_o)
        de = np.linalg.norm(lab_p - lab_o, axis=2)
        diff = (de > DIFF_DE) & rp.face
        diff = cv2.morphologyEx(diff.astype(np.uint8), cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
        diff = cv2.morphologyEx(diff, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8)).astype(bool)
        n, lab_c, st, _ = cv2.connectedComponentsWithStats(diff.astype(np.uint8))
        covered_o = seeds_o | glare_o
        owners = {'p': 0, 'o': 0, None: 0}
        for i in range(1, n):
            if st[i, cv2.CC_STAT_AREA] < 0.001 * rp.face.sum():
                continue
            comp = lab_c == i
            who = _owner(comp, rp, ro, lab_p, lab_o, rp.face, seeds_p, seeds_o, glare_p, glare_o)
            owners[who] += 1
            if who == 'p':
                hole |= cv2.dilate(comp.astype(np.uint8), np.ones((7, 7), np.uint8)).astype(bool) & rp.face
            elif who == 'o':
                covered_o |= comp
        # never borrow the outermost strip of the other photo: its face edge may carry background
        edge = max(3, int(0.006 * max(rp.fw, rp.fh)))
        inner = cv2.erode(rp.face.astype(np.uint8), np.ones((2 * edge + 1,) * 2, np.uint8)).astype(bool)
        # parts of the face that lie outside the other photo cannot be borrowed
        in_frame = cv2.warpPerspective(ro.warp(np.ones(O.shape[:2], np.uint8), nearest=True), A, (rp.W, rp.H), flags=cv2.INTER_NEAREST)
        in_frame = cv2.erode(in_frame, np.ones((2 * edge + 1,) * 2, np.uint8)).astype(bool)
        usable = inner & in_frame & ~cv2.dilate(covered_o.astype(np.uint8), np.ones((9, 9), np.uint8)).astype(bool)
        # the soft edge of the hand's shadow in the primary is too faint for DIFF_DE, but the other photo shows
        # the same paper unshaded there: take the darker-but-same-colour fringe connected to the hole as well
        if hole.any():
            r = max(3, int(FRINGE_BAND * np.sqrt(rp.face.sum())))
            band = cv2.dilate(hole.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1,) * 2)).astype(bool)
            dl = lab_o[..., 0] - lab_p[..., 0]
            dc = np.abs(lab_o[..., 1:] - lab_p[..., 1:]).max(2)
            fringe = band & usable & rp.face & (dl > FRINGE_DL) & (dc < 5)
            n2, lab2 = cv2.connectedComponents((fringe | hole).astype(np.uint8), connectivity=8)
            ids = np.unique(lab2[hole]); ids = ids[ids > 0]
            grown = np.isin(lab2, ids) & (fringe | hole)
            per_fringe = int((grown & ~hole).sum())
            hole |= grown
        else:
            per_fringe = 0
        use = hole & usable
        if debug is not None:
            debug.setdefault('others', []).append({'rect_o': rect_o, 'seeds_o': seeds_o, 'covered_o': covered_o, 'usable': usable,
                                                   'diff': diff, 'inner': inner, 'in_frame': in_frame})
        acc[use] += rect_o[use].astype(np.float32); cnt[use] += 1
        whole += rect_o.astype(np.float32) / len(others)
        per.append({'ecc': None if cc is None else round(cc, 3), 'gain': [round(float(g), 3) for g in gain],
                    'patches_primary_covered': owners['p'], 'patches_other_covered': owners['o'], 'patches_undecided': owners[None],
                    'shadow_fringe_px': per_fringe})
    info = {'applied': False, 'hand_detector': dinfo, 'photos': per}
    if not hole.any():
        info['reason'] = 'nothing covers the primary photo'
        return info
    got = (cnt > 0) & hole
    if debug is not None:
        debug.update(rect_p=rect_p, seeds_p=seeds_p, hole=hole.copy(), got=got, face=rp.face)
    fused = rect_p.astype(np.float32)
    fused[got] = acc[got] / cnt[got, None]
    patch = whole.copy(); patch[got] = fused[got]
    rect_out = _seamless(patch.clip(0, 255).astype(np.uint8), rect_p, got, rp.face.astype(bool) & ~hole)
    face_photo = face_mask(P.shape, primary_quad).astype(bool)
    back = rp.unwarp(rect_out)
    got_back = rp.unwarp(cv2.dilate(got.astype(np.uint8), np.ones((5, 5), np.uint8)), nearest=True).astype(bool) & face_photo
    out = P.copy()
    out[got_back] = back[got_back]
    hole_photo = rp.unwarp(hole.astype(np.uint8), nearest=True).astype(bool) & face_photo
    remaining = hole_photo & ~got_back
    if remaining.any():
        out = fill_hole(out, primary_quad, remaining, method='paper')   # LaMa measured worse on these remainders
    Image.fromarray(cv2.cvtColor(out, cv2.COLOR_BGR2RGB)).save(primary_png)
    info.update(applied=True, hole_share=round(float(hole_photo.sum() / max(1, face_photo.sum())), 4),
                from_other_photos=round(float((hole_photo & got_back).sum() / max(1, hole_photo.sum())), 3),
                inpainted_share_of_hole=round(float(remaining.sum() / max(1, hole_photo.sum())), 3))
    return info
