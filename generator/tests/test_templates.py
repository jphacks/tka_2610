"""Regression tests for kt templates.

Real-photo tests use the photo sets from this project (skipped if absent). Synthetic tests render a
known shape with Katachi itself and rebuild it from that 'photo' (ground truth is exact).
IoU values are 2D silhouette consistency, not 3D accuracy.
"""
from __future__ import annotations
import json
import os
from pathlib import Path

import cv2
import numpy as np
import pytest

from kt import quad_detect as qd
from kt.cli import main
from kt.segment import skin_like
from kt.templates.revolve import lathe_points
from katachi.schema import SceneSpec
import synth

# the project's photo sets: ~/Pictures/作品 (same layout on every machine), or KT_WORKS_DIR
WORKS = Path(os.environ.get('KT_WORKS_DIR') or Path.home() / 'Pictures' / '作品')
BOOK = WORKS / 'jpg'
MAYO = WORKS / 'mayo' / 'jpg'
MANUAL_FRONT = [(0.177, 0.072), (0.988, 0.067), (1.05, 0.9155), (0.104, 0.888)]   # measured by hand earlier
MANUAL_BACK = [(0.080, 0.146), (0.836, 0.127), (0.938, 0.889), (0.088, 0.921)]
MANUAL_SPINE = [(0.383, 0.046), (0.472, 0.046), (0.452, 0.985), (0.277, 0.985)]
PX = np.array([2160, 2880])

needs_book = pytest.mark.skipif(not BOOK.exists(), reason='book photos not present')
needs_mayo = pytest.mark.skipif(not MAYO.exists(), reason='mayo photos not present')


def run(argv):
    assert main(argv) == 0
    out = Path(argv[argv.index('--out') + 1])
    return json.loads((out / 'report.json').read_text(encoding='utf-8')), out


# ------------------------------------------------------------------ detection accuracy (real photos)
@needs_book
def test_book_face_corners_match_manual():
    front = qd.detect_face(BOOK / 'IMG_6984.jpg')
    assert front.clipped_sides == ['right']
    err = np.abs(np.array(front.corners) - MANUAL_FRONT) * PX
    assert err[[0, 3]].max() <= 30                      # visible corners (TR/BR are on the clipped side)
    back = qd.detect_face(BOOK / 'IMG_6986.jpg')
    assert back.clipped_sides == []
    assert (np.abs(np.array(back.corners) - MANUAL_BACK) * PX).max() <= 30


@needs_book
def test_book_spine_strip():
    spine = qd.detect_strip(BOOK / 'IMG_6985.jpg')
    err = np.abs(np.array(spine.corners) - MANUAL_SPINE) * PX
    assert err[:2].max() <= 30                          # top corners
    assert err[2:, 0].max() <= 60                       # long sides near the bottom


# ------------------------------------------------------------------ end-to-end (real photos)
@needs_book
def test_box_book_end_to_end(tmp_path):
    rep, out = run(['box', '--front', str(BOOK / 'IMG_6984.jpg'), '--back', str(BOOK / 'IMG_6986.jpg'),
                    '--side', str(BOOK / 'IMG_6985.jpg'), '--size', '183x233', '--kind', 'book', '--out', str(tmp_path / 'b')])
    q = rep['quality']
    assert q['glb_errors'] == []
    assert q['silhouette_iou_by_view']['front'] >= 0.9 and q['silhouette_iou_by_view']['back'] >= 0.85
    w, h, t = rep['size_m']
    assert abs(w - 0.183) < 1e-3 and abs(h - 0.233) < 1e-3 and 0.020 <= t <= 0.027
    assert rep['total_s'] < 40
    assert (out / 'model.glb').stat().st_size > 1e6 and (out / 'compare.jpg').exists()


BOOK2 = WORKS / 'book2' / 'jpg'


@pytest.mark.skipif(not BOOK2.exists(), reason='book2 photos not present')
def test_box_kraft_cover_end_to_end(tmp_path):
    """Kraft bookstore cover: back edge next to the photo border, baked shadows, matte paper."""
    back = qd.detect_face(BOOK2 / 'IMG_6996.jpg')
    assert back.clipped_sides == [] and back.corners[1][0] < 0.85      # true slanted edge, not the photo border
    rep, out = run(['box', '--front', str(BOOK2 / 'IMG_6994.jpg'), '--back', str(BOOK2 / 'IMG_6996.jpg'),
                    '--side', str(BOOK2 / 'IMG_6995.jpg'), '--size', '148x210', '--kind', 'book', '--out', str(tmp_path / 'k')])
    iou = rep['quality']['silhouette_iou_by_view']
    assert iou['front'] >= 0.9 and iou['back'] >= 0.9
    assert any(n.startswith('finish: matte') for n in rep['notes'])
    assert sum('flattened' in n for n in rep['notes']) == 3


@needs_book
def test_box_glossy_cover_detected(tmp_path):
    rep, _ = run(['box', '--front', str(BOOK / 'IMG_6984.jpg'), '--back', str(BOOK / 'IMG_6986.jpg'),
                  '--size', '183x233x24', '--kind', 'book', '--out', str(tmp_path / 'g')])
    assert any(n.startswith('finish: glossy') for n in rep['notes'])


W_, H_ = 600, 800


