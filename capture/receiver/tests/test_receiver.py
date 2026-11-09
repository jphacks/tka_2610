"""End-to-end tests for memoria_receiver (in-process server on an ephemeral port).

    cd receiver && python3 -m unittest -v
    python3 -m unittest discover -s receiver/tests -v   (from the repo root)
"""
import hashlib
import http.client
import io
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
import zlib
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import memoria_receiver as mr  # noqa: E402

HAS_SIPS = os.path.exists(mr.SIPS_PATH)


def make_png(width, height):
    """Minimal valid 8-bit grayscale PNG."""
    raw = b"".join(b"\x00" + bytes((x * 60 + y * 30) % 256 for x in range(width)) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def png_size(data):
    return struct.unpack(">II", data[16:24])


def sha(data):
    return hashlib.sha256(data).hexdigest()


def new_id():
    return str(uuid.uuid4()).upper()


class Capture:
    """A fake capture session: files (path -> bytes) and its manifest."""

    def __init__(self, photos=None, title="テスト", session_id=None, jpeg=b"\xff\xd8fake-jpeg\xff\xd9", png=None):
        self.sid = session_id or new_id()
        png = png if png is not None else make_png(4, 2)
        self.photos = photos if photos is not None else [(new_id(), 90, "candidate"), (new_id(), 0, "failed")]
        self.files = {}
        records = []
        for seq, (pid, rot, mask_status) in enumerate(self.photos, 1):
            self.files["photos/%s.jpg" % pid] = jpeg + pid.encode()
            has_mask = mask_status in ("candidate", "confirmed")
            if has_mask:
                self.files["masks/%s.png" % pid] = png
            records.append({
                "photoId": pid, "sequence": seq,
                "image": {"file": "photos/%s.jpg" % pid, "format": "jpeg", "width": 4, "height": 2,
                          "exifOrientation": 1, "displayRotationDegClockwise": rot},
                "direction": {"confirmed": seq == 1, "targetId": "a000-e20", "azimuthDeg": 3.2, "elevationDeg": 21.0},
                "mask": {"status": mask_status, "file": "masks/%s.png" % pid if has_mask else None},
            })
        self.session = {"schema": "memoria.capture.session", "schemaVersion": 1, "sessionId": self.sid,
                        "title": title, "photos": records}
        self.set_session(self.session)

    def set_session(self, session):
        self.session = session
        self.files["session.json"] = json.dumps(session, ensure_ascii=False).encode("utf-8")

    def manifest(self):
        return {"files": [{"path": p, "size": len(d), "sha256": sha(d)} for p, d in sorted(self.files.items())]}

    def manifest_hash(self):
        return mr.manifest_hash(self.manifest()["files"])


class ReceiverTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.assets = Path(tempfile.mkdtemp(prefix="memoria-assets-"))
        cls.real_png = make_png(4, 2)
        cls.real_jpeg = None
        if HAS_SIPS:
            (cls.assets / "src.png").write_bytes(cls.real_png)
            subprocess.run([mr.SIPS_PATH, "-s", "format", "jpeg", str(cls.assets / "src.png"),
                            "--out", str(cls.assets / "src.jpg")], stdout=subprocess.DEVNULL, check=True)
            cls.real_jpeg = (cls.assets / "src.jpg").read_bytes()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(str(cls.assets), ignore_errors=True)

    def setUp(self):
        self.data_dir = Path(tempfile.mkdtemp(prefix="memoria-data-")).resolve()
        identity = {"receiverId": new_id(), "pairingCode": "123456", "name": "テストの Mac"}
        self.receiver = mr.Receiver(self.data_dir, identity)
        self.out = io.StringIO()
        with redirect_stdout(self.out):
            self.receiver.prepare()
        self.server = mr.ReceiverServer(("127.0.0.1", 0), self.receiver)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        with redirect_stdout(self.out):
            self.server.serve_forever(poll_interval=0.05)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
        shutil.rmtree(str(self.data_dir), ignore_errors=True)

    # -- HTTP helpers ------------------------------------------------------------

    def request(self, method, path, body=None, headers=None, token="123456"):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            hdrs = dict(headers or {})
            if token is not None:
                hdrs["X-Memoria-Token"] = token
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode("utf-8")
                hdrs["Content-Type"] = "application/json"
            conn.request(method, "/api/v1" + path, body=body, headers=hdrs)
            resp = conn.getresponse()
            return resp.status, json.loads(resp.read().decode("utf-8"))
        finally:
            conn.close()

    def post_manifest(self, cap, manifest=None):
        return self.request("POST", "/sessions/%s/uploads" % cap.sid, manifest or cap.manifest())

    def put(self, cap, upload_id, path, data=None, header_sha=None):
        data = cap.files[path] if data is None else data
        return self.request("PUT", "/sessions/%s/uploads/%s/files/%s" % (cap.sid, upload_id, path), data,
                            {"X-Content-SHA256": header_sha or sha(cap.files.get(path, data))})

    def commit(self, cap, upload_id):
        return self.request("POST", "/sessions/%s/uploads/%s/commit" % (cap.sid, upload_id))

    def upload_all(self, cap):
        status, body = self.post_manifest(cap)
        self.assertEqual(status, 200, body)
        self.assertEqual(body["status"], "uploading")
        for path in body["missing"]:
            status, put_body = self.put(cap, body["uploadId"], path)
            self.assertEqual(status, 200, put_body)
        return body["uploadId"]

    def send(self, cap):
        upload_id = self.upload_all(cap)
        status, body = self.commit(cap, upload_id)
        self.assertEqual(status, 200, body)
        self.assertEqual(body["status"], "complete")
        return upload_id, body

    def published(self, cap):
        return self.data_dir / "sessions" / cap.sid

    def index(self):
        return json.loads((self.data_dir / "index.json").read_text("utf-8"))["sessions"]

    def partials(self):
        return list((self.data_dir / "incoming" / ".partial").iterdir())


class AuthTests(ReceiverTestCase):
    def test_ping_requires_token(self):
        self.assertEqual(self.request("GET", "/ping", token=None)[0], 401)
        self.assertEqual(self.request("GET", "/ping", token="000000")[0], 401)
        status, body = self.request("GET", "/ping")
        self.assertEqual(status, 200)
        self.assertEqual(body["service"], "memoria-capture-receiver")
        self.assertEqual(body["protocolVersion"], 1)
        self.assertEqual(body["receiverId"], self.receiver.identity["receiverId"])
        self.assertEqual(body["name"], "テストの Mac")
        self.assertNotIn("123456", self.out.getvalue())  # the token is never logged

    def test_all_endpoints_require_token(self):
        cap = Capture()
        self.assertEqual(self.request("POST", "/sessions/%s/uploads" % cap.sid, cap.manifest(), token="1")[0], 401)
        self.assertEqual(self.request("GET", "/sessions/%s" % cap.sid, token=None)[0], 401)

    def test_repeated_failures_are_throttled(self):
        for _ in range(mr.AUTH_FAIL_LIMIT):
            self.assertEqual(self.request("GET", "/ping", token="999999")[0], 401)
        self.assertEqual(self.request("GET", "/ping")[0], 429)


class TransferTests(ReceiverTestCase):
    def test_happy_path(self):
        cap = Capture()
        upload_id, body = self.send(cap)
        self.assertEqual(upload_id, cap.manifest_hash())
        folder = self.published(cap)
        self.assertEqual(body["path"], str(folder))
        for path, data in cap.files.items():
            self.assertEqual((folder / path).read_bytes(), data)
        receipt = json.loads((folder / "_receipt.json").read_text("utf-8"))
        self.assertTrue(receipt["complete"])
        self.assertEqual(receipt["manifestHash"], upload_id)
        self.assertEqual(sorted(f["path"] for f in receipt["files"]), sorted(cap.files))
        self.assertFalse((folder / "_manifest.json").exists())
        allowed = set(cap.files) | {"_receipt.json"}
        for p in folder.rglob("*"):
            rel = p.relative_to(folder).as_posix()
            if p.is_file():
                self.assertTrue(rel in allowed or rel.startswith("upright/"), rel)
        self.assertFalse((self.data_dir / "incoming" / cap.sid).exists())
        [entry] = self.index()
        self.assertEqual(entry["sessionId"], cap.sid)
        self.assertEqual(entry["title"], "テスト")
        self.assertEqual(entry["photoCount"], 2)
        self.assertEqual(entry["maskCount"], {"candidate": 1, "failed": 1})
        self.assertEqual(entry["manifestHash"], upload_id)
        self.assertEqual(entry["path"], "sessions/%s" % cap.sid)
        self.assertIn("incoming/", (self.data_dir / "README.md").read_text("utf-8"))
        self.assertEqual(self.request("GET", "/sessions/%s" % cap.sid),
                         (200, {"status": "complete", "manifestHash": upload_id, "path": str(folder)}))
        self.assertEqual(self.request("GET", "/sessions/%s" % new_id()), (404, {"status": "notFound"}))

    def test_resume_after_partial_upload(self):
        cap = Capture(photos=[(new_id(), 0, "confirmed"), (new_id(), 0, "confirmed")])
        status, body = self.post_manifest(cap)
        upload_id = body["uploadId"]
        self.assertEqual(sorted(body["missing"]), sorted(cap.files))
        sent = body["missing"][:2]
        for path in sent:
            self.assertEqual(self.put(cap, upload_id, path), (200, {"status": "stored"}))
        status, body = self.post_manifest(cap)
        self.assertEqual(body["uploadId"], upload_id)
        self.assertEqual(sorted(body["missing"]), sorted(set(cap.files) - set(sent)))
        self.assertEqual(self.put(cap, upload_id, sent[0]), (200, {"status": "alreadyStored"}))
        status, body = self.commit(cap, upload_id)
        self.assertEqual(status, 409)
        self.assertEqual(sorted(body["missing"]), sorted(set(cap.files) - set(sent)))
        for path in set(cap.files) - set(sent):
            self.assertEqual(self.put(cap, upload_id, path)[0], 200)
        self.assertEqual(self.commit(cap, upload_id)[1]["status"], "complete")

    def test_resume_survives_server_restart(self):
        cap = Capture()
        status, body = self.post_manifest(cap)
        self.put(cap, body["uploadId"], "session.json")
        self.receiver._hash_cache.clear()  # like a fresh process: hashes are re-read from disk
        status, body = self.post_manifest(cap)
        self.assertNotIn("session.json", body["missing"])

    def test_retry_after_complete_is_idempotent(self):
        cap = Capture()
        upload_id, first = self.send(cap)
        self.assertEqual(self.post_manifest(cap), (200, {"status": "alreadyComplete", "manifestHash": upload_id}))
        self.assertEqual(self.commit(cap, upload_id), (200, first))
        self.assertEqual(self.put(cap, upload_id, "session.json"), (200, {"status": "alreadyStored"}))
        self.assertEqual(len(list((self.data_dir / "sessions").iterdir())), 1)
        self.assertEqual(list((self.data_dir / "replaced").iterdir()), [])
        self.assertEqual(len(self.index()), 1)

    def test_commit_with_missing_file(self):
        cap = Capture()
        status, body = self.post_manifest(cap)
        upload_id = body["uploadId"]
        skipped = sorted(cap.files)[0]
        for path in cap.files:
            if path != skipped:
                self.put(cap, upload_id, path)
        self.assertEqual(self.commit(cap, upload_id), (409, {"status": "incomplete", "missing": [skipped]}))
        self.assertFalse(self.published(cap).exists())
        self.assertEqual(self.index(), [])

    def test_corrupted_staged_file_is_reported_missing(self):
        cap = Capture()
        upload_id = self.upload_all(cap)
        (self.data_dir / "incoming" / cap.sid / upload_id / "session.json").write_bytes(b"{}")
        status, body = self.commit(cap, upload_id)
        self.assertEqual((status, body["missing"]), (409, ["session.json"]))

    def test_hash_mismatch_is_rejected(self):
        cap = Capture()
        status, body = self.post_manifest(cap)
        upload_id = body["uploadId"]
        path = "session.json"
        good = cap.files[path]
        bad = bytes([good[0] ^ 1]) + good[1:]
        status, body = self.put(cap, upload_id, path, data=bad, header_sha=sha(good))
        self.assertEqual((status, body["status"]), (422, "mismatch"))
        staged = self.data_dir / "incoming" / cap.sid / upload_id / path
        self.assertFalse(staged.exists())
        self.assertEqual(self.partials(), [])
        # header that disagrees with the manifest, and a wrong length
        self.assertEqual(self.put(cap, upload_id, path, data=bad, header_sha=sha(bad))[0], 422)
        self.assertEqual(self.put(cap, upload_id, path, data=good + b" ", header_sha=sha(good))[0], 422)
        self.assertFalse(staged.exists())
        self.assertIn(path, self.post_manifest(cap)[1]["missing"])
        self.assertEqual(self.put(cap, upload_id, path), (200, {"status": "stored"}))

    def test_bad_paths_and_ids(self):
        cap = Capture()
        upload_id = self.post_manifest(cap)[1]["uploadId"]
        pid = cap.photos[0][0]
        for bad in ["../session.json", "%2E%2E%2Fsession.json", "photos/abc.jpg", "/etc/passwd",
                    "other.txt", "photos/%s.png" % pid, "photos/%s.jpg" % pid.lower(), "photos/../session.json",
                    "session.json%0A"]:
            status, _ = self.request("PUT", "/sessions/%s/uploads/%s/files/%s" % (cap.sid, upload_id, bad), b"x",
                                     {"X-Content-SHA256": sha(b"x")})
            self.assertEqual(status, 400, bad)
        # valid name but not in the manifest
        self.assertEqual(self.put(cap, upload_id, "masks/%s.png" % new_id(), data=b"x")[0], 409)
        # bad sessionId
        for bad_sid in [cap.sid.lower(), "not-a-uuid", "..", cap.sid + "0"]:
            self.assertEqual(self.request("POST", "/sessions/%s/uploads" % bad_sid, cap.manifest())[0], 400, bad_sid)
        # unknown / malformed uploadId
        self.assertEqual(self.put(cap, "0" * 64, "session.json")[0], 404)
        self.assertEqual(self.commit(cap, "0" * 64)[0], 404)
        self.assertEqual(self.put(cap, "xyz", "session.json")[0], 400)
        # bad manifests
        bad_manifests = [
            {"files": [{"path": "../x", "size": 1, "sha256": "0" * 64}]},
            {"files": [{"path": "session.json", "size": -1, "sha256": "0" * 64}]},
            {"files": [{"path": "session.json", "size": 1, "sha256": "zz"}]},
            {"files": [{"path": "photos/%s.jpg" % pid, "size": 1, "sha256": "0" * 64}]},  # no session.json
            {"files": [{"path": "session.json", "size": 1, "sha256": "0" * 64}] * 2},
            {"files": [{"path": "session.json", "size": mr.MAX_FILE_SIZE + 1, "sha256": "0" * 64}]},
            {"files": []},
            {"files": [{"path": "photos/%s.jpg" % new_id(), "size": 1, "sha256": "0" * 64}
                       for _ in range(mr.MAX_FILES + 1)]},
        ]
        for manifest in bad_manifests:
            self.assertEqual(self.post_manifest(cap, manifest)[0], 400)
        self.assertEqual(self.request("POST", "/sessions/%s/uploads" % cap.sid, b"not json")[0], 400)
        self.assertEqual(self.partials(), [])

    def test_invalid_session_json(self):
        def wrong_session_id(cap):
            cap.session["sessionId"] = new_id()

        def photo_not_in_manifest(cap):
            pid = cap.photos[1][0]
            del cap.files["photos/%s.jpg" % pid]

        def candidate_without_file(cap):
            cap.session["photos"][1]["mask"] = {"status": "candidate", "file": None}

        def duplicate_photo(cap):
            cap.session["photos"].append(dict(cap.session["photos"][0]))

        def wrong_schema_version(cap):
            cap.session["schemaVersion"] = 2

        for mutate in (wrong_session_id, photo_not_in_manifest, candidate_without_file, duplicate_photo,
                       wrong_schema_version):
            with self.subTest(mutate.__name__):
                cap = Capture()
                mutate(cap)
                cap.set_session(cap.session)
                upload_id = self.upload_all(cap)
                status, body = self.commit(cap, upload_id)
                self.assertEqual((status, body["status"]), (422, "invalid"), body)
                self.assertTrue(body["errors"])
                self.assertFalse(self.published(cap).exists())
        self.assertEqual(self.index(), [])

    def test_accepts_additive_optional_fields(self):
        # schemaVersion 1 のまま足した項目（mask.check・referenceFrames[].object）があっても受け取る。
        cap = Capture()
        cap.session["object"] = {"heightM": 0.04, "radiusM": 0.09, "source": "userAdjusted"}
        cap.session["referenceFrames"] = [
            {"id": "ref-1", "basePointWorld": [0, 0, 0], "object": {"heightM": 0.15, "radiusM": 0.09, "source": "userAdjusted"}},
            {"id": "ref-2", "basePointWorld": [0, 0, 0], "object": None},
        ]
        cap.session["photos"][0]["mask"]["check"] = {
            "status": "suspicious", "reasons": ["outsideObject", "touchesCropEdge"],
            "insideSilhouetteRatio": 0.654, "cropCoverage": 0.318, "silhouetteAreaRatio": 0.579,
            "centerOffset": 0.381, "touchedCropEdges": 2}
        cap.session["photos"][1]["mask"]["check"] = None
        cap.set_session(cap.session)
        self.send(cap)
        published = json.loads((self.published(cap) / "session.json").read_text("utf-8"))
        self.assertEqual(published["photos"][0]["mask"]["check"]["status"], "suspicious")
        self.assertEqual(published["referenceFrames"][0]["object"]["heightM"], 0.15)

    def test_resend_with_changed_manifest_replaces_old_version(self):
        cap = Capture()
        old_id, _ = self.send(cap)
        old_files = set(cap.files)
        cap2 = Capture(session_id=cap.sid, photos=cap.photos + [(new_id(), 0, "confirmed")], title="撮り直し")
        new_id_, _ = self.send(cap2)
        self.assertNotEqual(old_id, new_id_)
        receipt = json.loads((self.published(cap) / "_receipt.json").read_text("utf-8"))
        self.assertEqual(receipt["manifestHash"], new_id_)
        [old] = list((self.data_dir / "replaced").iterdir())
        self.assertTrue(old.name.startswith(cap.sid + "-"))
        self.assertEqual(json.loads((old / "_receipt.json").read_text("utf-8"))["manifestHash"], old_id)
        self.assertEqual({f["path"] for f in json.loads((old / "_receipt.json").read_text("utf-8"))["files"]}, old_files)
        [entry] = self.index()
        self.assertEqual((entry["title"], entry["photoCount"]), ("撮り直し", 3))

    def test_concurrent_puts(self):
        big = os.urandom(3 * 1024 * 1024)
        cap = Capture(jpeg=big)
        upload_id = self.post_manifest(cap)[1]["uploadId"]
        results = []
        lock = threading.Lock()

        def worker(path):
            r = self.put(cap, upload_id, path)
            with lock:
                results.append(r)

        threads = [threading.Thread(target=worker, args=(p,)) for p in list(cap.files) * 4]
        for t in threads:
            t.start()
        for t in threads:
            t.join(30)
        self.assertEqual(len(results), len(cap.files) * 4)
        for status, body in results:
            self.assertEqual(status, 200, body)
            self.assertIn(body["status"], ("stored", "alreadyStored"))
        self.assertEqual(self.commit(cap, upload_id)[1]["status"], "complete")
        for path, data in cap.files.items():
            self.assertEqual(sha((self.published(cap) / path).read_bytes()), sha(data))
        self.assertEqual(self.partials(), [])

    def test_fail_put_every_hook(self):
        self.receiver.fail_put_every = 2
        cap = Capture()
        upload_id = self.post_manifest(cap)[1]["uploadId"]
        paths = sorted(cap.files)
        self.assertEqual(self.put(cap, upload_id, paths[0])[0], 200)
        self.assertEqual(self.put(cap, upload_id, paths[1])[0], 500)
        self.assertIn(paths[1], self.post_manifest(cap)[1]["missing"])
        self.assertEqual(self.put(cap, upload_id, paths[1])[0], 200)

    def test_list_and_show_commands(self):
        cap = Capture()
        self.send(cap)
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(mr.main(["list", "--data-dir", str(self.data_dir)]), 0)
            self.assertEqual(mr.main(["show", cap.sid[:8], "--data-dir", str(self.data_dir)]), 0)
        text = out.getvalue()
        self.assertIn(cap.sid, text)
        self.assertIn("photos/%s.jpg" % cap.photos[0][0], text)


class DisconnectLogTests(ReceiverTestCase):
    def _handle_error(self, error):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            try:
                raise error
            except Exception:  # noqa: BLE001
                self.server.handle_error(None, ("192.0.2.1", 50000))
        return out.getvalue(), err.getvalue()

    def test_client_disconnects_log_one_line(self):
        for error in (ConnectionResetError(54, "Connection reset by peer"), BrokenPipeError(32, "Broken pipe")):
            out, err = self._handle_error(error)
            self.assertEqual(err, "")
            self.assertEqual(len(out.strip().splitlines()), 1)
            self.assertIn(type(error).__name__, out)
            self.assertNotIn("Traceback", out)

    def test_other_errors_keep_traceback(self):
        out, err = self._handle_error(ValueError("boom"))
        self.assertIn("Traceback", err)
        self.assertIn("ValueError: boom", err)

    def test_dropped_keep_alive_connection_is_one_line(self):
        # Like the iPhone: one request on a keep-alive connection, then the connection is reset.
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("GET", "/api/v1/ping", headers={"X-Memoria-Token": "123456"})
        resp = conn.getresponse()
        resp.read()
        self.assertEqual(resp.status, 200)
        conn.sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))  # RST on close
        conn.close()
        deadline = time.monotonic() + 3
        while "接続が切れました" not in self.out.getvalue() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertIn("接続が切れました（ConnectionResetError）", self.out.getvalue())
        self.assertNotIn("Traceback", self.out.getvalue())
        status, _ = self.request("GET", "/ping")
        self.assertEqual(status, 200)


