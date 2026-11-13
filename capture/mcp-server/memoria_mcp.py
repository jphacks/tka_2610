# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "mcp>=2.3,<3",
# ]
# ///
"""Memoria Capture MCP server (stdio): lets Claude Code / Codex read received capture sessions.

    uv run --script mcp-server/memoria_mcp.py

The logic lives in memoria_core.py (standard library only). stdout carries only MCP protocol messages;
logs go to stderr. See mcp-server/README.md.
"""
from __future__ import annotations

import json
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import memoria_core as core  # noqa: E402

from mcp.server.mcpserver import Image, MCPServer  # noqa: E402
from mcp.server.mcpserver.exceptions import ToolError  # noqa: E402
from mcp_types import TextContent, ToolAnnotations  # noqa: E402

log = logging.getLogger("memoria-mcp")

INSTRUCTIONS = """\
Memoria Capture: photo sessions of a physical object (often a child's artwork) shot with the iPhone app and
received on this Mac. Flow: receiver_status -> list_sessions or latest_session -> get_brief (read the brief
first) -> get_view for the overview and views -> build a 3D model -> save it under the folder from output_dir.
workKind "flat" means flat artwork (a drawing or collage) shot once from above: no 3D reconstruction is needed;
use the picture (view "artwork") on a thin panel or frame of the sheet size (measurements.sheet).
declaredSize is what the person picked or typed in on the iPhone (flat: the paper from a list; 3D: the height);
it is not measured and takes precedence over measured or derived sizes.
guidance "free" (the default for new 3D sessions) means the photos were shot freely without guidance (views photo-01...,
no direction recorded: judge front/side/back/top from the pictures; no size unless the person typed in a height).
guidance "heading" means the 3D capture was guided by the phone's heading (crosshair, no base point or cylinder):
the object position and its approximate size were derived after capture; the brief says how reliable they are.
Every result has absolute paths, so with file access you can also open files directly.
The photos are the user's private data; viewing them sends them to the model provider, so only do it when the
user asked for this work. Never modify anything under captures/sessions/ and never read captures/incoming/.
"""

READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
WRITES = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=False)

mcp = MCPServer("memoria-capture", instructions=INSTRUCTIONS)


def as_json(obj) -> str:
    return json.dumps(obj, ensure_ascii=False)


def run(fn, *args, **kwargs):
    try:
        return fn(core.captures_dir(), *args, **kwargs)
    except core.MemoriaError as e:
        raise ToolError(str(e)) from None


@mcp.tool(annotations=READ_ONLY, structured_output=False)
def list_sessions(limit: int = 20) -> str:
    """List received capture sessions, newest first.

    Each entry: sessionId, title, workKind ("object" = 3D work, "flat" = flat artwork shot once from above),
    guidance (3D work: "free" = shot freely without guidance, any number of photos, no direction recorded;
    "heading" = guided by the phone's heading, position and size derived after capture;
    "baseCylinder" = base point and cylinder set before shooting; null for flat artwork),
    declaredSize (what the person picked or typed in, not measured: {"sheet": {id, longSideM, shortSideM} for
    flat artwork, "heightM" for 3D work}, or null when nothing was entered), capturePlan (e.g. "ai5" = 5 photos front/right/back/left/top, "flat1" = 1 photo from above), photoCount,
    receivedAt, hasPack (whether the AI-ready pack for_claude/<id>/ exists), packDir, briefPath, sessionDir
    (absolute paths). Use a sessionId (or a unique prefix of it) with the other tools.
    """
    return as_json(run(core.list_sessions, limit))


@mcp.tool(annotations=READ_ONLY, structured_output=False)
def latest_session(received_after: str | None = None) -> str:
    """Return the newest received session, or status "nothing_new" if none arrived after `received_after`.

    Use this to wait for a new capture: note the current time (ISO 8601 with time zone, e.g.
    2026-11-12T10:00:00+09:00), ask the user to shoot and send from the iPhone, then call this every 10-20
    seconds with received_after set to that time. Each call returns immediately. A found session may still
    have hasPack=false for a few seconds while the pack is being built.
    """
    return as_json(run(core.latest_session, received_after))


