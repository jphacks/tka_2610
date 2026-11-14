"""Tests for memoria_build (model building through the prepared builders) and the installer's desktop config merge.

    python3 -m unittest discover -s mcp-server/tests -v   (from capture/)

Standard library only, no network. The builders themselves are replaced by a fake for most tests; the tests that
run the real builders (BuilderRunTests) are skipped automatically when tools/.venv is not set up
(scripts/install-mcp.sh --tools-only), and the rendering part also when Node/Playwright are missing.
"""
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import memoria_build as build  # noqa: E402
import memoria_core as core  # noqa: E402
from test_core import (AI5, OLD, CoreTestBase, fake_jpeg, ids, make_pack, make_session, photo,  # noqa: E402
                       view, write)

FLAT = "EEEE6666-0000-4000-8000-000000000006"
FREE_TOP = "FFFF7777-0000-4000-8000-000000000007"
FREE_LOW = "FFFF8888-0000-4000-8000-000000000008"
INSTALLER = Path(__file__).resolve().parent.parent.parent / "scripts" / "install-mcp.sh"


def tiny_glb(size=(0.2, 0.03, 0.1)):
    """A GLB with only a JSON chunk: one mesh, one triangle-list primitive with POSITION min/max and indices."""
    gltf = {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
            "nodes": [{"name": "object", "children": [1]}, {"mesh": 0}],
            "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1, "mode": 4}]}],
            "accessors": [{"count": 8, "type": "VEC3", "componentType": 5126,
                           "min": [-size[0] / 2, 0, -size[2] / 2], "max": [size[0] / 2, size[1], size[2] / 2]},
                          {"count": 36, "type": "SCALAR", "componentType": 5125}]}
    js = json.dumps(gltf).encode()
    js += b" " * ((4 - len(js) % 4) % 4)
    return struct.pack("<4sII", b"glTF", 2, 20 + len(js)) + struct.pack("<I4s", len(js), b"JSON") + js


FAKE_BUILDER = r'''
import json, sys
from pathlib import Path
script, cmd = Path(sys.argv[1]).name, sys.argv[2]
if cmd != "build":
    sys.exit("fake builder: only build")
cfg_path, out = Path(sys.argv[3]), Path(sys.argv[5])
cfg = json.loads(cfg_path.read_text())
if cfg.get("fail"):
    print("Traceback (most recent call last):\nValueError: %s" % cfg["fail"], file=sys.stderr)
    sys.exit(1)
(out / "model.glb").write_bytes(bytes.fromhex("GLB_HEX"))
(out / "seen_config.json").write_text(json.dumps({"script": script, "config": str(cfg_path)}))
if script == "flatart_glb.py":
    (out / "report.json").write_text(json.dumps({"tool": "flat-art-glb", "mode": cfg.get("mode"),
        "sheet": {"size_mm": [271, 392], "size_guessed": False}, "pieces": [], "warnings": ["w1"], "seconds": 0.1}))
    (out / "overlay.jpg").write_bytes(bytes.fromhex("JPG_HEX"))
else:
    (out / "report.json").write_text(json.dumps({"template": "slab", "size_mm": {"width": 200}, "triangles": 12}))
    (out / "top_overlay.jpg").write_bytes(bytes.fromhex("JPG_HEX"))
    print("moved more than 2.5 mm by the circle search (check top_overlay.jpg): []")
'''


