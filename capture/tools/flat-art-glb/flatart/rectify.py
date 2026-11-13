"""Sheet detection and perspective rectification.

Sheet coordinates are millimetres on the ideal sheet rectangle: x to the
right, y downwards, origin at the top-left corner of the sheet.
"""
import cv2
import numpy as np

# Common paper sizes, (short, long) in mm.  Order = tie-break preference.
PAPER_SIZES = [
    ('yotsugiri', (392.0, 542.0)),
    ('yatsugiri', (271.0, 392.0)),
    ('A3', (297.0, 420.0)),
    ('B4', (257.0, 364.0)),
    ('A4', (210.0, 297.0)),
    ('B5', (182.0, 257.0)),
]


def load_photo(path):
    """Read a photo as 8-bit BGR (EXIF orientation applied, alpha dropped)."""
    img = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if img is None:
        raise FileNotFoundError('cannot read photo: %s' % path)
    return img


# ---------------------------------------------------------------- mask helpers
def disk(r_px):
    r = max(1, int(round(r_px)))
    return cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1))


def dilate(mask, r_px):
    if r_px <= 0:
        return mask.astype(bool)
    return cv2.dilate(mask.astype(np.uint8), disk(r_px)).astype(bool)


def erode(mask, r_px):
    if r_px <= 0:
        return mask.astype(bool)
    return cv2.erode(mask.astype(np.uint8), disk(r_px)).astype(bool)


def close(mask, r_px):
    return cv2.morphologyEx(mask.astype(np.uint8), cv2.MORPH_CLOSE, disk(r_px)).astype(bool)


def open_(mask, r_px):
    return cv2.morphologyEx(mask.astype(np.uint8), cv2.MORPH_OPEN, disk(r_px)).astype(bool)


def fill_holes(mask):
    m = mask.astype(np.uint8)
    pad = cv2.copyMakeBorder(m, 1, 1, 1, 1, cv2.BORDER_CONSTANT, value=0)
    cv2.floodFill(pad, None, (0, 0), 2)
    return mask.astype(bool) | (pad[1:-1, 1:-1] == 0)


def largest_component(mask):
    n, lab, st, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), connectivity=8)
    if n <= 1:
        return np.zeros(mask.shape, bool)
    return lab == 1 + int(np.argmax(st[1:, cv2.CC_STAT_AREA]))


# ---------------------------------------------------------------- sheet mask
def sheet_mask(backing_mask):
    """Paper region in the photo from the pixels classified as backing colour.

    Close small gaps, keep the largest blob and fill its holes (the pieces on
    top of the sheet are holes in the backing mask).
    """
    h, w = backing_mask.shape
    r = max(2.0, 0.006 * min(h, w))
    m = close(open_(backing_mask, 1), r)
    m = largest_component(m)
    m = fill_holes(m)
    # a wider closing bridges notches where a piece reaches the sheet edge
    m = fill_holes(close(m, 2.5 * r))
    return m


# ---------------------------------------------------------------- line fitting
def _order_quad(q):
    """Order four points TL, TR, BR, BL (image y down)."""
    q = np.asarray(q, float).reshape(4, 2)
    c = q.mean(0)
    ang = np.arctan2(q[:, 1] - c[1], q[:, 0] - c[0])
    q = q[np.argsort(ang)]                    # clockwise on screen (y down)
    start = int(np.argmin(q[:, 0] + q[:, 1]))
    return np.roll(q, -start, axis=0)


def _rough_quad(contour):
    hull = cv2.convexHull(contour.astype(np.float32))
    peri = cv2.arcLength(hull, True)
    for f in np.linspace(0.01, 0.2, 40):
        ap = cv2.approxPolyDP(hull, f * peri, True)
        if len(ap) == 4:
            return _order_quad(ap.reshape(4, 2))
        if len(ap) < 4:
            break
    return _order_quad(cv2.boxPoints(cv2.minAreaRect(hull)))


def fit_line_robust(pts, scale=1.5, iters=30):
    """Total-least-squares line through pts with Cauchy reweighting.

    Returns (normal n, offset c) with n . p = c, plus the final weights.
    """
    pts = np.asarray(pts, float)
    w = np.ones(len(pts))
    n, c = np.array([0.0, 1.0]), 0.0
    for _ in range(iters):
        cen = (pts * w[:, None]).sum(0) / w.sum()
        d = pts - cen
        cov = (d * w[:, None]).T @ d
        evals, evecs = np.linalg.eigh(cov)
        n = evecs[:, 0]
        c = float(n @ cen)
        r = pts @ n - c
        w = 1.0 / (1.0 + (r / scale) ** 2)
    return n, c, w


