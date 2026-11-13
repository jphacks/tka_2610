"""Tests on a synthetic photo: a box with round parts seen in perspective (no real photos, no Node.js)."""
import json, struct, sys, tempfile, unittest
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import solidglb as sg

W_MM, D_MM = 200.0, 120.0
KNOBS = [(60.0, 50.0), (140.0, 70.0)]          # true centres (x from the left, z from the back), 24 mm wide


def synthetic_photo(folder):
    """Render the top of the box through a pinhole camera; returns the photo size and the corner pixels."""
    ppm = 5.0
    top = np.full((int(D_MM * ppm), int(W_MM * ppm), 3), (205, 180, 120), np.uint8)
    for x in range(0, top.shape[1], 50):
        cv2.line(top, (x, 0), (x + 200, top.shape[0]), (150, 120, 90), 6)
    for x, z in KNOBS:
        cv2.circle(top, (int(x * ppm), int(z * ppm)), int(12 * ppm), (40, 40, 40), -1)
        cv2.circle(top, (int(x * ppm), int(z * ppm)), int(8 * ppm), (90, 90, 90), -1)
    w, h, f = 1200, 900, 1100.0
    ax, ay = np.radians(28), np.radians(12)                      # tilt and turn of the plane
    Rx = np.array([[1, 0, 0], [0, np.cos(ax), -np.sin(ax)], [0, np.sin(ax), np.cos(ax)]])
    Ry = np.array([[np.cos(ay), 0, np.sin(ay)], [0, 1, 0], [-np.sin(ay), 0, np.cos(ay)]])
    P = np.array([[0, 0], [W_MM, 0], [W_MM, D_MM], [0, D_MM]], float)
    X = np.c_[P - [W_MM / 2, D_MM / 2], np.zeros(4)] @ (Ry @ Rx).T + [0, 0, 330.0]
    px = np.stack([f * X[:, 0] / X[:, 2] + w / 2, f * X[:, 1] / X[:, 2] + h / 2], 1)
    Hm = cv2.getPerspectiveTransform((P * ppm).astype(np.float32), px.astype(np.float32))
    photo = np.full((h, w, 3), (236, 236, 232), np.uint8)
    cv2.warpPerspective(top, Hm, (w, h), dst=photo, borderMode=cv2.BORDER_TRANSPARENT)
    cv2.imwrite(str(folder / 'top.png'), photo)
    to_photo = lambda pts: cv2.perspectiveTransform((np.asarray(pts, np.float32) * ppm)[None], Hm)[0] / [w, h]
    return px / [w, h], to_photo


class SlabTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(); d = Path(cls.tmp.name)
        corners, to_photo = synthetic_photo(d)
        inner = to_photo([[2, 2], [W_MM - 2, 2], [W_MM - 2, D_MM - 2], [2, D_MM - 2]])
        cfg = {'template': 'slab', 'top': {'photo': 'top.png', 'corners': corners.tolist(), 'width_mm': W_MM},
               'outline': inner.tolist(), 'outline_round_mm': 4,
               'layers': [{'name': 'base', 'height_mm': 20, 'inset_mm': 3}, {'name': 'lid', 'height_mm': 4, 'texture': 'top'}],
               'features': [{'name': 'knobs', 'shape': 'button', 'diameter_mm': 24, 'height_mm': 6, 'texture': 'top',
                             'at': to_photo([[x + 2.0, z - 1.5] for x, z in KNOBS]).tolist()}],          # deliberately off
               'side_marks': [{'name': 'port', 'layer': 'base', 'side': 'back', 'size_mm': [9, 3]}]}
        (d / 'cfg.json').write_text(json.dumps(cfg))
        cls.out = d / 'out'; cls.out.mkdir()
        cls.rep = sg.build_slab(cfg, d, cls.out)
        raw = (cls.out / 'model.glb').read_bytes()
        cls.magic, _, cls.total = struct.unpack('<4sII', raw[:12])
        n = struct.unpack('<I', raw[12:16])[0]
        cls.gltf = json.loads(raw[20:20 + n]); cls.raw = raw

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_depth_comes_from_the_perspective(self):
        self.assertTrue(self.rep['depth_from_photo'])
        self.assertAlmostEqual(self.rep['size_mm']['depth'], D_MM, delta=D_MM * 0.03)
        self.assertAlmostEqual(self.rep['focal_px'], 1100, delta=60)

    def test_round_parts_move_onto_the_circles(self):
        self.assertEqual(self.rep['features_snapped'], 2)
        for f, (x, z) in zip(self.rep['feature_list'], KNOBS):
            self.assertAlmostEqual(f["x_mm"], x, delta=0.8)
            self.assertAlmostEqual(f['z_mm'], z, delta=0.8)
            self.assertGreater(f['moved_mm'], 1.0)

    def test_glb_is_well_formed(self):
        self.assertEqual(self.magic, b'glTF'); self.assertEqual(self.total, len(self.raw))
        names = [m['name'] for m in self.gltf['meshes']]
        self.assertEqual(names, ['base', 'lid', 'knobs', 'port'])
        pos = [self.gltf['accessors'][p['attributes']['POSITION']] for m in self.gltf['meshes'] for p in m['primitives']]
        lo = np.min([a['min'] for a in pos], 0); hi = np.max([a['max'] for a in pos], 0)
        self.assertAlmostEqual(lo[1], 0.0, places=6)                                  # sits on y = 0
        self.assertAlmostEqual(hi[1], 0.030, delta=1e-4)                              # 20 + 4 + 6 mm
        self.assertAlmostEqual(hi[0] - lo[0], (W_MM - 4) / 1000, delta=0.002)
        for a in self.gltf['accessors']:
            self.assertGreater(a['count'], 0)

    def test_layers_stack_from_the_bottom(self):
        L = self.rep['layers']
        self.assertEqual([(l['y0_mm'], l['y1_mm']) for l in L], [(0.0, 20.0), (20.0, 24.0)])


class GeometryTest(unittest.TestCase):
    def test_aspect_of_a_square_seen_straight_on_falls_back_to_side_lengths(self):
        ratio, focal = sg.quad_aspect([[100, 100], [500, 100], [500, 300], [100, 300]], 600, 400)
        self.assertAlmostEqual(ratio, 2.0, places=6); self.assertIsNone(focal)

    def test_inset_shrinks_the_outline(self):
        sq = np.array([[0, 0], [100, 0], [100, 60], [0, 60]], float)
        p = sg.shape_outline(sq, inset_mm=5)
        self.assertAlmostEqual(np.ptp(p[:, 0]), 90, delta=0.6); self.assertAlmostEqual(np.ptp(p[:, 1]), 50, delta=0.6)

    def test_prism_faces_point_outwards(self):
        sq = np.array([[0, 0], [10, 0], [10, 10], [0, 10]], float) - 5
        pos, nrm, tri, _ = sg.prism(sq, 0, 4)['side']
        fn = np.cross(pos[tri[:, 1]] - pos[tri[:, 0]], pos[tri[:, 2]] - pos[tri[:, 0]])
        centre = pos[tri].mean(1) - [0, 2, 0]
        self.assertTrue((np.sum(fn * centre, 1) > 0).all())


if __name__ == '__main__':
    unittest.main()
