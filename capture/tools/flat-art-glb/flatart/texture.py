"""Appearance: illumination correction, white balance, inpainting, textures."""
import cv2
import numpy as np

from .rectify import erode, resample_field
from .segment import to_lab, LAB_WEIGHTS

MAX_TEX = 2048


def blur(img, sigma_px, max_direct=6.0):
    """Gaussian blur; large sigmas run on a down-sampled copy (approximate, fast)."""
    if sigma_px <= 0.05:
        return img.copy()
    if sigma_px <= max_direct:
        return cv2.GaussianBlur(img, (0, 0), sigmaX=float(sigma_px), sigmaY=float(sigma_px),
                                borderType=cv2.BORDER_REFLECT)
    h, w = img.shape[:2]
    f = max_direct / sigma_px
    sw, sh = max(1, int(round(w * f))), max(1, int(round(h * f)))
    small = cv2.resize(img, (sw, sh), interpolation=cv2.INTER_AREA)
    s_eff = np.sqrt(max(sigma_px ** 2 - (0.5 / f) ** 2, 0.25)) * (sw / w)
    small = cv2.GaussianBlur(small, (0, 0), sigmaX=float(s_eff), sigmaY=float(s_eff),
                             borderType=cv2.BORDER_REFLECT)
    return cv2.resize(small, (w, h), interpolation=cv2.INTER_LINEAR)


def normconv_fill(img, valid, sigmas_px):
    """Fill invalid pixels from valid neighbours with a fine-to-coarse cascade
    of normalised convolutions.  Valid pixels are returned untouched."""
    img = img.astype(np.float32)
    w = valid.astype(np.float32)
    three = img.ndim == 3
    w3 = w[..., None] if three else w
    out = np.zeros_like(img)
    acc = np.zeros(valid.shape, np.float32)
    for s in sigmas_px:
        num, den = blur(img * w3, s), blur(w, s)
        conf = np.clip(den / 0.05, 0, 1) * (1 - acc)
        d = np.maximum(den, 1e-6)
        out += (num / (d[..., None] if three else d)) * (conf[..., None] if three else conf)
        acc += conf
    med = np.median(img[valid], axis=0) if valid.any() else (np.zeros(3, np.float32) + 128 if three else 128.0)
    rem = 1 - acc
    out += (rem[..., None] if three else rem) * med
    return np.where(valid[..., None] if three else valid, img, out)


def fill_sigmas(ppm, max_mm):
    """Inpainting scales from 0.5 mm up to max_mm."""
    s, out = 0.5, []
    while s < max_mm:
        out.append(s * ppm)
        s *= 3
    out.append(max_mm * ppm)
    return out


# ---------------------------------------------------------------- illumination
class Appearance:
    """Photo colour correction: smooth per-channel gain map + white balance.

    The gain map is estimated where the backing paper is visible, assuming the
    backing has one uniform colour; it maps every pixel to the colour it would
    have under the backing's median illumination.
    """

    def __init__(self, gain, gain_ppm, wb=(1.0, 1.0, 1.0)):
        self.gain = gain.astype(np.float32)
        self.gain_ppm = float(gain_ppm)
        self.wb = np.asarray(wb, np.float32)

    @classmethod
    def estimate(cls, rect_bgr, rect_ppm, backing_valid, sigma_mm=28.0, wide_mm=70.0, low_ppm=1.0):
        f = low_ppm / rect_ppm
        size = (max(1, int(round(rect_bgr.shape[1] * f))), max(1, int(round(rect_bgr.shape[0] * f))))
        small = cv2.resize(rect_bgr.astype(np.float32), size, interpolation=cv2.INTER_AREA)
        ws = cv2.resize(backing_valid.astype(np.float32), size, interpolation=cv2.INTER_AREA)
        if not backing_valid.any():
            return cls(np.ones(small.shape, np.float32), low_ppm)
        num, den = blur(small * ws[..., None], sigma_mm * low_ppm), blur(ws, sigma_mm * low_ppm)
        num2, den2 = blur(small * ws[..., None], wide_mm * low_ppm), blur(ws, wide_mm * low_ppm)
        conf = np.clip(den / 0.08, 0, 1)[..., None]
        ill = conf * num / np.maximum(den, 1e-6)[..., None] + \
            (1 - conf) * num2 / np.maximum(den2, 1e-6)[..., None]
        # far away from any backing pixel: global median
        ref = np.median(rect_bgr[backing_valid].astype(np.float32), axis=0)
        far = (den2 < 1e-3)[..., None]
        ill = np.where(far, ref, ill)
        gain = np.clip(ref / np.maximum(ill, 1.0), 0.7, 1.5)
        return cls(gain, low_ppm)

    def set_white(self, white_bgr_corrected, max_lift=1.2, target=225.0):
        """Neutralise the reference white and lift it towards `target`."""
        wv = np.asarray(white_bgr_corrected, np.float32)
        g = float(wv.mean())
        lift = float(np.clip(target / max(g, 1.0), 1.0, max_lift))
        self.wb = (g * lift / np.maximum(wv, 1.0)).astype(np.float32)
        return self.wb

    def correct(self, img, window, ppm):
        g = resample_field(self.gain, self.gain_ppm, window, ppm)
        return img.astype(np.float32) * g * self.wb