def _flat_case(name):
    """Synthetic faces: (image, regions to compare, expectation)."""
    t = np.linspace(0, 1, H_)[:, None, None]
    x = np.linspace(0.55, 1.0, W_)[None, :, None]
    if name == 'two_tone_design':                      # design, not shadow: must not change
        img = np.zeros((H_, W_, 3)); img[:H_ // 2] = [30, 40, 90]; img[H_ // 2:] = [225, 205, 165]
        return img, {'a': (50, 350, 50, 550), 'b': (450, 750, 50, 550)}, 'unchanged'
    if name == 'dark_cover_white_title':
        img = np.full((H_, W_, 3), [25, 25, 35], float); img[200:260, 80:520] = 235
        return img, {'a': (300, 550, 50, 550), 'b': (210, 250, 100, 500)}, 'unchanged'
    if name == 'sunset_artwork':
        img = ((1 - t) * np.array([70, 120, 220]) + t * np.array([250, 150, 60])) * np.ones((1, W_, 1))
        return img, {'a': (0, 150, 0, 600), 'b': (650, 800, 0, 600)}, 'unchanged'
    if name == 'crayon_filled_page':
        rng = np.random.default_rng(3); img = np.zeros((H_, W_, 3))
        cols = [(230, 60, 50), (40, 120, 220), (250, 210, 40), (60, 170, 80), (160, 80, 200), (250, 140, 40)]
        for k in range(40):
            x0, y0 = rng.integers(0, W_ - 150), rng.integers(0, H_ - 150)
            cv2.rectangle(img, (int(x0), int(y0)), (int(x0) + 150, int(y0) + 150), cols[k % 6], -1)
        img[img.sum(2) == 0] = [245, 243, 235]
        return img, {'a': (0, 200, 0, 200), 'b': (600, 800, 400, 600)}, 'unchanged'
    if name == 'drawing_with_shadow':                 # paper + big coloured areas + left shadow: even the paper
        img = np.full((H_, W_, 3), [245, 243, 235], float)
        cv2.circle(img, (300, 300), 170, (240, 120, 40), -1); img[560:800] = [60, 160, 70]
        return img * x, {'a': (40, 100, 20, 120), 'b': (40, 100, 480, 580)}, 'evened'
    if name == 'kraft_with_shadow':
        img = np.full((H_, W_, 3), [210, 180, 130], float) * x; img[300:340, 100:500] = [40, 40, 70]
        return img, {'a': (100, 250, 40, 120), 'b': (100, 250, 480, 560), 'ink': (310, 330, 200, 400)}, 'evened'


@pytest.mark.parametrize('name', ['two_tone_design', 'dark_cover_white_title', 'sunset_artwork', 'crayon_filled_page',
                                  'drawing_with_shadow', 'kraft_with_shadow'])
def test_flatten_is_safe_on_designs_and_fixes_shadows(tmp_path, name):
    from PIL import Image
    from kt.lighting import flatten_face
    img, reg, expect = _flat_case(name)
    path = tmp_path / f'{name}.png'
    Image.fromarray(img.clip(0, 255).astype(np.uint8)).save(path)
    before = np.asarray(Image.open(path)).astype(float)
    flatten_face(path, [[0, 0], [1, 0], [1, 1], [0, 1]])
    after = np.asarray(Image.open(path)).astype(float)
    m = lambda arr, r: arr[r[0]:r[1], r[2]:r[3]].mean()
    if expect == 'unchanged':
        for r in reg.values():
            assert abs(m(after, r) - m(before, r)) / m(before, r) < 0.03
    else:
        gap_before = abs(m(before, reg['a']) - m(before, reg['b'])) / m(before, reg['b'])
        gap_after = abs(m(after, reg['a']) - m(after, reg['b'])) / m(after, reg['b'])
        assert gap_before > 0.3 and gap_after < 0.08
        if 'ink' in reg:
            assert m(after, reg['ink']) < 0.5 * m(after, reg['b'])


def test_flat_drawing_shadow_removed(tmp_path):
    photo, _ = synth.drawing_photo(tmp_path / 'sheet.jpg', cutout=False, shadow=True)
    rep, out = run(['flat', '--photo', str(photo), '--width-cm', '20', '--height-cm', '15', '--out', str(tmp_path / 'f')])
    assert any('flattened' in n for n in rep['notes']) and any(n.startswith('finish: matte') for n in rep['notes'])
    from PIL import Image
    tex = next((out / 'inputs').glob('*/texture_regions/*/texture.png'))
    a = np.asarray(Image.open(tex).convert('RGB')).astype(float)
    h, w = a.shape[:2]
    left, right = a[h // 10:h // 4, w // 20:w // 6].mean(), a[h // 10:h // 4, -w // 6:-w // 20].mean()
    assert abs(left - right) / right < 0.1


@needs_mayo
def test_bottle_mayo_end_to_end(tmp_path):
    rep, out = run(['bottle', '--front', str(MAYO / 'IMG_6990.jpg'), '--side', str(MAYO / 'IMG_6991.jpg'),
                    '--back', str(MAYO / 'IMG_6992.jpg'), '--side2', str(MAYO / 'IMG_6993.jpg'),
                    '--height-cm', '20', '--cap', 'ribbed', '--out', str(tmp_path / 'm')])
    iou = rep['quality']['silhouette_iou_by_view']
    assert rep['quality']['glb_errors'] == []
    assert iou['front'] >= 0.9 and iou['back'] >= 0.9 and iou['side2'] >= 0.85   # 'side' is hand-occluded: reported only
    assert any('cap detected' in n for n in rep['notes'])
    assert abs(rep['size_m'][1] - 0.20) < 1e-3
    assert rep['total_s'] < 30


# ------------------------------------------------------------------ synthetic round trips (exact ground truth)
def test_revolve_vase_round_trip(tmp_path):
    photo = synth.render_photo(synth.vase_scene(), tmp_path / 'vase.jpg', yaw=0, pitch=4)
    rep, out = run(['revolve', '--photo', str(photo), '--height-cm', '15', '--out', str(tmp_path / 'v')])
    assert rep['quality']['silhouette_iou_by_view']['side'] >= 0.95
    truth = np.array(synth.VASE[1:-1], float)
    assert abs(rep['size_m'][0] - 2 * truth[:, 0].max() / 100) / (2 * truth[:, 0].max() / 100) < 0.05
    prof = np.array(json.loads((out / 'scene.json').read_text(encoding='utf-8'))['parts'][0]['geometry']['profile'][1:-1])
    est = np.interp(truth[:, 1], prof[:, 1], prof[:, 0])
    assert np.mean(np.abs(est - truth[:, 0])) / truth[:, 0].max() < 0.06


def test_flat_cutout_round_trip(tmp_path):
    photo, meta = synth.drawing_photo(tmp_path / 'heart.jpg', cutout=True)
    rep, _ = run(['flat', '--photo', str(photo), '--width-cm', '20', '--out', str(tmp_path / 'h')])
    assert 'mode: cutout' in rep['notes']
    assert rep['quality']['silhouette_iou_by_view']['front'] >= 0.9
    assert abs(rep['size_m'][0] - 0.20) < 2e-3


def test_flat_rect_exact_size(tmp_path):
    photo, meta = synth.drawing_photo(tmp_path / 'sheet.jpg', cutout=False)
    rep, _ = run(['flat', '--photo', str(photo), '--width-cm', '20', '--height-cm', '15', '--out', str(tmp_path / 's')])
    assert 'mode: rect' in rep['notes']
    w, h, _t = rep['size_m']
    assert abs(w - 0.20) < 1e-3 and abs(h - 0.15) < 1e-3


# ------------------------------------------------------------------ units
def test_hollow_lathe_profile_is_valid():
    ts = np.linspace(0, 1, 20); r = 0.3 + 0.1 * np.sin(ts * 3)
    pts = lathe_points(ts, r, 10.0, hollow=True, wall=0.3, floor=0.4)
    SceneSpec.model_validate({'title': 't', 'height_m': 0.1, 'materials': [{'id': 'm'}],
                              'parts': [{'id': 'p', 'geometry': {'kind': 'lathe', 'profile': pts}, 'material': 'm'}]})
    assert pts[0] == [0.0, 0.0] and pts[-1][0] == 0.0


def lab_pixel(L, a, b):
    lab = np.uint8([[[round(L * 255 / 100), round(a + 128), round(b + 128)]]])
    return cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)


@pytest.mark.parametrize('lab,expected', [
    ((59.6, 9, 15), True), ((71, 9, 3), True), ((64, 10, 5), True),          # fingers / palm (measured)
    ((93.3, -3.5, 26.5), False), ((72.2, 1, 22), False),                     # cream plastic, lit and shaded
    ((34.1, 54, 35), False), ((60, 8, 25), False)])                          # red cap, wood-like
def test_skin_rule(lab, expected):
    assert bool(skin_like(lab_pixel(*lab))[0, 0]) is expected


def _hand_face(skin_cover=False):
    """White (or skin-toned) cover with blue lettering; a thumb enters from the left edge."""
    bg = (140, 165, 210) if skin_cover else (240, 240, 236)          # BGR: a peach/skin-toned cover vs white
    img = np.full((800, 600, 3), bg, np.uint8)
    cv2.putText(img, 'MAHJONG', (150, 200), cv2.FONT_HERSHEY_SIMPLEX, 2.2, (170, 90, 30), 6)   # BGR blue-ish
    cv2.ellipse(img, (0, 450), (110, 60), 0, 0, 360, (150, 175, 225), -1)                     # BGR skin
    return img


@pytest.mark.parametrize('skin_cover', [False, True])
def test_hand_removed_from_face_only_when_safe(tmp_path, skin_cover):
    from PIL import Image
    from kt.hands import remove_hands_on_face
    path = tmp_path / 'face.png'
    bgr = _hand_face(skin_cover)
    Image.fromarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)).save(path)
    info = remove_hands_on_face(path, [[0, 0], [1, 0], [1, 1], [0, 1]])
    out = cv2.cvtColor(np.asarray(Image.open(path).convert('RGB')), cv2.COLOR_RGB2BGR)
    if skin_cover:
        assert not info['applied'] and np.array_equal(out, bgr)            # skin-toned cover: untouched
    else:
        assert info['applied'] and 0.005 < info['hand_share'] < 0.05
        assert skin_like(out[400:500, 0:100]).mean() < 0.02               # thumb gone
        assert np.abs(out[150:210, 150:450].astype(int) - bgr[150:210, 150:450].astype(int)).max() == 0   # lettering untouched


