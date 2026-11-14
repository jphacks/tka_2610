"""Model building for the Memoria Capture MCP server (standard library only).

The shapes are built by the prepared tools, not by the agent: tools/flat-art-glb (flat artwork from one photo) and
tools/solid-glb (flat-topped solids, template "slab"). The agent only writes their JSON config and judges one
overlay image and one comparison image. This module

    - recommends a builder for a session and fills a starter config (build_guide),
    - draws a coordinate grid on a photo of the session (photo_grid, through `solidglb.py grid`),
    - writes the config into captures/reconstructions/<sessionId>/<label>/ and runs the builder (build_model),
    - validates and renders the result (check_model) and lists what was built (list_models).

The builders run as subprocesses in their own Python environment (tools/.venv; numpy, OpenCV, mapbox_earcut) and
with Node.js (three, gltf-validator, Playwright's Chromium) for checking; scripts/install-mcp.sh prepares both.
A config may only point at images of the same session (its pack or its original photos); every other path is
refused. Nothing is written outside reconstructions/<sessionId>/<label>/ (photo_grid uses a temporary folder).
"""
from __future__ import annotations

import copy
import json
import os
import re
import shutil
import struct
import subprocess
import tempfile
import time
from pathlib import Path

import memoria_core as core
from memoria_core import MemoriaError

TOOLS_DIR = core.REPO_DIR / "tools"
INSTALL_SCRIPT = core.REPO_DIR / "scripts" / "install-mcp.sh"
FIX_COMMAND = "%s --tools-only" % INSTALL_SCRIPT
DEFAULT_TOOLS_PYTHON = TOOLS_DIR / ".venv" / "bin" / "python"
VALIDATOR = TOOLS_DIR / "flat-art-glb" / "render" / "validate.mjs"  # generic GLB validator (any builder's model)

BUILDERS = {
    "flat-art-glb": {
        "dir": TOOLS_DIR / "flat-art-glb",
        "script": "flatart_glb.py",
        "overlay": "overlay.jpg",
        "overlay_meaning": "the rectified photo with the sheet as the tool understood it; in layers mode each paper "
                           "piece's outline with its name and layer (L1, L2, ...); magenta = outside the photo (filled in)",
        "compare_meaning": "left: the photo cropped around the sheet; middle: render from the front; right: oblique render",
        "readme_sections": ("モード", "設定（JSON）"),
        "examples": ("examples/plane.example.json", "examples/collage.example.json"),
        "outputs": ("model.glb", "report.json", "overlay.jpg"),
    },
    "solid-glb": {
        "dir": TOOLS_DIR / "solid-glb",
        "script": "solidglb.py",
        "overlay": "top_overlay.jpg",
        "overlay_meaning": "the rectified top photo; green line = the outline (outline + outline_round_mm), "
                           "red circles = round features after snapping",
        "compare_meaning": "one cell per entry of config.views, in order; in each cell the photo is on the left and "
                           "the render on the right (a view without a photo is render only)",
        "readme_sections": ("作れる形", "設定ファイル（`slab`）"),
        "examples": (),
        "outputs": ("model.glb", "report.json", "top_rectified.jpg", "top_overlay.jpg"),
    },
}
CHECK_OUTPUTS = ("compare.jpg", "validation.json", "check.json", "views.json", "front.png", "oblique.png")
OWN_FILES = ("config.json", "build.json")

BUILD_TIMEOUT = 150.0
CHECK_TIMEOUT = 240.0
GRID_TIMEOUT = 60.0
PROBE_TIMEOUT = 60.0
IMAGE_MAX_SIDE = 1568
GRID_MAX_SIDE = 1500
TOP_MIN_ELEVATION = 60.0      # a photo looking down at least this steeply counts as a photo "from above"
CONFIG_MAX_BYTES = 256 * 1024
VIEW_NAME_RE = re.compile(r"[A-Za-z0-9_-]{1,40}")
TODO_PREFIX = "TODO"
FLAT_FULL_FRAME = [[0, 0], [1, 0], [1, 1], [0, 1]]
FLAT_PAPER_SAMPLES = [[0.03, 0.03], [0.97, 0.03], [0.97, 0.97], [0.03, 0.97]]


# ---------------------------------------------------------------------------
# Runtime (tools/.venv, node, node_modules, Playwright's Chromium)


def tools_python() -> Path:
    env = os.environ.get("MEMORIA_TOOLS_PYTHON")
    return Path(env).expanduser() if env else DEFAULT_TOOLS_PYTHON


def _executable(path: Path) -> bool:
    return path.is_file() and os.access(path, os.X_OK)


def _run(cmd, cwd: Path, timeout: float, what: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONUNBUFFERED="1")
    try:
        return subprocess.run([str(c) for c in cmd], cwd=str(cwd), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=timeout, env=env, text=True, errors="replace")
    except FileNotFoundError as e:
        raise MemoriaError("%s: %s not found. Ask the user to run once: %s" % (what, e.filename, FIX_COMMAND))
    except subprocess.TimeoutExpired:
        raise MemoriaError("%s did not finish within %d s." % (what, timeout))


def _tail(text: str, lines: int = 14, chars: int = 1800) -> str:
    kept = [l for l in (text or "").splitlines() if l.strip()][-lines:]
    return "\n".join(kept)[-chars:]


def _require_python() -> Path:
    py = tools_python()
    if not _executable(py):
        raise MemoriaError("The builders' Python environment is missing (%s). Ask the user to run once in a "
                           "terminal: %s" % (py, FIX_COMMAND))
    return py