@mcp.tool(annotations=READ_ONLY, structured_output=False)
def get_brief(session: str) -> list[TextContent]:
    """Read the AI-ready pack of a session: brief.md (read it fully first), measurements, and available views.

    `session` is a full sessionId or a unique prefix (case-insensitive). The second block is JSON with
    workKind ("flat": flat artwork, views "artwork" (rectified picture) and "photo", measurements.sheet = sheet
    size with source "declared" (picked from a list, preferred) or "measured", or null; no overview), guidance,
    declaredSize (picked/typed in on the iPhone; a typed-in height, also in measurements.declaredHeight, takes
    precedence over the derived or measured height), measurements (real size in metres/cm with uncertainty, a rough user-set
    cylinder for 5-photo "baseCylinder" sessions, or for "heading" sessions an approximate size derived after
    capture with lower/upper bounds and a confidence in measurements.heading; "free" sessions have no size from the
    photos, method "freeCapture"),
    views (name — for "free" sessions photo-01, photo-02, ... in shooting order with only the elevation known — kind photo/cutout, direction azimuth/elevation in degrees: 0 = front, 90 = right, 180 = back,
    270 = left; pixel size; absolute path), missingViews, overview, and hullObjPath (coarse shape, older packs
    only). Pass a view name, or "overview", to get_view.
    """
    data = run(core.get_brief, session)
    brief = data.pop("brief")
    return [TextContent(type="text", text=brief), TextContent(type="text", text=as_json(data))]


@mcp.tool(annotations=READ_ONLY, structured_output=False)
def get_view(session: str, view: str, max_side: int = 1568) -> list:
    """Return one photo of a session's pack as an image, plus its absolute path and direction.

    `view` must be a name listed by get_brief (e.g. "front", "top", "front_cutout") or "overview" (the
    contact sheet of all chosen photos, arranged as seen from above with the front at the bottom). Images
    larger than max_side pixels on the long side are downscaled (JPEG stays JPEG; transparent PNG cutouts
    stay PNG). Only open photos when the user asked for this work: they are the user's private data.
    """
    try:
        root = core.captures_dir()
        path, entry = core.resolve_view(root, session, view)
        data, fmt, info = core.load_image(path, max_side)
    except core.MemoriaError as e:
        raise ToolError(str(e)) from None
    meta = {"sessionId": entry["sessionId"], "view": entry["name"], "kind": entry["kind"], "path": entry["path"], "label": entry["label"],
            "direction": entry["direction"], "photoId": entry["photoId"], "notes": entry["notes"], **info}
    return [TextContent(type="text", text=as_json(meta)), Image(data=data, format=fmt)]


@mcp.tool(annotations=READ_ONLY, structured_output=False)
def get_original_photos(session: str) -> str:
    """List the full-resolution original photos of a session (paths and metadata, no image bytes).

    Per photo: absolute path (sensor orientation, usually 4032x3024; rotate clockwise by
    displayRotationDegClockwise to view upright), mask/upright paths relative to sessionDir, direction
    (azimuth/elevation/distance from the object), camera (ARKit cameraToWorld and intrinsics K for the
    unrotated image), mask status, and usedInPackAs (the pack view built from it). Also the reference
    frames (objectToWorld). These files are read only.
    """
    return as_json(run(core.get_original_photos, session))


@mcp.tool(annotations=WRITES, structured_output=False)
def rebuild_pack(session: str, cutouts: bool = False) -> str:
    """Rebuild the AI-ready pack (captures/for_claude/<id>/) with memoria-pack, as the receiver does.

    Use when a session has no pack or the pack looks stale. cutouts=true also writes
    views/<name>_cutout.png (background made transparent with the iPhone mask). Writes only for_claude/<id>/.
    Usually takes a few seconds. Fails with the build command if memoria-pack is not built.
    """
    return as_json(run(core.rebuild_pack, session, cutouts))


@mcp.tool(annotations=WRITES, structured_output=False)
def output_dir(session: str, label: str) -> str:
    """Create (if needed) and return captures/reconstructions/<sessionId>/<label>/ for your outputs.

    Put the generated model (model.glb preferred, or .obj), preview renders and notes.md there. `label`
    names this attempt (e.g. "claude-v1"); characters outside A-Z a-z 0-9 . _ - become "-". Write nothing
    outside this folder.
    """
    return as_json(run(core.output_dir, session, label))


@mcp.tool(annotations=READ_ONLY, structured_output=False)
def receiver_status() -> str:
    """Check the capture receiver: whether it is listening on its port (a bare TCP check, no credentials),
    the captures folder, session count and newest session, and whether memoria-pack is built.
    """
    return as_json(run(core.receiver_status))


def main() -> None:
    logging.basicConfig(stream=sys.stderr, level=logging.INFO, format="%(name)s: %(message)s")
    log.info("captures: %s", core.captures_dir())
    mcp.run("stdio")


if __name__ == "__main__":
    main()