class BuildTestBase(CoreTestBase):
    """Base fixtures plus a flat session (rectified artwork, declared yatsugiri) and two free 3D sessions."""

    def setUp(self):
        super().setUp()
        # flat artwork
        pid = ids(1, "A0000006")[0]
        p = photo(pid, 1, None, 86.5, "top-e90")
        p["referenceFrameId"] = None
        p["mask"] = {"status": "notGenerated", "file": None, "check": None}
        make_session(self.root, FLAT, "flat1", [p], "2026-11-12T09:00:00+09:00")
        folder = self.root / "sessions" / FLAT
        session = json.loads((folder / "session.json").read_text("utf-8"))
        session.update(workKind="flat", referenceFrames=[],
                       declaredSize={"sheet": {"id": "yatsugiri", "longSideM": 0.392, "shortSideM": 0.271}, "heightM": None})
        write(folder / "session.json", session)
        (folder / "masks" / ("%s.png" % pid)).unlink()
        write(folder / "rectified" / ("%s.jpg" % pid), fake_jpeg(1084, 1568))
        pack = make_pack(self.root, FLAT, [view("artwork", pid, None, 86.5), view("photo", pid, None, 86.5)])
        (pack / "overview.jpg").unlink()
        index = json.loads((pack / "pack.json").read_text("utf-8"))
        index.update(workKind="flat", flat={"photoId": pid, "artworkSource": "rectified"})
        write(pack / "pack.json", index)
        write(pack / "measurements.json", {"workKind": "flat", "status": "ok", "method": "declaredSheet",
                                           "sheet": {"source": "declared", "longSideM": 0.392, "shortSideM": 0.271,
                                                     "declaredSheetId": "yatsugiri", "declaredSheetName": "八つ切"}})
        # free 3D sessions: one with a photo from above (82°), one without
        for sid, base, els in ((FREE_TOP, "A0000007", (18.0, 25.0, 82.0)), (FREE_LOW, "A0000009", (15.0, 35.0))):
            pids = ids(len(els), base)
            photos = []
            for i, (q, el) in enumerate(zip(pids, els)):
                ph = photo(q, i + 1, None, el, None)
                ph["referenceFrameId"] = None
                ph["mask"] = {"status": "notGenerated", "file": None, "check": None}
                photos.append(ph)
            make_session(self.root, sid, "free", photos, "2026-11-12T08:00:00+09:00")
            f = self.root / "sessions" / sid
            s = json.loads((f / "session.json").read_text("utf-8"))
            s.update(guidance="free", referenceFrames=[], declaredSize={"sheet": None, "heightM": 0.03})
            write(f / "session.json", s)
            for q in pids:
                (f / "masks" / ("%s.png" % q)).unlink()
            pk = make_pack(self.root, sid, [view("photo-%02d" % (i + 1), q, None, el)
                                            for i, (q, el) in enumerate(zip(pids, els))])
            (pk / "overview.jpg").unlink()
            idx = json.loads((pk / "pack.json").read_text("utf-8"))
            idx.update(workKind="object", guidance="free")
            write(pk / "pack.json", idx)
            write(pk / "measurements.json", {"status": "unavailable", "method": "freeCapture", "sizeCm": None,
                                             "declaredHeight": {"heightM": 0.03, "heightCm": 3.0}})
        self.sessions_snapshot = self.snapshot(self.root / "sessions")
        self.pack = self.root / "for_claude"

    def flat_config(self):
        return build.build_guide(self.root, FLAT)["starterConfig"]

    def solid_config(self, sid=FREE_TOP, photo_value="photo-03"):
        return {"template": "slab", "top": {"photo": photo_value, "corners": [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9], [0.1, 0.9]],
                                            "width_mm": 100},
                "outline": [[0.12, 0.12], [0.88, 0.12], [0.88, 0.88], [0.12, 0.88]],
                "layers": [{"name": "body", "height_mm": 30}],
                "views": [{"name": "top", "az": 0, "el": 89.9, "up": [0, 0, -1], "photo": photo_value},
                          {"name": "front", "az": 0, "el": 18, "photo": "photo-01"}]}


class FakeBuilderMixin:
    def install_fake_builder(self):
        fake = Path(self.tmp.name) / "fake-python"
        fake.write_text("#!%s\n" % sys.executable
                        + FAKE_BUILDER.replace("GLB_HEX", tiny_glb().hex()).replace("JPG_HEX", fake_jpeg(40, 30).hex()))
        fake.chmod(0o755)
        patcher = mock.patch.dict(os.environ, {"MEMORIA_TOOLS_PYTHON": str(fake)})
        patcher.start()
        self.addCleanup(patcher.stop)
        return fake


