"""Silhouette measurements: width/offset profiles, cap detection, lathe radius profile."""
from __future__ import annotations
import cv2
import numpy as np


class Profile:
    """Row-wise silhouette extent of a mask, normalised by the silhouette height.
    t = fraction of height from the bottom (0) to the top (1). The tilt of the object's axis
    (line from the top-centre to the bottom-centre) is removed from the centre offsets."""

    def __init__(self, mask: np.ndarray, clip_protrusions: bool = True, occluded: np.ndarray | None = None):
        ys = np.where(mask.any(1))[0]
        if len(ys) < 10:
            raise ValueError('mask too small to measure')
        self.top, self.bot = int(ys.min()), int(ys.max())
        self.height_px = self.bot - self.top
        left = np.array([np.where(mask[y])[0].min() for y in ys], float)
        right = np.array([np.where(mask[y])[0].max() for y in ys], float)
        self.interpolated_rows = 0
        self.clipped_rows = 0
        if occluded is not None and occluded.any():
            # A hand IN FRONT of the outline leaves an inward bite after it is removed; a hand merely
            # touching the outline from behind does not. Fill only inward bites next to removed hands.
            near = cv2.dilate(occluded.astype(np.uint8), np.ones((9, 9), np.uint8)).astype(bool)
            w = mask.shape[1]
            left, right = self._fill_bites(ys, left, right, near, w)
        if clip_protrusions:
            left, right = self._clip(left, right)
        self.rows = {int(y): (int(round(l)), int(round(r))) for y, l, r in zip(ys, left, right)}
        c = {y: (l + r) / 2 for y, (l, r) in self.rows.items()}
        H = self.height_px
        self.c_top = float(np.mean([c[y] for y in ys if y < self.top + 0.05 * H]))
        self.c_bot = float(np.mean([c[y] for y in ys if y > self.bot - 0.06 * H]))
        self._c = c

    def _fill_bites(self, ys, left, right, near, w):
        from scipy.ndimage import median_filter
        n = len(left)
        win = max(9, int(0.15 * n) | 1)
        floor = 0.008 * self.height_px
        out = []
        for e, sign in ((left, -1), (right, +1)):
            touch = np.array([near[y, int(min(max(x, 0), w - 1))] for y, x in zip(ys, e)])
            med = median_filter(e, size=win, mode='nearest')
            mad = median_filter(np.abs(e - med), size=win, mode='nearest') * 1.4826
            inward = (med - e) * sign                     # > 0 means the outline is pulled inward
            bad = touch & (inward > np.maximum(3 * mad, floor))
            self.interpolated_rows += int(bad.sum())
            e = e.copy(); e[bad] = med[bad]
            out.append(e)
        return out[0], out[1]

    def _clip(self, left, right):
        """Remove short OUTWARD spikes of the outline (fingers or other things attached from outside).
        Inward features (dents, waists) are kept: only protrusions beyond a running median are clamped."""
        from scipy.ndimage import median_filter
        n = len(left)
        win = max(9, int(0.15 * n) | 1)
        floor = 0.008 * self.height_px
        out = []
        for e, sign in ((left, -1), (right, +1)):
            med = median_filter(e, size=win, mode='nearest')
            dev = (e - med) * sign                       # > 0 means outward
            mad = median_filter(np.abs(e - med), size=win, mode='nearest') * 1.4826
            bad = dev > np.maximum(3 * mad, floor)
            self.clipped_rows += int(bad.sum())
            e = e.copy(); e[bad] = med[bad]
            out.append(e)
        return out[0], out[1]

    def row(self, t: float) -> int:
        y = int(round(self.bot - t * self.height_px))
        return min(max(y, self.top), self.bot)

    def at(self, t: float) -> tuple[float, float]:
        """(width / height, centre offset from the axis / height)."""
        y = self.row(t)
        while y not in self.rows and y < self.bot:
            y += 1
        l, r = self.rows[y]
        axis = self.c_bot + (self.c_top - self.c_bot) * t
        return (r - l) / self.height_px, (self._c[y] - axis) / self.height_px

    def tilt(self) -> float:
        return (self.c_top - self.c_bot) / self.height_px

    def to_mask(self, shape) -> np.ndarray:
        """The cleaned outline (hands interpolated, spikes clipped) as a filled row-span mask."""
        m = np.zeros(shape, bool)
        for y, (l, r) in self.rows.items():
            m[y, max(l, 0):r + 1] = True
        return m


