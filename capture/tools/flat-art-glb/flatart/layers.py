"""Layer numbers and hidden-part completion for stacked paper pieces."""
import cv2
import numpy as np

from .rectify import dilate, fill_holes
from .segment import components


def assign_layers(pieces, ppm, touch_mm=1.0):
    """layer = 1 + max(layer of touching pieces from earlier groups), else 1."""
    grown = [dilate(p['mask'], touch_mm * ppm) for p in pieces]
    order = sorted(range(len(pieces)), key=lambda i: pieces[i]['group'])
    for i in order:
        below = [j for j in order if pieces[j]['group'] < pieces[i]['group'] and (grown[i] & pieces[j]['mask']).any()]
        pieces[i]['layer'] = 1 + max([pieces[j]['layer'] for j in below], default=0)
        pieces[i]['below'] = [pieces[j]['name'] for j in below]
    return pieces


def complete_hidden(pieces, ppm, seam_mm=0.8, hull_grow_mm=8.0, keep_in_mm=2.5):
    """Extend each lower piece underneath the pieces that cover it.

    For each upper piece U touching a lower piece L: bridge the seam between
    them, then add (dilated convex hull of L) & (U eroded by keep_in_mm), so
    the lower piece continues under U without ever showing past U's edge.
    The visible mask is kept as 'visible'.
    """
    for p in pieces:
        p['visible'] = p['mask'].copy()
    for lo in pieces:
        ups = [u for u in pieces if u['layer'] > lo['layer'] and lo['name'] in u.get('below', [])]
        if not ups:
            continue
        m = lo['visible'].copy()
        for u in ups:
            seam = dilate(m, seam_mm * ppm) & dilate(u['visible'], seam_mm * ppm) & ~u['visible']
            m = fill_holes(m | seam)
        hull = np.zeros(m.shape, np.uint8)
        pts = cv2.findNonZero(m.astype(np.uint8))
        cv2.fillConvexPoly(hull, cv2.convexHull(pts), 1)
        hull = hull.astype(bool)
        grown = dilate(hull, hull_grow_mm * ppm)
        for u in ups:
            inner = cv2.erode(u['visible'].astype(np.uint8), cv2.getStructuringElement(
                cv2.MORPH_ELLIPSE, (2 * int(round(keep_in_mm * ppm)) + 1,) * 2)).astype(bool)
            m |= (grown & inner) | (hull & u['visible'])
        m = fill_holes(m)
        comps = components(m)
        lo['mask'] = comps[0] if comps else m
        lo['hidden_mm2'] = round(float((lo['mask'] & ~lo['visible']).sum()) / (ppm * ppm), 1)
    return pieces