class UprightTests(ReceiverTestCase):
    @unittest.skipUnless(HAS_SIPS, "sips がありません")
    def test_upright_previews(self):
        cap = Capture(jpeg=self.real_jpeg, png=self.real_png,
                      photos=[(new_id(), 90, "confirmed"), (new_id(), 0, "candidate"), (new_id(), 180, "noObject")])
        # the fake JPEG builder appends the photoId; keep real JPEG bytes intact instead
        for pid, _, _ in cap.photos:
            cap.files["photos/%s.jpg" % pid] = self.real_jpeg
        self.send(cap)
        up = self.published(cap) / "upright"
        rotated, straight, no_mask = (p[0] for p in cap.photos)
        self.assertEqual(png_size((up / "masks" / ("%s.png" % rotated)).read_bytes()), (2, 4))
        self.assertEqual((up / "masks" / ("%s.png" % straight)).read_bytes(), self.real_png)
        self.assertFalse((up / "masks" / ("%s.png" % no_mask)).exists())
        for pid in (rotated, straight, no_mask):
            self.assertTrue((up / "photos" / ("%s.jpg" % pid)).is_file(), pid)
        dims = subprocess.run([mr.SIPS_PATH, "-g", "pixelWidth", "-g", "pixelHeight", str(up / "photos" / ("%s.jpg" % rotated))],
                              stdout=subprocess.PIPE, check=True).stdout.decode()
        self.assertIn("pixelWidth: 2", dims)
        self.assertIn("pixelHeight: 4", dims)
        # the original stays in sensor orientation
        self.assertEqual((self.published(cap) / "photos" / ("%s.jpg" % rotated)).read_bytes(), self.real_jpeg)

    @unittest.skipUnless(HAS_SIPS, "sips がありません")
    def test_preview_failure_does_not_fail_commit(self):
        cap = Capture(photos=[(new_id(), 90, "candidate")], png=b"not a png")  # both files are invalid images
        self.send(cap)
        self.assertFalse((self.published(cap) / "upright").exists())
        self.assertIn("upright を作れませんでした", self.out.getvalue())

    def test_missing_sips_does_not_fail_commit(self):
        self.receiver.sips_path = "/nonexistent/sips"
        cap = Capture()
        self.send(cap)
        self.assertFalse((self.published(cap) / "upright").exists())


if __name__ == "__main__":
    unittest.main()
