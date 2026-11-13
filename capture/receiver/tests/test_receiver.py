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
        self.receiver = mr.Receiver(self.data_dir, identity, pack_path=None)  # PackHookTests turn the hook on
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


class AddressClassifierTests(unittest.TestCase):
    def test_same_network_addresses_are_allowed(self):
        for ip, scope in [
            ("127.0.0.1", "loopback"), ("127.8.9.10", "loopback"), ("::1", "loopback"),
            ("10.0.0.1", "private"), ("10.255.255.255", "private"),
            ("172.16.0.1", "private"), ("172.31.255.254", "private"), ("172.20.10.2", "private"),  # Personal Hotspot
            ("192.168.0.10", "private"), ("192.168.255.1", "private"),
            ("169.254.3.4", "linkLocal"), ("fe80::1", "linkLocal"), ("fe80::aede:48ff:fe00:1122%en5", "linkLocal"),
            ("[fe80::1]", "linkLocal"), ("fd12:3456:789a::1", "uniqueLocal"), ("fc00::1", "uniqueLocal"),
            ("::ffff:192.168.1.5", "private"), ("::ffff:127.0.0.1", "loopback"), ("::ffff:169.254.1.1", "linkLocal"),
        ]:
            with self.subTest(ip=ip):
                self.assertEqual(mr.address_scope(ip), scope)
                self.assertTrue(mr.is_local_address(ip))

    def test_other_addresses_are_refused(self):
        for ip in [
            # addresses from the real run log (scanner, iPhone over the internet, the Mac's public addresses)
            "192.0.2.88", "203.0.113.45", "198.51.100.23", "198.51.100.77",
            "8.8.8.8", "11.0.0.1", "172.15.255.255", "172.32.0.1", "192.169.0.1", "169.255.0.1",
            "100.64.0.1", "100.127.255.254",  # carrier-grade NAT: shared with other customers, not this LAN
            "0.0.0.0", "255.255.255.255", "224.0.0.251",
            "2001:db8::1", "2400:4050::1", "fec0::1", "::", "ff02::fb", "::ffff:8.8.8.8",
        ]:
            with self.subTest(ip=ip):
                self.assertEqual(mr.address_scope(ip), "public")
                self.assertFalse(mr.is_local_address(ip))

    def test_non_addresses_are_refused(self):
        for value in ["", "mac.local", "localhost", "1.2.3", "300.1.1.1", None, 12]:
            with self.subTest(value=value):
                self.assertIsNone(mr.address_scope(value))
                self.assertFalse(mr.is_local_address(value))

    def test_connect_urls_only_offer_same_network_addresses(self):
        urls, warnings = mr.connect_urls(["192.168.1.20", "198.51.100.23", "169.254.7.8"], 8765)
        self.assertEqual(urls[0], "http://192.168.1.20:8765")
        self.assertTrue(urls[1].startswith("http://169.254.7.8:8765"))
        self.assertEqual(len(urls), 2)
        self.assertEqual(warnings, [])

    def test_connect_urls_warn_when_only_public_addresses(self):
        # The real run: a public address plus a link-local one, no private LAN address.
        urls, warnings = mr.connect_urls(["198.51.100.23", "169.254.7.8"], 8765)
        self.assertEqual(len(urls), 1)
        self.assertTrue(urls[0].startswith("http://169.254.7.8:8765"))
        self.assertNotIn("198.51.100.23:8765", " ".join(urls))
        text = "\n".join(warnings)
        self.assertIn("198.51.100.23", text)
        self.assertIn("USB ケーブル", text)
        self.assertIn("インターネット共有", text)
        self.assertIn("受け付けません", text)
        urls, warnings = mr.connect_urls(["198.51.100.77"], 8765)
        self.assertNotIn("http://198.51.100.77:8765", urls)
        self.assertTrue(warnings)

    def test_connect_urls_with_allow_remote_list_public_and_warn(self):
        urls, warnings = mr.connect_urls(["198.51.100.23"], 8765, allow_remote=True)
        self.assertTrue(urls[0].startswith("http://198.51.100.23:8765"))
        self.assertIn("暗号化", "\n".join(warnings))

    def test_connect_urls_keep_a_host_name(self):
        self.assertEqual(mr.connect_urls(["mac.local"], 8765), (["http://mac.local:8765"], []))