def test_ui_publish_sends_the_corrected_photo(tmp_path):
    """--ui must upload the workspace copy (hands removed, lighting flattened), not the original photo."""
    import httpx
    from PIL import Image
    from kt.engine import Workspace, BuildPlan
    from kt.publish import publish
    original = tmp_path / 'orig.jpg'
    Image.fromarray(np.full((300, 200, 3), 120, np.uint8)).save(original)
    ws = Workspace(tmp_path / 'ws')
    p = ws.add_photo('front', original, 0)
    Image.fromarray(np.full((300, 200, 3), 200, np.uint8)).save(p.source)       # stands in for a corrected copy
    ws.set_mask('front', np.ones((300, 200), bool))
    uploaded = []

    def handler(request):
        path = request.url.path
        if path == '/api/config':
            return httpx.Response(200, json={'session_token': 't'})
        if path == '/api/projects':
            return httpx.Response(200, json={'id': 'p1'})
        if path.endswith('/images'):
            uploaded.append(request.content)
            return httpx.Response(200, json={'id': 'image_000000000001', 'width': 200, 'height': 300})
        if path.endswith('/mask'):
            return httpx.Response(200, json={})
        if path == '/api/jobs':
            return httpx.Response(200, json={'id': 'j1'})
        if path.startswith('/api/jobs/'):
            return httpx.Response(200, json={'status': 'needs_review'})
        return httpx.Response(404, json={})

    plan = BuildPlan(title='t', height_m=0.1, scene_fn=lambda tex: {'height_m': 0.1})
    info = publish(ws, plan, transport=httpx.MockTransport(handler))
    assert info['status'] == 'needs_review' and len(uploaded) == 1
    assert p.source.read_bytes() in uploaded[0] and original.read_bytes() not in uploaded[0]


def test_hand_fill_takes_no_colour_from_outside_the_face(tmp_path):
    """Real hand-held case: the thumb continues outside the cover. The filled area must take the cover's
    colour, not the skin outside (earlier versions left a pink band)."""
    from PIL import Image
    from kt.hands import remove_hands_on_face
    img = np.full((900, 700, 3), (60, 60, 60), np.uint8)                       # dark room
    img[100:800, 150:650] = (236, 238, 240)                                     # white cover (BGR)
    cv2.putText(img, 'BOOK', (300, 300), cv2.FONT_HERSHEY_SIMPLEX, 2.5, (170, 90, 30), 7)
    cv2.ellipse(img, (150, 480), (120, 55), 0, 0, 360, (150, 175, 225), -1)  # thumb across the cover edge
    path = tmp_path / 'held.png'
    Image.fromarray(cv2.cvtColor(img, cv2.COLOR_BGR2RGB)).save(path)
    quad = [[150 / 700, 100 / 900], [650 / 700, 100 / 900], [650 / 700, 800 / 900], [150 / 700, 800 / 900]]
    info = remove_hands_on_face(path, quad)
    out = cv2.cvtColor(np.asarray(Image.open(path).convert('RGB')), cv2.COLOR_RGB2BGR)
    face = out[100:800, 150:650]
    assert info['applied'] and info['skin_left_share'] < 0.002
    assert skin_like(face).mean() < 0.002
    patch = face[340:420, 0:60].reshape(-1, 3).mean(0)                          # where the thumb was
    assert np.abs(patch - np.array([236, 238, 240])).max() < 12                 # cover white, not pink
    assert np.array_equal(out[200:320, 300:560], img[200:320, 300:560])         # lettering untouched


# ------------------------------------------------------------------ hands over the edge, several photos, residue
FIXW = Path(__file__).resolve().parent.parent / 'bench' / 'fixtures' / 'works'
SHEET_TRUE = np.array([[249, 520], [959, 479], [999, 1009], [210, 1049]], float)   # sheet_clean.jpg corners (px)
needs_sheet = pytest.mark.skipif(not (FIXW / 'sheet_hand_a.jpg').exists(), reason='hand-held sheet fixtures not present')


def _wood_desk_photo():
    """Brown desk (skin-coloured by the Lab rule), a white sheet, and a pink 'thumb' over its left edge."""
    rng = np.random.default_rng(0)
    img = np.clip(np.array([65, 95, 140], float) + rng.normal(0, 4, (800, 600, 3)), 0, 255).astype(np.uint8)
    cv2.fillPoly(img, [np.int32([[150, 250], [480, 230], [500, 520], [130, 540]])], (236, 240, 242))
    cv2.ellipse(img, (120, 470), (70, 260), 0, 0, 360, (150, 175, 225), -1)       # thumb + arm to the bottom
    return img


def test_wooden_desk_is_not_taken_for_a_hand():
    img = _wood_desk_photo()
    occ = qd._occluders(img)
    assert occ is not None                                         # occlusion handling stays on
    assert occ[470, 120] and occ[700, 120]                         # the thumb/arm is an occluder
    assert not occ[100:200, 300:550].any()                         # the desk is not


