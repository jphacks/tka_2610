# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "mcp>=2.3,<3",
# ]
# ///
"""Memoria Capture MCP server (stdio): lets Claude Code / Codex / the Claude desktop app read received capture
sessions and build GLB models from them with the prepared builders (tools/flat-art-glb, tools/solid-glb).

    uv run --script mcp-server/memoria_mcp.py

The logic lives in memoria_core.py and memoria_build.py (standard library only; the builders run as
subprocesses in tools/.venv and Node.js). stdout carries only MCP protocol messages; logs go to stderr.
See mcp-server/README.md.
"""
from __future__ import annotations

import json
import logging
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import memoria_build as build  # noqa: E402
import memoria_core as core  # noqa: E402

from mcp.server.mcpserver import Image, MCPServer  # noqa: E402
from mcp.server.mcpserver.exceptions import ToolError  # noqa: E402
from mcp_types import TextContent, ToolAnnotations  # noqa: E402

log = logging.getLogger("memoria-mcp")

INSTRUCTIONS = """\
Memoria Capture: photo sessions of a physical object (often a child's artwork) shot with the iPhone app and
received on this Mac, and prepared builders that turn them into GLB models on this Mac.

Generating a model (e.g. "make a 3D model of the latest capture"): you do NOT write geometry code. Prepared
builders make the shape; you only write a small JSON config and judge two pictures.
1. Find the session: latest_session (or list_sessions), then get_brief and read brief.md.
2. build_guide(session): which builder fits (flat-art-glb for flat artwork; solid-glb "slab" only for
   flat-topped objects; none for rounded or figurine-like objects), a starter config with the photo paths
   and known sizes filled in, the config reference, and the steps.
   If it says no builder fits - or the photos show a rounded/organic object - tell the user plainly that it
   cannot be built with the prepared builders, and stop. Do not improvise geometry code.
3. Look at the photos once (get_view). Use photo_grid (optionally zoomed with region) to read positions as
   fractions for corners, outlines or colour sample points. Replace every TODO in the starter config.
4. build_model(session, label, builder, config): builds model.glb under captures/reconstructions/<id>/<label>/
   and returns the numbers plus an overlay image - look at it once. Builder errors come back as tool errors
   with the builder's message: fix the config and call again.
5. check_model(session, label): validator summary (must be 0 errors) and compare.jpg (photo vs render) - look
   at it once. Revise the config at most about twice; do not chase small differences.
6. Tell the user the absolute path of model.glb, how it compares with the photos, and every assumed value
   (size, heights). Registering it in memoria is manual for now: upload the .glb in memoria's artwork form or
   edit screen. list_models shows earlier builds so a later conversation can continue.
If a builder tool says the runtime is missing, call tools_status and give the user the exact command it prints.
Other tools: receiver_status (is the iPhone receiver running), get_original_photos (full-resolution originals and
camera data), rebuild_pack, output_dir (a folder for other outputs, only when the user asks for another method).

workKind "flat" means flat artwork (a drawing or collage) shot once from above: no 3D reconstruction is needed;
the picture (view "artwork") goes on a thin sheet of the sheet size (measurements.sheet).
declaredSize is what the person picked or typed in on the iPhone (flat: the paper from a list; 3D: the height);
it is not measured and takes precedence over measured or derived sizes.
guidance "free" (the default for new 3D sessions) means the photos were shot freely without guidance (views photo-01...,
no direction recorded: judge front/side/back/top from the pictures; no size unless the person typed in a height).
guidance "heading" means the 3D capture was guided by the phone's heading (crosshair, no base point or cylinder):
the object position and its approximate size were derived after capture; the brief says how reliable they are.
Every result has absolute paths, so with file access you can also open files directly.
The photos are the user's private data; viewing them (get_view, photo_grid, and the overlay/compare images of
build_model/check_model) sends them to the model provider, so only do it when the user asked for this work.
Never modify anything under captures/sessions/ and never read captures/incoming/.
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


# ---------------------------------------------------------------------------
# Building models with the prepared builders (memoria_build.py)


def _text_and_image(meta: dict, image_path) -> list:
    """The JSON result, plus the image downscaled to a long side of at most 1568 px (JPEG) when there is one."""
    content: list = []
    if image_path is not None:
        try:
            data, fmt, info = core.load_image(Path(image_path), build.IMAGE_MAX_SIDE)
            meta = dict(meta, image={"path": str(image_path), **info})
            content.append(Image(data=data, format=fmt))
        except (OSError, core.MemoriaError) as e:
            meta = dict(meta, imageError=str(e))
    return [TextContent(type="text", text=as_json(meta))] + content


@mcp.tool(annotations=READ_ONLY, structured_output=False)
def build_guide(session: str) -> list[TextContent]:
    """Decide how to build a GLB for a session with the prepared builders, and get a starter config. Call this
    after get_brief and before build_model.

    Returns (1) JSON: builder ("flat-art-glb" for flat artwork, "solid-glb" for flat-topped objects, or null when
    neither fits), fit, decision (what to do; if no builder fits, tell the user so instead of writing geometry
    code), starterConfig (photo paths and known sizes filled in; values starting with "TODO" must be replaced -
    build_model refuses them), photoKeys (config keys that name photos), photos (the session's usable views:
    name, absolute path, pixel size, elevationDeg = look-down angle, azimuthDeg), assumptions (say these to the
    user), steps, outputRoot; and (2) the builder's config reference taken from its README (Japanese; positions are
    fractions of the photo, x right and y down, lengths in mm). Sizes in configs are millimetres; the built model
    is in metres, +Y up, front +Z.
    """
    data = run(build.build_guide, session)
    docs = data.pop("configDocs", None)
    blocks = [TextContent(type="text", text=as_json(data))]
    if docs:
        blocks.append(TextContent(type="text", text=docs))
    return blocks


@mcp.tool(annotations=READ_ONLY, structured_output=False)
def photo_grid(session: str, view: str, region: list[float] | None = None) -> list:
    """Return a photo of the session with a labelled coordinate grid, to read positions for a config.

    `view` is a view name from get_brief / build_guide (e.g. "artwork", "top", "photo-03") or the absolute path of
    an image of this session. Grid labels are fractions of the WHOLE photo (x to the right, y down, 0-1); write
    config positions (corners, outline points, sample points, feature centres) in these fractions.
    `region` = [x0, y0, x1, y1] (fractions) zooms into part of the photo; the labels stay whole-photo fractions.
    The image's long side is at most 1500 px. Viewing it sends the photo to the model provider.
    """
    try:
        data, fmt, meta = build.photo_grid(core.captures_dir(), session, view, region)
    except core.MemoriaError as e:
        raise ToolError(str(e)) from None
    return [TextContent(type="text", text=as_json(meta)), Image(data=data, format=fmt)]


@mcp.tool(annotations=WRITES, structured_output=False)
def build_model(session: str, label: str, builder: str, config: dict[str, Any]) -> list:
    """Build model.glb from a config with a prepared builder, on this Mac (about a second).

    builder: "flat-art-glb" or "solid-glb" (as recommended by build_guide). config: the builder's JSON config as an
    object (start from build_guide's starterConfig; no "TODO" values). Photo fields (flat-art-glb: photo;
    solid-glb: top.photo and views[].photo) must be a view name of this session or an absolute image path inside
    this session's pack or original photos - anything else is refused. label names the attempt (e.g. "v1";
    characters outside A-Z a-z 0-9 . _ - become "-"); the same label overwrites that attempt.
    Writes config.json, model.glb, report.json and the overlay into captures/reconstructions/<sessionId>/<label>/.
    Returns JSON (modelPath, sizeMm x/y/z, triangles, bytes, warnings, builder details, absolute paths) and the
    overlay image: flat-art-glb = the rectified photo with the sheet/pieces it found; solid-glb = the rectified top
    photo with the outline (green) and round features (red). Look at it once. On a builder error the tool fails
    with the builder's message: fix the config and call again.
    """
    try:
        result, overlay = build.build_model(core.captures_dir(), session, label, builder, config)
    except core.MemoriaError as e:
        raise ToolError(str(e)) from None
    return _text_and_image(result, overlay)


@mcp.tool(annotations=WRITES, structured_output=False)
def check_model(session: str, label: str) -> list:
    """Validate and render a model built with build_model, and return the comparison image (several seconds).

    Runs the Khronos glTF validator (validation: errors must be 0) and renders the model headlessly from the
    builder's views, then returns JSON (validation summary and messages, comparePath, renders, absolute paths) and
    compare.jpg downscaled to at most 1568 px: flat-art-glb = photo crop | front render | oblique render;
    solid-glb = one cell per config view, photo left and render right. Look at it once and compare shape, size
    proportions, colours and positions. If the renderer is not installed, returns rendererReady false with the
    command the user must run (the model itself is still usable).
    """
    try:
        result, compare = build.check_model(core.captures_dir(), session, label)
    except core.MemoriaError as e:
        raise ToolError(str(e)) from None
    return _text_and_image(result, compare)


@mcp.tool(annotations=READ_ONLY, structured_output=False)
def list_models(session: str) -> str:
    """List the models built for a session (newest first), so a later conversation can pick up.

    Per model: label, builder, absolute paths (folder, model.glb, config.json, compare.jpg, overlay), sizeMm (x =
    left-right, y = up, z = front-back), triangles, bytes, builtAt, warnings, validation (errors/warnings after
    check_model) and checkedAt. Read configPath to continue from an earlier config.
    """
    return as_json(run(build.list_models, session))


@mcp.tool(annotations=READ_ONLY, structured_output=False)
def tools_status() -> str:
    """Check whether the model builders can run on this Mac: the builders' Python environment (numpy, OpenCV,
    mapbox_earcut), Node.js, each builder's node_modules (three, gltf-validator, playwright) and Playwright's
    Chromium. ready.build / ready.photoGrid / ready.check say what works; when something is missing, `fix` is the
    exact command the user must run in a terminal (once).
    """
    return as_json(build.tools_status())


def main() -> None:
    logging.basicConfig(stream=sys.stderr, level=logging.INFO, format="%(name)s: %(message)s")
    log.info("captures: %s", core.captures_dir())
    mcp.run("stdio")


if __name__ == "__main__":
    main()