class RemoteAddressTests(ReceiverTestCase):
    """Requests from outside this network are closed without reading or answering anything."""

    def handle_as(self, client_ip, raw, server=None):
        """Run one RequestHandler on a socketpair as if the connection came from `client_ip`."""
        ours, theirs = socket.socketpair()
        try:
            theirs.sendall(raw)
            with redirect_stdout(self.out):
                mr.RequestHandler(ours, (client_ip, 40000), server or self.server)
            ours.close()
            theirs.settimeout(5)
            data = b""
            while True:
                chunk = theirs.recv(65536)
                if not chunk:
                    return data
                data += chunk
        finally:
            ours.close()
            theirs.close()

    def ping_request(self, body=b""):
        head = ("GET /api/v1/ping HTTP/1.1\r\nHost: x\r\nX-Memoria-Token: 123456\r\nConnection: close\r\n"
                "Content-Length: %d\r\n\r\n" % len(body)).encode("ascii")
        return head + body

    def test_allowed_addresses_are_served(self):
        for ip in ("192.168.1.20", "172.20.10.2", "10.1.2.3", "169.254.7.8", "fe80::1%en0", "::ffff:192.168.1.20"):
            with self.subTest(ip=ip):
                data = self.handle_as(ip, self.ping_request())
                self.assertTrue(data.startswith(b"HTTP/1.1 200"), data[:80])
                self.assertIn(b'"service": "memoria-capture-receiver"', data)

    def test_public_addresses_get_no_reply(self):
        for ip in ("192.0.2.88", "203.0.113.45", "100.64.0.1", "2001:db8::1", "::ffff:8.8.8.8"):
            with self.subTest(ip=ip):
                self.assertEqual(self.handle_as(ip, b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"), b"")
                self.assertEqual(self.handle_as(ip, self.ping_request()), b"")
                self.assertIn("[拒否] 外部アドレス %s" % ip, self.out.getvalue())
        log = self.out.getvalue()
        self.assertNotIn("/api/v1/ping ->", log)
        self.assertNotIn("GET / ->", log)

    def test_public_upload_body_is_never_read(self):
        cap = Capture()
        body = json.dumps(cap.manifest()).encode("utf-8")
        raw = ("POST /api/v1/sessions/%s/uploads HTTP/1.1\r\nHost: x\r\nX-Memoria-Token: 123456\r\n"
               "Content-Type: application/json\r\nContent-Length: %d\r\n\r\n" % (cap.sid, len(body))).encode("ascii") + body
        self.assertEqual(self.handle_as("203.0.113.45", raw), b"")
        self.assertEqual(list((self.data_dir / "incoming").glob("*/*")), [])

    def test_verify_request_closes_before_reading(self):
        with redirect_stdout(self.out):
            self.assertTrue(self.server.verify_request(None, ("192.168.0.5", 1)))
            self.assertTrue(self.server.verify_request(None, ("127.0.0.1", 1)))
            self.assertFalse(self.server.verify_request(None, ("192.0.2.88", 1)))
            self.assertFalse(self.server.verify_request(None, ("::ffff:192.0.2.88", 1)))

    def test_refused_log_is_one_line_per_address_per_interval(self):
        with redirect_stdout(self.out):
            for _ in range(5):
                self.server.verify_request(None, ("203.0.113.9", 1))
        lines = [l for l in self.out.getvalue().splitlines() if "203.0.113.9" in l]
        self.assertEqual(len(lines), 1)
        self.assertIn("[拒否] 外部アドレス 203.0.113.9", lines[0])
        self.assertNotIn("123456", self.out.getvalue())

    def test_allow_remote_opts_in(self):
        server = mr.ReceiverServer(("127.0.0.1", 0), self.receiver, allow_remote=True)
        try:
            self.assertTrue(server.verify_request(None, ("203.0.113.45", 1)))
            data = self.handle_as("203.0.113.45", self.ping_request(), server=server)
            self.assertTrue(data.startswith(b"HTTP/1.1 200"), data[:80])
        finally:
            server.server_close()

    def test_rate_limit_still_applies(self):
        bad = self.ping_request().replace(b"123456", b"999999")
        for _ in range(mr.AUTH_FAIL_LIMIT):
            self.assertTrue(self.handle_as("192.168.1.30", bad).startswith(b"HTTP/1.1 401"))
        self.assertTrue(self.handle_as("192.168.1.30", self.ping_request()).startswith(b"HTTP/1.1 429"))


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


def make_flat_capture(rectified=True, corners=True, size=True):
    """A flat-artwork session (workKind flat, plan flat1): one overhead photo, no mask, optional rectified image."""
    pid = new_id()
    cap = Capture(photos=[(pid, 90, "notGenerated")], title="えのぐの絵")
    flat = {
        "corners": {"topLeft": [100, 120], "topRight": [900, 110], "bottomRight": [910, 700], "bottomLeft": [95, 690]}
        if corners else None,
        "cornersMethod": "VNDetectRectanglesRequest" if corners else None,
        "cornersConfidence": 0.97 if corners else None,
        "sheetAtFrameEdge": False if corners else None,
        "size": {"widthM": 0.297, "heightM": 0.21, "planeSource": "estimatedPlane"} if size else None,
        "rectified": {"file": "rectified/%s.jpg" % pid, "width": 2970, "height": 2100} if rectified else None,
    }
    cap.session["workKind"] = "flat"
    cap.session["directionPlan"] = {"id": "flat1", "targets": [{"id": "top-e90", "azimuthDeg": 0, "elevationDeg": 90,
                                                               "azimuthToleranceDeg": 180, "elevationToleranceDeg": 20,
                                                               "anyAzimuth": True}]}
    cap.session["photos"][0]["referenceFrameId"] = None
    cap.session["photos"][0]["direction"] = {"confirmed": True, "targetId": "top-e90", "azimuthDeg": None, "elevationDeg": 86.5}
    cap.session["photos"][0]["flat"] = flat
    if rectified:
        cap.files["rectified/%s.jpg" % pid] = b"\xff\xd8rectified\xff\xd9"
    cap.set_session(cap.session)
    return cap, pid


class FlatSessionTests(ReceiverTestCase):
    def test_flat_session_with_rectified_image(self):
        cap, pid = make_flat_capture()
        self.send(cap)
        folder = self.published(cap)
        self.assertEqual((folder / "rectified" / ("%s.jpg" % pid)).read_bytes(), cap.files["rectified/%s.jpg" % pid])
        [entry] = self.index()
        self.assertEqual(entry["workKind"], "flat")
        self.assertEqual(entry["maskCount"], {"notGenerated": 1})

    def test_flat_session_without_sheet(self):
        cap, _ = make_flat_capture(rectified=False, corners=False, size=False)
        self.send(cap)
        self.assertEqual(self.index()[0]["workKind"], "flat")

    def test_object_session_without_work_kind_is_object(self):
        cap = Capture()
        self.send(cap)
        self.assertEqual(self.index()[0]["workKind"], "object")

    def test_invalid_flat_fields(self):
        def rectified_not_in_manifest(cap, pid):
            del cap.files["rectified/%s.jpg" % pid]

        def rectified_wrong_path(cap, pid):
            cap.session["photos"][0]["flat"]["rectified"]["file"] = "photos/%s.jpg" % pid

        def bad_corners(cap, pid):
            cap.session["photos"][0]["flat"]["corners"] = {"topLeft": [1, 2]}

        def bad_size(cap, pid):
            cap.session["photos"][0]["flat"]["size"] = {"widthM": -1, "heightM": 0.2, "planeSource": "x"}

        def unknown_work_kind(cap, pid):
            cap.session["workKind"] = "sculpture"

        def flat_not_object(cap, pid):
            cap.session["photos"][0]["flat"] = "yes"

        for mutate in (rectified_not_in_manifest, rectified_wrong_path, bad_corners, bad_size, unknown_work_kind,
                       flat_not_object):
            with self.subTest(mutate.__name__):
                cap, pid = make_flat_capture()
                mutate(cap, pid)
                cap.set_session(cap.session)
                upload_id = self.upload_all(cap)
                status, body = self.commit(cap, upload_id)
                self.assertEqual((status, body["status"]), (422, "invalid"), body)
                self.assertFalse(self.published(cap).exists())

    def test_rectified_path_is_allowed_only_for_uuids(self):
        cap, _ = make_flat_capture()
        manifest = cap.manifest()
        manifest["files"].append({"path": "rectified/../x.jpg", "size": 1, "sha256": "0" * 64})
        status, body = self.post_manifest(cap, manifest)
        self.assertEqual(status, 400, body)

    def test_list_and_show_flat(self):
        cap, pid = make_flat_capture()
        self.send(cap)
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(mr.main(["list", "--data-dir", str(self.data_dir)]), 0)
            self.assertEqual(mr.main(["show", cap.sid[:8], "--data-dir", str(self.data_dir)]), 0)
        text = out.getvalue()
        self.assertIn("平面", text)
        self.assertIn("workKind flat", text)
        self.assertIn("29.7 × 21.0 cm", text)
        self.assertIn("rectified/%s.jpg" % pid, text)


def make_heading_capture(derived=True, size=True):
    """A heading-guided 3D session (guidance heading): a frame without a base point, derived centre and approximate size."""
    cap = Capture(photos=[(new_id(), 90, "candidate"), (new_id(), 90, "candidate")], title="ねんど")
    derivation = {
        "method": "opticalAxesLeastSquares", "status": "ok", "reasons": [], "photoIds": [p[0] for p in cap.photos],
        "excludedPhotoIds": [], "centerWorld": [0.1, -0.2, -0.4], "residualRmsM": 0.008, "residualMaxM": 0.012,
        "perPhoto": [], "origin": "center",
        "size": {"status": "approximate", "confidence": "low", "method": "maskBoundsBoxAndCenterPlane",
                 "reasons": ["shapeDependent"], "widthM": 0.065, "depthM": 0.127, "heightM": 0.044,
                 "photoIds": [], "crossChecks": []} if size else None,
    }
    cap.session["guidance"] = "heading"
    cap.session["referenceFrames"] = [{
        "id": "ref-1", "basePointWorld": None, "objectToWorld": None, "frontPhotoId": cap.photos[0][0],
        "heading": {"frontHeadingDeg": 6.9, "frontPitchDeg": 15.2, "derivation": derivation if derived else None},
    }]
    for p in cap.session["photos"]:
        p["heading"] = {"relativeHeadingDeg": 0, "pitchDeg": 15.2, "position": "notChecked", "estimatedDistanceM": None}
    cap.set_session(cap.session)
    return cap


class HeadingSessionTests(ReceiverTestCase):
    def test_heading_session_is_accepted_and_indexed(self):
        cap = make_heading_capture()
        self.send(cap)
        [entry] = self.index()
        self.assertEqual(entry["guidance"], "heading")
        self.assertEqual(entry["workKind"], "object")

    def test_not_yet_derived_session_is_accepted(self):
        cap = make_heading_capture(derived=False)
        self.send(cap)
        self.assertEqual(self.index()[0]["guidance"], "heading")

    def test_guidance_defaults(self):
        cap = Capture()
        self.send(cap)
        self.assertEqual(self.index()[0]["guidance"], "baseCylinder")  # 3D work from before the field
        flat, _ = make_flat_capture()
        self.send(flat)
        self.assertIsNone([e for e in self.index() if e["workKind"] == "flat"][0]["guidance"])

    def test_invalid_heading_fields(self):
        def unknown_guidance(cap):
            cap.session["guidance"] = "compass"

        def bad_status(cap):
            cap.session["referenceFrames"][0]["heading"]["derivation"]["status"] = "great"

        def bad_center(cap):
            cap.session["referenceFrames"][0]["heading"]["derivation"]["centerWorld"] = [1, 2]

        def negative_size(cap):
            cap.session["referenceFrames"][0]["heading"]["derivation"]["size"]["heightM"] = -0.01

        def null_base_without_heading(cap):
            cap.session["referenceFrames"][0]["heading"] = None

        for mutate in (unknown_guidance, bad_status, bad_center, negative_size, null_base_without_heading):
            with self.subTest(mutate.__name__):
                cap = make_heading_capture()
                mutate(cap)
                cap.set_session(cap.session)
                upload_id = self.upload_all(cap)
                status, body = self.commit(cap, upload_id)
                self.assertEqual((status, body["status"]), (422, "invalid"), body)

    def test_show_prints_guidance_and_derivation(self):
        cap = make_heading_capture()
        self.send(cap)
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(mr.main(["list", "--data-dir", str(self.data_dir)]), 0)
            self.assertEqual(mr.main(["show", cap.sid[:8], "--data-dir", str(self.data_dir)]), 0)
        text = out.getvalue()
        self.assertIn("立体・向き", text)
        self.assertIn("向きで案内（guidance heading）", text)
        self.assertIn("線の外れ 0.8 cm", text)
        self.assertIn("6.5 × 12.7 × 4.4 cm", text)
        self.assertIn("机の面 分からない", text)
        self.assertIn("見下ろし 15.2°", text)

    def test_show_old_object_session_says_old_method(self):
        cap = Capture()
        self.send(cap)
        out = io.StringIO()
        with redirect_stdout(out):
            mr.main(["show", cap.sid[:8], "--data-dir", str(self.data_dir)])
        self.assertIn("底の中心と円柱で案内（guidance baseCylinder。記録なし＝前の方法）", out.getvalue())


class DeclaredSizeTests(ReceiverTestCase):
    """declaredSize (added later): the paper picked from the list (flat) or the height typed in (3D). Not measured."""

    def test_declared_sheet_and_height_are_accepted_and_shown(self):
        flat, _ = make_flat_capture(size=False)
        flat.session["declaredSize"] = {"sheet": {"id": "yatsugiri", "longSideM": 0.392, "shortSideM": 0.271}, "heightM": None}
        flat.set_session(flat.session)
        self.send(flat)
        obj = make_heading_capture()
        obj.session["declaredSize"] = {"sheet": None, "heightM": 0.12}
        obj.set_session(obj.session)
        self.send(obj)
        self.assertEqual(json.loads((self.published(flat) / "session.json").read_text("utf-8"))["declaredSize"]["sheet"]["id"],
                         "yatsugiri")
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(mr.main(["show", flat.sid[:8], "--data-dir", str(self.data_dir)]), 0)
            self.assertEqual(mr.main(["show", obj.sid[:8], "--data-dir", str(self.data_dir)]), 0)
        text = out.getvalue()
        self.assertIn("選んだ大きさ : 紙 八つ切（27.1 × 39.2 cm、id yatsugiri）", text)
        self.assertIn("選んだ大きさ : 高さ 12.0 cm", text)
        self.assertIn("測った実寸 不明", text)

    def test_missing_or_null_declared_size_is_fine(self):
        cap = Capture()
        self.send(cap)  # no declaredSize key (sessions from before)
        nulled = Capture()
        nulled.session["declaredSize"] = None
        nulled.set_session(nulled.session)
        self.send(nulled)
        unknown_id = make_flat_capture()[0]
        unknown_id.session["declaredSize"] = {"sheet": {"id": "custom", "longSideM": 0.5, "shortSideM": 0.3}}
        unknown_id.set_session(unknown_id.session)
        self.send(unknown_id)  # ids outside today's list are accepted (a later list may add some)
        self.assertEqual(len(self.index()), 3)
        out = io.StringIO()
        with redirect_stdout(out):
            mr.main(["show", cap.sid[:8], "--data-dir", str(self.data_dir)])
        self.assertIn("選んだ大きさ : 入力なし", out.getvalue())

    def test_invalid_declared_size(self):
        def not_object(cap):
            cap.session["declaredSize"] = "A4"

        def sheet_not_object(cap):
            cap.session["declaredSize"] = {"sheet": "a4"}

        def sheet_without_id(cap):
            cap.session["declaredSize"] = {"sheet": {"longSideM": 0.297, "shortSideM": 0.21}}

        def sheet_side_out_of_range(cap):
            cap.session["declaredSize"] = {"sheet": {"id": "a4", "longSideM": 297, "shortSideM": 210}}

        def sheet_sides_swapped(cap):
            cap.session["declaredSize"] = {"sheet": {"id": "a4", "longSideM": 0.21, "shortSideM": 0.297}}

        def height_too_small(cap):
            cap.session["declaredSize"] = {"heightM": 0.001}

        def height_too_large(cap):
            cap.session["declaredSize"] = {"heightM": 12}

        def height_not_number(cap):
            cap.session["declaredSize"] = {"heightM": "12cm"}

        def height_bool(cap):
            cap.session["declaredSize"] = {"heightM": True}

        for mutate in (not_object, sheet_not_object, sheet_without_id, sheet_side_out_of_range, sheet_sides_swapped,
                       height_too_small, height_too_large, height_not_number, height_bool):
            with self.subTest(mutate.__name__):
                cap = Capture()
                mutate(cap)
                cap.set_session(cap.session)
                upload_id = self.upload_all(cap)
                status, body = self.commit(cap, upload_id)
                self.assertEqual((status, body["status"]), (422, "invalid"), body)
                self.assertFalse(self.published(cap).exists())

    def test_readme_explains_declared_size(self):
        self.assertIn("declaredSize", (self.data_dir / "README.md").read_text("utf-8"))


def make_free_capture(n=3):
    """A free-capture 3D session (guidance free, plan free with no targets): photos without masks or reference frames."""
    cap = Capture(photos=[(new_id(), 90, "notGenerated") for _ in range(n)], title="ねんど")
    cap.session["guidance"] = "free"
    cap.session["directionPlan"] = {"id": "free", "targets": []}
    cap.session["referenceFrames"] = []
    for i, p in enumerate(cap.session["photos"]):
        p["referenceFrameId"] = None
        p["direction"] = {"confirmed": True, "targetId": None, "azimuthDeg": None, "elevationDeg": 20.0 + 10 * i,
                          "distanceM": None, "unconfirmedReason": None}
    cap.set_session(cap.session)
    return cap


class FreeSessionTests(ReceiverTestCase):
    def test_free_session_is_accepted_listed_and_shown(self):
        cap = make_free_capture()
        cap.session["declaredSize"] = {"sheet": None, "heightM": 0.08}
        cap.set_session(cap.session)
        self.send(cap)
        [entry] = self.index()
        self.assertEqual(entry["guidance"], "free")
        self.assertEqual(entry["workKind"], "object")
        self.assertEqual(entry["maskCount"], {"notGenerated": 3})
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(mr.main(["list", "--data-dir", str(self.data_dir)]), 0)
            self.assertEqual(mr.main(["show", cap.sid[:8], "--data-dir", str(self.data_dir)]), 0)
        text = out.getvalue()
        self.assertIn("立体・自由", text)
        self.assertIn("自由に撮る（guidance free）", text)
        self.assertIn("選んだ大きさ : 高さ 8.0 cm", text)
        self.assertIn("仰角 40.0", text)

    def test_invalid_free_plans(self):
        def empty_plan_without_free(cap):
            cap.session["guidance"] = "heading"

        def free_with_targets(cap):
            cap.session["directionPlan"] = {"id": "free", "targets": [{"id": "a000-e15"}]}

        def free_with_other_plan(cap):
            cap.session["directionPlan"] = {"id": "ai5", "targets": []}

        def empty_plan_missing_guidance(cap):
            del cap.session["guidance"]

        for mutate in (empty_plan_without_free, free_with_targets, free_with_other_plan, empty_plan_missing_guidance):
            with self.subTest(mutate.__name__):
                cap = make_free_capture()
                mutate(cap)
                cap.set_session(cap.session)
                upload_id = self.upload_all(cap)
                status, body = self.commit(cap, upload_id)
                self.assertEqual((status, body["status"]), (422, "invalid"), body)
                self.assertFalse(self.published(cap).exists())

    def test_readme_explains_free_capture(self):
        readme = (self.data_dir / "README.md").read_text("utf-8")
        self.assertIn("guidance` が `free`", readme)
        self.assertIn("photo-01", readme)

    def test_custom_sheet_is_named(self):
        flat, _ = make_flat_capture()
        flat.session["declaredSize"] = {"sheet": {"id": "custom", "longSideM": 0.3, "shortSideM": 0.21}}
        flat.set_session(flat.session)
        self.send(flat)
        out = io.StringIO()
        with redirect_stdout(out):
            mr.main(["show", flat.sid[:8], "--data-dir", str(self.data_dir)])
        self.assertIn("紙 その他（21.0 × 30.0 cm、id custom）", out.getvalue())


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


class PackHookTests(ReceiverTestCase):
    """After a commit the receiver runs tools/claude-pack's memoria-pack in the background (mocked by a script)."""

    def setUp(self):
        super().setUp()
        self.tools = Path(tempfile.mkdtemp(prefix="memoria-pack-mock-"))
        self.calls = self.tools / "calls.txt"

    def tearDown(self):
        super().tearDown()
        shutil.rmtree(str(self.tools), ignore_errors=True)

    def mock(self, body):
        script = self.tools / "memoria-pack"
        script.write_text("#!/bin/sh\necho \"$@\" >> '%s'\n%s\n" % (self.calls, body), "utf-8")
        script.chmod(0o755)
        self.receiver.pack_path = str(script)
        return script

    def wait_for(self, predicate, timeout=10.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return True
            time.sleep(0.05)
        return False

    def test_runs_pack_after_commit_with_data_dir(self):
        self.mock('echo "[pack] done"')
        cap = Capture()
        self.send(cap)
        self.assertTrue(self.wait_for(lambda: "[for_claude] [pack] done" in self.out.getvalue()), self.out.getvalue())
        self.assertEqual(self.calls.read_text("utf-8").strip(), "%s --data-dir %s" % (cap.sid, self.data_dir))

    def test_repeated_commit_does_not_run_again(self):
        self.mock('echo ok')
        cap = Capture()
        upload_id, _ = self.send(cap)
        self.assertTrue(self.wait_for(lambda: self.calls.exists()))
        status, body = self.commit(cap, upload_id)  # already complete: same answer, no new pack run
        self.assertEqual((status, body["status"]), (200, "complete"))
        time.sleep(0.3)
        self.assertEqual(len(self.calls.read_text("utf-8").splitlines()), 1)

    def test_failure_is_one_log_line_and_commit_succeeds(self):
        self.mock('echo "error: something broke" >&2\nexit 1')
        cap = Capture()
        _, body = self.send(cap)
        self.assertEqual(body["status"], "complete")
        self.assertTrue(self.wait_for(lambda: "for_claude/ を作れませんでした" in self.out.getvalue()))
        lines = [l for l in self.out.getvalue().splitlines() if "for_claude" in l]
        self.assertEqual(len(lines), 1, lines)
        self.assertIn("error: something broke", lines[0])
        self.assertIn("終了コード 1", lines[0])
        self.assertTrue(self.published(cap).is_dir())

    def test_commit_does_not_wait_for_the_pack(self):
        self.mock("sleep 2\necho finished")
        cap = Capture()
        upload_id = self.upload_all(cap)
        started = time.time()
        status, body = self.commit(cap, upload_id)
        self.assertEqual((status, body["status"]), (200, "complete"))
        self.assertLess(time.time() - started, 1.5)
        # let the background run finish before the temporary folders go away
        self.assertTrue(self.wait_for(lambda: "[for_claude] finished" in self.out.getvalue()))

    def test_missing_binary_prints_build_hint_once(self):
        self.receiver.pack_path = str(self.tools / "not-built" / "memoria-pack")
        self.send(Capture())
        self.send(Capture())
        hints = [l for l in self.out.getvalue().splitlines() if "swift build -c release" in l]
        self.assertEqual(len(hints), 1, self.out.getvalue())
        self.assertIn("tools/claude-pack", hints[0])

    def test_hook_off(self):
        self.receiver.pack_path = None
        self.send(Capture())
        self.assertNotIn("for_claude", self.out.getvalue())
        self.assertNotIn("swift build", self.out.getvalue())

    def test_default_path_points_at_the_release_build(self):
        r = mr.Receiver(self.data_dir, {"receiverId": new_id(), "pairingCode": "123456", "name": "x"})
        self.assertEqual(Path(r.pack_path), mr.REPO_DIR / "tools" / "claude-pack" / ".build" / "release" / "memoria-pack")

    def test_data_readme_points_ai_tools_at_for_claude(self):
        readme = (self.data_dir / "README.md").read_text("utf-8")
        self.assertIn("for_claude/<sessionId>/brief.md", readme)


if __name__ == "__main__":
    unittest.main()
