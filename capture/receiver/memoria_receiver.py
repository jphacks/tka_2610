#!/usr/bin/env python3
"""Memoria Capture receiver: receives capture sessions from the iPhone app over the LAN.

Contract: docs/transfer-protocol.md (HTTP API) and docs/data-format.md (session folder).
Standard library only; works on Python 3.9+.

    python3 receiver/memoria_receiver.py [serve] [--port 8765] [--data-dir DIR] [--host 0.0.0.0] [--no-bonjour] [--allow-remote]
    python3 receiver/memoria_receiver.py list [--data-dir DIR]
    python3 receiver/memoria_receiver.py show <sessionId-or-prefix> [--data-dir DIR]
"""
from __future__ import annotations

import argparse
import atexit
import collections
import concurrent.futures
import hashlib
import hmac
import http.server
import ipaddress
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.parse
import uuid
from datetime import datetime, timezone
from pathlib import Path

PROTOCOL_VERSION = 1
SERVICE_NAME = "memoria-capture-receiver"
BONJOUR_TYPE = "_memoriacap._tcp"
SCHEMA = "memoria.capture.session"
SCHEMA_VERSION = 1

UUID_PATTERN = r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
SESSION_ID_RE = re.compile(UUID_PATTERN)
FILE_PATH_RE = re.compile(r"session\.json|photos/%s\.jpg|masks/%s\.png|rectified/%s\.jpg" % (UUID_PATTERN, UUID_PATTERN, UUID_PATTERN))
SHA256_RE = re.compile(r"[0-9a-fA-F]{64}")
UPLOAD_ID_RE = re.compile(r"[0-9a-f]{64}")
PAIRING_CODE_RE = re.compile(r"[0-9]{6}")

MAX_FILES = 2000
MAX_FILE_SIZE = 200 * 1024 * 1024
MAX_MANIFEST_BODY = 2 * 1024 * 1024
DRAIN_LIMIT = 8 * 1024 * 1024  # unread request bodies up to this size are drained to keep the connection
CHUNK_SIZE = 1024 * 1024
MASK_FILE_STATUSES = ("candidate", "confirmed")
WORK_KINDS = ("object", "flat")  # session.json "workKind" (added later; missing or null = "object")
# session.json "guidance" (added later): how 3D work was guided. Missing or null = "baseCylinder" for 3D work, none for flat.
# "free" (added later): shot freely without guidance; its directionPlan is "free" with no targets, no reference frames, no masks.
GUIDANCES = ("heading", "baseCylinder", "free")
FREE_PLAN_ID = "free"
DERIVATION_STATUSES = ("ok", "lowConfidence", "unknown")
# session.json "declaredSize" (added later): the size the person picked or typed in (not measured). Missing or null = not entered.
# Sheets of the app's list (CaptureCore SheetPreset): id -> (Japanese name, short side mm, long side mm).
SHEET_PRESETS = {
    "yatsugiri": ("八つ切", 271, 392), "yotsugiri": ("四つ切", 392, 542), "a4": ("A4", 210, 297),
    "b4": ("B4", 257, 364), "a3": ("A3", 297, 420), "b5": ("B5", 182, 257),
}
CUSTOM_SHEET_ID = "custom"  # 「その他」: the person typed both sides (1–300 cm)
CUSTOM_SHEET_NAME = "その他"
DECLARED_HEIGHT_RANGE_M = (0.005, 3.0)  # the app accepts 0.5–300 cm
DECLARED_SHEET_SIDE_RANGE_M = (0.01, 3.0)
AUTH_FAIL_LIMIT = 20  # failed tokens per client IP within AUTH_FAIL_WINDOW -> 429
AUTH_FAIL_WINDOW = 300.0
SIPS_PATH = "/usr/bin/sips"

REPO_DIR = Path(__file__).resolve().parent.parent
DEFAULT_DATA_DIR = REPO_DIR / "captures"
# tools/claude-pack (memoria-pack) builds captures/for_claude/<sessionId>/ for AI tools after each commit.
PACK_PATH = REPO_DIR / "tools" / "claude-pack" / ".build" / "release" / "memoria-pack"
PACK_TIMEOUT = 600.0

# Same-network only (docs/transfer-protocol.md「同じネットワークの中だけ」): by default the receiver
# accepts connections only from these ranges and closes every other connection before reading anything.
# 100.64.0.0/10 (carrier-grade NAT, RFC 6598) is deliberately NOT here: carriers share it among many
# customers, so a peer in it is not necessarily on this LAN. iPhone Personal Hotspot (Wi-Fi / USB) uses
# 172.20.10.0/28, which is RFC 1918. The iOS app checks the same ranges (CaptureCore LocalNetworkPolicy).
LOCAL_NETWORKS = (
    ("loopback", ipaddress.ip_network("127.0.0.0/8")),
    ("private", ipaddress.ip_network("10.0.0.0/8")),
    ("private", ipaddress.ip_network("172.16.0.0/12")),
    ("private", ipaddress.ip_network("192.168.0.0/16")),
    ("linkLocal", ipaddress.ip_network("169.254.0.0/16")),
    ("loopback", ipaddress.ip_network("::1/128")),
    ("linkLocal", ipaddress.ip_network("fe80::/10")),
    ("uniqueLocal", ipaddress.ip_network("fc00::/7")),
)
REFUSED_LOG_INTERVAL = 60.0  # log a refused address at most once per this many seconds


def log(message: str) -> None:
    print("%s %s" % (datetime.now().strftime("%H:%M:%S"), message), flush=True)


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def atomic_write_bytes(path: Path, data: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="." + path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, str(path))
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def atomic_write_json(path: Path, obj, mode: int = 0o644) -> None:
    atomic_write_bytes(path, (json.dumps(obj, ensure_ascii=False, indent=2) + "\n").encode("utf-8"), mode)


def read_json(path: Path):
    try:
        with open(path, "rb") as f:
            return json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        return None


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK_SIZE), b""):
            h.update(chunk)
    return h.hexdigest()


def manifest_hash(entries) -> str:
    text = "".join("%s\t%d\t%s\n" % (e["path"], e["size"], e["sha256"]) for e in sorted(entries, key=lambda e: e["path"]))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def run_text(cmd) -> str:
    try:
        out = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=True)
        return out.stdout.decode("utf-8", "replace").strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def computer_name() -> str:
    return run_text(["scutil", "--get", "ComputerName"]) or socket.gethostname()


def local_host_name() -> str:
    name = run_text(["scutil", "--get", "LocalHostName"])
    if not name:
        name = socket.gethostname().split(".")[0]
    return name


def lan_ipv4_addresses():
    """Every non-loopback IPv4 address of this Mac, the default-route one first."""
    found = []

    def add(ip):
        if ip and not ip.startswith("127.") and ip != "0.0.0.0" and ip not in found:
            found.append(ip)

    try:  # UDP connect sends nothing; it only picks the interface of the default route.
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            add(s.getsockname()[0])
        finally:
            s.close()
    except OSError:
        pass
    for exe in ("/sbin/ifconfig", "ifconfig"):
        text = run_text([exe])
        if text:
            for ip in re.findall(r"^\s*inet (\d+\.\d+\.\d+\.\d+)", text, re.MULTILINE):
                add(ip)
            break
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            add(info[4][0])
    except OSError:
        pass
    return found


def address_scope(text) -> "str | None":
    """'loopback' / 'private' / 'linkLocal' / 'uniqueLocal' / 'public', or None if `text` is not an IP address.

    Accepts IPv6 zone ids (fe80::1%en0) and brackets; IPv4-mapped IPv6 (::ffff:a.b.c.d) is judged as IPv4.
    """
    if not isinstance(text, str):
        return None
    text = text.strip()
    if text.startswith("[") and text.endswith("]"):
        text = text[1:-1]
    text = text.split("%", 1)[0]
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        return None
    if addr.version == 6 and addr.ipv4_mapped is not None:
        addr = addr.ipv4_mapped
    for scope, network in LOCAL_NETWORKS:
        if addr.version == network.version and addr in network:
            return scope
    return "public"


def is_local_address(text) -> bool:
    """True only for loopback, RFC 1918 private, link-local and IPv6 ULA addresses (same network)."""
    scope = address_scope(text)
    return scope is not None and scope != "public"


# ---------------------------------------------------------------------------
# Receiver identity (.receiver.json)


def load_identity(data_dir: Path, reset_code: bool = False) -> dict:
    path = data_dir / ".receiver.json"
    data = read_json(path)
    cfg = data if isinstance(data, dict) else {}
    changed = not isinstance(data, dict)
    rid = cfg.get("receiverId")
    try:
        uuid.UUID(str(rid))
    except ValueError:
        cfg["receiverId"] = str(uuid.uuid4()).upper()
        changed = True
    code = cfg.get("pairingCode")
    if reset_code or not (isinstance(code, str) and PAIRING_CODE_RE.fullmatch(code)):
        cfg["pairingCode"] = "%06d" % secrets.randbelow(10 ** 6)
        changed = True
    name = computer_name()
    if name and name != cfg.get("name"):
        cfg["name"] = name
        changed = True
    if changed:
        atomic_write_json(path, cfg, mode=0o600)
    return cfg


