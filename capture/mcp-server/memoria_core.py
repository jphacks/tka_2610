"""Read-side logic for the Memoria Capture MCP server (standard library only).

Everything here works on the folder the receiver writes (captures/, see captures/README.md):

    sessions/<id>/          completed sessions (read only, never written)
    for_claude/<id>/        the AI-ready pack built by tools/claude-pack (memoria-pack)
    reconstructions/<id>/   models and notes made by agents (output_dir)
    incoming/               uploads in progress: never read or listed here
    .receiver.json          receiver id and pairing code: never read here

Only rebuild_pack (through memoria-pack, into for_claude/) and output_dir (into reconstructions/) write
anything. Errors meant for the agent are raised as MemoriaError with a message that says what to do next.
"""
from __future__ import annotations

import json
import os
import re
import socket
import struct
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent
DEFAULT_CAPTURES_DIR = REPO_DIR / "captures"
PACK_PATH = REPO_DIR / "tools" / "claude-pack" / ".build" / "release" / "memoria-pack"
PACK_BUILD_COMMAND = "cd %s && swift build -c release" % (REPO_DIR / "tools" / "claude-pack")
PACK_TIMEOUT = 300.0
DEFAULT_RECEIVER_PORT = 8765
SIPS_PATH = "/usr/bin/sips"