def _intersect(l1, l2):
    A = np.array([l1[0], l2[0]])
    b = np.array([l1[1], l2[1]])
    return np.linalg.solve(A, b)


def fit_sheet_quad(mask, t_range=(0.1, 0.9)):
    """Corners (TL, TR, BR, BL, photo px) of the sheet from its mask.

    Boundary samples on the image border are ignored (the sheet may run out
    of the frame); samples near the corners are ignored (dog-ears); the rest
    of each side is fitted with a robust line and the corners are the line
    intersections.
    """
    h, w = mask.shape
    cs, _ = cv2.findContours(mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    if not cs:
        raise RuntimeError('sheet not found (no backing-colour region)')
    cnt = max(cs, key=cv2.contourArea).reshape(-1, 2).astype(float)
    on_border = (cnt[:, 0] <= 1) | (cnt[:, 1] <= 1) | (cnt[:, 0] >= w - 2) | (cnt[:, 1] >= h - 2)
    quad = _rough_quad(cnt)
    sides = []
    for tol in (0.06, 0.025, 0.012):
        lines, sides = [], []
        for i in range(4):
            p0, p1 = quad[i], quad[(i + 1) % 4]
            d = p1 - p0
            L = np.linalg.norm(d)
            u = d / L
            nrm = np.array([-u[1], u[0]])
            t = (cnt - p0) @ u / L
            r = (cnt - p0) @ nrm
            sel = (t > t_range[0]) & (t < t_range[1]) & (np.abs(r) < tol * L) & ~on_border
            info = {'samples': int(sel.sum())}
            if sel.sum() >= 20:
                n, c, wt = fit_line_robust(cnt[sel])
                res = cnt[sel] @ n - c
                inl = np.abs(res) < 3.0
                info.update(inliers=int(inl.sum()), rms_px=float(np.sqrt(np.mean(res[inl] ** 2))) if inl.any() else None)
            else:
                n = nrm
                c = float(nrm @ p0)
                info.update(inliers=0, rms_px=None, fallback=True)
            lines.append((n, c))
            sides.append(info)
        # lines: 0 top, 1 right, 2 bottom, 3 left
        quad = np.array([_intersect(lines[3], lines[0]), _intersect(lines[0], lines[1]),
                         _intersect(lines[1], lines[2]), _intersect(lines[2], lines[3])])
    names = ['top', 'right', 'bottom', 'left']
    return quad, {names[i]: sides[i] for i in range(4)}


def quad_side_lengths(quad):
    q = np.asarray(quad, float)
    top = np.linalg.norm(q[1] - q[0])
    right = np.linalg.norm(q[2] - q[1])
    bottom = np.linalg.norm(q[3] - q[2])
    left = np.linalg.norm(q[0] - q[3])
    return top, right, bottom, left


def sheet_orientation(quad):
    top, right, bottom, left = quad_side_lengths(quad)
    return 'portrait' if (left + right) >= (top + bottom) else 'landscape'


def guess_sheet_size(quad):
    """Guess the paper size from the quad's aspect ratio (scale is unknown)."""
    top, right, bottom, left = quad_side_lengths(quad)
    hor, ver = (top + bottom) / 2, (left + right) / 2
    aspect = max(hor, ver) / min(hor, ver)
    best = min(PAPER_SIZES, key=lambda s: abs(s[1][1] / s[1][0] - aspect) - 1e-3 * (len(PAPER_SIZES) - PAPER_SIZES.index(s)))
    return best[0], best[1], aspect


def oriented_size(size_mm, quad):
    a, b = sorted(float(v) for v in size_mm)
    return (a, b) if sheet_orientation(quad) == 'portrait' else (b, a)


# ---------------------------------------------------------------- homography
class Rectifier:
    """Homography between the photo (px) and the sheet rectangle (mm)."""

    def __init__(self, corners_px, size_mm, photo_shape):
        self.corners = np.asarray(corners_px, np.float32).reshape(4, 2)
        self.w_mm, self.h_mm = float(size_mm[0]), float(size_mm[1])
        self.photo_shape = tuple(photo_shape[:2])
        dst = np.float32([[0, 0], [self.w_mm, 0], [self.w_mm, self.h_mm], [0, self.h_mm]])
        self.H = cv2.getPerspectiveTransform(self.corners, dst)       # photo px -> sheet mm
        self.Hinv = np.linalg.inv(self.H)

    @staticmethod
    def _apply(M, x, y):
        x, y = np.asarray(x, float), np.asarray(y, float)
        den = M[2, 0] * x + M[2, 1] * y + M[2, 2]
        return (M[0, 0] * x + M[0, 1] * y + M[0, 2]) / den, (M[1, 0] * x + M[1, 1] * y + M[1, 2]) / den

    def sheet_to_photo(self, x_mm, y_mm):
        return self._apply(self.Hinv, x_mm, y_mm)

    def photo_to_sheet(self, px, py):
        return self._apply(self.H, px, py)

    def native_px_per_mm(self):
        """(median, min, max) photo pixels per mm over the sheet."""
        xs = np.linspace(0.05, 0.95, 9) * self.w_mm
        ys = np.linspace(0.05, 0.95, 9) * self.h_mm
        X, Y = np.meshgrid(xs, ys)
        e = 0.5
        px0, py0 = self.sheet_to_photo(X - e, Y)
        px1, py1 = self.sheet_to_photo(X + e, Y)
        qx0, qy0 = self.sheet_to_photo(X, Y - e)
        qx1, qy1 = self.sheet_to_photo(X, Y + e)
        jx = np.stack([px1 - px0, py1 - py0], -1) / (2 * e)
        jy = np.stack([qx1 - qx0, qy1 - qy0], -1) / (2 * e)
        s = np.sqrt(np.abs(jx[..., 0] * jy[..., 1] - jx[..., 1] * jy[..., 0]))
        return float(np.median(s)), float(s.min()), float(s.max())

    def _matrix(self, window, ppm):
        x0, y0 = window[0], window[1]
        S = np.array([[ppm, 0, -x0 * ppm - 0.5], [0, ppm, -y0 * ppm - 0.5], [0, 0, 1]], float)
        return S @ self.H

    def warp(self, img, ppm, window=None, interp=cv2.INTER_LINEAR, border_value=None):
        """Resample `img` (photo space) onto a sheet-space window.

        window = (x0, y0, w, h) in mm (default: the whole sheet).  Pixel
        centres are at x0 + (i + 0.5) / ppm.  Returns (image, seen) where
        `seen` marks pixels that came from inside the photo frame.
        """
        if window is None:
            window = (0.0, 0.0, self.w_mm, self.h_mm)
        nx = max(1, int(round(window[2] * ppm)))
        ny = max(1, int(round(window[3] * ppm)))
        M = self._matrix(window, ppm)
        if border_value is None:
            out = cv2.warpPerspective(img, M, (nx, ny), flags=interp, borderMode=cv2.BORDER_REPLICATE)
        else:
            out = cv2.warpPerspective(img, M, (nx, ny), flags=interp, borderMode=cv2.BORDER_CONSTANT,
                                      borderValue=border_value)
        inside = np.zeros(self.photo_shape, np.uint8)
        inside[1:-1, 1:-1] = 255
        seen = cv2.warpPerspective(inside, M, (nx, ny), flags=cv2.INTER_NEAREST,
                                   borderMode=cv2.BORDER_CONSTANT, borderValue=0) > 0
        return out, seen

    def warp_mask(self, mask, ppm, window=None):
        out, _ = self.warp(mask.astype(np.uint8) * 255, ppm, window, interp=cv2.INTER_LINEAR, border_value=0)
        return out > 127


def window_grid(window, ppm):
    """Pixel-centre coordinates (mm) of a sheet window raster."""
    x0, y0, w, h = window
    nx, ny = max(1, int(round(w * ppm))), max(1, int(round(h * ppm)))
    return np.meshgrid(x0 + (np.arange(nx) + 0.5) / ppm, y0 + (np.arange(ny) + 0.5) / ppm)


def resample_field(field, field_ppm, window, ppm, interp=cv2.INTER_LINEAR, border_value=None):
    """Resample a full-sheet raster (origin at the sheet corner) onto a window."""
    X, Y = window_grid(window, ppm)
    mx = (X * field_ppm - 0.5).astype(np.float32)
    my = (Y * field_ppm - 0.5).astype(np.float32)
    if border_value is None:
        return cv2.remap(field, mx, my, interp, borderMode=cv2.BORDER_REPLICATE)
    return cv2.remap(field, mx, my, interp, borderMode=cv2.BORDER_CONSTANT, borderValue=border_value)