# ---------------------------------------------------------------------------
# Validation


class HttpError(Exception):
    def __init__(self, status: int, body: dict):
        super().__init__(status)
        self.status = status
        self.body = body


def bad_request(*errors):
    return HttpError(400, {"status": "badRequest", "errors": list(errors)})


def parse_manifest(body: bytes):
    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise bad_request("本文が JSON ではありません")
    files = data.get("files") if isinstance(data, dict) else None
    if not isinstance(files, list) or not files:
        raise bad_request("files が空か、配列ではありません")
    if len(files) > MAX_FILES:
        raise bad_request("ファイルが多すぎます（%d 個まで）" % MAX_FILES)
    entries, errors = {}, []
    for i, f in enumerate(files):
        if not isinstance(f, dict):
            errors.append("files[%d] がオブジェクトではありません" % i)
            continue
        path, size, sha = f.get("path"), f.get("size"), f.get("sha256")
        ok = True
        if not isinstance(path, str) or not FILE_PATH_RE.fullmatch(path):
            errors.append("files[%d].path は使えません: %r" % (i, path))
            ok = False
        elif path in entries:
            errors.append("files[%d].path が重複しています: %s" % (i, path))
            ok = False
        if not isinstance(size, int) or isinstance(size, bool) or not 0 <= size <= MAX_FILE_SIZE:
            errors.append("files[%d].size が不正です（0〜%d）" % (i, MAX_FILE_SIZE))
            ok = False
        if not isinstance(sha, str) or not SHA256_RE.fullmatch(sha):
            errors.append("files[%d].sha256 が 64 桁の 16 進数ではありません" % i)
            ok = False
        if ok:
            entries[path] = {"path": path, "size": size, "sha256": sha.lower()}
    if not errors and "session.json" not in entries:
        errors.append("session.json が files にありません")
    if errors:
        raise bad_request(*errors[:50])
    return [entries[p] for p in sorted(entries)]


def validate_session(path: Path, session_id: str, manifest_paths):
    """Returns (session, errors). The session is published only when errors is empty."""
    try:
        with open(path, "rb") as f:
            data = json.loads(f.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as e:
        return None, ["session.json を読めません: %s" % e]
    if not isinstance(data, dict):
        return None, ["session.json がオブジェクトではありません"]
    errors = []
    if data.get("schema") != SCHEMA:
        errors.append("schema が %s ではありません" % SCHEMA)
    version = data.get("schemaVersion")
    if not (isinstance(version, int) and not isinstance(version, bool) and version == SCHEMA_VERSION):
        errors.append("schemaVersion が %d ではありません" % SCHEMA_VERSION)
    if data.get("sessionId") != session_id:
        errors.append("sessionId が URL の %s と違います" % session_id)
    kind = data.get("workKind")
    if kind is not None and kind not in WORK_KINDS:
        errors.append("workKind は %s のどれか（または無し）であるべきです（%r）" % (" / ".join(WORK_KINDS), kind))
    guidance = data.get("guidance")
    if guidance is not None and guidance not in GUIDANCES:
        errors.append("guidance は %s のどれか（または無し）であるべきです（%r）" % (" / ".join(GUIDANCES), guidance))
    errors.extend(validate_declared_size(data.get("declaredSize")))
    errors.extend(validate_direction_plan(data.get("directionPlan"), guidance))
    frames = data.get("referenceFrames")
    if isinstance(frames, list):
        for i, frame in enumerate(frames):
            if isinstance(frame, dict):
                errors.extend(validate_heading_frame(frame, "referenceFrames[%d]" % i))
    photos = data.get("photos")
    if not isinstance(photos, list):
        errors.append("photos が配列ではありません")
        return data, errors
    seen = set()
    for i, photo in enumerate(photos):
        label = "photos[%d]" % i
        if not isinstance(photo, dict):
            errors.append("%s がオブジェクトではありません" % label)
            continue
        pid = photo.get("photoId")
        if not isinstance(pid, str) or not SESSION_ID_RE.fullmatch(pid):
            errors.append("%s.photoId が大文字の UUID ではありません" % label)
            continue
        if pid in seen:
            errors.append("%s.photoId が重複しています: %s" % (label, pid))
        seen.add(pid)
        image = photo.get("image")
        image_file = image.get("file") if isinstance(image, dict) else None
        expected = "photos/%s.jpg" % pid
        if image_file != expected:
            errors.append("%s.image.file は %s であるべきです（%r）" % (label, expected, image_file))
        elif image_file not in manifest_paths:
            errors.append("%s.image.file %s が manifest にありません" % (label, image_file))
        errors.extend(validate_flat(photo.get("flat"), label, pid, manifest_paths))
        mask = photo.get("mask")
        if mask is None:
            continue
        if not isinstance(mask, dict):
            errors.append("%s.mask がオブジェクトではありません" % label)
            continue
        if mask.get("status") in MASK_FILE_STATUSES:
            mask_file = mask.get("file")
            expected = "masks/%s.png" % pid
            if mask_file != expected:
                errors.append("%s.mask.file は %s であるべきです（%r）" % (label, expected, mask_file))
            elif mask_file not in manifest_paths:
                errors.append("%s.mask.file %s が manifest にありません" % (label, mask_file))
    return data, errors[:50]


def validate_flat(flat, label: str, pid: str, manifest_paths):
    """photos[].flat (flat artwork, added later): null/missing is fine; corners need 4 [x, y] points and
    rectified.file must be rectified/<photoId>.jpg and in the manifest."""
    errors = []
    if flat is None:
        return errors
    if not isinstance(flat, dict):
        return ["%s.flat がオブジェクトではありません" % label]
    corners = flat.get("corners")
    if corners is not None:
        names = ("topLeft", "topRight", "bottomRight", "bottomLeft")
        ok = isinstance(corners, dict) and all(
            isinstance(corners.get(n), list) and len(corners[n]) == 2
            and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in corners[n]) for n in names)
        if not ok:
            errors.append("%s.flat.corners は topLeft・topRight・bottomRight・bottomLeft の [x, y] であるべきです" % label)
    size = flat.get("size")
    if size is not None:
        ok = isinstance(size, dict) and all(
            isinstance(size.get(k), (int, float)) and not isinstance(size.get(k), bool) and size.get(k) > 0
            for k in ("widthM", "heightM"))
        if not ok:
            errors.append("%s.flat.size の widthM・heightM が正の数ではありません" % label)
    rectified = flat.get("rectified")
    if rectified is not None:
        rfile = rectified.get("file") if isinstance(rectified, dict) else None
        expected = "rectified/%s.jpg" % pid
        if rfile != expected:
            errors.append("%s.flat.rectified.file は %s であるべきです（%r）" % (label, expected, rfile))
        elif rfile not in manifest_paths:
            errors.append("%s.flat.rectified.file %s が manifest にありません" % (label, rfile))
    return errors


def validate_direction_plan(plan, guidance):
    """A plan without targets is allowed only for free capture (guidance "free", plan id "free"); free capture needs it."""
    if not isinstance(plan, dict):
        return []
    targets = plan.get("targets")
    errors = []
    if isinstance(targets, list) and not targets and guidance != "free":
        errors.append("directionPlan.targets が空なのは、自由に撮ったセッション（guidance free）だけです")
    if guidance == "free" and (plan.get("id") != FREE_PLAN_ID or targets != []):
        errors.append("自由に撮ったセッション（guidance free）の directionPlan は id free・targets [] であるべきです（%r）" % plan.get("id"))
    return errors


def sheet_name(sheet_id) -> str:
    """Japanese name of a declared sheet id: the app's list, 「その他」 for typed-in sizes, else the id itself."""
    if sheet_id == CUSTOM_SHEET_ID:
        return CUSTOM_SHEET_NAME
    return SHEET_PRESETS.get(sheet_id, (str(sheet_id),))[0]


def validate_declared_size(declared):
    """declaredSize (added later): null/missing is fine. sheet is null or {id, longSideM, shortSideM} with a non-empty id
    and sides in range (long >= short); heightM is null or 0.005–3 m. Unknown sheet ids are accepted (future lists)."""
    if declared is None:
        return []
    if not isinstance(declared, dict):
        return ["declaredSize がオブジェクトではありません"]
    errors = []
    sheet = declared.get("sheet")
    if sheet is not None:
        lo, hi = DECLARED_SHEET_SIDE_RANGE_M
        if not isinstance(sheet, dict):
            errors.append("declaredSize.sheet がオブジェクトではありません")
        else:
            if not isinstance(sheet.get("id"), str) or not sheet.get("id"):
                errors.append("declaredSize.sheet.id が文字列ではありません")
            long_side, short_side = sheet.get("longSideM"), sheet.get("shortSideM")
            if not all(_is_num(v) and lo <= v <= hi for v in (long_side, short_side)):
                errors.append("declaredSize.sheet の longSideM・shortSideM は %g〜%g m の数であるべきです" % (lo, hi))
            elif long_side < short_side:
                errors.append("declaredSize.sheet の longSideM が shortSideM より短いです")
    height = declared.get("heightM")
    if height is not None:
        lo, hi = DECLARED_HEIGHT_RANGE_M
        if not (_is_num(height) and lo <= height <= hi):
            errors.append("declaredSize.heightM は %g〜%g m の数か null であるべきです（%r）" % (lo, hi, height))
    return errors