@needs_sheet
def test_sheet_corner_under_the_thumb_recovered():
    """The thumb hides the sheet's bottom-left corner and its outline is a strong straight-ish edge: the
    detected side must follow the paper (visible above the thumb), not the thumb."""
    for f in ('sheet_clean.jpg', 'sheet_hand_a.jpg'):
        r = qd.detect_face(FIXW / f)
        err = np.linalg.norm(np.array(r.corners) * [1200, 1600] - SHEET_TRUE, axis=1)
        assert err.max() < 4, (f, err)


@needs_sheet
def test_flat_hand_held_sheet_one_and_two_photos(tmp_path):
    from kt.report import finger_residue
    clean, _ = run(['flat', '--photo', str(FIXW / 'sheet_clean.jpg'), '--width-cm', '20', '--height-cm', '15', '--out', str(tmp_path / 'c')])
    one, out1 = run(['flat', '--photo', str(FIXW / 'sheet_hand_a.jpg'), '--width-cm', '20', '--height-cm', '15', '--out', str(tmp_path / 'one')])
    two, out2 = run(['flat', '--photo', str(FIXW / 'sheet_hand_a.jpg'), str(FIXW / 'sheet_hand_b.jpg'),
                     '--width-cm', '20', '--height-cm', '15', '--out', str(tmp_path / 'two')])
    assert 'mode: rect' in one['notes'] and 'mode: rect' in two['notes']          # the thumb is not part of the sheet
    assert any('hand/fingers on the sheet removed' in n for n in one['notes'])
    assert any(n.startswith('fused with 1 more photo') for n in two['notes'])
    assert finger_residue(out1) == {'art': 0.0} and finger_residue(out2) == {'art': 0.0}
    from PIL import Image
    tex = lambda o: cv2.cvtColor(np.asarray(Image.open(next((o / 'inputs').glob('*/texture_regions/*/texture.png'))).convert('RGB')), cv2.COLOR_RGB2BGR)
    gt = tex(tmp_path / 'c'); h, w = gt.shape[:2]
    lab = lambda b: cv2.cvtColor(b, cv2.COLOR_BGR2LAB).astype(np.float32) * np.array([100 / 255, 1, 1], np.float32)
    region = (slice(int(0.41 * h), h), slice(0, int(0.19 * w)))                   # where the thumb was
    err = {k: float(np.linalg.norm(lab(cv2.resize(tex(o), (w, h)))[region] - lab(gt)[region], axis=2).mean())
           for k, o in (('one', out1), ('two', out2))}
    assert err['two'] < 4.0 and err['one'] < 7.0, err


def test_finger_residue_metric():
    from kt.report import border_skin_blobs
    tex = np.full((400, 300, 3), (236, 238, 240), np.uint8)
    cv2.putText(tex, 'ORANGE', (40, 200), cv2.FONT_HERSHEY_SIMPLEX, 1.5, (150, 175, 225), 4)   # skin-coloured print
    assert border_skin_blobs(tex) == 0.0                           # inside the face: not a finger
    cv2.ellipse(tex, (0, 300), (40, 25), 0, 0, 360, (150, 175, 225), -1)                     # finger at the edge
    assert border_skin_blobs(tex) > 0.003


@pytest.mark.skipif(not (FIXW / 'label_bottle' / 'front.jpg').exists(), reason='label bottle fixture not present')
def test_bottle_print_projects_the_label(tmp_path):
    L = FIXW / 'label_bottle'
    rep, out = run(['bottle', '--front', str(L / 'front.jpg'), '--side', str(L / 'side.jpg'), '--back', str(L / 'back.jpg'),
                    '--side2', str(L / 'side2.jpg'), '--height-cm', '17', '--out', str(tmp_path / 'b')])
    scene = json.loads((out / 'scene.json').read_text(encoding='utf-8'))
    kinds = {p['id']: p['geometry']['kind'] for p in scene['parts']}
    assert kinds.get('front_print') == 'surface_patch' and kinds.get('back_print') == 'surface_patch'
    assert not any('photo print dropped' in w for w in rep['quality']['warnings'])
    assert rep['quality']['glb_errors'] == []


def test_local_fit_runs_with_template_controls(tmp_path):
    photo = synth.render_photo(synth.vase_scene(), tmp_path / 'vase.jpg', yaw=0, pitch=4)
    rep, out = run(['revolve', '--photo', str(photo), '--height-cm', '15', '--fit', '6', '--out', str(tmp_path / 'v')])
    scene = json.loads((out / 'scene.json').read_text(encoding='utf-8'))
    assert [c['name'] for c in scene['controls']] == ['radius_scale']
    assert rep['quality']['glb_errors'] == [] and rep['quality']['silhouette_iou_by_view']['side'] >= 0.95


# ------------------------------------------------------------------ LaMa fill (optional model)
def _face_with_hole(w=600, h=800, stripe=True):
    img = np.full((h, w, 3), (236, 238, 240), np.uint8)
    if stripe:                                                   # an illustration running into the hole
        cv2.rectangle(img, (0, 380), (w, 440), (40, 120, 200), -1)
    hole = np.zeros((h, w), bool); hole[350:470, 0:120] = True
    return img, hole


def test_fill_paper_when_no_illustration_or_small_hole():
    from kt.hands import fill_hole
    img, hole = _face_with_hole(stripe=False)
    st = {}
    out = fill_hole(img, [[0, 0], [1, 0], [1, 1], [0, 1]], hole, method='lama', stats=st)
    assert st['fill'].startswith('paper')                        # plain paper (or no model): the network is not run
    assert np.abs(out[hole].astype(int) - [236, 238, 240]).mean() < 6   # Telea is ~+3 bright on flat paper
    small = np.zeros_like(hole); small[400:410, 0:10] = True
    st = {}
    fill_hole(img, [[0, 0], [1, 0], [1, 1], [0, 1]], small, method='lama', stats=st)
    assert st['fill'] == 'paper (small hole)'


@pytest.mark.skipif(not __import__('kt.lama', fromlist=['available']).available(), reason='LaMa model not installed')
def test_fill_lama_continues_an_illustration_and_skips_strips():
    from kt.hands import fill_hole
    img, hole = _face_with_hole()
    st = {}
    out = fill_hole(img, [[0, 0], [1, 0], [1, 1], [0, 1]], hole, method='lama', stats=st)
    assert st['fill'].startswith('lama')                         # an illustration runs into the hole: the net runs
    assert np.array_equal(out[~hole], img[~hole])                # only the hole is written
    assert not np.array_equal(out[hole], fill_hole(img, [[0, 0], [1, 0], [1, 1], [0, 1]], hole, method='paper')[hole])
    strip = img[:, 280:330].copy(); sh = hole[:, 280:330].copy(); sh[350:470, :10] = True
    st = {}
    fill_hole(strip, [[0, 0], [1, 0], [1, 1], [0, 1]], sh, method='lama', stats=st)
    assert st['fill'] == 'paper (strip-shaped face)'


