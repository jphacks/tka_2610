"""Colour classification and piece extraction.

Colours are compared in CIE Lab with the lightness down-weighted, so that
shading on one paper colour stays in one class.
"""
import cv2
import numpy as np

from .rectify import close, fill_holes, open_

UNKNOWN = -1
LAB_WEIGHTS = np.array([0.5, 1.0, 1.0], np.float32)


def to_lab(bgr):
    """8-bit BGR -> float Lab (L 0..100, a/b roughly -128..127)."""
    return cv2.cvtColor(bgr.astype(np.float32) / 255.0, cv2.COLOR_BGR2LAB)


class ColorClassifier:
    """Nearest-prototype classifier in weighted Lab."""

    def __init__(self, names, prototypes, max_dist=22.0, weights=LAB_WEIGHTS):
        self.names = list(names)
        self.protos = [np.asarray(p, np.float32).reshape(-1, 3) for p in prototypes]
        self.max_dist = float(max_dist)
        self.weights = np.asarray(weights, np.float32)

    def index(self, name):
        return self.names.index(name)

    @classmethod
    def fit(cls, photo_bgr, colors, k=3, max_dist=22.0, window_frac=0.006, seed_dist=18.0, rng_seed=0):
        """Prototypes from sample points (fractions of photo width/height).

        Each sample gives a seed colour (median in a small window).  The seeds
        then classify a down-sampled photo, and k-means inside the pixels close
        to each class adds prototypes that cover its shading range.
        """
        h, w = photo_bgr.shape[:2]
        lab = to_lab(photo_bgr)
        r = max(2, int(round(window_frac * min(h, w))))
        names, seeds = [], []
        for name, pts in colors.items():
            pts = np.asarray(pts, float).reshape(-1, 2)
            s = []
            for fx, fy in pts:
                x, y = int(round(fx * (w - 1))), int(round(fy * (h - 1)))
                if not (0 <= x < w and 0 <= y < h):
                    raise ValueError('sample point of %r is outside the photo: %s' % (name, (fx, fy)))
                win = lab[max(0, y - r):y + r + 1, max(0, x - r):x + r + 1].reshape(-1, 3)
                s.append(np.median(win, axis=0))
            names.append(name)
            seeds.append(np.array(s, np.float32))
        clf = cls(names, seeds, max_dist)
        # refine on a down-sampled copy
        scale = min(1.0, np.sqrt(4e5 / (h * w)))
        small = cv2.resize(lab, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA) if scale < 1 else lab
        labels, dist = clf.classify_lab(small)
        flat_lab, flat_lbl, flat_d = small.reshape(-1, 3), labels.ravel(), dist.ravel()
        rng = np.random.default_rng(rng_seed)
        crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.2)
        protos = []
        for ci in range(len(names)):
            sel = (flat_lbl == ci) & (flat_d < seed_dist)
            pts = flat_lab[sel]
            if len(pts) > 30000:
                pts = pts[rng.choice(len(pts), 30000, replace=False)]
            kk = min(k, len(pts) // 50)
            if kk >= 2:
                cv2.setRNGSeed(rng_seed)
                _, _, cen = cv2.kmeans(pts.astype(np.float32), kk, None, crit, 3, cv2.KMEANS_PP_CENTERS)
                protos.append(np.concatenate([seeds[ci], cen]).astype(np.float32))
            else:
                protos.append(seeds[ci])
        clf.protos = protos
        return clf

    def classify_lab(self, lab):
        """Returns (labels int16, UNKNOWN = -1; weighted distance to the winner)."""
        shp = lab.shape[:2]
        x = lab.reshape(-1, 3) * self.weights
        best = np.full(x.shape[0], np.inf, np.float32)
        lbl = np.full(x.shape[0], UNKNOWN, np.int16)
        for ci, P in enumerate(self.protos):
            for p in P * self.weights:
                d = ((x - p) ** 2).sum(1)
                b = d < best
                best[b] = d[b]
                lbl[b] = ci
        best = np.sqrt(best)
        lbl[best > self.max_dist] = UNKNOWN
        return lbl.reshape(shp), best.reshape(shp)

    def classify(self, bgr):
        return self.classify_lab(to_lab(bgr))

    def describe(self):
        out = {}
        for n, P in zip(self.names, self.protos):
            out[n] = [[round(float(v), 1) for v in p] for p in P]
        return out


# ---------------------------------------------------------------- pieces
def components(mask, min_px=1):
    n, lab, st, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), connectivity=8)
    out = [lab == i for i in range(1, n) if st[i, cv2.CC_STAT_AREA] >= min_px]
    return sorted(out, key=lambda m: -int(m.sum()))


def extract_pieces(labels, names, stack, domain, ppm, min_piece_mm2=150.0, primary_share=0.35,
                   clean_mm=0.5, bridge_mm=2.0):
    """Cut the classified raster into paper pieces, group by group.

    stack: list of groups (bottom to top); each group is a list of colour
    names, the first being the primary colour.  A connected component of the
    union of the group's colours becomes a piece only if at least
    `primary_share` of it is the primary colour; otherwise its pixels stay
    available for the following groups.

    Returns a list of dicts: name, group (index), colors, mask (bool raster).
    """
    available = domain.copy()
    min_px = min_piece_mm2 * ppm * ppm
    pieces, dropped = [], []
    for gi, group in enumerate(stack):
        ids = [names.index(c) for c in group]
        prim = ids[0]
        union = np.isin(labels, ids) & available
        union = close(open_(union, clean_mm * ppm), clean_mm * ppm) & domain
        # transition pixels between the group's colours (e.g. paint soaking
        # into a white margin) match no colour: let a wider closing take them
        union |= close(union, bridge_mm * ppm) & (labels == UNKNOWN) & available & domain
        count = 0
        for comp in components(union, min_px=max(1, int(0.2 * min_px))):
            share = float((comp & (labels == prim)).sum()) / float(comp.sum())
            if share < primary_share:
                continue
            m = fill_holes(comp) & domain
            area = float(m.sum()) / (ppm * ppm)
            if area < min_piece_mm2:
                dropped.append({'group': gi, 'area_mm2': round(area, 1)})
                continue
            count += 1
            pieces.append({'name': '%s_%d' % (group[0], count), 'group': gi, 'colors': list(group),
                           'mask': m, 'primary_share': round(share, 3)})
            available &= ~m
    # stable names: within a group, number pieces top-to-bottom, left-to-right
    for gi in range(len(stack)):
        grp = [p for p in pieces if p['group'] == gi]
        def key(p):
            ys, xs = np.nonzero(p['mask'])
            return (round(ys.mean() / (20 * ppm)), xs.mean())
        for i, p in enumerate(sorted(grp, key=key)):
            p['name'] = '%s_%d' % (stack[gi][0], i + 1)
    return pieces, dropped