def declared_size_text(session) -> "str | None":
    """One line for `show`: the paper picked or the height typed in. None when nothing was entered."""
    declared = session.get("declaredSize") if isinstance(session, dict) else None
    if not isinstance(declared, dict):
        return None
    parts = []
    sheet = declared.get("sheet")
    if isinstance(sheet, dict) and _is_num(sheet.get("longSideM")) and _is_num(sheet.get("shortSideM")):
        name = sheet_name(sheet.get("id"))
        parts.append("紙 %s（%.1f × %.1f cm、id %s）" % (name, sheet["shortSideM"] * 100, sheet["longSideM"] * 100, sheet.get("id")))
    height = declared.get("heightM")
    if _is_num(height):
        parts.append("高さ %.1f cm" % (height * 100))
    return "、".join(parts) or None


def _is_num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _is_vec3(v) -> bool:
    return isinstance(v, list) and len(v) == 3 and all(_is_num(x) for x in v)


def validate_heading_frame(frame, label: str):
    """referenceFrames[].heading (heading-guided capture, added later): null/missing is fine. basePointWorld may be null
    for such frames. derivation (filled after capture) needs a known status; centerWorld is [x, y, z] or null; size
    numbers are positive or null."""
    errors = []
    base = frame.get("basePointWorld")
    heading = frame.get("heading")
    if base is not None and not _is_vec3(base):
        errors.append("%s.basePointWorld は [x, y, z] か null であるべきです" % label)
    if base is None and heading is None and "basePointWorld" in frame:
        errors.append("%s.basePointWorld が null なのは、向きで案内した基準（heading あり）だけです" % label)
    if heading is None:
        return errors
    if not isinstance(heading, dict):
        return errors + ["%s.heading がオブジェクトではありません" % label]
    for key in ("frontHeadingDeg", "frontPitchDeg"):
        if heading.get(key) is not None and not _is_num(heading.get(key)):
            errors.append("%s.heading.%s が数ではありません" % (label, key))
    d = heading.get("derivation")
    if d is None:
        return errors
    if not isinstance(d, dict):
        return errors + ["%s.heading.derivation がオブジェクトではありません" % label]
    if d.get("status") not in DERIVATION_STATUSES:
        errors.append("%s.heading.derivation.status は %s のどれかであるべきです（%r）"
                      % (label, " / ".join(DERIVATION_STATUSES), d.get("status")))
    center = d.get("centerWorld")
    if center is not None and not _is_vec3(center):
        errors.append("%s.heading.derivation.centerWorld は [x, y, z] か null であるべきです" % label)
    if d.get("origin") not in (None, "base", "center"):
        errors.append("%s.heading.derivation.origin は base / center / null であるべきです" % label)
    size = d.get("size")
    if size is not None:
        if not isinstance(size, dict) or size.get("status") not in ("approximate", "unknown"):
            errors.append("%s.heading.derivation.size.status は approximate / unknown であるべきです" % label)
        else:
            for key in ("widthM", "depthM", "heightM"):
                v = size.get(key)
                if v is not None and not (_is_num(v) and v > 0):
                    errors.append("%s.heading.derivation.size.%s が正の数ではありません" % (label, key))
    return errors


def guidance_of(session) -> "str | None":
    """How 3D work was guided: "heading" or "baseCylinder" (missing/null in sessions from before). None for flat artwork."""
    if work_kind_of(session) == "flat":
        return None
    g = session.get("guidance") if isinstance(session, dict) else None
    return g if g in GUIDANCES else "baseCylinder"


def work_kind_of(session) -> str:
    kind = session.get("workKind") if isinstance(session, dict) else None
    return kind if kind in WORK_KINDS else "object"


def rotation_of(photo) -> "int | None":
    image = photo.get("image") if isinstance(photo, dict) else None
    rot = image.get("displayRotationDegClockwise", 0) if isinstance(image, dict) else 0
    if rot is None:
        return 0
    if isinstance(rot, bool) or not isinstance(rot, (int, float)) or rot % 90 != 0:
        return None
    return int(rot) % 360


# ---------------------------------------------------------------------------
# Index


def scan_sessions(data_dir: Path):
    entries = []
    sessions_dir = data_dir / "sessions"
    if not sessions_dir.is_dir():
        return entries
    for d in sorted(sessions_dir.iterdir()):
        if not d.is_dir() or not SESSION_ID_RE.fullmatch(d.name):
            continue
        receipt = read_json(d / "_receipt.json")
        if not isinstance(receipt, dict) or receipt.get("complete") is not True:
            continue
        session = read_json(d / "session.json")
        session = session if isinstance(session, dict) else {}
        photos = session.get("photos") if isinstance(session.get("photos"), list) else []
        mask_count = collections.Counter()
        for p in photos:
            mask = p.get("mask") if isinstance(p, dict) else None
            mask_count[str(mask.get("status")) if isinstance(mask, dict) else "none"] += 1
        entries.append({
            "sessionId": d.name,
            "title": session.get("title"),
            "workKind": work_kind_of(session),
            "guidance": guidance_of(session),
            "photoCount": len(photos),
            "maskCount": dict(sorted(mask_count.items())),
            "receivedAt": receipt.get("receivedAt"),
            "manifestHash": receipt.get("manifestHash"),
            "path": "sessions/%s" % d.name,
        })
    entries.sort(key=lambda e: str(e.get("receivedAt") or ""), reverse=True)
    return entries


def scan_incoming(data_dir: Path):
    """Unfinished uploads: list of (sessionId, uploadId, present, total)."""
    result = []
    incoming = data_dir / "incoming"
    if not incoming.is_dir():
        return result
    for manifest_path in sorted(incoming.glob("*/*/_manifest.json")):
        manifest = read_json(manifest_path)
        files = manifest.get("files", []) if isinstance(manifest, dict) else []
        staging = manifest_path.parent
        present = sum(1 for f in files if isinstance(f, dict) and (staging / str(f.get("path"))).is_file())
        result.append((staging.parent.name, staging.name, present, len(files)))
    return result


# ---------------------------------------------------------------------------
# Receiver core


