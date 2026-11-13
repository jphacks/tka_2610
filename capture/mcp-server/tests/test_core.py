"""Tests for memoria_core against a temporary fake captures tree (never the real captures/).

    python3 -m unittest discover -s mcp-server/tests -v   (from the repo root)
"""
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import memoria_core as core  # noqa: E402

HAS_SIPS = os.path.exists(core.SIPS_PATH)
SECRET = "pairing-code-123456"

AI5 = "AAAA1111-0000-4000-8000-000000000001"     # newest, 5-view plan, pack without cutouts or hull
OLD = "AAAA2222-0000-4000-8000-000000000002"     # older 8-view pack with _cutout.jpg, hull.obj, a missing slot
NOPACK = "BBBB3333-0000-4000-8000-000000000003"  # oldest, no pack
PARTIAL = "CCCC4444-0000-4000-8000-000000000004"  # receipt not complete: must be invisible
INCOMING = "DDDD5555-0000-4000-8000-000000000005"  # only under incoming/: must be invisible


def make_png(width, height):
    raw = b"".join(b"\x00" + bytes((x * 7 + y * 3) % 256 for x in range(width)) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def fake_jpeg(width, height):
    """JPEG markers only (SOI, APP0, SOF0, EOI): enough for the header parser, not decodable."""
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof0 = b"\xff\xc0" + struct.pack(">HBHHB", 11, 8, height, width, 1) + b"\x01\x11\x00"
    return b"\xff\xd8" + app0 + sof0 + b"\xff\xd9"


def write(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, (dict, list)):
        data = json.dumps(data, ensure_ascii=False).encode("utf-8")
    elif isinstance(data, str):
        data = data.encode("utf-8")
    path.write_bytes(data)


def photo(pid, seq, az, el, target):
    return {"photoId": pid, "sequence": seq, "capturedAt": "2026-11-12T10:00:%02d+09:00" % seq,
            "referenceFrameId": "ref-1",
            "image": {"file": "photos/%s.jpg" % pid, "width": 4032, "height": 3024, "displayRotationDegClockwise": 90},
            "camera": {"cameraToWorld": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
                       "intrinsics": [[3000, 0, 2016], [0, 3000, 1512], [0, 0, 1]],
                       "intrinsicsResolution": {"width": 4032, "height": 3024}, "trackingState": "normal",
                       "exposureDurationS": 0.01},
            "direction": {"confirmed": True, "targetId": target, "azimuthDeg": az, "elevationDeg": el,
                          "distanceM": 0.3, "unconfirmedReason": None},
            "mask": {"status": "candidate", "file": "masks/%s.png" % pid, "check": {"status": "ok", "reasons": []}}}


def view(name, pid, az, el, file=True, cutout=None, missing=None):
    return {"name": name, "label": name.replace("_", "-"), "photoId": pid, "azimuthDeg": az, "elevationDeg": el,
            "distanceM": 0.3, "requestedAzimuthDeg": az, "requestedElevationDeg": el, "targetId": "t-" + name,
            "maskUse": "good", "notes": [], "missingReason": missing,
            "file": "views/%s.jpg" % name if file else None, "cutoutFile": cutout}


def make_session(root: Path, sid, plan, photos, received_at, complete=True):
    folder = root / "sessions" / sid
    write(folder / "session.json", {"schema": "memoria.capture.session", "sessionId": sid, "title": "t-" + sid[:4],
                                    "directionPlan": {"id": plan, "targets": []}, "photos": photos,
                                    "referenceFrames": [{"id": "ref-1", "basePointWorld": [0, 0, 0],
                                                         "objectToWorld": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
                                                         "object": {"heightM": 0.1, "radiusM": 0.05}}]})
    write(folder / "_receipt.json", {"complete": complete, "sessionId": sid, "receivedAt": received_at})
    for p in photos:
        write(folder / "photos" / ("%s.jpg" % p["photoId"]), fake_jpeg(4032, 3024))
        write(folder / "masks" / ("%s.png" % p["photoId"]), make_png(8, 6))


def make_pack(root: Path, sid, views, hull=False, extra_files=()):
    pack = root / "for_claude" / sid
    write(pack / "brief.md", "# brief for %s\n" % sid)
    write(pack / "measurements.json", {"status": "approximate" if not hull else "measured", "sizeCm": {"width": 5}})
    write(pack / "overview.jpg", fake_jpeg(1200, 1800))
    files = []
    for v in views:
        if v["file"]:
            write(pack / v["file"], fake_jpeg(800, 600))
            files.append(v["file"])
        if v["cutoutFile"]:
            write(pack / v["cutoutFile"], fake_jpeg(800, 600))
            files.append(v["cutoutFile"])
    if hull:
        write(pack / "hull.obj", "v 0 0 0\n")
    for rel in extra_files:
        write(pack / rel, fake_jpeg(10, 10))
    write(pack / "pack.json", {"schema": "memoria.claude-pack", "title": "t-" + sid[:4], "views": views,
                               "files": files, "coverage": {"photoCount": len(views)},
                               "provenance": {"sessionId": sid, "generatedAt": "2026-11-12T01:00:00Z"}})
    return pack


def ids(n, base):
    return ["%s-0000-4000-8000-%012d" % (base, i) for i in range(n)]


class CoreTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "captures"
        names = ["front", "right", "back", "left", "top"]
        angles = [(0, 15), (90, 15), (180, 15), (270, 15), (0, 85)]
        ai5_ids = ids(5, "A0000001")
        make_session(self.root, AI5, "ai5", [photo(pid, i + 1, az, el, "x") for i, (pid, (az, el)) in
                                             enumerate(zip(ai5_ids, angles))], "2026-11-12T10:05:00+09:00")
        make_pack(self.root, AI5, [view(n, pid, az, el) for n, pid, (az, el) in zip(names, ai5_ids, angles)],
                  extra_files=["views/extra_shot.jpg"])
        old_ids = ids(3, "A0000002")
        make_session(self.root, OLD, "ring8", [photo(pid, i + 1, 45 * i, 20, "y") for i, pid in enumerate(old_ids)],
                     "2026-11-12T00:30:00Z")
        make_pack(self.root, OLD, [view("front", old_ids[0], 0, 20, cutout="views/front_cutout.jpg"),
                                   view("front_right", old_ids[1], 45, 20, cutout="views/front_right_cutout.jpg"),
                                   view("top", None, None, 70, file=False, missing="no photo at 40° elevation or higher")],
                  hull=True)
        make_session(self.root, NOPACK, "ring4", [photo(ids(1, "A0000003")[0], 1, 0, 20, "z")],
                     "2026-11-11T09:00:00+09:00")
        make_session(self.root, PARTIAL, "ai5", [], "2026-11-12T11:00:00+09:00", complete=False)
        write(self.root / "incoming" / INCOMING / "upload" / "session.json", {"sessionId": INCOMING})
        write(self.root / ".receiver.json", {"receiverId": "r", "pairingCode": SECRET})
        self.sessions_snapshot = self.snapshot(self.root / "sessions")

    def tearDown(self):
        # No operation may write under sessions/.
        self.assertEqual(self.snapshot(self.root / "sessions"), self.sessions_snapshot)
        self.tmp.cleanup()

    @staticmethod
    def snapshot(folder: Path):
        return {str(p.relative_to(folder)): (p.stat().st_size, p.stat().st_mtime_ns)
                for p in sorted(folder.rglob("*"))}

    def assertNoSecrets(self, result):
        text = json.dumps(result, ensure_ascii=False)
        self.assertNotIn(SECRET, text)
        self.assertNotIn("incoming", text)
        self.assertNotIn(INCOMING, text)
        self.assertNotIn(PARTIAL, text)


FLAT = "EEEE6666-0000-4000-8000-000000000006"  # flat artwork (workKind flat, plan flat1), pack without overview


class FlatTests(CoreTestBase):
    """A flat-artwork session added on top of the base fixtures (snapshot retaken so tearDown still guards sessions/)."""

    def setUp(self):
        super().setUp()
        pid = ids(1, "A0000006")[0]
        p = photo(pid, 1, None, 86.5, "top-e90")
        p["referenceFrameId"] = None
        p["mask"] = {"status": "notGenerated", "file": None, "check": None}
        p["flat"] = {"corners": {"topLeft": [10, 20], "topRight": [30, 20], "bottomRight": [30, 40], "bottomLeft": [10, 40]},
                     "sheetAtFrameEdge": False, "size": {"widthM": 0.297, "heightM": 0.21, "planeSource": "estimatedPlane"},
                     "rectified": {"file": "rectified/%s.jpg" % pid, "width": 2970, "height": 2100}}
        make_session(self.root, FLAT, "flat1", [p], "2026-11-12T09:00:00+09:00")
        folder = self.root / "sessions" / FLAT
        session = json.loads((folder / "session.json").read_text("utf-8"))
        session["workKind"] = "flat"
        session["referenceFrames"] = []
        write(folder / "session.json", session)
        (folder / "masks" / ("%s.png" % pid)).unlink()
        write(folder / "rectified" / ("%s.jpg" % pid), fake_jpeg(2970, 2100))
        artwork = view("artwork", pid, None, 86.5)
        artwork["cropSource"] = "rectified"
        whole = view("photo", pid, None, 86.5)
        pack = make_pack(self.root, FLAT, [artwork, whole])
        (pack / "overview.jpg").unlink()
        index = json.loads((pack / "pack.json").read_text("utf-8"))
        index["workKind"] = "flat"
        index["flat"] = {"photoId": pid, "artworkSource": "rectified", "rectifiedInSession": "rectified/%s.jpg" % pid}
        write(pack / "pack.json", index)
        write(pack / "measurements.json", {"workKind": "flat", "status": "ok", "method": "flatSheetCorners", "sizeCm": None,
                                           "sheet": {"widthCm": 29.7, "heightCm": 21.0}})
        self.pid = pid
        self.sessions_snapshot = self.snapshot(self.root / "sessions")

    def test_list_and_latest_show_work_kind(self):
        kinds = {s["sessionId"]: s["workKind"] for s in core.list_sessions(self.root)["sessions"]}
        self.assertEqual(kinds[FLAT], "flat")
        self.assertEqual(kinds[AI5], "object")  # no workKind in session.json: object
        self.assertEqual(kinds[NOPACK], "object")
        guidance = {s["sessionId"]: s["guidance"] for s in core.list_sessions(self.root)["sessions"]}
        self.assertIsNone(guidance[FLAT])  # flat artwork has no guidance
        latest = core.latest_session(self.root, "2026-11-12T08:00:00+09:00")
        self.assertEqual(latest["session"]["sessionId"], AI5)
        flat = next(s for s in core.list_sessions(self.root)["sessions"] if s["sessionId"] == FLAT)
        self.assertEqual(flat["capturePlan"], "flat1")

    def test_flat_brief_and_views(self):
        brief = core.get_brief(self.root, "EEEE")
        self.assertEqual(brief["workKind"], "flat")
        self.assertEqual([v["name"] for v in brief["views"]], ["artwork", "photo"])
        self.assertIsNone(brief["overview"])
        self.assertIsNone(brief["hullObjPath"])
        self.assertEqual(brief["measurements"]["sheet"]["widthCm"], 29.7)
        self.assertEqual(brief["flat"]["artworkSource"], "rectified")
        self.assertIn("no 3D reconstruction", brief["next"])
        self.assertIsNone(brief["views"][0]["direction"]["azimuthDeg"])
        path, entry = core.resolve_view(self.root, FLAT, "artwork")
        self.assertEqual(path.name, "artwork.jpg")
        self.assertEqual(entry["kind"], "photo")
        data, fmt, info = core.load_image(path, 1568)
        self.assertEqual((fmt, info["width"], info["height"]), ("jpeg", 800, 600))
        with self.assertRaises(core.MemoriaError) as ctx:
            core.resolve_view(self.root, FLAT, "overview")
        self.assertIn("no overview.jpg", str(ctx.exception))
        self.assertNoSecrets(brief)

    def test_object_brief_reports_object(self):
        self.assertEqual(core.get_brief(self.root, AI5)["workKind"], "object")
        self.assertNotIn("flat", core.get_brief(self.root, AI5))

    def test_flat_declared_sheet(self):
        self.assertIsNone(core.get_brief(self.root, FLAT)["declaredSize"])  # nothing picked: null
        self.assertNotIn("the person picked yatsugiri", core.get_brief(self.root, FLAT)["next"])
        folder = self.root / "sessions" / FLAT
        session = json.loads((folder / "session.json").read_text("utf-8"))
        session["declaredSize"] = {"sheet": {"id": "yatsugiri", "longSideM": 0.392, "shortSideM": 0.271}, "heightM": 0.5}
        write(folder / "session.json", session)
        self.sessions_snapshot = self.snapshot(self.root / "sessions")
        expected = {"sheet": {"id": "yatsugiri", "longSideM": 0.392, "shortSideM": 0.271}, "heightM": None}  # flat: no height
        flat = next(s for s in core.list_sessions(self.root)["sessions"] if s["sessionId"] == FLAT)
        self.assertEqual(flat["declaredSize"], expected)
        brief = core.get_brief(self.root, FLAT)
        self.assertEqual(brief["declaredSize"], expected)
        self.assertIn("the person picked yatsugiri (27.1 × 39.2 cm)", brief["next"])
        self.assertIn("'declared'", brief["next"])
        originals = core.get_original_photos(self.root, FLAT)
        self.assertEqual(originals["declaredSize"], expected)
        self.assertTrue(any("declaredSize" in n for n in originals["notes"]))
        self.assertNoSecrets(brief)
        session["declaredSize"] = {"sheet": {"id": "custom", "longSideM": 0.3, "shortSideM": 0.21}}
        write(folder / "session.json", session)
        self.sessions_snapshot = self.snapshot(self.root / "sessions")
        self.assertIn("typed in the paper size (custom, 21.0 × 30.0 cm)", core.get_brief(self.root, FLAT)["next"])

    def test_flat_original_photos(self):
        result = core.get_original_photos(self.root, FLAT)
        self.assertEqual(result["workKind"], "flat")
        [p] = result["photos"]
        self.assertEqual(p["flat"]["rectified"], "rectified/%s.jpg" % self.pid)
        self.assertEqual(p["flat"]["size"]["widthM"], 0.297)
        self.assertIsNone(p["mask"])
        self.assertIsNone(core.get_original_photos(self.root, AI5)["photos"][0]["flat"])


FREE = "ABCD8888-0000-4000-8000-000000000008"  # free capture 3D session (guidance free, plan free)
HEADING = "FFFF7777-0000-4000-8000-000000000007"  # heading-guided 3D session (guidance heading)


class HeadingTests(CoreTestBase):
    """A heading-guided session added on top of the base fixtures."""

    def setUp(self):
        super().setUp()
        pids = ids(2, "A0000007")
        photos = [photo(pid, i + 1, az, 15, t) for i, (pid, az, t) in enumerate(zip(pids, (0, 90), ("a000-e15", "a090-e15")))]
        for p in photos:
            p["heading"] = {"relativeHeadingDeg": p["direction"]["azimuthDeg"], "pitchDeg": 15.1, "position": "ok",
                            "estimatedDistanceM": 0.3}
        make_session(self.root, HEADING, "ai5", photos, "2026-11-12T08:00:00+09:00")
        folder = self.root / "sessions" / HEADING
        session = json.loads((folder / "session.json").read_text("utf-8"))
        session["guidance"] = "heading"
        session["referenceFrames"][0]["basePointWorld"] = None
        session["referenceFrames"][0]["heading"] = {"frontHeadingDeg": 7.0, "frontPitchDeg": 15.1, "derivation": {
            "status": "lowConfidence", "reasons": ["onlyTwoPhotos"], "centerWorld": [0.1, -0.2, -0.4], "residualRmsM": 0.0,
            "origin": "center", "size": None}}
        write(folder / "session.json", session)
        pack = make_pack(self.root, HEADING, [view("front", pids[0], 0, 15), view("right", pids[1], 90, 15)])
        index = json.loads((pack / "pack.json").read_text("utf-8"))
        index["workKind"] = "object"
        index["guidance"] = "heading"
        write(pack / "pack.json", index)
        self.sessions_snapshot = self.snapshot(self.root / "sessions")

    def test_summary_brief_and_originals_show_guidance(self):
        by_id = {s["sessionId"]: s for s in core.list_sessions(self.root)["sessions"]}
        self.assertEqual(by_id[HEADING]["guidance"], "heading")
        self.assertEqual(by_id[AI5]["guidance"], "baseCylinder")  # 3D work without the field: the old method
        brief = core.get_brief(self.root, HEADING)
        self.assertEqual(brief["guidance"], "heading")
        self.assertIn("derived after capture", brief["next"])
        self.assertEqual(core.get_brief(self.root, AI5)["guidance"], "baseCylinder")
        originals = core.get_original_photos(self.root, HEADING)
        self.assertEqual(originals["guidance"], "heading")
        frame = originals["referenceFrames"][0]
        self.assertIsNone(frame["basePointWorld"])
        self.assertEqual(frame["heading"]["derivation"]["origin"], "center")
        self.assertEqual(originals["photos"][1]["heading"]["position"], "ok")
        self.assertTrue(any("guidance heading" in n for n in originals["notes"]))
        self.assertIsNone(core.get_original_photos(self.root, AI5)["photos"][0]["heading"])
        self.assertNoSecrets(brief)


class DeclaredHeightTests(CoreTestBase):
    """declaredSize.heightM on 3D work (typed in on the iPhone, not measured)."""

    def setUp(self):
        super().setUp()
        folder = self.root / "sessions" / AI5
        session = json.loads((folder / "session.json").read_text("utf-8"))
        session["declaredSize"] = {"sheet": {"id": "a4", "longSideM": 0.297, "shortSideM": 0.21}, "heightM": 0.12}
        write(folder / "session.json", session)
        self.sessions_snapshot = self.snapshot(self.root / "sessions")

    def test_height_is_reported_and_preferred(self):
        expected = {"sheet": None, "heightM": 0.12}  # 3D work: the sheet is dropped
        by_id = {s["sessionId"]: s for s in core.list_sessions(self.root)["sessions"]}
        self.assertEqual(by_id[AI5]["declaredSize"], expected)
        self.assertIsNone(by_id[OLD]["declaredSize"])  # sessions from before: null
        brief = core.get_brief(self.root, AI5)
        self.assertEqual(brief["declaredSize"], expected)
        self.assertIn("typed in the height: 12.0 cm", brief["next"])
        self.assertIn("Prefer it", brief["next"])
        self.assertNotIn("typed in the height", core.get_brief(self.root, OLD)["next"])
        self.assertEqual(core.get_original_photos(self.root, AI5)["declaredSize"], expected)

    def test_malformed_declared_size_is_ignored(self):
        folder = self.root / "sessions" / AI5
        session = json.loads((folder / "session.json").read_text("utf-8"))
        for bad in ("12cm", {"heightM": "12"}, {"heightM": True}, [], {"sheet": None, "heightM": None}):
            session["declaredSize"] = bad
            write(folder / "session.json", session)
            self.assertIsNone(core.list_sessions(self.root)["sessions"][0]["declaredSize"], bad)
        self.sessions_snapshot = self.snapshot(self.root / "sessions")


class FreeTests(CoreTestBase):
    """A free-capture 3D session (guidance free, plan free): photos shot freely, views photo-01..., no overview."""

    def setUp(self):
        super().setUp()
        pids = ids(3, "A0000008")
        photos = []
        for i, (pid, el) in enumerate(zip(pids, (18.0, 25.0, 82.0))):
            p = photo(pid, i + 1, None, el, None)
            p["referenceFrameId"] = None
            p["direction"]["distanceM"] = None
            p["mask"] = {"status": "notGenerated", "file": None, "check": None}
            photos.append(p)
        make_session(self.root, FREE, "free", photos, "2026-11-12T07:00:00+09:00")
        folder = self.root / "sessions" / FREE
        session = json.loads((folder / "session.json").read_text("utf-8"))
        session["guidance"] = "free"
        session["referenceFrames"] = []
        session["declaredSize"] = {"sheet": None, "heightM": 0.08}
        write(folder / "session.json", session)
        for pid in pids:
            (folder / "masks" / ("%s.png" % pid)).unlink()
        views = [view("photo-%02d" % (i + 1), pid, None, el) for i, (pid, el) in enumerate(zip(pids, (18.0, 25.0, 82.0)))]
        pack = make_pack(self.root, FREE, views)
        (pack / "overview.jpg").unlink()
        index = json.loads((pack / "pack.json").read_text("utf-8"))
        index["workKind"] = "object"
        index["guidance"] = "free"
        index["free"] = {"photoCount": 3, "viewCount": 3, "selection": "all"}
        write(pack / "pack.json", index)
        write(pack / "measurements.json", {"status": "unavailable", "method": "freeCapture", "sizeCm": None,
                                           "declaredHeight": {"heightM": 0.08, "heightCm": 8.0, "source": "userEntered"}})
        self.pids = pids
        self.sessions_snapshot = self.snapshot(self.root / "sessions")

    def test_free_session_summary_brief_and_views(self):
        by_id = {s["sessionId"]: s for s in core.list_sessions(self.root)["sessions"]}
        self.assertEqual(by_id[FREE]["guidance"], "free")
        self.assertEqual(by_id[FREE]["capturePlan"], "free")
        self.assertEqual(by_id[FREE]["declaredSize"], {"sheet": None, "heightM": 0.08})
        brief = core.get_brief(self.root, FREE)
        self.assertEqual(brief["guidance"], "free")
        self.assertEqual([v["name"] for v in brief["views"]], ["photo-01", "photo-02", "photo-03"])
        self.assertIsNone(brief["overview"])
        self.assertIn("Free capture", brief["next"])
        self.assertIn("decide from the pictures", brief["next"])
        self.assertIn("typed in the height: 8.0 cm", brief["next"])
        self.assertEqual(brief["views"][2]["direction"]["elevationDeg"], 82.0)
        path, _ = core.resolve_view(self.root, FREE, "photo-02")
        self.assertEqual(path.name, "photo-02.jpg")
        originals = core.get_original_photos(self.root, FREE)
        self.assertEqual(originals["guidance"], "free")
        self.assertEqual(originals["referenceFrames"], [])
        self.assertTrue(any("guidance free" in n for n in originals["notes"]))
        self.assertIsNone(originals["photos"][0]["mask"])
        self.assertNoSecrets(brief)

    def test_other_sessions_keep_their_guidance(self):
        by_id = {s["sessionId"]: s for s in core.list_sessions(self.root)["sessions"]}
        self.assertEqual(by_id[AI5]["guidance"], "baseCylinder")
        self.assertNotIn("Free capture", core.get_brief(self.root, AI5)["next"])


class SessionTests(CoreTestBase):
    def test_list_sessions_newest_first_and_only_complete(self):
        result = core.list_sessions(self.root)
        self.assertEqual([s["sessionId"] for s in result["sessions"]], [AI5, OLD, NOPACK])
        self.assertEqual(result["total"], 3)
        first = result["sessions"][0]
        self.assertEqual(first["capturePlan"], "ai5")
        self.assertEqual(first["photoCount"], 5)
        self.assertTrue(first["hasPack"])
        self.assertTrue(Path(first["packDir"]).is_absolute())
        self.assertTrue(Path(first["briefPath"]).is_file())
        nopack = result["sessions"][2]
        self.assertFalse(nopack["hasPack"])
        self.assertIsNone(nopack["packDir"])
        self.assertNoSecrets(result)

    def test_list_sessions_limit(self):
        self.assertEqual(len(core.list_sessions(self.root, limit=1)["sessions"]), 1)

    def test_list_sessions_without_captures_dir(self):
        result = core.list_sessions(Path(self.tmp.name) / "missing")
        self.assertEqual(result["sessions"], [])

    def test_latest_session(self):
        found = core.latest_session(self.root)
        self.assertEqual(found["status"], "found")
        self.assertEqual(found["session"]["sessionId"], AI5)
        # 10:05+09:00 is 01:05Z: after 01:00Z, not after 01:05Z.
        self.assertEqual(core.latest_session(self.root, "2026-11-12T01:00:00Z")["status"], "found")
        nothing = core.latest_session(self.root, "2026-11-12T10:05:00+09:00")
        self.assertEqual(nothing["status"], "nothing_new")
        self.assertIsNone(nothing["session"])
        self.assertEqual(nothing["newestKnown"]["sessionId"], AI5)
        self.assertIn("latest_session", nothing["hint"])
        with self.assertRaises(core.MemoriaError):
            core.latest_session(self.root, "yesterday")

    def test_latest_session_empty(self):
        empty = Path(self.tmp.name) / "empty"
        self.assertEqual(core.latest_session(empty)["status"], "no_sessions")

    def test_latest_session_pack_not_ready(self):
        sid = "EEEE6666-0000-4000-8000-000000000006"
        make_session(self.root, sid, "ai5", [], "2026-11-12T12:00:00+09:00")
        result = core.latest_session(self.root, "2026-11-12T11:59:00+09:00")
        self.assertEqual(result["session"]["sessionId"], sid)
        self.assertFalse(result["session"]["hasPack"])
        self.assertIn("rebuild_pack", result["hint"])
        self.sessions_snapshot = self.snapshot(self.root / "sessions")

    def test_resolve_session_prefix(self):
        self.assertEqual(core.resolve_session(self.root, "bbbb").name, NOPACK)
        self.assertEqual(core.resolve_session(self.root, AI5.lower()).name, AI5)
        with self.assertRaises(core.MemoriaError) as ctx:
            core.resolve_session(self.root, "AAAA")
        self.assertIn(AI5, str(ctx.exception))
        self.assertIn(OLD, str(ctx.exception))
        with self.assertRaises(core.MemoriaError) as ctx:
            core.resolve_session(self.root, "FFFF")
        self.assertIn(NOPACK, str(ctx.exception))
        for hidden in ("CCCC", "DDDD", "", "  ", "../sessions"):
            with self.assertRaises(core.MemoriaError):
                core.resolve_session(self.root, hidden)


class PackTests(CoreTestBase):
    def test_ai5_brief_uses_names_from_pack(self):
        brief = core.get_brief(self.root, "AAAA1")
        self.assertEqual(brief["brief"], "# brief for %s\n" % AI5)
        names = [v["name"] for v in brief["views"]]
        self.assertEqual(names, ["front", "right", "back", "left", "top", "extra_shot"])
        self.assertTrue(all(v["kind"] == "photo" for v in brief["views"][:5]))
        extra = brief["views"][5]
        self.assertEqual(extra["kind"], "unlisted")
        self.assertIsNone(extra["direction"])
        top = brief["views"][4]
        self.assertEqual(top["direction"]["elevationDeg"], 85)
        self.assertEqual((top["width"], top["height"]), (800, 600))
        self.assertTrue(Path(top["path"]).is_absolute() and Path(top["path"]).is_file())
        self.assertIsNone(brief["hullObjPath"])
        self.assertEqual(brief["missingViews"], [])
        self.assertEqual((brief["overview"]["width"], brief["overview"]["height"]), (1200, 1800))
        self.assertNoSecrets(brief)

    def test_old_pack_has_cutouts_hull_and_missing(self):
        brief = core.get_brief(self.root, OLD)
        names = [v["name"] for v in brief["views"]]
        self.assertEqual(names, ["front", "front_cutout", "front_right", "front_right_cutout"])
        self.assertEqual(brief["views"][1]["kind"], "cutout")
        self.assertEqual(brief["views"][1]["direction"]["azimuthDeg"], 0)
        self.assertTrue(Path(brief["hullObjPath"]).is_file())
        self.assertEqual([m["name"] for m in brief["missingViews"]], ["top"])
        with self.assertRaises(core.MemoriaError) as ctx:
            core.resolve_view(self.root, OLD, "top")
        self.assertIn("no photo", str(ctx.exception))

    def test_no_pack(self):
        with self.assertRaises(core.MemoriaError) as ctx:
            core.get_brief(self.root, NOPACK)
        self.assertIn("rebuild_pack", str(ctx.exception))

    def test_resolve_view_only_listed_names(self):
        path, entry = core.resolve_view(self.root, AI5, "front")
        self.assertEqual(path, (self.root / "for_claude" / AI5 / "views" / "front.jpg").resolve())
        self.assertEqual(entry["sessionId"], AI5)
        path, entry = core.resolve_view(self.root, AI5, "overview")
        self.assertEqual(path.name, "overview.jpg")
        for bad in ("../../.receiver.json", "views/front.jpg", "front.jpg", str(path), "/etc/passwd",
                    "../../sessions/%s/session.json" % AI5, "front_cutout", ""):
            with self.assertRaises(core.MemoriaError, msg=bad):
                core.resolve_view(self.root, AI5, bad)

    def test_pack_json_paths_outside_the_pack_are_ignored(self):
        pack = self.root / "for_claude" / AI5
        index = json.loads((pack / "pack.json").read_text())
        index["views"].append(view("evil", None, 0, 0) | {"file": "../../.receiver.json"})
        index["views"].append(view("evil2", None, 0, 0) | {"file": "../../sessions/%s/photos/x.jpg" % AI5})
        write(pack / "pack.json", index)
        outside = Path(self.tmp.name) / "outside.jpg"
        write(outside, fake_jpeg(5, 5))
        os.symlink(outside, pack / "views" / "linked.jpg")
        views, missing = core.pack_views(pack)
        self.assertNotIn("evil", views)
        self.assertNotIn("evil2", views)
        self.assertNotIn("linked", views)
        self.assertIn("evil", [m["name"] for m in missing])
        with self.assertRaises(core.MemoriaError):
            core.resolve_view(self.root, AI5, "linked")

    def test_image_size(self):
        d = Path(self.tmp.name)
        write(d / "a.png", make_png(7, 3))
        write(d / "a.jpg", fake_jpeg(640, 480))
        write(d / "a.txt", "hello")
        self.assertEqual(core.image_size(d / "a.png"), (7, 3))
        self.assertEqual(core.image_size(d / "a.jpg"), (640, 480))
        self.assertIsNone(core.image_size(d / "a.txt"))
        self.assertIsNone(core.image_size(d / "nope.jpg"))

    def test_load_image_small_is_returned_as_is(self):
        path = self.root / "for_claude" / AI5 / "views" / "front.jpg"
        data, fmt, info = core.load_image(path, 1568)
        self.assertEqual(data, path.read_bytes())
        self.assertEqual(fmt, "jpeg")
        self.assertFalse(info["downscaled"])

    def test_load_image_without_sips_is_not_downscaled(self):
        path = self.root / "for_claude" / AI5 / "overview.jpg"
        data, fmt, info = core.load_image(path, 512, sips_path="/nonexistent/sips")
        self.assertFalse(info["downscaled"])
        self.assertIn("not downscaled", info["note"])

    @unittest.skipUnless(HAS_SIPS, "sips not available")
    def test_load_image_downscales_with_sips(self):
        d = Path(self.tmp.name)
        write(d / "big.png", make_png(300, 200))
        data, fmt, info = core.load_image(d / "big.png", 100)
        self.assertEqual(fmt, "png")
        self.assertTrue(info["downscaled"])
        self.assertEqual(info["width"], 100)
        self.assertIn(info["height"], (66, 67))
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        subprocess.run([core.SIPS_PATH, "-s", "format", "jpeg", str(d / "big.png"), "--out", str(d / "big.jpg")],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        data, fmt, info = core.load_image(d / "big.jpg", 64)
        self.assertEqual(fmt, "jpeg")
        self.assertEqual(data[:2], b"\xff\xd8")
        self.assertEqual(max(info["width"], info["height"]), 64)
        self.assertEqual((info["originalWidth"], info["originalHeight"]), (300, 200))


class OriginalPhotoTests(CoreTestBase):
    def test_original_photos(self):
        result = core.get_original_photos(self.root, "aaaa1")
        self.assertEqual(result["photoCount"], 5)
        self.assertEqual(result["capturePlan"], "ai5")
        first = result["photos"][0]
        self.assertTrue(Path(first["path"]).is_absolute() and Path(first["path"]).is_file())
        self.assertEqual(first["mask"], "masks/%s.png" % first["photoId"])
        self.assertIsNone(first["upright"])
        self.assertEqual(first["usedInPackAs"], "front")
        self.assertEqual(first["camera"]["intrinsics"][0][0], 3000)
        self.assertNotIn("exposureDurationS", first["camera"])
        self.assertEqual(first["direction"]["azimuthDeg"], 0)
        self.assertEqual(result["referenceFrames"][0]["id"], "ref-1")
        self.assertNoSecrets(result)


class WriteTests(CoreTestBase):
    def fake_pack_tool(self, exit_code=0):
        """A stand-in for memoria-pack: records its arguments and writes a marker into for_claude/<id>/."""
        script = Path(self.tmp.name) / "memoria-pack"
        script.write_text("#!/bin/sh\n"
                          "echo \"$@\" > \"%s/args.txt\"\n"
                          "mkdir -p \"$3/for_claude/$1\" && echo rebuilt > \"$3/for_claude/$1/brief.md\"\n"
                          "echo \"[pack] $1: done\"\n"
                          "exit %d\n" % (self.tmp.name, exit_code))
        script.chmod(0o755)
        return script

    def test_rebuild_pack_not_built(self):
        with self.assertRaises(core.MemoriaError) as ctx:
            core.rebuild_pack(self.root, AI5, pack_path=Path(self.tmp.name) / "missing")
        self.assertIn("swift build -c release", str(ctx.exception))

    def test_rebuild_pack_runs_like_the_receiver(self):
        tool = self.fake_pack_tool()
        result = core.rebuild_pack(self.root, "bbbb", cutouts=True, pack_path=tool)
        args = (Path(self.tmp.name) / "args.txt").read_text().split()
        self.assertEqual(args, [NOPACK, "--data-dir", str(self.root), "--force", "--cutouts"])
        self.assertEqual(result["summary"], "[pack] %s: done" % NOPACK)
        self.assertEqual(Path(result["briefPath"]).read_text(), "rebuilt\n")
        core.rebuild_pack(self.root, NOPACK, pack_path=tool)
        self.assertNotIn("--cutouts", (Path(self.tmp.name) / "args.txt").read_text())

    def test_rebuild_pack_failure(self):
        with self.assertRaises(core.MemoriaError) as ctx:
            core.rebuild_pack(self.root, AI5, pack_path=self.fake_pack_tool(exit_code=3))
        self.assertIn("exit 3", str(ctx.exception))

    def test_output_dir(self):
        result = core.output_dir(self.root, "aaaa1", "claude v1")
        expected = (self.root / "reconstructions" / AI5 / "claude-v1").resolve()
        self.assertEqual(result["path"], str(expected))
        self.assertTrue(expected.is_dir())
        self.assertFalse(result["existed"])
        (expected / "notes.md").write_text("x")
        again = core.output_dir(self.root, AI5, "claude-v1")
        self.assertTrue(again["existed"])
        self.assertEqual(again["existingFiles"], ["notes.md"])

    def test_output_dir_label_is_sanitized(self):
        for label, clean in (("../../sessions", "sessions"), ("a/b\\c", "a-b-c"), ("v1..final", "v1.final"),
                             (".hidden", "hidden"), ("x" * 100, "x" * core.LABEL_MAX)):
            result = core.output_dir(self.root, AI5, label)
            self.assertEqual(result["label"], clean)
            self.assertTrue(core.inside(Path(result["path"]), self.root / "reconstructions"))
        for label in ("", "..", "/", "...", "日本語"):
            with self.assertRaises(core.MemoriaError, msg=label):
                core.output_dir(self.root, AI5, label)


class ReceiverStatusTests(CoreTestBase):
    def test_status_with_closed_port(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]  # bound but not listening: connections are refused
            status = core.receiver_status(self.root, pack_path=Path(self.tmp.name) / "missing", port=port)
        self.assertFalse(status["receiverListening"])
        self.assertIn("memoria_receiver.py", status["hint"])
        self.assertEqual(status["sessionCount"], 3)
        self.assertEqual(status["newestSessionId"], AI5)
        self.assertFalse(status["memoriaPackBuilt"])
        self.assertIn("swift build", status["buildCommand"])
        self.assertNoSecrets(status)

    def test_status_with_listening_port(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            s.listen(1)
            status = core.receiver_status(self.root, port=s.getsockname()[1])
        self.assertTrue(status["receiverListening"])
        self.assertNotIn("hint", status)
        self.assertNoSecrets(status)

    def test_captures_dir_env(self):
        old = os.environ.get("MEMORIA_CAPTURES_DIR")
        try:
            os.environ["MEMORIA_CAPTURES_DIR"] = str(self.root)
            self.assertEqual(core.captures_dir(), self.root.resolve())
            del os.environ["MEMORIA_CAPTURES_DIR"]
            self.assertEqual(core.captures_dir(), Path(core.__file__).resolve().parent.parent / "captures")
        finally:
            if old is not None:
                os.environ["MEMORIA_CAPTURES_DIR"] = old


if __name__ == "__main__":
    unittest.main()