def _node_path() -> "str | None":
    return shutil.which("node")


def _probe_python(py: Path) -> dict:
    info = {"path": str(py), "exists": _executable(py), "ok": False}
    if not info["exists"]:
        return info
    code = ("import json, sys, importlib.metadata as m, numpy, cv2, mapbox_earcut; "
            "print(json.dumps({'python': sys.version.split()[0], 'numpy': numpy.__version__, "
            "'opencv': cv2.__version__, 'mapbox_earcut': m.version('mapbox_earcut')}))")
    try:
        p = _run([py, "-c", code], TOOLS_DIR, PROBE_TIMEOUT, "Python check")
    except MemoriaError as e:
        info["error"] = str(e)
        return info
    if p.returncode == 0:
        try:
            info.update(json.loads(p.stdout.strip().splitlines()[-1]), ok=True)
        except (ValueError, IndexError):
            info["error"] = _tail(p.stdout + p.stderr, 3)
    else:
        info["error"] = _tail(p.stderr, 3)
    return info


def renderer_status(builder: str, probe: bool = True) -> dict:
    """What check_model needs for one builder: node, its node_modules (three, gltf-validator, playwright), the
    validator script's gltf-validator (flat-art-glb's node_modules) and Playwright's Chromium."""
    tool = BUILDERS[builder]["dir"]
    nm = tool / "node_modules"
    node = _node_path()
    st = {
        "node": node,
        "three": (nm / "three").is_dir(),
        "gltfValidator": (nm / "gltf-validator").is_dir(),
        "playwright": (nm / "playwright").is_dir(),
        "validatorScriptReady": bool(node) and (TOOLS_DIR / "flat-art-glb" / "node_modules" / "gltf-validator").is_dir(),
        "chromium": None,
    }
    if probe and node and st["playwright"]:
        try:
            p = _run([node, "-e", "process.stdout.write(require('playwright').chromium.executablePath())"],
                     tool, PROBE_TIMEOUT, "Playwright check")
            exe = p.stdout.strip() if p.returncode == 0 else ""
            st["chromium"] = exe if exe and os.path.exists(exe) else None
            if exe and not st["chromium"]:
                st["chromiumMissing"] = exe
        except MemoriaError as e:
            st["chromiumError"] = str(e)
    st["renderReady"] = bool(node and st["three"] and st["gltfValidator"] and st["playwright"]
                             and (st["chromium"] or not probe))
    return st


def tools_status() -> dict:
    """Whether the builders (Python) and the checker (Node, Playwright, Chromium) are ready, and how to fix them."""
    py = _probe_python(tools_python())
    node = _node_path()
    node_version = None
    if node:
        try:
            p = _run([node, "--version"], TOOLS_DIR, PROBE_TIMEOUT, "node --version")
            node_version = p.stdout.strip() or None
        except MemoriaError:
            pass
    builders = {name: renderer_status(name) for name in BUILDERS}
    ready = {
        "build": py["ok"],
        "photoGrid": py["ok"],
        "check": {name: py["ok"] and st["renderReady"] and st["validatorScriptReady"] for name, st in builders.items()},
    }
    status = {"python": py, "node": {"path": node, "version": node_version}, "renderer": builders,
              "ready": ready, "installScript": str(INSTALL_SCRIPT)}
    problems = []
    if not py["exists"]:
        problems.append("the builders' Python environment %s does not exist" % py["path"])
    elif not py["ok"]:
        problems.append("the builders' Python environment cannot import numpy / cv2 / mapbox_earcut")
    if not node:
        problems.append("node is not on PATH (needed by check_model; install Node.js, e.g. brew install node)")
    for name, st in builders.items():
        if node and not (st["three"] and st["gltfValidator"] and st["playwright"]):
            problems.append("%s: node_modules incomplete (npm ci)" % name)
        elif node and not st["chromium"]:
            problems.append("%s: Playwright's Chromium is not installed" % name)
    if problems:
        status["problems"] = problems
        status["fix"] = ("Ask the user to run once in a terminal: %s   (takes effect immediately; the app does not "
                         "need a restart)" % FIX_COMMAND)
    return status


# ---------------------------------------------------------------------------
# Paths: only images of this session may be used by a config