class Receiver:
    def __init__(self, data_dir: Path, identity: dict, fail_put_every: int = 0, sips_path: str = SIPS_PATH,
                 pack_path="default"):
        self.data_dir = Path(data_dir).resolve()
        self.identity = identity
        self.fail_put_every = fail_put_every
        self.sips_path = sips_path
        # None disables the for_claude/ hook (tests); a missing binary prints a build hint once.
        self.pack_path = str(PACK_PATH) if pack_path == "default" else pack_path
        self._pack_hint_shown = False
        self._pack_locks = {}
        self._pack_guard = threading.Lock()
        self.sessions_dir = self.data_dir / "sessions"
        self.incoming_dir = self.data_dir / "incoming"
        self.replaced_dir = self.data_dir / "replaced"
        self.partial_dir = self.incoming_dir / ".partial"
        self._locks = {}
        self._locks_guard = threading.Lock()
        self._index_lock = threading.Lock()
        self._hash_cache = {}
        self._hash_lock = threading.Lock()
        self._put_count = 0
        self._put_count_lock = threading.Lock()
        self._auth_failures = {}
        self._auth_lock = threading.Lock()

    # -- setup ---------------------------------------------------------------

    def prepare(self) -> None:
        for d in (self.sessions_dir, self.incoming_dir, self.replaced_dir, self.partial_dir):
            d.mkdir(parents=True, exist_ok=True)
        for leftover in self.partial_dir.iterdir():
            try:
                leftover.unlink()
            except OSError:
                pass
        atomic_write_bytes(self.data_dir / "README.md", DATA_README.encode("utf-8"))
        self.rebuild_index()

    def session_lock(self, session_id: str) -> threading.Lock:
        with self._locks_guard:
            return self._locks.setdefault(session_id, threading.Lock())

    # -- auth ----------------------------------------------------------------

    def authorize(self, client_ip: str, token) -> None:
        now = time.monotonic()
        with self._auth_lock:
            failures = self._auth_failures.get(client_ip)
            while failures and failures[0] < now - AUTH_FAIL_WINDOW:
                failures.popleft()
            if failures and len(failures) >= AUTH_FAIL_LIMIT:
                raise HttpError(429, {"status": "tooManyAttempts"})
        expected = self.identity["pairingCode"].encode("ascii")
        given = (token or "").strip().encode("utf-8", "surrogateescape")
        if not hmac.compare_digest(given, expected):
            with self._auth_lock:
                self._auth_failures.setdefault(client_ip, collections.deque()).append(now)
            raise HttpError(401, {"status": "unauthorized"})

    # -- helpers -------------------------------------------------------------

    def ping(self) -> dict:
        return {"service": SERVICE_NAME, "protocolVersion": PROTOCOL_VERSION,
                "receiverId": self.identity["receiverId"], "name": self.identity.get("name", "")}

    def staging_dir(self, session_id: str, upload_id: str) -> Path:
        return self.incoming_dir / session_id / upload_id

    def published_receipt(self, session_id: str):
        receipt = read_json(self.sessions_dir / session_id / "_receipt.json")
        if isinstance(receipt, dict) and receipt.get("complete") is True:
            return receipt
        return None

    def published_hash(self, session_id: str):
        receipt = self.published_receipt(session_id)
        return receipt.get("manifestHash") if receipt else None

    def load_manifest(self, session_id: str, upload_id: str):
        """Manifest entries of a previously POSTed manifest, or None."""
        data = read_json(self.staging_dir(session_id, upload_id) / "_manifest.json")
        if not isinstance(data, dict) or not isinstance(data.get("files"), list):
            return None
        entries = data["files"]
        if manifest_hash(entries) != upload_id:
            return None
        return entries

    def cached_sha256(self, path: Path, use_cache: bool = True) -> str:
        st = path.stat()
        key = str(path)
        sig = (st.st_size, st.st_mtime_ns, st.st_ino)
        if use_cache:
            with self._hash_lock:
                hit = self._hash_cache.get(key)
            if hit and hit[0] == sig:
                return hit[1]
        digest = sha256_file(path)
        with self._hash_lock:
            self._hash_cache[key] = (sig, digest)
        return digest

    def remember_hash(self, path: Path, digest: str) -> None:
        st = path.stat()
        with self._hash_lock:
            self._hash_cache[str(path)] = ((st.st_size, st.st_mtime_ns, st.st_ino), digest)

    def stored_ok(self, path: Path, entry: dict, use_cache: bool = True) -> bool:
        try:
            if not path.is_file() or path.stat().st_size != entry["size"]:
                return False
            return self.cached_sha256(path, use_cache) == entry["sha256"]
        except OSError:
            return False

    def missing_files(self, staging: Path, entries, use_cache: bool = True):
        missing = []
        for e in entries:
            path = staging / e["path"]
            if not self.stored_ok(path, e, use_cache):
                if path.exists():
                    try:
                        path.unlink()  # wrong size/hash on disk: drop it so it gets resent
                    except OSError:
                        pass
                missing.append(e["path"])
        return missing

    # -- endpoints -------------------------------------------------------------

    def create_upload(self, session_id: str, body: bytes):
        entries = parse_manifest(body)
        mhash = manifest_hash(entries)
        with self.session_lock(session_id):
            if self.published_hash(session_id) == mhash:
                return {"status": "alreadyComplete", "manifestHash": mhash}
            staging = self.staging_dir(session_id, mhash)
            if self.load_manifest(session_id, mhash) is None:
                atomic_write_json(staging / "_manifest.json",
                                  {"sessionId": session_id, "manifestHash": mhash, "createdAt": now_iso(), "files": entries})
            missing = self.missing_files(staging, entries)
        return {"status": "uploading", "uploadId": mhash, "missing": missing}

    def put_file(self, session_id: str, upload_id: str, rel: str, length, header_sha, read_chunks):
        if not FILE_PATH_RE.fullmatch(rel):
            raise bad_request("path は使えません: %r" % rel)
        if not UPLOAD_ID_RE.fullmatch(upload_id):
            raise bad_request("uploadId が不正です")
        staging = self.staging_dir(session_id, upload_id)
        dest = staging / rel
        with self.session_lock(session_id):
            entry = self._entry_for(session_id, upload_id, rel)
            if entry is None:
                return {"status": "alreadyStored"}  # already published with this manifest
            if self.stored_ok(dest, entry):
                return {"status": "alreadyStored"}
        if not isinstance(header_sha, str) or not SHA256_RE.fullmatch(header_sha.strip()):
            raise bad_request("X-Content-SHA256 ヘッダーがありません（64 桁の 16 進数）")
        if header_sha.strip().lower() != entry["sha256"]:
            raise HttpError(422, {"status": "mismatch", "errors": ["X-Content-SHA256 が manifest と違います"]})
        if length is None:
            raise HttpError(411, {"status": "lengthRequired"})
        if length != entry["size"]:
            raise HttpError(422, {"status": "mismatch", "errors": ["Content-Length %d が manifest の size %d と違います" % (length, entry["size"])]})

        tmp = self.partial_dir / ("%s.part" % uuid.uuid4().hex)
        try:
            h, received = hashlib.sha256(), 0
            with open(tmp, "wb") as f:
                for chunk in read_chunks(length):
                    h.update(chunk)
                    f.write(chunk)
                    received += len(chunk)
            if received != length:
                raise bad_request("本文が途中で切れました（%d / %d バイト）" % (received, length))
            if self._should_fail_put():
                raise HttpError(500, {"status": "error", "errors": ["テスト用の失敗（--fail-put-every）"]})
            if h.hexdigest() != entry["sha256"]:
                raise HttpError(422, {"status": "mismatch", "errors": ["受け取った内容の SHA-256 が合いません"]})
            with self.session_lock(session_id):
                if self._entry_for(session_id, upload_id, rel) is None:
                    return {"status": "alreadyStored"}
                dest.parent.mkdir(parents=True, exist_ok=True)
                os.replace(str(tmp), str(dest))
                self.remember_hash(dest, entry["sha256"])
            return {"status": "stored"}
        finally:
            if tmp.exists():
                tmp.unlink()

    def _entry_for(self, session_id, upload_id, rel):
        """Manifest entry for rel; None if the manifest is already published. Raises 404/409. Hold the lock."""
        entries = self.load_manifest(session_id, upload_id)
        if entries is None:
            receipt = self.published_receipt(session_id)
            if receipt and receipt.get("manifestHash") == upload_id:
                if any(f.get("path") == rel for f in receipt.get("files", [])):
                    return None
                raise HttpError(409, {"status": "notInManifest", "path": rel})
            raise HttpError(404, {"status": "unknownUpload"})
        for e in entries:
            if e["path"] == rel:
                return e
        raise HttpError(409, {"status": "notInManifest", "path": rel})

    def _should_fail_put(self) -> bool:
        if self.fail_put_every <= 0:
            return False
        with self._put_count_lock:
            self._put_count += 1
            return self._put_count % self.fail_put_every == 0

    def commit(self, session_id: str, upload_id: str):
        if not UPLOAD_ID_RE.fullmatch(upload_id):
            raise bad_request("uploadId が不正です")
        dest = self.sessions_dir / session_id
        with self.session_lock(session_id):
            if self.published_hash(session_id) == upload_id:
                return {"status": "complete", "manifestHash": upload_id, "path": str(dest)}
            entries = self.load_manifest(session_id, upload_id)
            if entries is None:
                raise HttpError(404, {"status": "unknownUpload"})
            staging = self.staging_dir(session_id, upload_id)
            missing = self.missing_files(staging, entries, use_cache=False)
            if missing:
                raise HttpError(409, {"status": "incomplete", "missing": missing})
            session, errors = validate_session(staging / "session.json", session_id, {e["path"] for e in entries})
            if errors:
                raise HttpError(422, {"status": "invalid", "errors": errors})
            atomic_write_json(staging / "_receipt.json", {
                "complete": True, "sessionId": session_id, "manifestHash": upload_id,
                "receivedAt": now_iso(), "files": entries})
            self.make_upright(staging, session)
            self._publish(session_id, staging, dest)
            with self._hash_lock:
                prefix = str(staging) + os.sep
                for key in [k for k in self._hash_cache if k.startswith(prefix)]:
                    del self._hash_cache[key]
        self.rebuild_index()
        log("[完了] %s を受け取りました（%d ファイル）→ %s" % (session_id, len(entries), dest))
        self.start_pack(session_id)
        return {"status": "complete", "manifestHash": upload_id, "path": str(dest)}

    # -- for_claude/ (memoria-pack) --------------------------------------------

    def start_pack(self, session_id: str):
        """Builds captures/for_claude/<sessionId>/ in the background. Never raises, never blocks the commit.

        Returns the thread (or None when the hook is off or the binary is not built)."""
        try:
            path = self.pack_path
            if not path:
                return None
            if not (os.path.isfile(path) and os.access(path, os.X_OK)):
                if not self._pack_hint_shown:
                    self._pack_hint_shown = True
                    log("[ヒント] AI ツール向けの入力（for_claude/）を自動で作るには、一度ビルドしてください: "
                        "cd tools/claude-pack && swift build -c release")
                return None
            thread = threading.Thread(target=self._run_pack, args=(path, session_id),
                                      name="memoria-pack-%s" % session_id[:8], daemon=True)
            thread.start()
            return thread
        except Exception as e:  # noqa: BLE001 - the hook must never affect the commit
            log("[警告] for_claude/ の作成を始められませんでした（%s）: %s" % (session_id, e))
            return None

    def _run_pack(self, path: str, session_id: str) -> None:
        with self._pack_guard:
            lock = self._pack_locks.setdefault(session_id, threading.Lock())
        with lock:  # one run per session at a time (a resend while packing waits, then rebuilds)
            try:
                result = subprocess.run([path, session_id, "--data-dir", str(self.data_dir)],
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=PACK_TIMEOUT)
                lines = [l for l in result.stdout.decode("utf-8", "replace").splitlines() if l.strip()]
                if result.returncode == 0:
                    log("[for_claude] %s" % (lines[-1] if lines else session_id))
                else:
                    detail = " / ".join(l.strip() for l in lines if "error" in l.lower()) or (lines[-1] if lines else "")
                    log("[警告] for_claude/ を作れませんでした（%s、終了コード %d）: %s"
                        % (session_id, result.returncode, detail[-300:]))
            except subprocess.TimeoutExpired:
                log("[警告] for_claude/ の作成が %d 秒で終わりませんでした（%s）" % (PACK_TIMEOUT, session_id))
            except Exception as e:  # noqa: BLE001
                log("[警告] for_claude/ を作れませんでした（%s）: %s" % (session_id, e))

    def _publish(self, session_id: str, staging: Path, dest: Path) -> None:
        moved_old = None
        if dest.exists():
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            moved_old = self.replaced_dir / ("%s-%s" % (session_id, stamp))
            n = 2
            while moved_old.exists():
                moved_old = self.replaced_dir / ("%s-%s-%d" % (session_id, stamp, n))
                n += 1
            os.rename(str(dest), str(moved_old))
            log("[置き換え] 前の版を %s に移しました" % moved_old)
        manifest_path = staging / "_manifest.json"
        manifest_bytes = manifest_path.read_bytes()
        manifest_path.unlink()  # the manifest stays out of the published folder
        try:
            os.rename(str(staging), str(dest))
        except OSError:
            atomic_write_bytes(manifest_path, manifest_bytes)
            if moved_old is not None and not dest.exists():
                os.rename(str(moved_old), str(dest))
            raise
        try:
            staging.parent.rmdir()  # incoming/<sid> when no other upload is pending
        except OSError:
            pass

    def make_upright(self, staging: Path, session: dict) -> None:
        """Display-only upright copies in upright/. Never raises."""
        upright = staging / "upright"
        try:
            shutil.rmtree(str(upright), ignore_errors=True)
            if not self.sips_path or not os.path.exists(self.sips_path):
                log("[警告] sips が無いので upright/ は作りません")
                return
            jobs = []
            for photo in session.get("photos", []):
                pid = photo["photoId"]
                rot = rotation_of(photo)
                if rot is None:
                    log("[警告] %s の displayRotationDegClockwise が 90 の倍数ではないので upright を作りません" % pid)
                    continue
                jobs.append((staging / "photos" / ("%s.jpg" % pid), upright / "photos" / ("%s.jpg" % pid), rot))
                mask = photo.get("mask")
                if isinstance(mask, dict) and mask.get("status") in MASK_FILE_STATUSES:
                    jobs.append((staging / "masks" / ("%s.png" % pid), upright / "masks" / ("%s.png" % pid), rot))

            def run(job):
                src, out, rot = job
                try:
                    self._rotate(src, out, rot)
                except Exception as e:  # noqa: BLE001 - previews must never fail the commit
                    log("[警告] upright を作れませんでした（%s）: %s" % (src.name, e))
                    if out.exists():
                        out.unlink()

            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(run, jobs))
            for d in (upright / "photos", upright / "masks", upright):
                if d.is_dir() and not any(d.iterdir()):
                    d.rmdir()
        except Exception as e:  # noqa: BLE001
            log("[警告] upright の作成で失敗しました: %s" % e)

    def _rotate(self, src: Path, out: Path, rot: int) -> None:
        out.parent.mkdir(parents=True, exist_ok=True)
        if rot == 0:
            shutil.copyfile(str(src), str(out))
            return
        result = subprocess.run([self.sips_path, "-r", str(rot), str(src), "--out", str(out)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        if result.returncode != 0 or not out.is_file() or out.stat().st_size == 0:
            raise RuntimeError("sips が失敗しました: %s" % result.stdout.decode("utf-8", "replace").strip()[-200:])

    def session_status(self, session_id: str):
        receipt = self.published_receipt(session_id)
        if not receipt:
            raise HttpError(404, {"status": "notFound"})
        return {"status": "complete", "manifestHash": receipt.get("manifestHash"),
                "path": str(self.sessions_dir / session_id)}

    def rebuild_index(self) -> None:
        with self._index_lock:
            atomic_write_json(self.data_dir / "index.json",
                              {"updatedAt": now_iso(), "sessions": scan_sessions(self.data_dir)})


# ---------------------------------------------------------------------------
# HTTP layer


# The iPhone drops idle keep-alive connections; these are normal and get one short log line, not a traceback.
CLIENT_DISCONNECT_ERRORS = (ConnectionResetError, BrokenPipeError, ConnectionAbortedError)


class ReceiverServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, receiver: Receiver, allow_remote: bool = False):
        self.receiver = receiver
        self.allow_remote = allow_remote
        self._refused = {}  # ip -> [last logged (monotonic), connections refused since]
        self._refused_lock = threading.Lock()
        super().__init__(address, RequestHandler)

    def client_allowed(self, client_ip) -> bool:
        return self.allow_remote or is_local_address(client_ip)

    def verify_request(self, request, client_address):
        """Runs before anything is read: a connection from outside this network is closed without a reply."""
        if self.client_allowed(client_address[0]):
            return True
        self.log_refused(client_address[0])
        return False

    def log_refused(self, client_ip) -> None:
        now = time.monotonic()
        with self._refused_lock:
            if len(self._refused) > 1000:
                self._refused = {ip: v for ip, v in self._refused.items() if now - v[0] < REFUSED_LOG_INTERVAL}
            entry = self._refused.get(client_ip)
            if entry is not None and now - entry[0] < REFUSED_LOG_INTERVAL:
                entry[1] += 1
                return
            suppressed = entry[1] if entry is not None else 0
            self._refused[client_ip] = [now, 0]
        log("[拒否] 外部アドレス %s からの接続を切りました（同じネットワークの中からだけ受け付けます%s）"
            % (client_ip, "。前回から %d 回" % suppressed if suppressed else ""))

    def handle_error(self, request, client_address):
        error = sys.exc_info()[1]
        if isinstance(error, CLIENT_DISCONNECT_ERRORS):
            log("[http] %s 接続が切れました（%s）" % (client_address[0], type(error).__name__))
            return
        super().handle_error(request, client_address)  # real errors keep the full traceback


class RequestHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MemoriaReceiver/1"
    timeout = 120

    def handle(self):
        # Second line of defence after ReceiverServer.verify_request: never read or answer outside callers.
        if not self.server.client_allowed(self.client_address[0]):
            self.server.log_refused(self.client_address[0])
            self.close_connection = True
            return
        super().handle()

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def log_request(self, code="-", size="-"):
        pass  # one line per request is written by _handle

    def log_message(self, format, *args):
        log("[http] %s %s" % (self.client_address[0], format % args))

    def _handle(self, method: str) -> None:
        started = time.monotonic()
        self._remaining = 0
        status, body = 500, {"status": "error"}
        try:
            self._remaining = self._content_length()
            status, body = 200, self._route(method)
        except HttpError as e:
            status, body = e.status, e.body
        except CLIENT_DISCONNECT_ERRORS as e:
            self.close_connection = True
            log("%s %s %s -> 接続が切れました（%s） (%.2fs)" % (self.client_address[0], method, self.path.split("?", 1)[0],
                                                       type(e).__name__, time.monotonic() - started))
            return
        except Exception:  # noqa: BLE001
            log("[エラー] %s" % traceback.format_exc().strip())
            status, body = 500, {"status": "error", "errors": ["受信側の内部エラー"]}
        self._discard_rest()
        self._send_json(status, body)
        path = self.path.split("?", 1)[0]
        log("%s %s %s -> %d %s (%.2fs)" % (self.client_address[0], method, path, status,
                                           body.get("status", "ok"), time.monotonic() - started))

    def _content_length(self):
        if self.headers.get("Transfer-Encoding"):
            self.close_connection = True
            raise HttpError(411, {"status": "lengthRequired", "errors": ["Content-Length を付けてください（chunked は使えません）"]})
        value = self.headers.get("Content-Length")
        if value is None:
            return None
        if not value.strip().isdigit():
            self.close_connection = True
            raise bad_request("Content-Length が不正です")
        return int(value)

    def _read_chunks(self, length: int):
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(CHUNK_SIZE, remaining))
            if not chunk:
                self.close_connection = True
                break
            remaining -= len(chunk)
            self._remaining -= len(chunk)
            yield chunk

    def _read_all(self, limit: int) -> bytes:
        if self._remaining is None:
            raise HttpError(411, {"status": "lengthRequired"})
        if self._remaining > limit:
            raise HttpError(413, {"status": "tooLarge"})
        return b"".join(self._read_chunks(self._remaining))

    def _discard_rest(self) -> None:
        """Keep HTTP/1.1 framing intact: drain a small unread body, close for a large one."""
        remaining = self._remaining or 0
        if remaining <= 0:
            return
        if remaining > DRAIN_LIMIT:
            self.close_connection = True
            return
        try:
            for _ in self._read_chunks(remaining):
                pass
        except OSError:
            self.close_connection = True

    def _send_json(self, status: int, body: dict) -> None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            if self.close_connection:
                self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
        except OSError:
            self.close_connection = True

    def _route(self, method: str) -> dict:
        receiver = self.server.receiver
        raw = self.path.split("?", 1)[0]
        prefix = "/api/v1/"
        if not raw.startswith(prefix):
            raise HttpError(404, {"status": "notFound"})
        receiver.authorize(self.client_address[0], self.headers.get("X-Memoria-Token"))
        parts = raw[len(prefix):].split("/")
        if parts == ["ping"]:
            if method != "GET":
                raise HttpError(405, {"status": "methodNotAllowed"})
            return receiver.ping()
        if len(parts) < 2 or parts[0] != "sessions":
            raise HttpError(404, {"status": "notFound"})
        session_id = urllib.parse.unquote(parts[1])
        if not SESSION_ID_RE.fullmatch(session_id):
            raise bad_request("sessionId が大文字の UUID ではありません")
        rest = parts[2:]
        if not rest:
            self._expect(method, "GET")
            return receiver.session_status(session_id)
        if rest[0] != "uploads":
            raise HttpError(404, {"status": "notFound"})
        if len(rest) == 1:
            self._expect(method, "POST")
            return receiver.create_upload(session_id, self._read_all(MAX_MANIFEST_BODY))
        upload_id = urllib.parse.unquote(rest[1])
        if len(rest) == 3 and rest[2] == "commit":
            self._expect(method, "POST")
            return receiver.commit(session_id, upload_id)
        if len(rest) >= 4 and rest[2] == "files":
            self._expect(method, "PUT")
            rel = urllib.parse.unquote("/".join(rest[3:]))
            return receiver.put_file(session_id, upload_id, rel, self._remaining,
                                     self.headers.get("X-Content-SHA256"), self._read_chunks)
        raise HttpError(404, {"status": "notFound"})

    @staticmethod
    def _expect(method: str, allowed: str) -> None:
        if method != allowed:
            raise HttpError(405, {"status": "methodNotAllowed"})


