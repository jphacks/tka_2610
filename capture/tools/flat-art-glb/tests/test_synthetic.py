"""End-to-end tests on a synthetic collage (no real photos, no network, no node).

Run from the repository root:
    python3 -m unittest discover -s tools/flat-art-glb/tests
"""
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from flatart import build as flat_build  # noqa: E402
from flatart import rectify  # noqa: E402

SHEET = (300.0, 400.0)            # mm, portrait
PPM = 2.0                         # synthetic sheet raster, px per mm
PHOTO_SIZE = (900, 1150)          # w, h
CORNERS = np.float32([[120, 90], [800, 130], [845, 1085], [70, 1040]])   # TL, TR, BR, BL in the photo

BLUE, RED, GREEN, WHITE, INK = (230, 200, 140), (40, 30, 215), (70, 150, 40), (238, 240, 240), (60, 50, 50)


def mm(p):
    return (int(round(p[0] * PPM)), int(round(p[1] * PPM)))


def ellipse(img, c, ax, color, angle=0):
    cv2.ellipse(img, mm(c), (int(ax[0] * PPM), int(ax[1] * PPM)), angle, 0, 360, color, -1, cv2.LINE_AA)


def make_sheet():
    w, h = int(SHEET[0] * PPM), int(SHEET[1] * PPM)
    img = np.zeros((h, w, 3), np.uint8)
    img[:] = BLUE
    # berry: white paper painted red, a thin white margin shows
    ellipse(img, (100, 170), (55, 75), WHITE)
    ellipse(img, (100, 172), (51, 71), RED)
    # calyx glued over the top of the berry
    ellipse(img, (100, 100), (45, 20), GREEN)
    # leaf, then a white flower over its top, with "handwriting"
    ellipse(img, (225, 340), (45, 14), GREEN, angle=-10)
    cv2.circle(img, mm((225, 300)), int(30 * PPM), WHITE, -1, cv2.LINE_AA)
    for x0 in (208, 222, 236):
        cv2.line(img, mm((x0, 293)), mm((x0 + 6, 307)), INK, 2, cv2.LINE_AA)
    return img


def make_photo():
    sheet = make_sheet()
    src = np.float32([[0, 0], [sheet.shape[1], 0], [sheet.shape[1], sheet.shape[0]], [0, sheet.shape[0]]])
    Hm = cv2.getPerspectiveTransform(src, CORNERS)
    bg = np.zeros((PHOTO_SIZE[1], PHOTO_SIZE[0], 3), np.uint8)
    bg[:] = (40, 55, 75)                                # dark floor
    photo = cv2.warpPerspective(sheet, Hm, PHOTO_SIZE, dst=bg, flags=cv2.INTER_LINEAR,
                                borderMode=cv2.BORDER_TRANSPARENT)
    # mild shading: brighter at the top left
    yy, xx = np.mgrid[0:PHOTO_SIZE[1], 0:PHOTO_SIZE[0]].astype(np.float32)
    shade = 1.05 - 0.15 * (xx / PHOTO_SIZE[0] + yy / PHOTO_SIZE[1]) / 2
    photo = photo.astype(np.float32) * shade[..., None]
    photo += np.random.default_rng(1).normal(0, 2.0, photo.shape)
    return np.clip(photo, 0, 255).astype(np.uint8), Hm


def frac(Hm, x_mm, y_mm):
    p = cv2.perspectiveTransform(np.float32([[[x_mm * PPM, y_mm * PPM]]]), Hm)[0, 0]
    return [float(p[0] / (PHOTO_SIZE[0] - 1)), float(p[1] / (PHOTO_SIZE[1] - 1))]


def read_glb(path):
    data = Path(path).read_bytes()
    magic, version, length = struct.unpack('<4sII', data[:12])
    clen, ctype = struct.unpack('<I4s', data[12:20])
    js = json.loads(data[20:20 + clen])
    return magic, version, length, len(data), ctype, js


class SyntheticCollageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        d = Path(cls.tmp.name)
        photo, Hm = make_photo()
        cv2.imwrite(str(d / 'photo.png'), photo)
        cls.Hm = Hm
        cls.cfg = {
            'photo': 'photo.png',
            'mode': 'layers',
            'sheet': {'size_mm': list(SHEET), 'thickness_mm': 0.3},
            'colors': {'backing': [frac(Hm, 270, 40)], 'red': [frac(Hm, 100, 190)],
                       'green': [frac(Hm, 100, 95)], 'white': [frac(Hm, 225, 278)]},
            'backing': 'backing',
            'stack': [['red', 'white'], ['green'], ['white']],
            'white_reference': 'white',
            'min_piece_mm2': 150,
        }
        (d / 'collage.json').write_text(json.dumps(cls.cfg))
        cls.report = flat_build.build(d / 'collage.json', d / 'out', log=lambda *a: None)
        cls.out = d / 'out'

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_corners(self):
        got = np.array(self.report['sheet']['corners_px'])
        err = np.abs(got - CORNERS).max()
        self.assertLess(err, 3.0, got)

    def test_pieces_and_layers(self):
        pieces = {p['name']: p for p in self.report['pieces']}
        self.assertEqual(sorted(pieces), ['green_1', 'green_2', 'red_1', 'white_1'])
        self.assertEqual(pieces['red_1']['layer'], 1)
        self.assertEqual(pieces['green_1']['layer'], 2)          # calyx, on the berry
        self.assertEqual(pieces['green_2']['layer'], 1)          # leaf, on the backing
        self.assertEqual(pieces['white_1']['layer'], 2)          # flower, on the leaf
        self.assertEqual(pieces['green_1']['on_top_of'], ['red_1'])
        self.assertEqual(pieces['white_1']['on_top_of'], ['green_2'])
        # the berry continues under the calyx
        self.assertGreater(pieces['red_1']['hidden_area_mm2'], 300)
        # bounding boxes close to the drawn shapes (mm)
        b = pieces['red_1']['bbox_mm']
        np.testing.assert_allclose([b[0], b[2], b[3]], [45, 155, 245], atol=3)
        # visible part starts below the calyx (y ~ 117); completed part reaches
        # under it but stays inside the calyx (y > 80)
        self.assertTrue(85 < b[1] < 112, b)
        np.testing.assert_allclose(pieces['white_1']['bbox_mm'], [195, 270, 255, 330], atol=3)
        # plain green paper -> flat colour; flower with ink -> photo texture
        self.assertEqual(pieces['green_2']['appearance'], 'flat_color')
        self.assertEqual(pieces['white_1']['appearance'], 'photo_texture')

    def test_glb(self):
        magic, version, length, size, ctype, js = read_glb(self.out / 'model.glb')
        self.assertEqual((magic, version, ctype), (b'glTF', 2, b'JSON'))
        self.assertEqual(length, size)
        self.assertEqual(js['asset']['version'], '2.0')
        names = [n['name'] for n in js['nodes']]
        for n in ('backing_sheet', 'red_1', 'green_1', 'green_2', 'white_1'):
            self.assertIn(n, names)
        W, H = SHEET[0] / 1000, SHEET[1] / 1000
        for acc in js['accessors']:
            if 'min' in acc:
                self.assertGreaterEqual(acc['min'][0], -W / 2 - 1e-6)
                self.assertLessEqual(acc['max'][0], W / 2 + 1e-6)
                self.assertGreaterEqual(acc['min'][1], -1e-6)
                self.assertLessEqual(acc['max'][1], H + 1e-6)
                self.assertGreaterEqual(acc['min'][2], -0.0003 - 1e-6)
                self.assertLessEqual(acc['max'][2], 0.002)
        for m in js['materials']:
            self.assertEqual(m['pbrMetallicRoughness']['metallicFactor'], 0.0)

    def test_outputs(self):
        for f in ('model.glb', 'report.json', 'overlay.jpg'):
            self.assertTrue((self.out / f).exists(), f)

    def test_plane_mode(self):
        d = Path(self.tmp.name)
        cfg = {'photo': 'photo.png', 'mode': 'plane', 'colors': {'paper': self.cfg['colors']['backing']},
               'backing': 'paper'}
        (d / 'plane.json').write_text(json.dumps(cfg))
        rep = flat_build.build(d / 'plane.json', d / 'out_plane', log=lambda *a: None)
        self.assertEqual(rep['pieces'], [])
        self.assertTrue(rep['sheet']['size_guessed'])
        self.assertEqual(rep['sheet']['orientation'], 'portrait')
        magic, version, length, size, ctype, js = read_glb(d / 'out_plane' / 'model.glb')
        self.assertEqual(magic, b'glTF')
        self.assertEqual(len(js['images']), 1)
        self.assertEqual(rep['glb']['triangles'], 12)

    def test_plane_mode_with_given_corners_keeps_the_whole_sheet(self):
        # An already rectified picture (the sheet fills the image) with a dark stroke from edge to edge: the part
        # below the stroke is not connected to the rest of the paper, but it is inside the given corners.
        d = Path(self.tmp.name)
        w, h = 400, 560
        img = np.full((h, w, 3), WHITE, np.uint8)
        cv2.line(img, (0, 300), (w - 1, 290), INK, 6)
        cv2.rectangle(img, (100, 380), (300, 500), RED, -1)
        cv2.imwrite(str(d / 'rectified.png'), img)
        cfg = {'photo': 'rectified.png', 'mode': 'plane',
               'sheet': {'size_mm': [200, 280], 'corners': [[0, 0], [1, 0], [1, 1], [0, 1]]},
               'colors': {'paper': [[0.03, 0.03], [0.97, 0.03]]}, 'backing': 'paper'}
        (d / 'rectified.json').write_text(json.dumps(cfg))
        rep = flat_build.build(d / 'rectified.json', d / 'out_rectified', log=lambda *a: None)
        self.assertEqual(rep['sheet']['corners_source'], 'config')
        data = (d / 'out_rectified' / 'model.glb').read_bytes()
        clen = struct.unpack('<I', data[12:16])[0]
        js = json.loads(data[20:20 + clen])
        binary = data[20 + clen + 8:]
        view = js['bufferViews'][js['images'][0]['bufferView']]
        tex = cv2.imdecode(np.frombuffer(binary[view['byteOffset']:view['byteOffset'] + view['byteLength']], np.uint8),
                           cv2.IMREAD_COLOR)
        # the red rectangle below the stroke survives (it would be inpainted with paper colour otherwise)
        cy, cx = int(tex.shape[0] * 440 / h), int(tex.shape[1] * 0.5)
        b, g, r = tex[cy, cx].astype(int)
        self.assertGreater(r - max(b, g), 80, tex[cy, cx])


class RectifyTest(unittest.TestCase):
    def test_guess_size(self):
        q = np.array([[0, 0], [297, 0], [297, 420], [0, 420]], float)
        name, size, _ = rectify.guess_sheet_size(q)
        self.assertAlmostEqual(size[1] / size[0], 420 / 297, places=1)
        q = np.array([[0, 0], [542, 0], [542, 392], [0, 392]], float)
        self.assertEqual(rectify.sheet_orientation(q), 'landscape')
        self.assertEqual(rectify.oriented_size((392, 542), q), (542.0, 392.0))

    def test_round_trip(self):
        r = rectify.Rectifier(CORNERS, SHEET, (PHOTO_SIZE[1], PHOTO_SIZE[0]))
        x, y = np.array([10.0, 150.0, 290.0]), np.array([20.0, 200.0, 390.0])
        px, py = r.sheet_to_photo(x, y)
        xb, yb = r.photo_to_sheet(px, py)
        np.testing.assert_allclose(xb, x, atol=1e-6)
        np.testing.assert_allclose(yb, y, atol=1e-6)


if __name__ == '__main__':
    unittest.main()