SESSION_ID_RE = re.compile(r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
IMAGE_SUFFIXES = (".jpg", ".jpeg", ".png")
GUIDANCES = ("heading", "baseCylinder", "free")  # session.json "guidance" (added later; "free" added later still)
CUSTOM_SHEET_ID = "custom"  # declaredSize.sheet typed in by the person ("その他")
WORK_KINDS = ("object", "flat")  # session.json "workKind": missing or null means "object" (sessions from before it)
LABEL_MAX = 64


class MemoriaError(Exception):
    """A problem the calling agent can act on (unknown session, missing pack, ...)."""


# ---------------------------------------------------------------------------
# Small helpers


def captures_dir() -> Path:
    """MEMORIA_CAPTURES_DIR, or the repository's captures/ (from this file's location, not the cwd)."""
    env = os.environ.get("MEMORIA_CAPTURES_DIR")
    return Path(env).expanduser().resolve() if env else DEFAULT_CAPTURES_DIR


def read_json(path: Path):
    try:
        with open(path, "rb") as f:
            return json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        return None


def parse_time(text) -> "datetime | None":
    """ISO 8601 with a time zone ("Z" allowed). A time without a zone is taken as UTC."""
    if not isinstance(text, str) or not text.strip():
        return None
    s = text.strip()
    if s.endswith(("Z", "z")):
        s = s[:-1] + "+00:00"
    try:
        t = datetime.fromisoformat(s)
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def inside(path: Path, root: Path) -> bool:
    """True when `path` (after resolving symlinks) is `root` or below it."""
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def image_size(path: Path) -> "tuple[int, int] | None":
    """(width, height) from a JPEG or PNG header, without decoding the image."""
    try:
        with open(path, "rb") as f:
            head = f.read(26)
            if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
                return struct.unpack(">II", head[16:24])
            if head[:2] != b"\xff\xd8":
                return None
            f.seek(2)
            while True:
                marker = f.read(2)
                if len(marker) < 2 or marker[0] != 0xFF:
                    return None
                kind = marker[1]
                if kind in (0xD8, 0x01) or 0xD0 <= kind <= 0xD7:  # markers without a length
                    continue
                length_bytes = f.read(2)
                if len(length_bytes) < 2:
                    return None
                length = struct.unpack(">H", length_bytes)[0]
                # SOF0..SOF15 except DHT (C4), JPG (C8) and DAC (CC) carry the frame size.
                if 0xC0 <= kind <= 0xCF and kind not in (0xC4, 0xC8, 0xCC):
                    data = f.read(5)
                    if len(data) < 5:
                        return None
                    height, width = struct.unpack(">HH", data[1:5])
                    return width, height
                f.seek(length - 2, os.SEEK_CUR)
    except OSError:
        return None


# ---------------------------------------------------------------------------
# Sessions


def _complete_session_dirs(root: Path) -> "list[Path]":
    sessions = root / "sessions"
    if not sessions.is_dir():
        return []
    result = []
    for d in sessions.iterdir():
        if d.is_dir() and SESSION_ID_RE.fullmatch(d.name):
            receipt = read_json(d / "_receipt.json")
            if isinstance(receipt, dict) and receipt.get("complete") is True:
                result.append(d)
    return result


def _received_at(folder: Path) -> "str | None":
    receipt = read_json(folder / "_receipt.json")
    value = receipt.get("receivedAt") if isinstance(receipt, dict) else None
    return value if isinstance(value, str) else None


def _sort_key(folder: Path):
    t = parse_time(_received_at(folder))
    return (t.timestamp() if t else float("-inf"), folder.name)


def work_kind(session) -> str:
    """"object" (3D work: craft, clay) or "flat" (flat artwork: drawings, collages shot once from above)."""
    kind = session.get("workKind") if isinstance(session, dict) else None
    return kind if kind in WORK_KINDS else "object"


def guidance(session) -> "str | None":
    """How 3D work was guided during capture: "free" (shot freely, any number of photos, no guidance, no positions or masks),
    "heading" (crosshair + phone heading; position and size derived after capture) or "baseCylinder" (base point and cylinder
    set before shooting; also sessions without the field). None for flat artwork."""
    if work_kind(session) == "flat":
        return None
    g = session.get("guidance") if isinstance(session, dict) else None
    return g if g in GUIDANCES else "baseCylinder"


def declared_size(session) -> "dict | None":
    """The size the person picked or typed in on the iPhone (session.json "declaredSize", added later; not measured).

    {"sheet": {"id", "longSideM", "shortSideM"} | None, "heightM": float | None} with only well-formed parts kept,
    or None when nothing was entered. Flat artwork keeps only the sheet, 3D work only the height."""
    declared = session.get("declaredSize") if isinstance(session, dict) else None
    if not isinstance(declared, dict):
        return None
    flat = work_kind(session) == "flat"
    sheet = declared.get("sheet")
    if not (flat and isinstance(sheet, dict) and isinstance(sheet.get("id"), str)
            and _num(sheet.get("longSideM")) and _num(sheet.get("shortSideM"))):
        sheet = None
    else:
        sheet = {"id": sheet["id"], "longSideM": sheet["longSideM"], "shortSideM": sheet["shortSideM"]}
    height = _num(declared.get("heightM")) if not flat else None
    if sheet is None and height is None:
        return None
    return {"sheet": sheet, "heightM": height}


def session_summary(root: Path, folder: Path) -> dict:
    sid = folder.name
    session = read_json(folder / "session.json")
    session = session if isinstance(session, dict) else {}
    photos = session.get("photos") if isinstance(session.get("photos"), list) else []
    plan = session.get("directionPlan") if isinstance(session.get("directionPlan"), dict) else {}
    pack_dir = root / "for_claude" / sid
    has_pack = (pack_dir / "pack.json").is_file()
    return {
        "sessionId": sid,
        "title": session.get("title") or "",
        "workKind": work_kind(session),
        "guidance": guidance(session),
        "declaredSize": declared_size(session),
        "capturePlan": plan.get("id"),
        "photoCount": len(photos),
        "receivedAt": _received_at(folder),
        "hasPack": has_pack,
        "packDir": str(pack_dir) if has_pack else None,
        "briefPath": str(pack_dir / "brief.md") if (pack_dir / "brief.md").is_file() else None,
        "sessionDir": str(folder),
    }


def list_sessions(root: Path, limit: int = 20) -> dict:
    folders = sorted(_complete_session_dirs(root), key=_sort_key, reverse=True)
    limit = max(1, min(int(limit), 500))
    return {
        "capturesDir": str(root),
        "total": len(folders),
        "sessions": [session_summary(root, f) for f in folders[:limit]],
    }


def latest_session(root: Path, received_after: "str | None" = None) -> dict:
    folders = sorted(_complete_session_dirs(root), key=_sort_key, reverse=True)
    newest = session_summary(root, folders[0]) if folders else None
    threshold = None
    if received_after:
        threshold = parse_time(received_after)
        if threshold is None:
            raise MemoriaError("received_after must be an ISO 8601 time such as 2026-11-12T10:00:00+09:00, got %r"
                               % received_after)
    is_new = newest is not None and (
        threshold is None or (parse_time(newest["receivedAt"]) or datetime.min.replace(tzinfo=timezone.utc)) > threshold)
    result = {"checkedAt": now_iso(), "capturesDir": str(root)}
    if not is_new:
        result.update({
            "status": "nothing_new" if newest else "no_sessions",
            "session": None,
            "newestKnown": newest,
            "hint": "No session received after %s yet. Ask the user to finish shooting and press send on the iPhone, "
                    "then call latest_session again in 10-20 seconds (each call returns immediately)."
                    % (received_after or "-") if received_after else
                    "No completed session yet. Check receiver_status, then ask the user to send a session from the iPhone.",
        })
        return result
    result.update({"status": "found", "session": newest})
    if not newest["hasPack"]:
        result["hint"] = ("The pack (for_claude/) is built in the background a few seconds after receiving. "
                          "Call latest_session again shortly, or rebuild_pack if it never appears.")
    else:
        result["hint"] = "Call get_brief with this sessionId next."
    return result


def resolve_session(root: Path, session: str) -> Path:
    """A completed session folder from a full sessionId or a unique prefix (case-insensitive)."""
    prefix = (session or "").strip().upper()
    if not prefix:
        raise MemoriaError("session is empty. Pass a sessionId or its first characters (see list_sessions).")
    folders = _complete_session_dirs(root)
    exact = [d for d in folders if d.name == prefix]
    matches = exact or sorted((d for d in folders if d.name.startswith(prefix)), key=_sort_key, reverse=True)
    if len(matches) == 1:
        return matches[0]
    if not matches:
        known = ", ".join(d.name for d in sorted(folders, key=_sort_key, reverse=True)[:10]) or "(none)"
        raise MemoriaError("No completed session matches %r. Completed sessions (newest first): %s"
                           % (session, known))
    raise MemoriaError("%r matches %d sessions; use more characters: %s"
                       % (session, len(matches), ", ".join(d.name for d in matches)))


# ---------------------------------------------------------------------------
# Pack (for_claude/<id>/)


def _pack_dir(root: Path, folder: Path) -> Path:
    pack = root / "for_claude" / folder.name
    if not (pack / "pack.json").is_file() or not (pack / "brief.md").is_file():
        raise MemoriaError(
            "Session %s has no pack (for_claude/%s/) yet. If it was just received, wait a few seconds and retry; "
            "otherwise call rebuild_pack." % (folder.name, folder.name))
    return pack


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _direction(v: dict) -> dict:
    return {
        "azimuthDeg": _num(v.get("azimuthDeg")),
        "elevationDeg": _num(v.get("elevationDeg")),
        "distanceM": _num(v.get("distanceM")),
        "requestedAzimuthDeg": _num(v.get("requestedAzimuthDeg")),
        "requestedElevationDeg": _num(v.get("requestedElevationDeg")),
        "targetId": v.get("targetId"),
    }


def _view_entry(pack: Path, name: str, rel, kind: str, source: "dict | None") -> "dict | None":
    """One image file of the pack, only if it exists and stays inside the pack folder."""
    if not isinstance(rel, str) or not rel:
        return None
    path = pack / rel
    if not path.is_file() or not inside(path, pack) or path.suffix.lower() not in IMAGE_SUFFIXES:
        return None
    size = image_size(path)
    entry = {
        "name": name,
        "kind": kind,
        "path": str(path.resolve()),
        "width": size[0] if size else None,
        "height": size[1] if size else None,
    }
    if source is not None:
        entry.update({"label": source.get("label"), "direction": _direction(source),
                      "photoId": source.get("photoId"), "maskUse": source.get("maskUse"),
                      "notes": source.get("notes") if isinstance(source.get("notes"), list) else []})
    else:
        entry.update({"label": None, "direction": None, "photoId": None, "maskUse": None, "notes": []})
    return entry


def pack_views(pack: Path) -> "tuple[dict[str, dict], list[dict]]":
    """(available views by name, slots without a photo). Names come from pack.json and the folder, never hard-coded.

    Every view in pack.json with an existing `file` is available as its `name`; an existing `cutoutFile`
    (older packs: _cutout.jpg, --cutouts: _cutout.png) as `<name>_cutout`. Other images in views/ that
    pack.json does not mention are listed by file stem without direction info. "overview" is overview.jpg.
    """
    index = read_json(pack / "pack.json")
    raw_views = index.get("views") if isinstance(index, dict) and isinstance(index.get("views"), list) else []
    views: dict[str, dict] = {}
    missing = []
    seen_files = set()
    for v in raw_views:
        if not isinstance(v, dict) or not isinstance(v.get("name"), str):
            continue
        name = v["name"]
        main = _view_entry(pack, name, v.get("file"), "photo", v)
        if main:
            views[name] = main
            seen_files.add(Path(main["path"]).name)
        else:
            missing.append({"name": name, "label": v.get("label"),
                            "reason": v.get("missingReason") or "no image file in the pack",
                            "requestedAzimuthDeg": _num(v.get("requestedAzimuthDeg")),
                            "requestedElevationDeg": _num(v.get("requestedElevationDeg"))})
        cut = _view_entry(pack, name + "_cutout", v.get("cutoutFile"), "cutout", v)
        if cut:
            views[cut["name"]] = cut
            seen_files.add(Path(cut["path"]).name)
    views_dir = pack / "views"
    if views_dir.is_dir():
        for f in sorted(views_dir.iterdir()):
            if f.name in seen_files or f.stem in views or f.stem == "overview":
                continue
            extra = _view_entry(pack, f.stem, "views/" + f.name, "unlisted", None)
            if extra:
                views[f.stem] = extra
    return views, missing


def get_brief(root: Path, session: str) -> dict:
    folder = resolve_session(root, session)
    pack = _pack_dir(root, folder)
    index = read_json(pack / "pack.json")
    index = index if isinstance(index, dict) else {}
    views, missing = pack_views(pack)
    overview = _view_entry(pack, "overview", "overview.jpg", "overview", None)
    hull = pack / "hull.obj"
    provenance = index.get("provenance") if isinstance(index.get("provenance"), dict) else {}
    session = read_json(folder / "session.json")
    kind = index.get("workKind") if index.get("workKind") in WORK_KINDS else work_kind(session)
    result = {
        "sessionId": folder.name,
        "title": index.get("title") if isinstance(index.get("title"), str) else "",
        "workKind": kind,
        "guidance": index.get("guidance") if index.get("guidance") in GUIDANCES else guidance(session),
        "declaredSize": declared_size(session),
        "packDir": str(pack.resolve()),
        "briefPath": str((pack / "brief.md").resolve()),
        "brief": (pack / "brief.md").read_text(encoding="utf-8", errors="replace"),
        "measurementsPath": str((pack / "measurements.json").resolve()) if (pack / "measurements.json").is_file() else None,
        "measurements": read_json(pack / "measurements.json"),
        "hullObjPath": str(hull.resolve()) if hull.is_file() else None,
        "overview": overview,
        "views": list(views.values()),
        "missingViews": missing,
        "coverage": index.get("coverage"),
        "packGeneratedAt": provenance.get("generatedAt"),
        "sessionDir": str(folder),
        "next": "Look at the overview and views with get_view (view=<name> or 'overview'); originals are listed by "
                "get_original_photos; write results to the folder from output_dir.",
    }
    if result["guidance"] == "free":
        result["next"] = ("Free capture: the photos were shot freely without guidance (views photo-01, photo-02, ... in shooting "
                          "order, at most 16); which photo shows the front, a side, the back or the top is NOT recorded - decide "
                          "from the pictures. Only each photo's look-down angle is known (direction.elevationDeg); there is no "
                          "object position, no mask and no size from the photos (measurements.status 'unavailable', method "
                          "'freeCapture'). There is no overview. " + result["next"])
    if result["guidance"] == "heading":
        result["next"] = ("Heading-guided capture: no base point or size was set while shooting; the object centre and the "
                          "approximate size (measurements.sizeM, with lowerM/upperM bounds and confidence in "
                          "measurements.heading) were derived after capture. Read brief.md for how reliable they are. "
                          + result["next"])
    height = (result["declaredSize"] or {}).get("heightM")
    if kind != "flat" and height is not None:
        result["next"] = ("The person typed in the height: %.1f cm (declaredSize.heightM, measurements.declaredHeight; not "
                          "measured). Prefer it over the derived or measured height; choose width and depth so their ratio "
                          "to this height matches the photos (the other numbers were not rescaled). " % (height * 100)
                          + result["next"])
    if kind == "flat":
        result["flat"] = index.get("flat") if isinstance(index.get("flat"), dict) else None
        sheet = (result["declaredSize"] or {}).get("sheet")
        result["next"] = ("Flat artwork (a drawing or collage shot once from straight above): no 3D reconstruction is "
                          "needed. Look at the picture with get_view(view='artwork'); put it on a thin panel or frame of "
                          "the sheet size in measurements.sheet (source 'declared': the paper the person picked from the "
                          "app's list, preferred; 'measured': ARKit; null when unknown)"
                          + (("; the person typed in the paper size (custom, %.1f × %.1f cm)" if sheet["id"] == CUSTOM_SHEET_ID
                              else "; the person picked " + sheet["id"] + " (%.1f × %.1f cm)")
                             % (sheet["shortSideM"] * 100, sheet["longSideM"] * 100) if sheet else "")
                          + "; write results to the folder from output_dir.")
    return result


def resolve_view(root: Path, session: str, view: str) -> "tuple[Path, dict]":
    """The file of a view listed for this session (or overview.jpg). Never joins `view` into a path."""
    folder = resolve_session(root, session)
    pack = _pack_dir(root, folder)
    name = (view or "").strip()
    if name == "overview":
        entry = _view_entry(pack, "overview", "overview.jpg", "overview", None)
        if entry is None:
            raise MemoriaError("The pack of %s has no overview.jpg." % folder.name)
    else:
        views, missing = pack_views(pack)
        if name not in views:
            reason = next((m["reason"] for m in missing if m["name"] == name), None)
            raise MemoriaError("No view %r for session %s%s. Available: %s"
                               % (view, folder.name, " (%s)" % reason if reason else "",
                                  ", ".join(["overview"] + list(views))))
        entry = views[name]
    return Path(entry["path"]), dict(entry, sessionId=folder.name)


def load_image(path: Path, max_side: int, sips_path: str = SIPS_PATH) -> "tuple[bytes, str, dict]":
    """(bytes, format "jpeg"|"png", info). Downscales with macOS sips when the long side exceeds max_side.

    PNG stays PNG so transparent cutouts keep their alpha; everything else is returned as JPEG."""
    max_side = max(64, min(int(max_side), 4096))
    size = image_size(path)
    fmt = "png" if path.suffix.lower() == ".png" else "jpeg"
    info = {"originalWidth": size[0] if size else None, "originalHeight": size[1] if size else None,
            "width": size[0] if size else None, "height": size[1] if size else None,
            "format": fmt, "downscaled": False}
    if size is None or max(size) <= max_side:
        return path.read_bytes(), fmt, info
    if not os.path.exists(sips_path):
        info["note"] = "not downscaled: %s not found (macOS only)" % sips_path
        return path.read_bytes(), fmt, info
    with tempfile.TemporaryDirectory(prefix="memoria-mcp-") as tmp:
        out = Path(tmp) / ("view." + ("png" if fmt == "png" else "jpg"))
        cmd = [sips_path, "-Z", str(max_side), "-s", "format", fmt]
        if fmt == "jpeg":
            cmd += ["-s", "formatOptions", "85"]
        result = subprocess.run(cmd + [str(path), "--out", str(out)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60)
        if result.returncode != 0 or not out.is_file():
            raise MemoriaError("Could not downscale %s with sips: %s"
                               % (path, result.stderr.decode("utf-8", "replace").strip()[-300:]))
        data = out.read_bytes()
        new_size = image_size(out)
    info.update({"width": new_size[0] if new_size else None, "height": new_size[1] if new_size else None,
                 "downscaled": True})
    return data, fmt, info


# ---------------------------------------------------------------------------
# Originals (sessions/<id>/, read only)


def get_original_photos(root: Path, session: str) -> dict:
    folder = resolve_session(root, session)
    data = read_json(folder / "session.json")
    if not isinstance(data, dict):
        raise MemoriaError("session.json of %s could not be read." % folder.name)
    used_in_pack = {}
    index = read_json(root / "for_claude" / folder.name / "pack.json")
    if isinstance(index, dict) and isinstance(index.get("views"), list):
        for v in index["views"]:
            if isinstance(v, dict) and isinstance(v.get("photoId"), str):
                used_in_pack[v["photoId"]] = v.get("name")
    photos = []
    raw = [p for p in data.get("photos", []) if isinstance(p, dict)] if isinstance(data.get("photos"), list) else []
    for p in sorted(raw, key=lambda p: _num(p.get("sequence")) or 0):
        pid = p.get("photoId")
        if not isinstance(pid, str) or not SESSION_ID_RE.fullmatch(pid):
            continue
        image = p.get("image") if isinstance(p.get("image"), dict) else {}
        mask = p.get("mask") if isinstance(p.get("mask"), dict) else {}
        check = mask.get("check") if isinstance(mask.get("check"), dict) else {}
        camera = p.get("camera") if isinstance(p.get("camera"), dict) else None
        direction = p.get("direction") if isinstance(p.get("direction"), dict) else None

        def existing(rel):
            return rel if (folder / rel).is_file() else None

        photo_file = existing("photos/%s.jpg" % pid)
        flat = p.get("flat") if isinstance(p.get("flat"), dict) else None
        photos.append({
            "photoId": pid,
            "sequence": p.get("sequence"),
            "capturedAt": p.get("capturedAt"),
            "path": str(folder / photo_file) if photo_file else None,
            "mask": existing("masks/%s.png" % pid),
            "upright": existing("upright/photos/%s.jpg" % pid),
            "width": image.get("width"),
            "height": image.get("height"),
            "displayRotationDegClockwise": image.get("displayRotationDegClockwise"),
            "referenceFrameId": p.get("referenceFrameId"),
            "direction": {k: direction.get(k) for k in ("confirmed", "targetId", "azimuthDeg", "elevationDeg",
                                                        "distanceM")} if direction else None,
            "camera": {k: camera.get(k) for k in ("cameraToWorld", "intrinsics", "intrinsicsResolution",
                                                  "trackingState")} if camera else None,
            "maskStatus": mask.get("status"),
            "maskCheck": check.get("status"),
            "usedInPackAs": used_in_pack.get(pid),
            "flat": {"corners": flat.get("corners"), "sheetAtFrameEdge": flat.get("sheetAtFrameEdge"),
                     "size": flat.get("size"), "rectified": existing("rectified/%s.jpg" % pid)} if flat else None,
            "heading": p.get("heading") if isinstance(p.get("heading"), dict) else None,
        })
    frames = []
    for f in data.get("referenceFrames", []) if isinstance(data.get("referenceFrames"), list) else []:
        if isinstance(f, dict):
            frames.append({k: f.get(k) for k in ("id", "basePointWorld", "objectToWorld", "object", "base", "heading",
                                                  "invalidatedAt", "invalidationReason")})
    plan = data.get("directionPlan") if isinstance(data.get("directionPlan"), dict) else {}
    return {
        "sessionId": folder.name,
        "title": data.get("title") or "",
        "sessionDir": str(folder),
        "sessionJsonPath": str(folder / "session.json"),
        "workKind": work_kind(data),
        "guidance": guidance(data),
        "declaredSize": declared_size(data),
        "capturePlan": plan.get("id"),
        "photoCount": len(photos),
        "notes": [
            "Read only: never modify files under sessions/. path is absolute; mask and upright are relative to sessionDir.",
            "photos/ and masks/ are in sensor orientation (landscape); rotate clockwise by "
            "displayRotationDegClockwise to view upright. upright is a display-only rotated copy.",
            "camera.intrinsics (K, row-major, pixels) and camera.cameraToWorld (ARKit, row-major, camera +X right, "
            "+Y up, -Z forward) apply to the unrotated photos/ image. Poses are comparable only within one "
            "referenceFrameId; objectToWorld of that frame gives the object frame (+Y up, +Z towards the front camera).",
            "Flat artwork (workKind flat): no masks; flat.corners are the sheet's corners in the photo (pixels), "
            "flat.size the sheet measured on an ARKit plane (null when unknown), flat.rectified the perspective-corrected image.",
            "declaredSize is what the person picked or typed in on the iPhone (not measured; null when nothing was "
            "entered): sheet (flat artwork: the paper from the app's list, or id 'custom' for sizes typed in; "
            "id/longSideM/shortSideM, orientation not recorded) or heightM (3D work). It takes precedence over flat.size "
            "and over the size derived after capture.",
            "Free capture (guidance free): directionPlan 'free' with no targets, no referenceFrames, no masks; each "
            "photo's direction has only elevationDeg (the camera's look-down angle); which side a photo shows is not recorded.",
            "Heading-guided capture (guidance heading): referenceFrames[].heading.derivation holds the object centre "
            "derived after capture (closest point to the photos' centre lines, with residualRmsM), the approximate size "
            "and origin: 'base' (objectToWorld origin on the table) or 'center' (table height unknown, basePointWorld null, "
            "origin at the derived centre). photos[].heading keeps the heading/pitch measured while shooting.",
            "Full conventions: docs/data-format.md and captures/README.md.",
        ],
        "referenceFrames": frames,
        "photos": photos,
    }


# ---------------------------------------------------------------------------
# Writing: rebuild_pack (for_claude/ via memoria-pack) and output_dir (reconstructions/)


def pack_built(pack_path: "str | Path" = PACK_PATH) -> bool:
    return os.path.isfile(pack_path) and os.access(pack_path, os.X_OK)


def rebuild_pack(root: Path, session: str, cutouts: bool = False, pack_path: "str | Path" = PACK_PATH,
                 timeout: float = PACK_TIMEOUT) -> dict:
    """Runs memoria-pack like the receiver does (plus --force), which writes only for_claude/<id>/."""
    folder = resolve_session(root, session)
    if not pack_built(pack_path):
        raise MemoriaError("memoria-pack is not built (%s). Build it once with: %s" % (pack_path, PACK_BUILD_COMMAND))
    cmd = [str(pack_path), folder.name, "--data-dir", str(root), "--force"]
    if cutouts:
        cmd.append("--cutouts")
    try:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                timeout=timeout)
    except subprocess.TimeoutExpired:
        raise MemoriaError("memoria-pack did not finish within %d s for %s." % (timeout, folder.name))
    lines = [l for l in result.stdout.decode("utf-8", "replace").splitlines() if l.strip()]
    if result.returncode != 0:
        raise MemoriaError("memoria-pack failed for %s (exit %d): %s"
                           % (folder.name, result.returncode, " / ".join(lines[-5:])[-600:]))
    pack = root / "for_claude" / folder.name
    return {
        "sessionId": folder.name,
        "packDir": str(pack),
        "briefPath": str(pack / "brief.md") if (pack / "brief.md").is_file() else None,
        "cutouts": bool(cutouts),
        "summary": lines[-1] if lines else "",
        "next": "Call get_brief to read the rebuilt pack.",
    }


def sanitize_label(label: str) -> str:
    clean = re.sub(r"[^A-Za-z0-9._-]+", "-", (label or "").strip())
    clean = re.sub(r"\.{2,}", ".", clean).strip(".-")[:LABEL_MAX].strip(".-")
    if not clean:
        raise MemoriaError("label %r has no usable characters; use letters, digits, '.', '_' or '-' "
                           "(for example 'claude-v1')." % label)
    return clean


def output_dir(root: Path, session: str, label: str) -> dict:
    folder = resolve_session(root, session)
    clean = sanitize_label(label)
    base = root / "reconstructions"
    out = base / folder.name / clean
    if not inside(out, base):  # e.g. a symlinked session folder pointing elsewhere
        raise MemoriaError("Refusing to write outside %s." % base)
    existed = out.is_dir()
    out.mkdir(parents=True, exist_ok=True)
    return {
        "sessionId": folder.name,
        "label": clean,
        "path": str(out.resolve()),
        "existed": existed,
        "existingFiles": sorted(p.name for p in out.iterdir()) if existed else [],
        "putHere": [
            "the model: model.glb (preferred) or model.obj (+ .mtl and textures); metres, +Y up, y = 0 the table, "
            "+Z towards the front view, as in brief.md",
            "preview images of the model, e.g. preview_front.png, preview_top.png",
            "notes.md: method, which views/photos were used, dimensions compared with measurements.json, known gaps",
        ],
        "rules": "Write only inside this folder. Never write under sessions/ or for_claude/.",
    }


# ---------------------------------------------------------------------------
# Receiver status


def receiver_port() -> int:
    try:
        return int(os.environ.get("MEMORIA_RECEIVER_PORT", DEFAULT_RECEIVER_PORT))
    except ValueError:
        return DEFAULT_RECEIVER_PORT


def port_open(host: str, port: int, timeout: float = 0.5) -> bool:
    """TCP connect and close without sending anything (no credentials, no HTTP request)."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def receiver_status(root: Path, pack_path: "str | Path" = PACK_PATH, port: "int | None" = None) -> dict:
    port = receiver_port() if port is None else port
    listening = port_open("127.0.0.1", port)
    folders = _complete_session_dirs(root)
    newest = max(folders, key=_sort_key) if folders else None
    built = pack_built(pack_path)
    status = {
        "receiverListening": listening,
        "port": port,
        "capturesDir": str(root),
        "capturesDirExists": root.is_dir(),
        "sessionCount": len(folders),
        "newestSessionId": newest.name if newest else None,
        "newestReceivedAt": _received_at(newest) if newest else None,
        "memoriaPackBuilt": built,
        "memoriaPackPath": str(pack_path),
    }
    if not listening:
        status["hint"] = ("Nothing is listening on port %d. Ask the user to start the receiver: "
                          "python3 receiver/memoria_receiver.py (in the memoria-capture repository)." % port)
    if not built:
        status["buildCommand"] = PACK_BUILD_COMMAND
    return status