# ------------------------------------------------------------------ inspect kit (AI-written recipes)
def _synthetic_face_photo(path, W=20.0, H=30.0, r=1.5, logo=(8.0, 12.0, 1.5)):
    """A dark rounded slab (W x H cm, corner radius r) on a white desk, seen in perspective, with a darker
    round logo (x, y from the top-left, radius, cm) and a broad bright reflection across it."""
    ppc = 30
    face = np.zeros((int(H * ppc), int(W * ppc), 3), np.uint8)
    yy, xx = np.mgrid[0:face.shape[0], 0:face.shape[1]]
    grad = np.clip((xx + yy - 0.9 * face.shape[0]) / (0.5 * face.shape[0]), 0, 1)[..., None]   # reflection band
    face[:] = (85, 88, 90)
    face = np.clip(face + grad * 90, 0, 255).astype(np.uint8)
    cv2.circle(face, (int(logo[0] * ppc), int(logo[1] * ppc)), int(logo[2] * ppc), (25, 25, 27), -1)
    alpha = np.zeros(face.shape[:2], np.uint8)
    rp = int(r * ppc)
    cv2.rectangle(alpha, (rp, 0), (face.shape[1] - rp, face.shape[0]), 255, -1)
    cv2.rectangle(alpha, (0, rp), (face.shape[1], face.shape[0] - rp), 255, -1)
    for cx, cy in ((rp, rp), (face.shape[1] - rp, rp), (rp, face.shape[0] - rp), (face.shape[1] - rp, face.shape[0] - rp)):
        cv2.circle(alpha, (cx, cy), rp, 255, -1)
    canvas = np.full((1400, 1100, 3), (232, 236, 238), np.uint8)
    src = np.float32([[0, 0], [face.shape[1], 0], [face.shape[1], face.shape[0]], [0, face.shape[0]]])
    dst = np.float32([[180, 140], [900, 110], [960, 1230], [130, 1260]])
    M = cv2.getPerspectiveTransform(src, dst)
    wf = cv2.warpPerspective(face, M, (1100, 1400)); wa = cv2.warpPerspective(alpha, M, (1100, 1400))[..., None] / 255
    out = (canvas * (1 - wa) + wf * wa).astype(np.uint8)
    cv2.imencode('.jpg', out, [cv2.IMWRITE_JPEG_QUALITY, 95])[1].tofile(str(path))
    return path


def test_inspect_face_measures_rounding_and_marks(tmp_path):
    from kt.inspect import measure_face
    photo = _synthetic_face_photo(tmp_path / 'slab.jpg')
    res = measure_face(photo, (20.0, 30.0), tmp_path / 'm')
    assert res['corner_radius_cm'] is not None and abs(res['corner_radius_cm'] - 1.5) < 0.35
    dark = [m for m in res['marks'] if m['polarity'] == 'dark']
    assert len(dark) == 1                                            # the logo; the reflection edge is not a mark
    assert np.allclose(dark[0]['centre_cm'], (8.0, 12.0), atol=0.4)
    assert abs(dark[0]['equivalent_diameter_cm'] - 3.0) < 0.3
    assert res['colour']['brightness_spread'] > 0.5 and any('uniform material' in n for n in res['notes'])
    back = measure_face(photo, (20.0, 30.0), tmp_path / 'mb', facing='back')     # seen from behind: x mirrored
    bd = [m for m in back['marks'] if m['polarity'] == 'dark'][0]
    assert np.isclose(bd['centre_centred_cm'][0], -dark[0]['centre_centred_cm'][0], atol=0.05)


def test_inspect_edge_positions_along_a_side(tmp_path):
    from kt.inspect import measure_edge
    ppc = 40; L, T = 30.0, 1.5
    img = np.full((1400, 500, 3), (230, 232, 235), np.uint8)
    x0, y0 = 220, 80
    cv2.rectangle(img, (x0, y0), (x0 + int(T * ppc), y0 + int(L * ppc)), (60, 62, 64), -1)
    for at_cm, len_cm in ((5.0, 0.9), (12.0, 1.6)):                  # two dark ports along the side
        yc = y0 + int(at_cm * ppc)
        cv2.rectangle(img, (x0 + 18, yc - int(len_cm * ppc / 2)), (x0 + 42, yc + int(len_cm * ppc / 2)), (15, 15, 15), -1)
    path = tmp_path / 'edge.png'; cv2.imwrite(str(path), img)
    h, w = img.shape[:2]
    ends = [(x0 + T * ppc / 2) / w, y0 / h, (x0 + T * ppc / 2) / w, (y0 + L * ppc) / h]
    res = measure_edge(path, L, T, tmp_path / 'e', ends=ends)
    ports = sorted([m for m in res['marks'] if m['polarity'] == 'dark'], key=lambda m: m['from_end_a_cm'])
    assert len(ports) == 2
    assert abs(ports[0]['from_end_a_cm'] - 5.0) < 0.3 and abs(ports[1]['from_end_a_cm'] - 12.0) < 0.3
    assert abs(ports[1]['length_cm'] - 1.6) < 0.3


def test_recipe_build_and_views(tmp_path):
    from kt.recipe import build
    from kt.inspect import views_sheet
    photo = _synthetic_face_photo(tmp_path / 'slab.jpg')
    scene = {'schema_version': '1.0', 'title': 'slab', 'height_m': 0.3, 'seed': 1, 'controls': [], 'assumptions': [],
             'materials': [{'id': 'm', 'color': [0.33, 0.34, 0.35, 1], 'roughness': 0.5}],
             'parts': [{'id': 'body', 'geometry': {'kind': 'rounded_box', 'size': [20, 30, 1.5], 'bevel': 0.3}, 'material': 'm',
                        'transform': {'translation': [0, 15, 0]}}]}
    (tmp_path / 'scene.json').write_text(json.dumps(scene), encoding='utf-8')
    rep = build(tmp_path / 'scene.json', {'front': (str(photo), 0.0, 0.0)}, tmp_path / 'out')
    assert rep['quality']['glb_errors'] == [] and rep['quality']['silhouette_iou_by_view']['front'] > 0.85
    out = tmp_path / '作品'; out.mkdir()                                        # non-ASCII folder (Windows paths)
    sheet = views_sheet(tmp_path / 'out' / 'model.glb', out / 'views.jpg', {'front': (str(photo), 0.0, 0.0)})
    assert Path(sheet).exists() and Path(sheet).stat().st_size > 10000


# ------------------------------------------------------------------ --look ai (the AI call is replaced by a fixed decision)
MAC = WORKS / 'mac' / 'jpg'


def _fake_ask(decision, seen):
    def ask(images, text, model='sonnet', cwd=None, timeout=240):
        seen.append({'images': len(images), 'text': text})
        return decision, {'model': 'fake', 'wall_s': 0, 'api_s': 0, 'cost_usd': 0, 'input_tokens': 0, 'output_tokens': 0}
    return ask