# ---------------------------------------------------------------------------
# Bonjour


def start_bonjour(name: str, port: int):
    exe = shutil.which("dns-sd") or ("/usr/bin/dns-sd" if os.path.exists("/usr/bin/dns-sd") else None)
    if not exe:
        return None, "なし（dns-sd が見つかりません。iPhone では URL を手で入れてください）"
    host = "%s.local" % local_host_name()
    cmd = [exe, "-R", name, BONJOUR_TYPE, "local", str(port), "host=%s" % host, "port=%d" % port, "pv=%d" % PROTOCOL_VERSION]
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as e:
        return None, "なし（dns-sd を起動できません: %s）" % e
    time.sleep(0.3)
    if proc.poll() is not None:
        return None, "なし（dns-sd がすぐに終了しました。終了コード %s）" % proc.returncode
    return proc, "広告中 \"%s\"（%s, host=%s）" % (name, BONJOUR_TYPE, host)


def stop_bonjour(proc) -> None:
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=3)


# ---------------------------------------------------------------------------
# Commands


def cmd_serve(args) -> int:
    data_dir = Path(args.data_dir).expanduser().resolve()
    data_dir.mkdir(parents=True, exist_ok=True)
    identity = load_identity(data_dir, reset_code=args.reset_code)
    fail_every = args.fail_put_every or int(os.environ.get("MEMORIA_FAIL_PUT_EVERY", "0") or 0)
    receiver = Receiver(data_dir, identity, fail_put_every=fail_every)
    receiver.prepare()
    try:
        server = ReceiverServer((args.host, args.port), receiver, allow_remote=args.allow_remote)
    except OSError as e:
        print("ポート %d で待ち受けできません: %s" % (args.port, e), file=sys.stderr)
        return 1
    port = server.server_address[1]
    proc, bonjour_status = (None, "なし（--no-bonjour）") if args.no_bonjour else start_bonjour(identity["name"], port)
    atexit.register(stop_bonjour, proc)

    def on_signal(signum, frame):
        raise KeyboardInterrupt

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, on_signal)

    addresses = lan_ipv4_addresses() if args.host in ("", "0.0.0.0") else [args.host]
    urls, warnings = connect_urls(addresses, port, args.allow_remote)
    code = identity["pairingCode"]
    print("")
    print("Memoria Capture 受信サーバー（protocolVersion %d）" % PROTOCOL_VERSION)
    print("  ペアリングコード : %s" % code)
    print("  接続先 URL       : %s" % urls[0])
    for url in urls[1:]:
        print("                     %s" % url)
    print("  受け付ける相手   : %s" % ("どこからでも（--allow-remote）" if args.allow_remote else
                                      "同じネットワークの中だけ（自宅の LAN・USB ケーブル・インターネット共有）"))
    print("  保存先           : %s" % data_dir)
    print("  Bonjour          : %s" % bonjour_status)
    print("  受信機の名前     : %s" % identity.get("name", ""))
    if fail_every:
        print("  [テスト用] %d 回に 1 回 PUT を 500 で失敗させます（--fail-put-every）" % fail_every)
    print("  終了するには Ctrl-C")
    for line in warnings:
        print(line)
    print("", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n終了します", flush=True)
    finally:
        server.server_close()
        stop_bonjour(proc)
    return 0


def connect_urls(addresses, port: int, allow_remote: bool = False):
    """(URLs to print, warning lines) for the startup banner.

    Only same-network addresses are offered as connect URLs (link-local last, with a note): connections to a
    public address are refused anyway, and offering one would invite sending photos over the internet.
    """
    def url(ip):
        return "http://%s:%d" % ("[%s]" % ip if ":" in ip else ip, port)

    scopes = [(ip, address_scope(ip)) for ip in addresses]
    private = [ip for ip, scope in scopes if scope == "private"]
    link_local = [ip for ip, scope in scopes if scope in ("linkLocal", "uniqueLocal")]
    loopback = [ip for ip, scope in scopes if scope == "loopback"]
    public = [ip for ip, scope in scopes if scope == "public"]
    names = [ip for ip, scope in scopes if scope is None]  # --host given as a name: checked per connection
    urls = [url(ip) for ip in private + loopback + names]
    urls += ["%s（USB ケーブルなどで直接つないだとき）" % url(ip) for ip in link_local]
    warnings = []
    if allow_remote:
        urls += ["%s（公開アドレス・暗号化なし）" % url(ip) for ip in public]
        warnings += [
            "",
            "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!",
            "  !! 警告: --allow-remote のため、ネットワークの外からの接続も受け付けます。",
            "  !! 通信は暗号化されていない HTTP です。写真がインターネットを平文で流れることがあります。",
            "  !! 必要な作業が終わったら、すぐに --allow-remote なしで起動し直してください。",
            "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!",
        ]
    elif public and not private:
        warnings += [
            "",
            "  [注意] この Mac の IPv4 アドレスは公開 IP アドレス（%s）で、LAN のアドレスがありません。" % "、".join(public),
            "         このネットワークは自宅などの LAN（プライベートなネットワーク）ではないようです。",
            "         公開 IP アドレスからの接続は受け付けません（写真をインターネットに流さないため）。",
            "         iPhone を同じ LAN の Wi-Fi につなぐか、USB ケーブル・インターネット共有で Mac とつないでください。",
        ]
    if not urls:
        urls = ["（同じネットワークのアドレスが見つかりません）"]
    return urls, warnings


KIND_LABELS = {"object": "立体", "flat": "平面"}
GUIDANCE_LABELS = {"heading": "向きで案内", "baseCylinder": "底の中心と円柱で案内", "free": "自由に撮る"}
GUIDANCE_SHORT = {"heading": "・向き", "free": "・自由"}


def cmd_list(args) -> int:
    data_dir = Path(args.data_dir).expanduser().resolve()
    index = read_json(data_dir / "index.json")
    sessions = index.get("sessions") if isinstance(index, dict) else None
    if not isinstance(sessions, list):
        sessions = scan_sessions(data_dir)
    print("完了したセッション: %d 件（%s）" % (len(sessions), data_dir / "sessions"))
    if sessions:
        print("%-36s  %-6s  %5s  %-28s  %-25s  %s" % ("sessionId", "種類", "写真", "マスク", "受信", "タイトル"))
        for s in sessions:
            masks = ", ".join("%s=%d" % kv for kv in (s.get("maskCount") or {}).items()) or "-"
            kind = KIND_LABELS.get(s.get("workKind") or "object", "立体") + GUIDANCE_SHORT.get(s.get("guidance"), "")
            print("%-36s  %-6s  %5s  %-28s  %-25s  %s" % (s.get("sessionId"), kind, s.get("photoCount"), masks,
                                                          s.get("receivedAt") or "-", s.get("title") or ""))
    incoming = scan_incoming(data_dir)
    print("転送途中（未完成。使わないでください）: %d 件" % len(incoming))
    for sid, uid, present, total in incoming:
        print("  %s  upload %s…  %d / %d ファイル" % (sid, uid[:12], present, total))
    return 0


def cmd_show(args) -> int:
    data_dir = Path(args.data_dir).expanduser().resolve()
    prefix = args.session.upper()
    sessions_dir = data_dir / "sessions"
    matches = sorted(d for d in (sessions_dir.iterdir() if sessions_dir.is_dir() else [])
                     if d.is_dir() and d.name.startswith(prefix) and (d / "_receipt.json").is_file())
    if not matches:
        pending = [i for i in scan_incoming(data_dir) if i[0].startswith(prefix)]
        print("完了したセッションに %s はありません%s" % (args.session, "（転送途中のものがあります。未完成なので使えません）" if pending else ""))
        return 1
    if len(matches) > 1:
        print("複数あてはまります: " + ", ".join(d.name for d in matches))
        return 1
    folder = matches[0]
    session = read_json(folder / "session.json") or {}
    receipt = read_json(folder / "_receipt.json") or {}
    photos = session.get("photos") if isinstance(session.get("photos"), list) else []
    print("セッション   : %s" % folder.name)
    print("タイトル     : %s" % (session.get("title") or ""))
    kind = work_kind_of(session)
    plan = session.get("directionPlan") if isinstance(session.get("directionPlan"), dict) else {}
    print("種類         : %s（workKind %s、撮影方向 %s）" % (KIND_LABELS[kind], kind, plan.get("id") or "-"))
    guidance = guidance_of(session)
    if guidance:
        print("案内         : %s（guidance %s%s）" % (GUIDANCE_LABELS[guidance], guidance,
                                                   "" if session.get("guidance") else "。記録なし＝前の方法"))
    print("選んだ大きさ : %s" % (declared_size_text(session) or "入力なし（declaredSize null）"))
    for frame in session.get("referenceFrames") or []:
        heading = frame.get("heading") if isinstance(frame, dict) else None
        if not isinstance(heading, dict):
            continue
        d = heading.get("derivation") if isinstance(heading.get("derivation"), dict) else None
        if d is None:
            print("基準 %-7s : 向きで案内（撮ったあとの中心はまだ求めていません）" % frame.get("id"))
            continue
        rms = d.get("residualRmsM")
        size = d.get("size") if isinstance(d.get("size"), dict) else None
        if size and size.get("status") == "approximate":
            size_text = "%s × %s × %s cm（おおよそ、信頼度 %s）" % tuple(
                ["%.1f" % ((size.get(k) or 0) * 100) for k in ("widthM", "depthM", "heightM")] + [size.get("confidence") or "-"])
        elif size:
            size_text = "分からない（%s）" % ", ".join(size.get("reasons") or [])
        else:
            size_text = "まだ求めていない"
        print("基準 %-7s : 中心 %s（写真 %d 枚、線の外れ %s）、机の面 %s、大きさ %s" % (
            frame.get("id"), d.get("status"), len(d.get("photoIds") or []),
            "%.1f cm" % (rms * 100) if _is_num(rms) else "-",
            {"base": "あり", "center": "分からない"}.get(d.get("origin"), "-"), size_text))
    print("フォルダ     : %s" % folder)
    print("受信         : %s  manifestHash %s" % (receipt.get("receivedAt"), receipt.get("manifestHash")))
    print("写真         : %d 枚" % len(photos))
    for p in sorted((p for p in photos if isinstance(p, dict)), key=lambda p: p.get("sequence") or 0):
        pid = p.get("photoId", "?")
        d = p.get("direction") if isinstance(p.get("direction"), dict) else {}
        mask = p.get("mask") if isinstance(p.get("mask"), dict) else {}

        def num(v):
            return "%.1f" % v if isinstance(v, (int, float)) and not isinstance(v, bool) else "-"

        print("#%-3s %s  方向 %s 方位 %s 仰角 %s 目標 %s  マスク %s  回転 %s" % (
            p.get("sequence"), pid, "確定" if d.get("confirmed") else "参考",
            num(d.get("azimuthDeg")), num(d.get("elevationDeg")), d.get("targetId") or "-",
            mask.get("status") or "-", (p.get("image") or {}).get("displayRotationDegClockwise")))
        heading = p.get("heading") if isinstance(p.get("heading"), dict) else None
        if heading is not None:
            print("     向き 正面から %s° 見下ろし %s° 位置 %s" % (
                num(heading.get("relativeHeadingDeg")), num(heading.get("pitchDeg")), heading.get("position") or "-"))
        flat = p.get("flat") if isinstance(p.get("flat"), dict) else None
        if flat is not None:
            size = flat.get("size") if isinstance(flat.get("size"), dict) else None
            print("     用紙 %s  端 %s  測った実寸 %s  補正 %s" % (
                "あり" if flat.get("corners") else "見つからない",
                {True: "かかっている", False: "OK"}.get(flat.get("sheetAtFrameEdge"), "-"),
                "%s × %s cm（%s）" % (num((size.get("widthM") or 0) * 100), num((size.get("heightM") or 0) * 100),
                                     size.get("planeSource")) if size else "不明",
                "あり" if flat.get("rectified") else "なし"))
        files = ["photos/%s.jpg" % pid, "masks/%s.png" % pid, "rectified/%s.jpg" % pid,
                 "upright/photos/%s.jpg" % pid, "upright/masks/%s.png" % pid]
        existing = [f for f in files if (folder / f).is_file()]
        print("     " + ("  ".join(existing) if existing else "（ファイルなし）"))
    return 0


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] not in ("serve", "list", "show", "-h", "--help"):
        argv.insert(0, "serve")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--data-dir", default=str(DEFAULT_DATA_DIR), help="保存先（既定: %(default)s）")
    parser = argparse.ArgumentParser(description="Memoria Capture の受信サーバー（iPhone → Mac）")
    sub = parser.add_subparsers(dest="command")
    serve = sub.add_parser("serve", parents=[common], help="受信サーバーを起動する（既定）")
    serve.add_argument("--port", type=int, default=8765)
    serve.add_argument("--host", default="0.0.0.0")
    serve.add_argument("--no-bonjour", action="store_true", help="Bonjour で広告しない")
    serve.add_argument("--allow-remote", action="store_true",
                       help="例外用: 同じネットワークの外（公開 IP アドレス）からの接続も受け付ける。通信は暗号化されないので通常は使わない")
    serve.add_argument("--reset-code", action="store_true", help="ペアリングコードを作り直す")
    serve.add_argument("--fail-put-every", type=int, default=0, metavar="N",
                       help="テスト専用: N 回に 1 回 PUT を 500 で失敗させる（環境変数 MEMORIA_FAIL_PUT_EVERY でも可）")
    sub.add_parser("list", parents=[common], help="受け取ったセッションの一覧")
    show = sub.add_parser("show", parents=[common], help="1 つのセッションの写真ごとの情報")
    show.add_argument("session", help="sessionId かその先頭")
    args = parser.parse_args(argv)
    return {"serve": cmd_serve, "list": cmd_list, "show": cmd_show}[args.command](args)