def row_colors(bgr: np.ndarray, mask: np.ndarray, prof: Profile, samples=200):
    """Median Lab colour of the central half of each sampled row (t from 1 down to 0)."""
    lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(float)
    out = []
    for t in np.linspace(1, 0, samples):
        y = prof.row(t)
        l, r = prof.rows.get(y, (0, 0))
        if r - l < 4:
            out.append((t, None)); continue
        q = (r - l) // 4
        px = lab[y, l + q:r - q + 1][mask[y, l + q:r - q + 1]]
        out.append((t, np.median(px, 0) if len(px) else None))
    return out


def lab_to_rgb01(lab):
    px = np.uint8([[np.clip(lab, 0, 255)]])
    return (cv2.cvtColor(px, cv2.COLOR_LAB2RGB)[0, 0] / 255).tolist()


def detect_cap(bgr, mask, prof: Profile, threshold=18.0):
    """A cap/lid = a band at the top whose colour differs from the body. Returns
    {'t_bottom': start of the cap (fraction from bottom), 'cap_rgb', 'body_rgb'} or None."""
    cols = row_colors(bgr, mask, prof)
    body = [c for t, c in cols if c is not None and 0.2 <= t <= 0.6]
    if not body:
        return None
    body_lab = np.median(np.array(body), 0)
    cap_rows, gap = [], 0
    for t, c in cols:                      # from the top down
        if c is None:
            continue
        if np.linalg.norm(c - body_lab) > threshold:
            cap_rows.append((t, c)); gap = 0
        else:
            gap += 1
            if cap_rows and gap > 2:
                break
            if not cap_rows and t < 0.9:  # cap must start at the very top
                break
    if not cap_rows:
        return None
    t_bottom = min(t for t, _ in cap_rows)
    frac = 1 - t_bottom
    if not 0.03 <= frac <= 0.35:
        return None
    cap_lab = np.median(np.array([c for _, c in cap_rows]), 0)
    return {'t_bottom': float(t_bottom), 'cap_rgb': lab_to_rgb01(cap_lab), 'body_rgb': lab_to_rgb01(body_lab)}


def body_color(bgr, mask) -> list[float]:
    core = cv2.erode(mask.astype(np.uint8), np.ones((9, 9), np.uint8)).astype(bool)
    hsv_v = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)[..., 2]
    px = bgr[core & (hsv_v < 245)]
    if len(px) == 0:
        px = bgr[mask]
    return (np.median(px, 0)[::-1] / 255).tolist()


def deskew_photo(source_png, mask: np.ndarray, occluded: np.ndarray | None = None, min_deg=0.4):
    """Rotate the (workspace copy of the) photo and its masks so the object's axis is vertical.
    Narrow views are very sensitive to a hand-held tilt. Returns (mask, occluded, angle_deg)."""
    from PIL import Image
    angle = float(np.degrees(np.arctan(Profile(mask, clip_protrusions=False).tilt())))
    if abs(angle) < min_deg:
        return mask, occluded, 0.0
    img = np.asarray(Image.open(source_png).convert('RGB'))
    h, w = mask.shape
    M = cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1.0)  # +: counter-clockwise, undoes a top-right lean
    Image.fromarray(cv2.warpAffine(img, M, (w, h), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)).save(source_png)
    rot = lambda a: cv2.warpAffine(a.astype(np.uint8), M, (w, h), flags=cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT, borderValue=0).astype(bool)
    m = rot(mask)
    o = rot(occluded) if occluded is not None else None
    return m, o, angle


def upright(mask: np.ndarray) -> np.ndarray:
    """Rotate the mask so the object's axis is vertical (small tilts only)."""
    prof = Profile(mask)
    angle = np.degrees(np.arctan(prof.tilt()))
    if abs(angle) < 0.3:
        return mask
    h, w = mask.shape
    M = cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1.0)  # +: counter-clockwise, undoes a top-right lean
    return cv2.warpAffine(mask.astype(np.uint8), M, (w, h), flags=cv2.INTER_NEAREST).astype(bool)


def flatten_ends(widths: np.ndarray, band=0.06) -> np.ndarray:
    """A flat end seen slightly from above/below shows as an elliptical arc that narrows the last rows.
    Replace that narrowing (within `band` of each end) by the width just inside it."""
    w = np.asarray(widths, float).copy()
    n = len(w)
    k = max(1, int(round(band * n)))
    if n > 2 * k + 1:
        w[:k] = np.maximum(w[:k], w[k])              # bottom band: never narrower than at the band edge
        w[n - k:] = np.maximum(w[n - k:], w[n - k - 1])
    return w