@pytest.mark.skipif(not MAC.exists(), reason='laptop photos not present')
def test_box_look_ai_builds_materials_marks_copies_and_seam(tmp_path, monkeypatch):
    import kt.design as design
    grey = [0.3, 0.3, 0.31]
    dec = {'object': 'test slab', 'body': {'color_rgb': grey, 'roughness': 0.4, 'metallic': 0.3, 'corner_radius_cm': 1.1, 'edge_round_cm': 0.4},
           'back_color_rgb': [0.25, 0.25, 0.26], 'faces_use_photo': [],
           'marks': [{'face': 'front', 'id': 0, 'build': 'print', 'color_rgb': [0.1, 0.1, 0.1], 'roughness': 0.2, 'metallic': 0.3},
                     {'face': 'back', 'id': 0, 'build': 'raised', 'height_cm': 0.15, 'color_rgb': [0.08] * 3, 'roughness': 0.8,
                      'metallic': 0, 'copies_at_face_cm': [[3, 3], [19, 3], [19, 28.8], [3.3, 28.9]]},
                     {'face': 'back', 'id': 1, 'build': 'raised', 'height_cm': 0.15, 'color_rgb': [0.08] * 3, 'roughness': 0.8, 'metallic': 0},
                     {'face': 'back', 'id': 99, 'build': 'print', 'color_rgb': [0, 0, 0], 'roughness': 1, 'metallic': 0}],
           'seam': {'present': True, 'from_back_fraction': 0.7, 'width_cm': 0.06, 'color_rgb': [0.05] * 3}, 'notes': ''}
    seen = []
    monkeypatch.setattr(design, 'ask', _fake_ask(dec, seen))
    rep, out = run(['box', '--front', str(MAC / 'IMG_7006.jpg'), '--back', str(MAC / 'IMG_7007.jpg'), '--side', str(MAC / 'IMG_7010.jpg'),
                    '--size', '221.2x312.6x15.5', '--kind', 'box', '--look', 'ai', '--out', str(tmp_path / 'm')])
    assert rep['quality']['glb_errors'] == [] and rep['live_api_calls'] == 1
    assert seen and seen[0]['images'] == 3 and '"faces"' in seen[0]['text']          # photos, faces, side strip
    scene = json.loads((out / 'scene.json').read_text(encoding='utf-8'))
    ids = {p['id'] for p in scene['parts']}
    assert {'body_back', 'body_front', 'seam_line', 'back_face', 'mark_front_0', 'mark_back_0'} <= ids
    copies = [i for i in ids if i.startswith('mark_back_0_copy')]
    assert len(copies) == 2      # top two; the copy on mark 1 (listed) and the one on mark 0 itself are skipped
    assert not any('image_id' in m for m in scene['materials'])   # no photo pixels on plain faces
    body = next(p for p in scene['parts'] if p['id'] == 'body_front')
    xs = [x for x, _ in body['geometry']['outline']]
    assert len(body['geometry']['outline']) > 4 and abs(max(xs) - 11.06) < 0.01   # rounded corners, real width
    assert rep['size_m'][0] == pytest.approx(0.2212, abs=0.002)


@needs_book
def test_box_look_ai_keeps_print_where_decided(tmp_path, monkeypatch):
    import kt.design as design
    dec = {'object': 'book', 'body': {'color_rgb': [0.8, 0.79, 0.76], 'roughness': 0.6, 'metallic': 0, 'corner_radius_cm': 0.2, 'edge_round_cm': 0.1},
           'back_color_rgb': [0.8, 0.79, 0.76], 'faces_use_photo': ['front', 'back', 'side'], 'marks': [],
           'seam': {'present': False}, 'notes': ''}
    monkeypatch.setattr(design, 'ask', _fake_ask(dec, []))
    rep, out = run(['box', '--front', str(BOOK / 'IMG_6984.jpg'), '--back', str(BOOK / 'IMG_6986.jpg'), '--side', str(BOOK / 'IMG_6985.jpg'),
                    '--size', '183x233', '--kind', 'book', '--look', 'ai', '--out', str(tmp_path / 'b')])
    assert rep['quality']['glb_errors'] == []
    scene = json.loads((out / 'scene.json').read_text(encoding='utf-8'))
    assert {m['id'] for m in scene['materials'] if 'image_id' in m} == {'front_photo', 'back_photo', 'side_photo'}
    front = next(p for p in scene['parts'] if p['id'] == 'front_print')
    from shapely.geometry import Polygon
    seen = Polygon(front['geometry']['outline']).area
    assert seen < 0.99 * (18.3 - 0.2) * (23.3 - 0.2)          # the front's hidden corner strip is not stretched over
    assert rep['quality']['silhouette_iou_by_view']['front'] > 0.9


def test_design_outline_helpers():
    from kt.design import rounded_rect, clean_outline, _safe_bevel
    from shapely.geometry import Polygon
    r = rounded_rect(10, 20, 2)
    P = Polygon(r)
    assert P.is_valid and P.exterior.is_ccw and abs(P.area - (200 - (4 - np.pi) * 4)) < 0.2
    bow = [[0, 0], [2, 2], [2, 0], [0, 2]]                    # self-intersecting
    c = clean_outline(bow)
    assert c is not None and Polygon(c).is_valid
    assert clean_outline([[20, 20], [21, 20], [21, 21]], r) is None    # outside the clip
    neck = [[0, 0], [1, 0], [1, 0.45], [1.5, 0.45], [1.5, 0], [2.5, 0], [2.5, 1], [1.5, 1], [1.5, 0.55], [1, 0.55], [1, 1], [0, 1]]
    assert _safe_bevel(neck, 0.2) < 0.2


# ------------------------------------------------------------------ kt auto / kt gen (AI and the GPU generator replaced)
PS5 = WORKS / 'mac' / 'ps5' / 'jpg'