class PathSafetyTests(BuildTestBase):
    def resolve(self, sid, value):
        return build.resolve_photo(self.root, self.root / "sessions" / sid, value, "photo")

    def test_view_names_and_paths_of_the_session_are_accepted(self):
        self.assertEqual(self.resolve(FLAT, "artwork"), (self.pack / FLAT / "views" / "artwork.jpg").resolve())
        inside_pack = str(self.pack / FREE_TOP / "views" / "photo-02.jpg")
        self.assertEqual(self.resolve(FREE_TOP, inside_pack), Path(inside_pack).resolve())
        rectified = next((self.root / "sessions" / FLAT / "rectified").iterdir())
        self.assertEqual(self.resolve(FLAT, str(rectified)), rectified.resolve())
        original = next((self.root / "sessions" / AI5 / "photos").iterdir())
        self.assertEqual(self.resolve(AI5, str(original)), original.resolve())

    def test_everything_else_is_refused(self):
        outside = Path(self.tmp.name) / "outside.jpg"
        outside.write_bytes(fake_jpeg(10, 10))
        link = self.pack / FLAT / "views" / "link.jpg"
        link.symlink_to(outside)
        sessions = self.root / "sessions"
        bad = [
            "", None, 3, "views/artwork.jpg", "../../sessions/%s/photos/x.jpg" % FLAT, "artwork\x00",
            str(outside), str(link), "/etc/hosts",
            str(self.pack / FLAT / "views" / ".." / ".." / FREE_TOP / "views" / "photo-01.jpg"),  # another session
            str(self.pack / FREE_TOP / "views" / "photo-01.jpg"),       # another session's pack
            str(self.pack / FLAT / "pack.json"), str(self.pack / FLAT / "brief.md"),   # not images
            str(sessions / FLAT / "session.json"), str(sessions / FLAT / "_receipt.json"),
            str(next((sessions / AI5 / "masks").iterdir())),            # masks are not photos
            str(self.root / ".receiver.json"),
            str(self.pack / FLAT / "views" / "missing.jpg"),
        ]
        for value in bad:
            with self.assertRaises(core.MemoriaError, msg=repr(value)):
                self.resolve(FLAT if value != str(next((sessions / AI5 / "masks").iterdir())) else AI5, value)

    def test_build_model_refuses_bad_configs_before_writing(self):
        out_root = self.root / "reconstructions"
        cases = [
            ("flat-art-glb", dict(self.flat_config(), photo="/etc/hosts"), "not an image of session"),
            ("flat-art-glb", dict(self.flat_config(), photo="../" + FLAT), "relative paths"),
            ("solid-glb", self.solid_config(photo_value=str(self.pack / FLAT / "views" / "artwork.jpg")),
             "not an image of session"),
            ("solid-glb", dict(self.solid_config(), views=[{"name": "../../evil", "photo": "photo-01"}]), "views[0].name"),
            ("solid-glb", dict(self.solid_config(), views=[{"name": "a"}, {"name": "a"}]), "unique"),
            ("solid-glb", dict(self.solid_config(), template="blob"), "template must be"),
            ("solid-glb", dict(self.solid_config(), outline="TODO: trace it"), "/outline"),
            ("flat-art-glb", [], "JSON object"),
            ("flat-art-glb", "{not json", "not valid JSON"),
            ("blender", self.flat_config(), "builder must be one of"),
        ]
        for builder, cfg, expected in cases:
            with self.assertRaises(core.MemoriaError, msg=expected) as ctx:
                build.build_model(self.root, FREE_TOP if builder == "solid-glb" else FLAT, "v1", builder, cfg)
            self.assertIn(expected, str(ctx.exception))
        self.assertFalse(out_root.exists())

    def test_todo_placeholders_are_listed(self):
        cfg = build.build_guide(self.root, FREE_TOP)["starterConfig"]
        with self.assertRaises(core.MemoriaError) as ctx:
            build.build_model(self.root, FREE_TOP, "v1", "solid-glb", cfg)
        self.assertIn("/top/corners", str(ctx.exception))
        self.assertIn("/outline", str(ctx.exception))