DATA_README = """\
# captures/ の読み方

このフォルダは `receiver/memoria_receiver.py`（Memoria Capture の受信サーバー）が書きます。
iPhone のアプリから同じネットワーク（自宅の LAN・USB ケーブル・インターネット共有）で受け取った撮影セッションが入っています。
人と Claude Code などの AI エージェント向けの説明です（受信サーバーが起動のたびに書き直します）。

## どこを使うか

**AI ツール（Claude Code など）で作品の 3D モデルを作るときは、まず `for_claude/<sessionId>/brief.md` を読んでください。**
向きをそろえて切り抜いた代表の写真・一覧の画像・実寸・粗い形がまとめてあります（`sessions/` から作った派生データ）。

| 場所 | 中身 | 使ってよいか |
|---|---|---|
| `for_claude/<sessionId>/` | AI ツール向けの入力（`brief.md`・`overview.jpg`・`views/`・`measurements.json`・`hull.obj`・`pack.json`。平面の作品と自由に撮った立体は `overview.jpg`・`hull.obj` なし）。受信のたびに `tools/claude-pack` の `memoria-pack` が作り直す（ビルドしてあるときだけ） | **AI ツールの入口はここ**。読むだけ（作り直すと置き換わる） |
| `sessions/<sessionId>/` | 全部のファイルが届き、ハッシュと session.json を確かめ終わったセッション | 元のデータ。**書き込まない**（計算に使うのはここだけ） |
| `index.json` | `sessions/` の一覧（sessionId・title・workKind（object＝立体・flat＝平面）・guidance（立体の撮り方：free＝自由に撮る・heading＝向きで案内・baseCylinder＝底の中心と円柱。平面は null）・photoCount・maskCount（mask.status ごとの数）・receivedAt・manifestHash・path） | 一覧を見るのに使う |
| `incoming/` | 転送の途中。ファイルが欠けていたり、確かめる前だったりする | **使わない・読まない・消さない**（受信サーバーが使う） |
| `replaced/<sessionId>-<UTC 時刻>/` | 同じセッションを撮り直して送り直したときの前の版 | 前の版が要るときだけ |
| `.receiver.json` | 受信機の ID とペアリングコード | 触らない（秘密の値を含む） |

一覧は `python3 receiver/memoria_receiver.py list`、1 つのセッションの中身は `python3 receiver/memoria_receiver.py show <sessionId の先頭>` で見られます。

## AI ツール向けの入力（`for_claude/<sessionId>/`）

```
brief.md            最初に読む説明（作品名・実寸と誤差・座標の決まり・写真の一覧・撮れていない範囲・使い方）
overview.jpg        選んだ写真の一覧（カメラの位置に並べ、上から見た配置で正面が下）と実寸
views/<向き>.jpg     代表の写真をまっすぐに回し、作品のまわりで切り抜いたもの（背景は写ったまま。長い辺 1568 px 以下）
measurements.json   実寸（輪郭が 8 枚以上なら visual hull で測った幅 X・奥行き Z・高さ Y と誤差。少ないときは撮影時に合わせた円柱の大きさ＝目安。向きで案内したセッションは撮ったあとに切り抜きから求めたおおよその大きさ。撮る人が高さを入力したときは declaredHeight。平面の作品は sheet に紙の大きさ）
hull.obj            粗い形（visual hull を作れたときだけ。メートル、+Y が上、+Z が正面、y = 0 が机の面）
pack.json           写真の選び方・出どころ（sessionId・manifestHash）
```

向き：AI 用 5 方向（ai5）のセッションは front・right・back・left・top（真上）。自由に撮ったセッション（guidance free）は photo-01・photo-02…（撮った順。多いときは 16 枚まで）で、どれがどの向きかは写真を見て決める。ほかは front・front_right・right・back_right・back・back_left・left・front_left（低い段）、top（一番高い写真）、front_high。
平面の作品（session.json の `workKind` が `flat`。絵・貼り絵などを真上から 1 枚）は `views/artwork.jpg`（遠近を直してまっすぐにした絵。直せなかったときは写真をまっすぐに回したもの）と、補正したときは `views/photo.jpg`（元の写真をまっすぐに回したもの）。3D の形を作る必要はなく、絵を板や額の表面に貼る形で使えます。
手で作り直すときは `tools/claude-pack/.build/release/memoria-pack <sessionId の先頭> --force`（背景を透明にした `views/<向き>_cutout.png` も要るときは `--cutouts`）。

## 1 つのセッションの中身（`sessions/<sessionId>/`）

```
session.json            メタデータ（形は docs/data-format.md）
photos/<photoId>.jpg    元写真（センサーの向きのまま。回転・縮小・切り抜きなし）
masks/<photoId>.png     作品マスク（元写真と同じ幅・高さ・向き。8bit グレー、255 = 作品、0 = 背景）
rectified/<photoId>.jpg 平面の作品だけ：用紙の四隅から遠近を直してまっすぐにした画像（作れたときだけ。元写真は別に残る）
_receipt.json           受信の記録（complete・manifestHash・receivedAt・files（path・size・sha256））
upright/photos/<photoId>.jpg   表示用にまっすぐ回したコピー（sips があるときだけ）
upright/masks/<photoId>.png    同じくマスクの表示用コピー
```

- `session.json` の `photos[]` の 1 つが 1 枚の写真です。`photos[].photoId` → `photos/<photoId>.jpg`（`image.file`）。
- マスクは `photos[].mask.status` が `candidate`（自動で選んだ・未確定）か `confirmed`（ユーザーが確認）のときだけ `masks/<photoId>.png`（`mask.file`）があります。ほかの status（`notGenerated`・`processing`・`failed`・`noObject`）ではマスクはありません。
- 向きで案内したセッション（`guidance` が `heading`）は、撮るときに底の中心・円柱を決めていません。作品の中心・作品座標（`objectToWorld`）・写真ごとの方位と仰角・おおよその大きさは、撮ったあとに写真の中心の線と切り抜きから求めた値で、`referenceFrames[].heading.derivation` に求め方と線の外れ方（残差）があります。机の高さが分からないときは `basePointWorld` が null で、`objectToWorld` の原点は求めた中心です。
- 自由に撮ったセッション（`guidance` が `free`。立体の作品を案内なしで何枚でも撮ったもの）は、撮る方向の一覧が `free`（方向は 0 個）で、基準（`referenceFrames`）もマスクもありません。写真ごとの `direction` は見下ろす角度（`elevationDeg`。カメラの光軸が水平から下へ傾いた角度）だけで、方位・距離・`targetId` は null です。どの写真がどの向きかは記録していないので、写真を見て決めます。
- 平面の作品（`workKind` が `flat`）はマスクを作りません。`photos[].flat` に、用紙の四隅（`corners`。元写真のピクセル。無ければ null）・ARKit の平面で測った実寸（`size`。測れなければ null）・補正した画像（`rectified`）が入ります。
- `declaredSize`（後から足した項目。無い・null は「入力していない」）は、撮る人が新しいセッションで選んだ・入力した大きさです（AR で測った値ではない）。平面の作品は `declaredSize.sheet`（一覧から選んだ紙：`id`（`yatsugiri` 八つ切・`yotsugiri` 四つ切・`a4`・`b4`・`a3`・`b5`、撮る人が縦と横を入力した「その他」は `custom`）・`longSideM`・`shortSideM`。縦・横の向きは書かず、写真の中の紙の形で決める）、立体の作品は `declaredSize.heightM`（入力した高さ）。**選んだ・入力した値があれば、測った値・写真から求めた値より優先します**（紙の大きさ：`declaredSize.sheet` → `photos[].flat.size` → 分からない。立体の高さ：`declaredSize.heightM` を、求めたおおよその大きさより優先する。求めた大きさは書き換えない）。
- カメラの姿勢 `camera.cameraToWorld`、内部パラメータ `camera.intrinsics`（K）、方向 `direction` は写真ごとです。`direction.confirmed` が false の写真の方向は参考値です。
- 別の `referenceFrameId` の写真どうしの姿勢は比べられません（同じ世界座標とは限らない）。

## 画像の向き（大事）

- `photos/` と `masks/` はセンサーの向き（横長）のままです。EXIF Orientation は 1。
- `image.displayRotationDegClockwise` は、まっすぐ見るために時計回りに回す角度です。
- `upright/` はその角度で回した **表示専用** のコピーです。`intrinsics`（K）・`cameraToWorld`・マスクの座標は元の `photos/` の画像に対する値なので、`upright/` の画像には当てはまりません。計算には必ず `photos/` と `masks/` を使ってください。

## 決まり（conventions。docs/data-format.md と同じ）

| 項目 | 決まり |
|---|---|
| 単位 | メートル、角度は度、時刻は ISO 8601（タイムゾーン付き）、`arFrameTimestamp` は秒（端末の起動からの時間） |
| 世界座標 | ARKit の world（`worldAlignment = .gravity`）。右手系、+Y が重力の反対（上）、原点は AR セッション開始時の端末位置。**同じ `referenceFrameId` の中でだけ意味を持つ** |
| 行列 | 入れ子の配列で **行優先**（`m[row][col]`）。点は列ベクトルで `p' = M · p` |
| `cameraToWorld` | ARKit の `ARCamera.transform`（カメラ → 世界）。カメラ座標は ARKit の決まりで、+X が保存した画像の右、+Y が画像の上、−Z が見ている方向。OpenCV 式（x 右・y 下・z 前）にするには右から `diag(1, −1, −1, 1)` を掛ける |
| `intrinsics` | 3 × 3 の K（行優先、ピクセル単位、原点は保存した画像の左上）。`intrinsicsResolution` の大きさの画像に対する値 |
| 画像の向き | 保存した画像はセンサーの向き（横長）のまま。EXIF Orientation は 1。`displayRotationDegClockwise` は、まっすぐ見るために時計回りに回す角度（表示用の情報で、K は回さない画像のもの） |
| 作品座標（objectToWorld） | 原点は作品の底面中央（基準マーカー）。+Y は上、+Z は基準点から正面のカメラへ向かう水平方向、+X = Y × Z（正面から見て右）。向きで案内した基準は撮ったあとに求め、原点は机の面が分かれば底の中心、分からなければ求めた中心 |
| 方位角 `azimuthDeg` | 作品座標でのカメラ位置 (x, z) について `atan2(x, z)` を度にして 0〜360。0 = 正面、90 = +X 側（正面から見て右へ回り込んだ位置） |
| 仰角 `elevationDeg` | 作品の中心（基準点から `heightM / 2` 上）からカメラへのベクトルの水平面からの角度。上から見下ろすと正 |

## 外部への送信について

ここにある写真は、ユーザーの身の回りを写した個人のデータです。受信サーバーは外部のクラウドに何も送りません。
これらの画像や session.json を Claude（クラウドの AI）やほかのクラウドのツール・サービスに渡すことは **外部への送信** にあたります。
送るかどうかはユーザーが別に決めることです。AI エージェントは、ユーザーがはっきり頼んだときだけ画像を開いたり送ったりしてください。
"""


if __name__ == "__main__":
    sys.exit(main())