# ---------------------------------------------------------------- textures
def texture_ppm(window, native_ppm, factor=2.0, max_px=MAX_TEX):
    return float(min(factor * native_ppm, max_px / max(window[2], window[3])))


def is_uniform(img_bgr, valid, tol=12.0, detail_frac=0.003):
    """True if the valid pixels are close to one colour (weighted Lab).

    Not uniform when the typical spread is large (p90 > tol / 2) or when more
    than `detail_frac` of the pixels differ strongly (> 1.4 tol), e.g. a
    handwritten name on a plain paper piece.
    """
    if valid.sum() < 20:
        return True
    lab = to_lab(np.clip(img_bgr, 0, 255).astype(np.uint8))[valid]
    med = np.median(lab, axis=0)
    d = np.sqrt((((lab - med) * LAB_WEIGHTS) ** 2).sum(1))
    return bool(np.percentile(d, 90) < 0.5 * tol and float((d > 1.4 * tol).mean()) < detail_frac)


def median_color(img_bgr, valid):
    if not valid.any():
        return np.array([200.0, 200.0, 200.0])
    return np.median(img_bgr[valid].astype(np.float32), axis=0)


def piece_texture(photo, rectifier, appearance, piece_mask_fn, cover_mask_fn, window, ppm, rim_mm=0.8,
                  cover_margin_mm=0.4, rim_keep_fn=None, rim_inner_mm=0.25):
    """Photo texture for one piece, sampled from the original photo.

    piece_mask_fn / cover_mask_fn(window, ppm) -> bool rasters of the piece and
    of the pieces lying on top of it.  The rim (rim_mm wide) and the covered
    areas are inpainted from the piece's interior.  rim_keep_fn(raw_bgr) ->
    bool raster, optional: rim pixels it marks (e.g. pixels classified as one
    of the piece's own colours) are kept, so thin margins survive; only the
    outermost rim_inner_mm is always replaced.  Interior pixels are never
    restricted by colour (handwriting stays).
    Returns (bgr uint8, valid mask, piece mask).
    """
    raw, seen = rectifier.warp(photo, ppm, window, interp=cv2.INTER_CUBIC)
    img = appearance.correct(raw, window, ppm)
    piece = piece_mask_fn(window, ppm)
    cover = cover_mask_fn(window, ppm)
    if cover is not None and cover.any():
        cover = cv2.dilate(cover.astype(np.uint8), cv2.getStructuringElement(
            cv2.MORPH_ELLIPSE, (2 * max(1, int(round(cover_margin_mm * ppm))) + 1,) * 2)).astype(bool)
    else:
        cover = np.zeros(piece.shape, bool)
    keep = erode(piece, rim_mm * ppm)
    if rim_keep_fn is not None:
        keep |= erode(piece, rim_inner_mm * ppm) & rim_keep_fn(raw)
    valid = keep & ~cover & seen
    if valid.sum() < 20:
        valid = piece & seen
    span = max(window[2], window[3])
    filled = normconv_fill(img, valid, fill_sigmas(ppm, max(2.0, span / 4)))
    return np.clip(filled, 0, 255).astype(np.uint8), valid, piece


def encode_jpg(bgr, q=88):
    ok, buf = cv2.imencode('.jpg', bgr, [cv2.IMWRITE_JPEG_QUALITY, int(q)])
    if not ok:
        raise RuntimeError('JPEG encoding failed')
    return buf.tobytes()


def srgb_to_linear(c255):
    c = np.asarray(c255, float) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