class BuildWriteTests(FakeBuilderMixin, BuildTestBase):
    def test_config_is_written_with_resolved_paths_and_label_is_sanitised(self):
        self.install_fake_builder()
        result, overlay = build.build_model(self.root, "eeee", "my try/1", "flat-art-glb", json.dumps(self.flat_config()))
        out = (self.root / "reconstructions" / FLAT / "my-try-1").resolve()
        self.assertEqual(result["label"], "my-try-1")
        self.assertEqual(result["outDir"], str(out))
        self.assertEqual(result["modelPath"], str(out / "model.glb"))
        self.assertEqual(overlay, self.root / "reconstructions" / FLAT / "my-try-1" / "overlay.jpg")
        cfg = json.loads((out / "config.json").read_text("utf-8"))
        self.assertEqual(cfg["photo"], str((self.pack / FLAT / "views" / "artwork.jpg").resolve()))
        self.assertEqual(cfg["sheet"]["size_mm"], [271.0, 392.0])
        seen = json.loads((out / "seen_config.json").read_text())
        self.assertEqual(seen["script"], "flatart_glb.py")
        self.assertEqual(Path(seen["config"]).resolve(), out / "config.json")
        self.assertEqual(result["sizeMm"]["x"], 200.0)
        self.assertEqual(result["triangles"], 12)
        self.assertEqual(result["warnings"], ["w1"])
        self.assertFalse(result["replacedPrevious"])
        meta = json.loads((out / "build.json").read_text("utf-8"))
        self.assertEqual(meta["builder"], "flat-art-glb")
        self.assertNoSecrets(result)

    def test_solid_view_photos_are_resolved_and_stale_check_outputs_removed(self):
        self.install_fake_builder()
        out = self.root / "reconstructions" / FREE_TOP / "v1"
        build.build_model(self.root, FREE_TOP, "v1", "solid-glb", self.solid_config())
        for name in ("compare.jpg", "validation.json", "check.json", "front.png", "keep.txt"):
            (out / name).write_text("old")
        write(out / "views.json", [{"name": "front"}, {"name": "../escape"}])
        result, overlay = build.build_model(self.root, FREE_TOP, "v1", "solid-glb", self.solid_config())
        self.assertTrue(result["replacedPrevious"])
        for name in ("compare.jpg", "validation.json", "check.json", "front.png", "views.json"):
            self.assertFalse((out / name).exists(), name)
        self.assertTrue((out / "keep.txt").exists())
        cfg = json.loads((out / "config.json").read_text("utf-8"))
        views = self.pack / FREE_TOP / "views"
        self.assertEqual(cfg["top"]["photo"], str((views / "photo-03.jpg").resolve()))
        self.assertEqual(cfg["views"][1]["photo"], str((views / "photo-01.jpg").resolve()))
        self.assertEqual(overlay.name, "top_overlay.jpg")
        self.assertTrue(any(w.startswith("moved more than") for w in result["warnings"]))

    def test_builder_error_is_returned_with_its_message(self):
        self.install_fake_builder()
        with self.assertRaises(core.MemoriaError) as ctx:
            build.build_model(self.root, FLAT, "v1", "flat-art-glb", dict(self.flat_config(), fail="colour 'x' unknown"))
        self.assertIn("flat-art-glb failed (exit 1)", str(ctx.exception))
        self.assertIn("ValueError: colour 'x' unknown", str(ctx.exception))

    def test_missing_runtime_names_the_install_command(self):
        with mock.patch.dict(os.environ, {"MEMORIA_TOOLS_PYTHON": str(Path(self.tmp.name) / "nope" / "python")}):
            with self.assertRaises(core.MemoriaError) as ctx:
                build.build_model(self.root, FLAT, "v1", "flat-art-glb", self.flat_config())
            self.assertIn("install-mcp.sh --tools-only", str(ctx.exception))
            status = build.tools_status()
            self.assertFalse(status["ready"]["build"])
            self.assertIn("install-mcp.sh --tools-only", status["fix"])

    def test_list_models(self):
        self.install_fake_builder()
        self.assertEqual(build.list_models(self.root, FLAT)["models"], [])
        build.build_model(self.root, FLAT, "v1", "flat-art-glb", self.flat_config())
        build.build_model(self.root, FLAT, "v2", "flat-art-glb", self.flat_config())
        out = self.root / "reconstructions" / FLAT
        write(out / "v2" / "validation.json", {"errors": 0, "warnings": 1, "triangles": 12})
        os.utime(out / "v1" / "model.glb", (1, 1))
        (out / "manual").mkdir()
        (out / "manual" / "model.glb").write_bytes(tiny_glb())
        os.utime(out / "manual" / "model.glb", (0, 0))
        listing = build.list_models(self.root, FLAT)
        self.assertEqual([m["label"] for m in listing["models"]], ["v2", "v1", "manual"])
        v2 = listing["models"][0]
        self.assertEqual(v2["builder"], "flat-art-glb")
        self.assertEqual(v2["validation"], {"errors": 0, "warnings": 1, "triangles": 12})
        self.assertEqual(v2["triangles"], 12)
        self.assertEqual(v2["sizeMm"]["y"], 30.0)
        self.assertTrue(v2["configPath"].endswith("/v2/config.json"))
        self.assertIsNone(listing["models"][2]["builder"])
        self.assertNoSecrets(listing)

    def test_check_model_without_model_or_renderer(self):
        with self.assertRaises(core.MemoriaError):
            build.check_model(self.root, FLAT, "v1")
        self.install_fake_builder()
        build.build_model(self.root, FLAT, "v1", "flat-art-glb", self.flat_config())
        missing = {"node": None, "three": False, "gltfValidator": False, "playwright": False,
                   "validatorScriptReady": False, "chromium": None, "renderReady": False}
        with mock.patch.object(build, "renderer_status", return_value=missing):
            result, image = build.check_model(self.root, FLAT, "v1")
        self.assertIsNone(image)
        self.assertFalse(result["rendererReady"])
        self.assertIn("install-mcp.sh --tools-only", result["fix"])
        self.assertTrue((self.root / "reconstructions" / FLAT / "v1" / "check.json").is_file())