def test_auto_decision_to_command_line(tmp_path):
    from kt.auto import to_argv
    files = {n: tmp_path / n for n in ('a.jpg', 'b.jpg', 'c.jpg')}
    out = tmp_path / 'o'
    box = to_argv({'route': 'box', 'box': {'front': 'a.jpg', 'back': 'b.jpg', 'side': '', 'size_mm': [221.2, 312.6, 15.5],
                                            'kind': 'box'}}, files, out, 'sonnet')
    assert box[:3] == ['box', '--front', str(files['a.jpg'])] and '--back' in box and '--side' not in box
    assert box[box.index('--size') + 1] == '221.2x312.6x15.5' and box[box.index('--look') + 1] == 'ai'
    gen = to_argv({'route': 'generate', 'generate': {'photo': 'c.jpg', 'yaw': 0, 'pitch': 70, 'size_cm': [16, 6.6, 10.6],
                                                      'others': [{'photo': 'a.jpg', 'yaw': 180, 'pitch': -70}]}}, files, out, 'opus')
    assert gen[:3] == ['gen', '--photo', f"main={files['c.jpg']}@0,70"] and f"p1={files['a.jpg']}@180,-70" in gen
    assert gen[gen.index('--size') + 1] == '16,6.6,10.6' and gen[gen.index('--ai-model') + 1] == 'opus'
    flat = to_argv({'route': 'flat', 'flat': {'photo': 'a.jpg', 'width_cm': 20, 'height_cm': 15, 'thickness_mm': 1.5}}, files, out, 's')
    assert flat[:3] == ['flat', '--photo', str(files['a.jpg'])]
    # bottle: the AI's look decisions (print onto the body or not, cap shape) are passed on
    bottle = to_argv({'route': 'bottle', 'bottle': {'front': 'a.jpg', 'side': 'b.jpg', 'height_cm': 20, 'print': 'none',
                                                    'cap': 'ribbed'}}, files, out, 's')
    assert bottle[bottle.index('--print') + 1] == 'none' and bottle[bottle.index('--cap') + 1] == 'ribbed'
    # thickness unknown (0) with a side photo: WxH only, the template estimates T from the side
    book = to_argv({'route': 'box', 'box': {'front': 'a.jpg', 'side': 'b.jpg', 'size_mm': [183, 233, 0], 'kind': 'book'}}, files, out, 's')
    assert book[book.index('--size') + 1] == '183x233'
    for bad, why in ((({'route': 'box', 'box': {'front': 'zzz.jpg', 'size_mm': [1, 2, 3], 'kind': 'box'}}), 'not one of the photos'),
                     (({'route': 'box', 'box': {'front': 'a.jpg', 'size_mm': [183, 233, 0], 'kind': 'book'}}), 'no side photo'),
                     (({'route': 'generate', 'generate': {'photo': 'a.jpg', 'yaw': 0, 'pitch': 0, 'size_cm': [16, 0, 3]}}), 'positive'),
                     (({'route': 'bottle'}), 'missing'),
                     (({'route': 'revolve', 'revolve': {'photo': 'a.jpg', 'height_cm': -2}}), 'positive')):
        with pytest.raises(ValueError, match=why):
            to_argv(bad, files, out, 's')


def test_gen_pose_axes_from_size():
    import trimesh
    from kt.gen import place, quarter_turns
    assert len(quarter_turns()) == 24
    # the generator's own resting pose already matches: kept as it is (no rotation), per-axis scale ~1
    body = trimesh.creation.icosphere(subdivisions=3)
    body.apply_scale([0.5, 0.2, 0.33])
    placed, info = place(body, size_cm=[16, 6.6, 10.6])
    ext = np.ptp(placed.vertices, 0)
    assert np.allclose(ext, [0.16, 0.066, 0.106], atol=1e-4) and abs(placed.vertices[:, 1].min()) < 1e-9
    assert info['rotation_deg'] == 0 and max(abs(v - 1) for v in info['scale_per_axis_relative']) < 0.06
    # standing on the wrong axis: the quarter turn that matches the size proportions is chosen
    standing = trimesh.creation.icosphere(subdivisions=3)
    standing.apply_scale([0.5, 0.33, 0.2])
    placed, info = place(standing, size_cm=[16, 6.6, 10.6])
    assert info['rotation_deg'] == 90 and max(abs(v - 1) for v in info['scale_per_axis_relative']) < 0.06
    # nothing fits: the size is still met, and the per-axis scale shows the stretch
    _, odd = place(trimesh.creation.icosphere(subdivisions=3), size_cm=[16, 6.6, 10.6])
    assert max(abs(v - 1) for v in odd['scale_per_axis_relative']) > 0.3


@pytest.mark.skipif(not PS5.exists(), reason='controller photos not present')
def test_auto_generate_route_end_to_end(tmp_path, monkeypatch):
    import trimesh
    import kt.design as design
    import kt.gen as gen
    calls = []

    def fake_ask(images, text, model='sonnet', cwd=None, timeout=240, schema=None, system=None):
        calls.append(schema)
        meta = {'model': 'fake', 'wall_s': 0, 'api_s': 0, 'cost_usd': 0.01, 'input_tokens': 0, 'output_tokens': 0}
        if 'route' in (schema or {}).get('properties', {}):
            return {'object': 'controller', 'route': 'generate', 'reason': 'curved',
                    'generate': {'photo': 'IMG_7012.jpg', 'yaw': 0, 'pitch': 75, 'size_cm': [16, 6.6, 10.6],
                                 'others': [{'photo': 'IMG_7013.jpg', 'yaw': 180, 'pitch': -75}]}}, meta
        assert 'regions' in schema['properties'] and len(images) >= 3        # kt gen --material regions (default)
        return {'object': 'controller', 'notes': 'ok', 'marks': [{'id': 1, 'what': 'symbol', 'color_rgb': [0.5, 0.5, 0.5], 'photo_detail': False}],
                'regions': [{'id': i, 'what': 'body', 'color_rgb': [0.08, 0.08, 0.09], 'roughness': 0.4, 'metallic': 0.0}
                            for i in range(1, 7)]}, meta

    def fake_worker(image, out_mesh, settings, timeout=1800):
        m = trimesh.creation.icosphere(subdivisions=3); m.apply_scale([0.5, 0.33, 0.2]); m.export(out_mesh)
        return {'timings_s': {'import': 0, 'load_model': 0, 'generate': 0, 'postprocess': 0}, 'faces': len(m.faces),
                'faces_raw': len(m.faces), 'vertices': len(m.vertices), 'max_gpu_memory_gb': 0, 'settings': settings}

    monkeypatch.setattr(design, 'ask', fake_ask)
    monkeypatch.setattr(gen, 'run_worker', fake_worker)
    from kt.cli import main
    assert main(['auto', str(PS5), '--size', '16,10.6,6.6', '--out', str(tmp_path / 'a')]) == 0
    rep = json.loads((tmp_path / 'a' / 'report.json').read_text(encoding='utf-8'))
    assert rep['template'] == 'gen' and rep['auto']['route'] == 'generate' and rep['quality']['glb_errors'] == []
    assert rep['size_m'] == pytest.approx([0.16, 0.066, 0.106], abs=2e-3)
    assert rep['auto']['ai_cost_usd_total'] == pytest.approx(0.02) and len(calls) == 2
    assert (tmp_path / 'a' / 'route_decision.json').exists() and (tmp_path / 'a' / 'compare.jpg').exists()
    assert (tmp_path / 'a' / 'gen' / 'input.png').exists()           # the cut-out the generator saw
    assert rep['paint']['mode'] == 'regions' and (tmp_path / 'a' / 'paint' / 'regions.jpg').exists()
    assert rep['paint']['cameras']['main']['iou'] > 0.5