def _under(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _session_views(root: Path, folder: Path) -> dict:
    pack = root / "for_claude" / folder.name
    if not (pack / "pack.json").is_file():
        return {}
    views, _ = core.pack_views(pack)
    return views


def resolve_photo(root: Path, folder: Path, value, field: str, views: "dict | None" = None) -> Path:
    """An image of this session: a view name of its pack, or an absolute path inside its pack folder or inside its
    original photos (sessions/<id>/photos|upright|rectified). Anything else (relative paths, '..', other sessions,
    other files, symlinks leading elsewhere) is refused."""
    views = _session_views(root, folder) if views is None else views
    names = ", ".join(views) or "(no pack)"
    if not isinstance(value, str) or not value.strip():
        raise MemoriaError("%s must be a view name from get_brief (%s) or an absolute path of an image of session %s."
                           % (field, names, folder.name))
    value = value.strip()
    if value in views:
        return Path(views[value]["path"])
    if "\x00" in value:
        raise MemoriaError("%s contains a NUL character." % field)
    p = Path(value)
    if not p.is_absolute():
        raise MemoriaError("%s: %r is neither a view of session %s (%s) nor an absolute path; relative paths are not "
                           "accepted." % (field, value, folder.name, names))
    try:
        real = p.resolve(strict=True)
    except (OSError, RuntimeError):
        raise MemoriaError("%s: %s does not exist." % (field, value))
    allowed = [(root / "for_claude" / folder.name).resolve()]
    allowed += [(folder / sub).resolve() for sub in ("photos", "upright", "rectified")]
    if not (any(_under(real, a) for a in allowed) and real.is_file() and real.suffix.lower() in core.IMAGE_SUFFIXES):
        raise MemoriaError("%s: %s is not an image of session %s. Use a view name (%s) or an absolute path from "
                           "get_brief / get_original_photos (the pack's views, or the session's photos/, upright/, "
                           "rectified/)." % (field, value, folder.name, names))
    return real


def _find_todo(obj, pointer: str = "") -> "list[str]":
    if isinstance(obj, str):
        return [pointer or "/"] if obj.strip().upper().startswith(TODO_PREFIX) else []
    if isinstance(obj, dict):
        return [p for k, v in obj.items() for p in _find_todo(v, "%s/%s" % (pointer, k))]
    if isinstance(obj, list):
        return [p for i, v in enumerate(obj) for p in _find_todo(v, "%s/%d" % (pointer, i))]
    return []


def prepare_config(root: Path, folder: Path, builder: str, config) -> dict:
    """A copy of the config with every photo reference replaced by the resolved absolute path (or MemoriaError)."""
    if isinstance(config, str):
        try:
            config = json.loads(config)
        except ValueError as e:
            raise MemoriaError("config is not valid JSON: %s" % e)
    if not isinstance(config, dict):
        raise MemoriaError("config must be a JSON object (the builder's config, see build_guide).")
    if len(json.dumps(config)) > CONFIG_MAX_BYTES:
        raise MemoriaError("config is larger than %d KB." % (CONFIG_MAX_BYTES // 1024))
    todo = _find_todo(config)
    if todo:
        raise MemoriaError("config still has TODO placeholders at %s. Replace each with a real value (read positions "
                           "with photo_grid) before building." % ", ".join(todo))
    cfg = copy.deepcopy(config)
    views = _session_views(root, folder)
    if builder == "flat-art-glb":
        cfg["photo"] = str(resolve_photo(root, folder, cfg.get("photo"), "photo", views))
    else:
        if cfg.get("template") != "slab":
            raise MemoriaError("solid-glb config: template must be \"slab\" (the only template), got %r."
                               % cfg.get("template"))
        top = cfg.get("top")
        if not isinstance(top, dict):
            raise MemoriaError("solid-glb config: \"top\" must be an object with photo, corners and width_mm.")
        top["photo"] = str(resolve_photo(root, folder, top.get("photo"), "top.photo", views))
        vlist = cfg.get("views", [])
        if not isinstance(vlist, list):
            raise MemoriaError("solid-glb config: \"views\" must be a list.")
        seen = set()
        for i, v in enumerate(vlist):
            if not isinstance(v, dict):
                raise MemoriaError("solid-glb config: views[%d] must be an object." % i)
            name = v.get("name")
            if not isinstance(name, str) or not VIEW_NAME_RE.fullmatch(name) or name in seen:
                raise MemoriaError("solid-glb config: views[%d].name must be unique and use only A-Z a-z 0-9 _ - "
                                   "(1-40 characters), got %r." % (i, name))
            seen.add(name)
            if "photo" in v and v["photo"] is not None:
                v["photo"] = str(resolve_photo(root, folder, v["photo"], "views[%d].photo" % i, views))
    return cfg


# ---------------------------------------------------------------------------
# GLB facts (bounds, triangles) without third-party code


def glb_summary(path: Path) -> "dict | None":
    """{bytes, meshes, triangles, boundsM: {min, max, size} | None} from the GLB's JSON chunk (accessor min/max).
    Node transforms other than translation/scale make the bounds unknown (None)."""
    try:
        with open(path, "rb") as f:
            head = f.read(20)
            if len(head) < 20 or head[:4] != b"glTF":
                return None
            length, kind = struct.unpack("<I4s", head[12:20])
            if kind != b"JSON":
                return None
            gltf = json.loads(f.read(length).decode("utf-8"))
    except (OSError, ValueError, struct.error):
        return None
    acc = gltf.get("accessors", [])
    meshes = gltf.get("meshes", [])
    nodes = gltf.get("nodes", [])
    tris = 0
    for m in meshes:
        for p in m.get("primitives", []):
            if p.get("mode", 4) == 4:
                if "indices" in p:
                    tris += acc[p["indices"]].get("count", 0) // 3
                elif "POSITION" in p.get("attributes", {}):
                    tris += acc[p["attributes"]["POSITION"]].get("count", 0) // 3
    lo, hi, known = [float("inf")] * 3, [float("-inf")] * 3, True

    def visit(i, offset, scale, depth=0):
        nonlocal known
        if depth > 64 or i >= len(nodes):
            return
        n = nodes[i]
        if "matrix" in n or "rotation" in n:
            known = False
            return
        t = n.get("translation", [0, 0, 0])
        s = n.get("scale", [1, 1, 1])
        off = [offset[k] + scale[k] * t[k] for k in range(3)]
        sc = [scale[k] * s[k] for k in range(3)]
        if "mesh" in n and n["mesh"] < len(meshes):
            for p in meshes[n["mesh"]].get("primitives", []):
                a = acc[p["attributes"]["POSITION"]] if "POSITION" in p.get("attributes", {}) else None
                if not a or "min" not in a or "max" not in a:
                    known = False
                    continue
                for k in range(3):
                    v1, v2 = off[k] + sc[k] * a["min"][k], off[k] + sc[k] * a["max"][k]
                    lo[k], hi[k] = min(lo[k], v1, v2), max(hi[k], v1, v2)
        for c in n.get("children", []):
            visit(c, off, sc, depth + 1)

    scenes = gltf.get("scenes", [])
    roots = scenes[gltf.get("scene", 0)].get("nodes", []) if scenes else list(range(len(nodes)))
    for r in roots:
        visit(r, [0, 0, 0], [1, 1, 1])
    bounds = None
    if known and lo[0] != float("inf"):
        bounds = {"min": [round(v, 5) for v in lo], "max": [round(v, 5) for v in hi],
                  "size": [round(hi[k] - lo[k], 5) for k in range(3)]}
    return {"bytes": path.stat().st_size, "meshes": len(meshes), "triangles": tris, "boundsM": bounds}


def _size_mm(summary: "dict | None") -> "dict | None":
    b = (summary or {}).get("boundsM")
    if not b:
        return None
    x, y, z = (round(v * 1000, 1) for v in b["size"])
    return {"x": x, "y": y, "z": z, "axes": "x = left-right, y = up, z = front-back (model front is +Z)"}


# ---------------------------------------------------------------------------
# build_guide


def _readme_section(readme: Path, title: str) -> str:
    """The '## <title>' section of a README (up to the next '## ' heading), or '' when it is missing."""
    try:
        lines = readme.read_text(encoding="utf-8").splitlines()
    except OSError:
        return ""
    out, inside = [], False
    for line in lines:
        if line.startswith("## "):
            if inside:
                break
            inside = line[3:].strip() == title
        if inside:
            out.append(line)
    return "\n".join(out).strip()


def builder_docs(builder: str) -> str:
    """The config reference straight from the builder's own README (and example files), so it cannot drift."""
    b = BUILDERS[builder]
    readme = b["dir"] / "README.md"
    parts = ["# %s config reference (from %s)" % (builder, readme)]
    for title in b["readme_sections"]:
        text = _readme_section(readme, title)
        parts.append(text or "(section '%s' not found in %s)" % (title, readme))
    for rel in b["examples"]:
        p = b["dir"] / rel
        try:
            example = json.dumps(json.loads(p.read_text(encoding="utf-8")), ensure_ascii=False)
        except (OSError, ValueError):
            continue
        parts.append("Example %s: %s" % (rel, example))
    return "\n\n".join(parts)


def _photo_entry(v: dict) -> dict:
    d = v.get("direction") or {}
    return {"view": v["name"], "path": v["path"], "width": v["width"], "height": v["height"],
            "elevationDeg": d.get("elevationDeg"), "azimuthDeg": d.get("azimuthDeg"), "label": v.get("label")}


def _top_view(photos: "list[dict]") -> "dict | None":
    named = [p for p in photos if p["view"] == "top" and (p["elevationDeg"] is None
                                                            or p["elevationDeg"] >= TOP_MIN_ELEVATION)]
    if named:
        return named[0]
    steep = [p for p in photos if isinstance(p["elevationDeg"], (int, float)) and p["elevationDeg"] >= TOP_MIN_ELEVATION]
    return max(steep, key=lambda p: p["elevationDeg"]) if steep else None


def _round1(v):
    return round(float(v), 1)


STEPS_COMMON_END = [
    "check_model(session, label): the validator must report 0 errors; look at compare.jpg once.",
    "If something is clearly off, fix the config and build again (a new label such as v2 keeps the earlier try; "
    "the same label overwrites it). Revise at most about twice; do not chase small differences.",
    "Tell the user where model.glb is (absolute path), how it compares with the photos, and every assumed value "
    "(size, heights, colours). Registering it in memoria is manual: upload the .glb in memoria's artwork form or "
    "edit screen.",
]


def _flat_guide(base: dict, brief: dict, photos: "list[dict]") -> dict:
    by_name = {p["view"]: p for p in photos}
    artwork = by_name.get("artwork")
    if artwork is None:
        base.update(builder=None, fit="no", decision=(
            "Flat artwork, but the pack has no 'artwork' picture (%s). Call rebuild_pack; if it still has none, tell "
            "the user the photo is missing and ask them to shoot it again. Do not build anything else."
            % (", ".join(by_name) or "no views")))
        return base
    flat = brief.get("flat") or {}
    rectified = flat.get("artworkSource") == "rectified"
    sheet = (brief.get("measurements") or {}).get("sheet") or {}
    assumptions = []
    sheet_cfg = {}
    if isinstance(sheet.get("shortSideM"), (int, float)) and isinstance(sheet.get("longSideM"), (int, float)):
        sheet_cfg["size_mm"] = [_round1(sheet["shortSideM"] * 1000), _round1(sheet["longSideM"] * 1000)]
        if sheet.get("source") == "declared":
            assumptions.append("Sheet size %s × %s mm is the paper the person picked (%s), not measured."
                               % (sheet_cfg["size_mm"][0], sheet_cfg["size_mm"][1],
                                  sheet.get("declaredSheetName") or sheet.get("declaredSheetId") or "?"))
        else:
            assumptions.append("Sheet size %s × %s mm was measured with ARKit (error up to about 1 cm)."
                               % tuple(sheet_cfg["size_mm"]))
    else:
        assumptions.append("The sheet size is unknown: without sheet.size_mm the tool guesses a standard paper from "
                           "the aspect ratio (report warning). Tell the user the size is a guess.")
    if rectified:
        sheet_cfg["corners"] = FLAT_FULL_FRAME
        colors = {"paper": FLAT_PAPER_SAMPLES}
        assumptions.append("views/artwork.jpg is already rectified (the whole picture is the sheet), so sheet.corners "
                           "is the full frame; the paper colour samples are near the four corners - move them if a "
                           "corner is not bare paper.")
    else:
        colors = {"paper": "TODO: one or more [x, y] points (fractions of the photo) on bare paper, read with photo_grid"}
        assumptions.append("views/artwork.jpg is the upright photo (not rectified): the tool finds the sheet itself "
                           "(the paper must differ from the table); give sheet.corners if it fails.")
    starter = {"photo": artwork["path"], "mode": "plane", "sheet": sheet_cfg, "colors": colors, "backing": "paper"}
    base.update(
        builder="flat-art-glb", fit="yes",
        decision="Flat artwork: use flat-art-glb. Start with mode 'plane' (the picture on a thin sheet; right for "
                 "drawings, crayon, paint). Switch to mode 'layers' only for a collage of cut coloured paper: add one "
                 "colour per paper colour to 'colors' (sample points on each), list them in 'stack' from the bottom up "
                 "(first colour of each group = its main colour) and set 'white_reference' if there is white paper.",
        starterConfig=starter,
        photoKeys=["photo"],
        assumptions=assumptions,
        steps=[
            "get_view(session, view='artwork') once: decide 'plane' or 'layers'.",
            "photo_grid(session, view='artwork') only if you need positions (colour sample points for layers, or the "
            "sheet corners when the artwork is not rectified).",
            "build_model(session, label='v1', builder='flat-art-glb', config=<starterConfig, edited>).",
            "Look at the returned overlay once (outline / pieces and layers); fix the config if pieces or the sheet "
            "are wrong.",
        ] + STEPS_COMMON_END,
    )
    return base


def _solid_guide(base: dict, brief: dict, photos: "list[dict]", top: dict) -> dict:
    m = brief.get("measurements") or {}
    size = m.get("sizeCm") if isinstance(m.get("sizeCm"), dict) else None
    declared_h = (brief.get("declaredSize") or {}).get("heightM")
    assumptions = []
    if size and isinstance(size.get("width"), (int, float)) and m.get("status") in ("ok", "approximate"):
        width = _round1(size["width"] * 10)
        assumptions.append("top.width_mm %s comes from measurements.sizeCm.width (method %s, status %s); check it "
                           "against the photos." % (width, m.get("method"), m.get("status")))
    else:
        width = "TODO: the object's real left-right width in mm (not measured: estimate it, e.g. from the declared " \
                "height and the photos, and tell the user it is assumed)"
    if isinstance(declared_h, (int, float)):
        height = _round1(declared_h * 1000)
        assumptions.append("Total height %s mm is the height the person typed in (preferred over anything derived)."
                           % height)
    elif size and isinstance(size.get("height"), (int, float)) and m.get("status") in ("ok", "approximate"):
        height = _round1(size["height"] * 10)
        assumptions.append("Total height %s mm comes from measurements.sizeCm.height (method %s)."
                           % (height, m.get("method")))
    else:
        height = "TODO: the body's height in mm (estimate from the side photos relative to the width; say it is assumed)"
    views = [{"name": "top", "az": 0, "el": 89.9, "up": [0, 0, -1], "photo": top["path"]}]
    assumptions.append("views[0].up [0, 0, -1] assumes the top of the top photo shows the object's back; change it "
                       "if the photo was taken from another side ([0, 0, 1] front, [1, 0, 0] right, [-1, 0, 0] left).")
    others = [p for p in photos if p["view"] != top["view"]]
    by_name = {p["view"]: p for p in others}
    chosen = [by_name[n] for n in ("front", "right", "left", "back") if n in by_name][:2]
    if not chosen and others:
        chosen = [min(others, key=lambda p: p["elevationDeg"] if isinstance(p["elevationDeg"], (int, float)) else 90)]
    for p in chosen:
        az = p["azimuthDeg"]
        az = round(az) % 360 if isinstance(az, (int, float)) and p["view"] in ("front", "right", "left", "back") else \
            "TODO: which side this photo shows: 0 front, 90 right, 180 back, 270 left"
        el = round(p["elevationDeg"]) if isinstance(p["elevationDeg"], (int, float)) else 15
        views.append({"name": re.sub(r"[^A-Za-z0-9_-]", "-", p["view"])[:40] or "side", "az": az, "el": el,
                      "photo": p["path"]})
    starter = {
        "template": "slab",
        "top": {"photo": top["path"],
                "corners": "TODO: 4 [x, y] fractions of the top photo: back-left, back-right, front-right, front-left "
                           "(extend straight edges past rounded corners)",
                "width_mm": width},
        "outline": "TODO: [x, y] fractions tracing the top face once around, slightly inside its edge",
        "outline_round_mm": 0,
        "layers": [{"name": "body", "height_mm": height, "inset_mm": 0, "texture": "top",
                    "material": {"color": [0.8, 0.8, 0.8], "roughness": 0.6}}],
        "features": [],
        "views": views,
    }
    base.update(
        builder="solid-glb", fit="only if the object is flat-topped",
        decision="Object (3D work) with a photo from above ('%s', looking down %s°): solid-glb (template slab) fits "
                 "ONLY if the object has a flat top and roughly vertical sides - a box, board, tray, book, controller, "
                 "lidded container. Look at the photos first. If it is rounded, organic, sloped or figurine-like "
                 "(clay animal, doll, ball, computer mouse, cup), neither builder fits: tell the user so and stop - "
                 "do not write geometry code yourself." % (top["view"], top["elevationDeg"]),
        starterConfig=starter,
        photoKeys=["top.photo", "views[].photo"],
        assumptions=assumptions,
        steps=[
            "Look at each photo once (get_view) and decide whether the object is flat-topped (else stop, see "
            "decision) and which side is the front.",
            "photo_grid(session, view='%s') to read top.corners and trace the outline; add region=[x0, y0, x1, y1] "
            "to zoom into small parts (round buttons -> features)." % top["view"],
            "Replace every TODO in starterConfig (build_model refuses TODO values), then build_model(session, "
            "label='v1', builder='solid-glb', config=...).",
            "Look at the returned overlay once (green outline, red circles); fix corners/outline if they are off.",
        ] + STEPS_COMMON_END,
    )
    return base


def build_guide(root: Path, session: str) -> dict:
    brief = core.get_brief(root, session)  # raises when there is no pack
    sid = brief["sessionId"]
    photos = [_photo_entry(v) for v in brief["views"] if v["kind"] in ("photo", "unlisted")]
    base = {
        "sessionId": sid,
        "title": brief["title"],
        "workKind": brief["workKind"],
        "guidance": brief["guidance"],
        "declaredSize": brief["declaredSize"],
        "measurements": {k: (brief.get("measurements") or {}).get(k)
                         for k in ("status", "method", "sizeCm", "sheet", "declaredHeight")},
        "photos": photos,
        "outputRoot": str((root / "reconstructions" / sid).resolve()),
        "photoRule": "In a config, a photo is a view name from 'photos' (e.g. 'artwork', 'top', 'photo-03') or the "
                     "absolute path given here; nothing outside this session is accepted.",
        "privacy": "Photos are the user's private data; viewing them (get_view, photo_grid, overlay, compare) sends "
                   "them to the model provider. Only do this because the user asked for the model.",
    }
    if brief["workKind"] == "flat":
        result = _flat_guide(base, brief, photos)
    else:
        top = _top_view(photos)
        if top is None:
            best = max((p["elevationDeg"] for p in photos if isinstance(p["elevationDeg"], (int, float))), default=None)
            base.update(builder=None, fit="no", decision=(
                "Neither prepared builder fits this session: it is 3D work (flat-art-glb is for flat artwork only) "
                "and no photo looks down from above (steepest: %s; solid-glb needs one at %d° or more). Tell the "
                "user that this object cannot be built with the prepared builders. If it has a flat top (box, "
                "board, tray), they can add a photo from straight above in a new capture; rounded or figurine-like "
                "objects are not covered at all. Do not write geometry code yourself."
                % ("%.0f°" % best if best is not None else "unknown", TOP_MIN_ELEVATION)))
            result = base
        else:
            result = _solid_guide(base, brief, photos, top)
    if result.get("builder"):
        result["configDocs"] = builder_docs(result["builder"])
    return result


# ---------------------------------------------------------------------------
# photo_grid


def photo_grid(root: Path, session: str, view: str, region=None) -> "tuple[bytes, str, dict]":
    folder = core.resolve_session(root, session)
    photo = resolve_photo(root, folder, view, "view")
    size = core.image_size(photo)
    if size is None:
        raise MemoriaError("Cannot read the size of %s." % photo)
    box = [0.0, 0.0, 1.0, 1.0]
    if region is not None:
        if (not isinstance(region, (list, tuple)) or len(region) != 4
                or not all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in region)):
            raise MemoriaError("region must be [x0, y0, x1, y1] as fractions of the photo (0-1).")
        box = [float(v) for v in region]
        if not (0 <= box[0] < box[2] <= 1 and 0 <= box[1] < box[3] <= 1) or min(box[2] - box[0], box[3] - box[1]) < 0.02:
            raise MemoriaError("region must satisfy 0 <= x0 < x1 <= 1 and 0 <= y0 < y1 <= 1, each side at least 0.02.")
    w_px, h_px = (box[2] - box[0]) * size[0], (box[3] - box[1]) * size[1]
    height = int(max(200, min(1200, GRID_MAX_SIDE * h_px / w_px if w_px > h_px else 1200)))
    py = _require_python()
    with tempfile.TemporaryDirectory(prefix="memoria-grid-") as tmp:
        out = Path(tmp) / "grid.jpg"
        p = _run([py, BUILDERS["solid-glb"]["dir"] / "solidglb.py", "grid", photo, out] + ["%.4f" % v for v in box]
                 + [str(height)], BUILDERS["solid-glb"]["dir"], GRID_TIMEOUT, "photo_grid")
        if p.returncode != 0 or not out.is_file():
            raise MemoriaError("photo_grid failed: %s%s" % (_tail(p.stderr or p.stdout),
                                                             _fix_hint(p.stderr)))
        data, fmt, info = core.load_image(out, IMAGE_MAX_SIDE)
    meta = {"sessionId": folder.name, "view": view, "photoPath": str(photo), "photoWidth": size[0],
            "photoHeight": size[1], "region": box, "gridWidth": info["width"], "gridHeight": info["height"],
            "toolOutput": p.stdout.strip(),
            "howToRead": "Labels are fractions of the WHOLE photo (x to the right, y down, 0-1), also inside a zoomed "
                         "region; write config positions in the same fractions."}
    return data, fmt, meta


# ---------------------------------------------------------------------------
# build_model / check_model / list_models


def _fix_hint(stderr: str) -> str:
    if "ModuleNotFoundError" in (stderr or "") or "No module named" in (stderr or ""):
        return "\nThe builders' Python packages are missing: ask the user to run once: %s" % FIX_COMMAND
    return ""


def _model_dir(root: Path, folder: Path, label: str) -> Path:
    clean = core.sanitize_label(label)
    base = root / "reconstructions"
    out = base / folder.name / clean
    if not core.inside(out, base):
        raise MemoriaError("Refusing to use a folder outside %s." % base)
    return out


def _clear_outputs(out: Path) -> None:
    """Remove the previous build's and check's files (so a stale compare.jpg is never mistaken for the new one)."""
    names = set(OWN_FILES[1:]) | set(CHECK_OUTPUTS)
    for b in BUILDERS.values():
        names.update(b["outputs"])
    old_views = core.read_json(out / "views.json")
    if isinstance(old_views, list):
        for v in old_views:
            if isinstance(v, dict) and isinstance(v.get("name"), str) and VIEW_NAME_RE.fullmatch(v["name"]):
                names.add(v["name"] + ".png")
    for n in names:
        f = out / n
        if f.is_file() and not f.is_symlink():
            f.unlink()


def _write_json(path: Path, data) -> None:
    path.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")


def _flat_summary(report: dict) -> dict:
    sheet = report.get("sheet") or {}
    pieces = report.get("pieces") or []
    return {
        "mode": report.get("mode"),
        "sheetMm": sheet.get("size_mm"),
        "sheetSizeGuessed": sheet.get("size_guessed"),
        "sheetGuess": sheet.get("size_guess"),
        "cornersSource": sheet.get("corners_source"),
        "orientation": sheet.get("orientation"),
        "unseenFraction": sheet.get("unseen_fraction"),
        "photoPxPerMm": (sheet.get("photo_px_per_mm") or {}).get("median"),
        "unknownColourFraction": report.get("unknown_fraction"),
        "pieces": [{k: p.get(k) for k in ("name", "layer", "colors", "appearance", "bbox_mm", "area_mm2")}
                   for p in pieces[:40]],
        "pieceCount": len(pieces),
        "droppedComponents": len(report.get("dropped_components") or []),
        "builderSeconds": report.get("seconds"),
    }


def _solid_summary(report: dict) -> dict:
    return {k: report.get(k) for k in ("size_mm", "depth_from_photo", "outline_points", "layers", "features",
                                        "features_snapped", "features_not_snapped", "feature_list")}


def build_model(root: Path, session: str, label: str, builder: str, config) -> "tuple[dict, Path | None]":
    folder = core.resolve_session(root, session)
    if builder not in BUILDERS:
        raise MemoriaError("builder must be one of %s (see build_guide), got %r." % (", ".join(BUILDERS), builder))
    cfg = prepare_config(root, folder, builder, config)
    py = _require_python()
    out = _model_dir(root, folder, label)
    replaced = (out / "model.glb").is_file()
    out.mkdir(parents=True, exist_ok=True)
    _clear_outputs(out)
    config_path = out / "config.json"
    _write_json(config_path, cfg)
    b = BUILDERS[builder]
    started = time.monotonic()
    p = _run([py, b["dir"] / b["script"], "build", config_path, "--out", out], b["dir"], BUILD_TIMEOUT,
             "%s build" % builder)
    seconds = round(time.monotonic() - started, 2)
    if p.returncode != 0 or not (out / "model.glb").is_file():
        raise MemoriaError("%s failed (exit %d). Fix the config and call build_model again. Builder output:\n%s%s"
                           % (builder, p.returncode, _tail(p.stderr or p.stdout), _fix_hint(p.stderr)))
    report = core.read_json(out / "report.json") or {}
    glb = glb_summary(out / "model.glb")
    warnings = list(report.get("warnings") or [])
    warnings += [l for l in p.stdout.splitlines() if l.startswith("moved more than")]
    details = _flat_summary(report) if builder == "flat-art-glb" else _solid_summary(report)
    overlay = out / b["overlay"]
    result = {
        "sessionId": folder.name,
        "label": out.name,
        "builder": builder,
        "outDir": str(out.resolve()),
        "modelPath": str((out / "model.glb").resolve()),
        "configPath": str(config_path.resolve()),
        "reportPath": str((out / "report.json").resolve()),
        "overlayPath": str(overlay.resolve()) if overlay.is_file() else None,
        "replacedPrevious": replaced,
        "sizeMm": _size_mm(glb),
        "triangles": glb and glb["triangles"],
        "bytes": glb and glb["bytes"],
        "warnings": warnings,
        "details": details,
        "seconds": seconds,
        "builtAt": core.now_iso(),
        "overlay": b["overlay_meaning"],
        "next": "Look at the overlay image once. If the outline/pieces are wrong, fix the config and build again; "
                "otherwise call check_model(session, label).",
    }
    _write_json(out / "build.json", {k: v for k, v in result.items() if k not in ("details", "next", "overlay")})
    return result, (overlay if overlay.is_file() else None)


def _validate(glb: Path) -> dict:
    node = _node_path()
    p = _run([node, VALIDATOR, glb], VALIDATOR.parent.parent, CHECK_TIMEOUT, "gltf-validator")
    try:
        return json.loads(p.stdout)
    except ValueError:
        raise MemoriaError("gltf-validator failed: %s" % _tail(p.stderr or p.stdout))


def _builder_of(out: Path) -> "str | None":
    meta = core.read_json(out / "build.json")
    if isinstance(meta, dict) and meta.get("builder") in BUILDERS:
        return meta["builder"]
    report = core.read_json(out / "report.json")
    if isinstance(report, dict):
        if report.get("tool") == "flat-art-glb":
            return "flat-art-glb"
        if report.get("template") == "slab":
            return "solid-glb"
    return None


def check_model(root: Path, session: str, label: str) -> "tuple[dict, Path | None]":
    folder = core.resolve_session(root, session)
    out = _model_dir(root, folder, label)
    builder = _builder_of(out) if out.is_dir() else None
    if not (out / "model.glb").is_file() or builder is None:
        raise MemoriaError("No model built with build_model under label %r for session %s (list_models shows what "
                           "exists)." % (label, folder.name))
    py = _require_python()
    b = BUILDERS[builder]
    started = time.monotonic()
    for n in ("compare.jpg", "check.json"):
        (out / n).unlink(missing_ok=True)
    st = renderer_status(builder)
    validation = None
    if st["validatorScriptReady"]:
        validation = _validate(out / "model.glb")
        _write_json(out / "validation.json", validation)
    result = {
        "sessionId": folder.name, "label": out.name, "builder": builder, "outDir": str(out.resolve()),
        "modelPath": str((out / "model.glb").resolve()),
        "validation": None if validation is None else {
            k: validation.get(k) for k in ("errors", "warnings", "infos", "hints", "triangles", "vertices",
                                           "materials", "drawCalls", "validatorVersion")},
        "validationMessages": [m for m in (validation or {}).get("messages", [])
                               if m.get("severity") in ("error", "warning")][:10],
        "validationPath": str((out / "validation.json").resolve()) if validation is not None else None,
    }
    if not st["renderReady"] or not st["validatorScriptReady"]:
        result.update(rendererReady=False, comparePath=None, seconds=round(time.monotonic() - started, 2),
                      fix="The renderer is not ready (%s). Ask the user to run once in a terminal: %s. The model "
                          "itself is built; give the user modelPath meanwhile." % (
                              ", ".join(k for k in ("node", "three", "gltfValidator", "playwright", "chromium")
                                        if not st.get(k)) or "gltf-validator script", FIX_COMMAND))
        _write_json(out / "check.json", dict(result, checkedAt=core.now_iso()))
        return result, None
    p = _run([py, b["dir"] / b["script"], "check", out], b["dir"], CHECK_TIMEOUT, "%s check" % builder)
    compare = out / "compare.jpg"
    if not compare.is_file():
        raise MemoriaError("%s check failed (exit %d)%s:\n%s" % (
            builder, p.returncode, " - the validator found errors" if (validation or {}).get("errors") else "",
            _tail(p.stderr or p.stdout)))
    views = core.read_json(out / "views.json") if builder == "solid-glb" else None
    renders = ([v["name"] + ".png" for v in views if isinstance(v, dict) and isinstance(v.get("name"), str)]
               if isinstance(views, list) else ["front.png", "oblique.png"])
    result.update(
        rendererReady=True,
        comparePath=str(compare.resolve()),
        renders=[str((out / n).resolve()) for n in renders if (out / n).is_file()],
        compare=b["compare_meaning"] + (" (views: %s)" % ", ".join(n[:-4] for n in renders) if views else ""),
        seconds=round(time.monotonic() - started, 2),
        next="Look at compare once. Validator errors must be 0. Then either revise the config (at most about twice "
             "in total) or report to the user: modelPath, how it compares, what was assumed.",
    )
    _write_json(out / "check.json", dict(result, checkedAt=core.now_iso()))
    return result, compare


def list_models(root: Path, session: str) -> dict:
    folder = core.resolve_session(root, session)
    base = root / "reconstructions" / folder.name
    models = []
    if base.is_dir() and core.inside(base, root / "reconstructions"):
        for d in base.iterdir():
            if not d.is_dir() or not core.inside(d, base):
                continue
            glb = d / "model.glb"
            meta = core.read_json(d / "build.json")
            meta = meta if isinstance(meta, dict) else {}
            check = core.read_json(d / "check.json")
            check = check if isinstance(check, dict) else {}
            validation = core.read_json(d / "validation.json")
            summary = glb_summary(glb) if glb.is_file() else None
            models.append({
                "label": d.name,
                "path": str(d.resolve()),
                "builder": _builder_of(d),
                "modelPath": str(glb.resolve()) if glb.is_file() else None,
                "sizeMm": _size_mm(summary),
                "triangles": summary and summary["triangles"],
                "bytes": summary and summary["bytes"],
                "builtAt": meta.get("builtAt"),
                "warnings": meta.get("warnings"),
                "validation": {k: validation.get(k) for k in ("errors", "warnings", "triangles")}
                if isinstance(validation, dict) else None,
                "checkedAt": check.get("checkedAt"),
                "comparePath": str((d / "compare.jpg").resolve()) if (d / "compare.jpg").is_file() else None,
                "overlayPath": meta.get("overlayPath"),
                "configPath": str((d / "config.json").resolve()) if (d / "config.json").is_file() else None,
                "_mtime": glb.stat().st_mtime if glb.is_file() else d.stat().st_mtime,
            })
    models.sort(key=lambda m: m.pop("_mtime"), reverse=True)
    return {"sessionId": folder.name, "outputRoot": str(base.resolve()) if base.is_dir() else str(base),
            "models": models,
            "next": "Newest first. To continue, read a model's configPath, change it and call build_model with a new "
                    "label (or the same label to overwrite), then check_model." if models else
                    "Nothing built yet for this session: start with build_guide."}