class GuideTests(BuildTestBase):
    def test_flat_session(self):
        g = build.build_guide(self.root, FLAT)
        self.assertEqual(g["builder"], "flat-art-glb")
        cfg = g["starterConfig"]
        self.assertEqual(cfg["photo"], str((self.pack / FLAT / "views" / "artwork.jpg").resolve()))
        self.assertEqual(cfg["mode"], "plane")
        self.assertEqual(cfg["sheet"]["size_mm"], [271.0, 392.0])
        self.assertEqual(cfg["sheet"]["corners"], [[0, 0], [1, 0], [1, 1], [0, 1]])
        self.assertEqual(build._find_todo(cfg), [])
        self.assertIn("八つ切", " ".join(g["assumptions"]))
        self.assertIn("sheet.size_mm", g["configDocs"])        # from flat-art-glb/README.md
        self.assertIn("collage.example.json", g["configDocs"])
        self.assertNoSecrets(g)

    def test_flat_without_rectified_artwork_or_sheet(self):
        index = json.loads((self.pack / FLAT / "pack.json").read_text("utf-8"))
        index["flat"]["artworkSource"] = "uprightPhoto"
        write(self.pack / FLAT / "pack.json", index)
        write(self.pack / FLAT / "measurements.json", {"workKind": "flat", "status": "unavailable", "sheet": None})
        g = build.build_guide(self.root, FLAT)
        self.assertNotIn("corners", g["starterConfig"]["sheet"])
        self.assertNotIn("size_mm", g["starterConfig"]["sheet"])
        self.assertEqual(build._find_todo(g["starterConfig"]), ["/colors/paper"])
        self.assertIn("unknown", " ".join(g["assumptions"]))

    def test_object_with_top_view(self):
        g = build.build_guide(self.root, AI5)
        self.assertEqual(g["builder"], "solid-glb")
        self.assertIn("ONLY if", g["decision"])
        cfg = g["starterConfig"]
        self.assertEqual(cfg["top"]["photo"], str((self.pack / AI5 / "views" / "top.jpg").resolve()))
        self.assertEqual([v["name"] for v in cfg["views"]], ["top", "front", "right"])
        self.assertEqual(cfg["views"][2]["az"], 90)
        self.assertIn("/top/corners", build._find_todo(cfg))
        self.assertIn("top.width_mm", g["configDocs"].replace("`width_mm`", "top.width_mm"))
        self.assertIn("slab", g["configDocs"])

    def test_free_object_picks_the_steepest_photo_and_declared_height(self):
        g = build.build_guide(self.root, FREE_TOP)
        self.assertEqual(g["builder"], "solid-glb")
        cfg = g["starterConfig"]
        self.assertTrue(cfg["top"]["photo"].endswith("photo-03.jpg"))
        self.assertEqual(cfg["layers"][0]["height_mm"], 30.0)
        self.assertTrue(cfg["top"]["width_mm"].startswith("TODO"))
        self.assertTrue(str(cfg["views"][1]["az"]).startswith("TODO"))   # which side photo-01 shows is unknown

    def test_object_without_photo_from_above(self):
        for sid in (FREE_LOW, OLD):
            g = build.build_guide(self.root, sid)
            self.assertIsNone(g["builder"], sid)
            self.assertEqual(g["fit"], "no")
            self.assertIn("Neither prepared builder fits", g["decision"])
            self.assertNotIn("starterConfig", g)
            self.assertNotIn("configDocs", g)

    def test_no_pack(self):
        with self.assertRaises(core.MemoriaError):
            build.build_guide(self.root, "bbbb")

    def test_readme_sections_exist(self):
        for name, b in build.BUILDERS.items():
            for title in b["readme_sections"]:
                self.assertTrue(build._readme_section(b["dir"] / "README.md", title), (name, title))