def test_paint_regions_marks_and_borders(tmp_path):
    """kt.paint on a synthetic object with known colours: a box with a red band at the top of a cream body, lit from
    one side, and a light square printed on the front. The 'photo' is drawn through a known perspective camera; the
    analysis starts from rounded angles, as the routing AI gives them."""
    import trimesh
    from PIL import Image
    from katachi.schema import Camera
    from kt import paint
    m = trimesh.creation.box(extents=[0.08, 0.12, 0.05])
    for _ in range(5):
        m = m.subdivide()
    m.apply_translation([0, 0.06, 0])
    cap = m.triangles_center[:, 1] > 0.095
    cream, red = np.array([0.90, 0.84, 0.65]), np.array([0.80, 0.08, 0.08])
    face = np.where(cap[:, None], red, cream)
    light = 0.55 + 0.45 * np.clip(m.face_normals @ np.array([0.6, 0.5, 0.62]), 0, 1)
    W, H = 600, 800
    cam = Camera(projection='perspective', yaw_deg=24, pitch_deg=18, focus=[0, 0.06, 0], distance_m=0.4, fov_y_deg=40)
    geom = paint._geometry(m.vertices, m.faces)
    uv, depth = paint.photo_uv(geom, cam, (W, H))
    ids = paint.face_ids(uv * [W, H], depth, np.asarray(m.faces), (W, H))
    img = np.full((H, W, 3), 0.97)
    img[ids >= 0] = (face * light[:, None])[ids[ids >= 0]]
    front = np.flatnonzero((m.face_normals[:, 2] > 0.9) & (np.abs(m.triangles_center[:, 0]) < 0.004) & (np.abs(m.triangles_center[:, 1] - 0.05) < 0.004))
    cx, cy = (uv[np.asarray(m.faces)[front[0], 0]] * [W, H]).astype(int)
    img[cy - 12:cy + 12, cx - 12:cx + 12] = [0.98, 0.98, 0.98]          # a printed light square on the front
    Image.fromarray((img * 255).astype(np.uint8)).save(tmp_path / 'photo.png')
    Image.fromarray(((ids >= 0) * 255).astype(np.uint8)).save(tmp_path / 'mask.png')
    res = paint.analyse(m, [{'key': 'main', 'image': tmp_path / 'photo.png', 'mask': tmp_path / 'mask.png', 'yaw': 30, 'pitch': 20}],
                        tmp_path / 'paint', 'main')
    assert res['report']['cameras']['main']['iou'] > 0.95
    reds = [s for s in res['stats'] if s['colour_rgb'][0] - s['colour_rgb'][1] > 0.3]
    assert reds, res['stats']                                         # the cap is a region of its own
    square = [mk for mk in res['marks'] if mk['polarity'] == 'brighter' and abs(mk['box'][0] + mk['box'][2] / 2 - cx) < 20]
    assert square, res['mark_info']                                   # the printed square is a mark candidate
    dec = {'object': 't', 'notes': '', 'marks': [{'id': square[0]['id'], 'what': 'square', 'color_rgb': [1, 1, 1], 'photo_detail': False}],
           'regions': [{'id': s['id'], 'what': '', 'roughness': 0.4, 'metallic': 0,
                        'color_rgb': list(red) if s in reds else list(cream)} for s in res['stats']]}
    mats, kept, missing = paint.materials(dec, res['stats'], res['marks'])
    assert not missing and list(kept) == [square[0]['id']]
    seen = res['source'] >= 0
    labels, moved = paint.snap_borders(res['mesh'], res['labels'], mats, seen)
    area = res['mesh'].area_faces
    for lab in (res['labels'], labels):                               # before and after moving borders to creases
        is_red = np.array([mats[r]['rgb'][0] - mats[r]['rgb'][1] > 0.3 for r in lab])
        assert area[seen & cap & is_red].sum() / area[seen & cap].sum() > 0.85     # the cap the photo saw is red
        assert area[seen & ~cap & is_red].sum() / area[seen & ~cap].sum() < 0.03   # the body is not
    res['labels'] = labels
    scene, factors = paint.build_scene(res, mats, kept)
    glb = paint.write_glb(scene, tmp_path / 'model.glb', factors)
    from katachi.glb import validate_glb
    val = validate_glb(glb)
    assert not val['errors'], val['errors']
    assert any(f[:3] == pytest.approx(paint.srgb_to_linear([*red, 1])[:3], abs=1e-5) for f in factors.values())
    assert any(n.startswith('marks_main') for n in scene.geometry)      # the kept mark is a textured piece


# ------------------------------------------------------------------ macOS / Linux support (checked from here, no Mac needed)
def test_gen_device_defaults_and_worker_command(tmp_path, monkeypatch):
    import kt.gen as gen
    seen = {}

    class Done:
        returncode, stdout, stderr = 0, '{"timings_s": {}, "faces": 1}\n', ''

    def fake_run(cmd, **kw):
        seen['cmd'], seen['env'] = cmd, kw['env']
        return Done()

    monkeypatch.setattr(gen, 'available', lambda: True)
    monkeypatch.setattr(gen.subprocess, 'run', fake_run)
    monkeypatch.delenv('KT_HY3D_DEVICE', raising=False)
    monkeypatch.delenv('PYTORCH_ENABLE_MPS_FALLBACK', raising=False)
    arg = lambda name: seen['cmd'][seen['cmd'].index(name) + 1]
    monkeypatch.setattr(gen.sys, 'platform', 'darwin')                 # macOS: the Apple silicon GPU
    gen.run_worker(tmp_path / 'a.png', tmp_path / 'm.glb', {'steps': None, 'octree': None, 'seed': 7})
    assert arg('--device') == 'mps' and arg('--steps') == '30' and arg('--octree') == '256' and arg('--seed') == '7'
    assert seen['env']['PYTORCH_ENABLE_MPS_FALLBACK'] == '1' and seen['cmd'][1] == '-I'
    monkeypatch.setattr(gen.sys, 'platform', 'win32')                  # Windows / Linux: CUDA; given values win
    gen.run_worker(tmp_path / 'a.png', tmp_path / 'm.glb', {'steps': 12, 'octree': None})
    assert arg('--device') == 'cuda' and arg('--steps') == '12' and arg('--octree') == '384'
    assert 'PYTORCH_ENABLE_MPS_FALLBACK' not in seen['env']
    monkeypatch.setenv('KT_HY3D_DEVICE', 'cpu')
    gen.run_worker(tmp_path / 'a.png', tmp_path / 'm.glb', {})
    assert arg('--device') == 'cpu'


def test_fonts_and_unix_scripts():
    from kt.fonts import ui_font
    assert ui_font(18).getbbox('写真 abc')[2] > 0
    root = Path(__file__).resolve().parent.parent
    for name in ('kt.sh', 'setup.sh', 'setup_gen.sh'):
        data = (root / name).read_bytes()
        assert data.startswith(b'#!/usr/bin/env bash') and b'\r' not in data, name