class GlbSummaryTests(unittest.TestCase):
    def test_bounds_and_triangles(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "m.glb"
            p.write_bytes(tiny_glb((0.2, 0.03, 0.1)))
            s = build.glb_summary(p)
            self.assertEqual(s["triangles"], 12)
            self.assertEqual(s["boundsM"]["size"], [0.2, 0.03, 0.1])
            self.assertEqual(build._size_mm(s)["x"], 200.0)
            p.write_bytes(b"not a glb")
            self.assertIsNone(build.glb_summary(p))


def tools_ready() -> bool:
    py = build.tools_python()
    if not py.is_file():
        return False
    return subprocess.run([str(py), "-c", "import cv2, numpy, mapbox_earcut"], capture_output=True).returncode == 0


MAKE_IMAGES = r'''
import sys, cv2, numpy as np
art, top, side = sys.argv[1], sys.argv[2], sys.argv[3]
img = np.full((784, 542, 3), (236, 240, 242), np.uint8)
cv2.circle(img, (270, 260), 110, (40, 170, 250), -1)
cv2.line(img, (0, 600), (541, 560), (200, 60, 30), 10)
cv2.imwrite(art, img)
t = np.full((800, 600, 3), (205, 208, 210), np.uint8)
cv2.rectangle(t, (100, 250), (500, 550), (45, 40, 38), -1)
cv2.circle(t, (300, 400), 45, (30, 30, 200), -1)
cv2.imwrite(top, t)
s = np.full((600, 800, 3), (205, 208, 210), np.uint8)
cv2.rectangle(s, (150, 300), (650, 380), (45, 40, 38), -1)
cv2.imwrite(side, s)
'''


@unittest.skipUnless(tools_ready(), "builders' Python environment not set up (scripts/install-mcp.sh --tools-only)")
class BuilderRunTests(BuildTestBase):
    """The real builders on small synthetic pictures (no network)."""

    def setUp(self):
        super().setUp()
        art = self.pack / FLAT / "views" / "artwork.jpg"
        top = self.pack / FREE_TOP / "views" / "photo-03.jpg"
        side = self.pack / FREE_TOP / "views" / "photo-01.jpg"
        subprocess.run([str(build.tools_python()), "-c", MAKE_IMAGES, str(art), str(top), str(side)], check=True)

    def test_flat_build_grid_and_check(self):
        result, overlay = build.build_model(self.root, FLAT, "v1", "flat-art-glb", self.flat_config())
        self.assertEqual(result["sizeMm"]["x"], 271.0)
        self.assertEqual(result["sizeMm"]["y"], 392.0)
        self.assertEqual(result["triangles"], 12)
        self.assertEqual(core.image_size(overlay)[0] > 0, True)
        data, fmt, meta = build.photo_grid(self.root, FLAT, "artwork", [0.2, 0.2, 0.6, 0.5])
        self.assertEqual((fmt, data[:2]), ("jpeg", b"\xff\xd8"))
        self.assertEqual(meta["region"], [0.2, 0.2, 0.6, 0.5])
        with self.assertRaises(core.MemoriaError):
            build.photo_grid(self.root, FLAT, "artwork", [0.5, 0.2, 0.4, 0.5])
        if not build.renderer_status("flat-art-glb")["renderReady"]:
            self.skipTest("renderer not installed")
        check, compare = build.check_model(self.root, FLAT, "v1")
        self.assertEqual(check["validation"]["errors"], 0)
        self.assertTrue(compare.is_file())
        self.assertEqual(build.list_models(self.root, FLAT)["models"][0]["validation"]["errors"], 0)

    def test_solid_build_and_check(self):
        cfg = self.solid_config()
        cfg["top"]["corners"] = [[100 / 600, 250 / 800], [500 / 600, 250 / 800], [500 / 600, 550 / 800], [100 / 600, 550 / 800]]
        cfg["top"]["width_mm"] = 160
        cfg["outline"] = cfg["top"]["corners"]
        cfg["features"] = [{"name": "button", "shape": "button", "diameter_mm": 36, "height_mm": 5, "at": [[0.5, 0.5]]}]
        result, overlay = build.build_model(self.root, FREE_TOP, "v1", "solid-glb", cfg)
        self.assertAlmostEqual(result["sizeMm"]["x"], 160, delta=2)
        self.assertAlmostEqual(result["sizeMm"]["y"], 35, delta=0.5)
        self.assertEqual(overlay.name, "top_overlay.jpg")
        if not build.renderer_status("solid-glb")["renderReady"]:
            self.skipTest("renderer not installed")
        check, compare = build.check_model(self.root, FREE_TOP, "v1")
        self.assertEqual(check["validation"]["errors"], 0)
        self.assertEqual([Path(r).name for r in check["renders"]], ["top.png", "front.png"])
        self.assertTrue(compare.is_file())


class InstallerDesktopTests(unittest.TestCase):
    """scripts/install-mcp.sh --claude-desktop against a throwaway config (fake uv, no claude/codex on PATH)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.bin = t / "bin"
        self.bin.mkdir()
        (self.bin / "uv").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "uv").chmod(0o755)
        (self.bin / "python3").symlink_to(sys.executable)
        self.config = t / "Claude" / "claude_desktop_config.json"
        self.config.parent.mkdir()
        self.original = {"coworkUserFilesPath": "/somewhere", "preferences": {"a": 1, "nested": {"b": [1, 2]}},
                         "mcpServers": {"other": {"command": "x", "args": []}}}
        self.config.write_text(json.dumps(self.original, indent=2))
        self.server = str(INSTALLER.parent.parent.resolve() / "mcp-server" / "memoria_mcp.py")

    def tearDown(self):
        self.tmp.cleanup()

    def run_installer(self, *args, captures=None):
        env = {"PATH": "%s:/usr/bin:/bin" % self.bin, "HOME": self.tmp.name,
               "CLAUDE_DESKTOP_CONFIG": str(self.config)}
        if captures:
            env["MEMORIA_CAPTURES_DIR"] = captures
        return subprocess.run(["/bin/sh", str(INSTALLER), "--claude-desktop", "--skip-tools", *args], env=env,
                              capture_output=True, text=True)

    def backups(self):
        return sorted(self.config.parent.glob("claude_desktop_config.json.bak-*"))

    def test_install_reinstall_update_uninstall(self):
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(self.config.read_text())
        for k in ("coworkUserFilesPath", "preferences"):
            self.assertEqual(data[k], self.original[k])
        self.assertEqual(data["mcpServers"]["other"], self.original["mcpServers"]["other"])
        entry = data["mcpServers"]["memoria-capture"]
        self.assertEqual(entry["command"], str(self.bin / "uv"))
        self.assertEqual(entry["args"], ["run", "--script", self.server])
        self.assertTrue(entry["env"]["PATH"].startswith(str(self.bin) + ":"))
        self.assertNotIn("MEMORIA_CAPTURES_DIR", entry["env"])
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(json.loads(self.backups()[0].read_text()), self.original)
        self.assertIn("restart", r.stdout.replace("open it again", "restart"))

        r = self.run_installer()                       # same entry: nothing written, no new backup
        self.assertIn("unchanged", r.stdout)
        self.assertEqual(len(self.backups()), 1)

        r = self.run_installer(captures="/data/captures")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(self.config.read_text())["mcpServers"]["memoria-capture"]["env"]
                         ["MEMORIA_CAPTURES_DIR"], "/data/captures")
        self.assertEqual(len(self.backups()), 2)

        before = self.config.read_text()
        r = self.run_installer("--uninstall", "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.config.read_text(), before)
        r = self.run_installer("--uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(self.config.read_text())
        self.assertEqual(data["mcpServers"], self.original["mcpServers"])
        self.assertEqual({k: v for k, v in data.items() if k != "mcpServers"},
                         {k: v for k, v in self.original.items() if k != "mcpServers"})
        r = self.run_installer("--uninstall")
        self.assertIn("not registered", r.stdout)

    def test_new_file_dry_run_and_relative_captures(self):
        self.config.unlink()
        r = self.run_installer("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.config.exists())
        self.assertIn('"memoria-capture"', r.stdout)
        r = self.run_installer(captures="relative/captures")
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.config.exists())
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(list(json.loads(self.config.read_text())), ["mcpServers"])
        self.assertEqual(self.backups(), [])

    def test_broken_json_is_left_alone(self):
        self.config.write_text("{broken")
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not valid JSON", r.stderr)
        self.assertEqual(self.config.read_text(), "{broken")
        self.assertEqual(self.backups(), [])

    def test_missing_app_folder(self):
        shutil.rmtree(self.config.parent)
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("config folder not found", r.stderr)


if __name__ == "__main__":
    unittest.main()
