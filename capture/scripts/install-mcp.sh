#!/bin/sh
# Registers the memoria-capture MCP server (mcp-server/memoria_mcp.py of this checkout) at user scope for
# Claude Code, Codex CLI and the Claude desktop app (macOS), and prepares the model builders
# (tools/flat-art-glb, tools/solid-glb) that the server runs. Safe to run again.
#
#   scripts/install-mcp.sh                   register everywhere available and prepare the builders
#   scripts/install-mcp.sh --claude-desktop  only the Claude desktop app (also --claude-code, --codex; combinable)
#   scripts/install-mcp.sh --skip-tools      register only (do not prepare the builders)
#   scripts/install-mcp.sh --tools-only      prepare the builders only (no registration)
#   scripts/install-mcp.sh --uninstall       remove the registrations (the builders' files are kept)
#   scripts/install-mcp.sh --dry-run         print what would be done, change nothing
#
# Environment: MEMORIA_CAPTURES_DIR (passed to the server when set: the receiver's --data-dir),
# CLAUDE_DESKTOP_CONFIG (the desktop app's config file, default
# ~/Library/Application Support/Claude/claude_desktop_config.json), MEMORIA_TOOLS_PYTHON_VERSION (default 3.12).
# Absolute paths are computed here at run time; nothing machine-specific is committed.
set -eu

NAME="memoria-capture"
MODE="install"
DRY=""
TOOLS="yes"
ONLY_TOOLS=""
WANT_CODE=""
WANT_CODEX=""
WANT_DESKTOP=""
for arg in "$@"; do
    case "$arg" in
        --uninstall) MODE="uninstall" ;;
        --dry-run) DRY="1" ;;
        --skip-tools) TOOLS="" ;;
        --tools-only) ONLY_TOOLS="1" ;;
        --claude-code) WANT_CODE="1" ;;
        --codex) WANT_CODEX="1" ;;
        --claude-desktop) WANT_DESKTOP="1" ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done
EXPLICIT=""
[ -z "$WANT_CODE$WANT_CODEX$WANT_DESKTOP" ] || EXPLICIT="1"
if [ -n "$ONLY_TOOLS" ] && { [ "$MODE" = "uninstall" ] || [ -n "$EXPLICIT" ]; }; then
    echo "--tools-only cannot be combined with --uninstall or a client option" >&2
    exit 2
fi
[ "$MODE" = "install" ] || TOOLS=""

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
SERVER="$REPO/mcp-server/memoria_mcp.py"
TOOLS_DIR="$REPO/tools"
VENV="$TOOLS_DIR/.venv"
PY_VERSION="${MEMORIA_TOOLS_PYTHON_VERSION:-3.12}"
DESKTOP_CONFIG="${CLAUDE_DESKTOP_CONFIG:-$HOME/Library/Application Support/Claude/claude_desktop_config.json}"
CAPTURES="${MEMORIA_CAPTURES_DIR:-}"
[ -f "$SERVER" ] || { echo "not found: $SERVER" >&2; exit 1; }

run() {
    echo "+ $*"
    [ -n "$DRY" ] || "$@"
}

# Runs a removal that may legitimately fail (nothing registered yet) without stopping the script.
try_remove() {
    echo "+ $*"
    [ -n "$DRY" ] || "$@" >/dev/null 2>&1 || true
}

UV="$(command -v uv || true)"
if [ "$MODE" = "install" ] && [ -z "$UV" ]; then
    echo "uv is required: https://docs.astral.sh/uv/ (brew install uv)" >&2
    exit 1
fi
if [ -n "$CAPTURES" ]; then
    case "$CAPTURES" in
        /*) ;;
        *) echo "MEMORIA_CAPTURES_DIR must be an absolute path: $CAPTURES" >&2; exit 1 ;;
    esac
fi

# --------------------------------------------------------------------------- builders
setup_tools() {
    echo "== Builders (tools/flat-art-glb, tools/solid-glb) =="
    if [ -x "$VENV/bin/python" ]; then
        echo "Python environment: $VENV (exists)"
    else
        run "$UV" venv --python "$PY_VERSION" "$VENV"
    fi
    run "$UV" pip install --python "$VENV/bin/python" \
        -r "$TOOLS_DIR/flat-art-glb/requirements.txt" -r "$TOOLS_DIR/solid-glb/requirements.txt"
    # The first import of OpenCV after installing takes several seconds; do it here instead of in the first build.
    run "$VENV/bin/python" -c "import cv2, numpy, mapbox_earcut; print('Python builders: OpenCV', cv2.__version__, '/ numpy', numpy.__version__)"
    NPM="$(command -v npm || true)"
    if [ -z "$NPM" ]; then
        echo "Node.js (npm) not found: building works, but check_model (validation and rendering) needs Node.js." >&2
        echo "Install it (brew install node), then run: $0 --tools-only" >&2
        return 0
    fi
    for tool in flat-art-glb solid-glb; do
        run "$NPM" ci --prefix "$TOOLS_DIR/$tool" --no-audit --no-fund
    done
    # Playwright's Chromium (one copy in ~/Library/Caches/ms-playwright, shared by both tools).
    run "$TOOLS_DIR/solid-glb/node_modules/.bin/playwright" install chromium
    echo "Builders ready. Check with the MCP tool tools_status."
}

if [ -n "$ONLY_TOOLS" ]; then
    setup_tools
    [ -z "$DRY" ] || echo "(dry run: nothing was changed)"
    exit 0
fi

# --------------------------------------------------------------------------- Claude desktop app
# PATH for the desktop app's server process: the app does not inherit the shell's PATH, and the server runs
# node / npx (check_model) and uv itself.
server_path_env() {
    p=""
    for d in "$(dirname "$UV")" "$(dirname "$(command -v node || echo /usr/bin/node)")" \
             /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
        case ":$p:" in *":$d:"*) ;; *) p="${p:+$p:}$d" ;; esac
    done
    echo "$p"
}

desktop_config() {
    # $1 = install | uninstall. Merges or removes only mcpServers["memoria-capture"]; every other key is kept.
    # A timestamped backup of the file is written before any change; nothing is written when nothing changes.
    py="$(command -v python3 || true)"
    if [ -z "$py" ]; then
        echo "python3 is required to edit $DESKTOP_CONFIG" >&2
        return 1
    fi
    "$py" -I - "$1" "$DESKTOP_CONFIG" "$DRY" "$NAME" "$UV" "$SERVER" "$(server_path_env)" "$CAPTURES" <<'PY'
import json, os, shutil, sys, tempfile, time

mode, path, dry, name, uv, server, path_env, captures = sys.argv[1:9]
path = os.path.realpath(path)  # write through a symlink instead of replacing it
try:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    exists = True
except FileNotFoundError:
    text, exists = "", False
try:
    data = json.loads(text) if text.strip() else {}
except ValueError as e:
    sys.exit("%s is not valid JSON (%s); nothing was changed" % (path, e))
if not isinstance(data, dict):
    sys.exit("%s does not hold a JSON object; nothing was changed" % path)
servers = data.get("mcpServers")
if servers is not None and not isinstance(servers, dict):
    sys.exit("mcpServers in %s is not an object; nothing was changed" % path)

if mode == "install":
    env = {"PATH": path_env}
    if captures:
        env["MEMORIA_CAPTURES_DIR"] = captures
    entry = {"command": uv, "args": ["run", "--script", server], "env": env}
    if servers is not None and servers.get(name) == entry:
        print("Claude desktop: \"%s\" already registered in %s (unchanged)" % (name, path))
        sys.exit(0)
    action = "updated" if servers and name in servers else "added"
    if servers is None:
        servers = data["mcpServers"] = {}
    servers[name] = entry
else:
    if not servers or name not in servers:
        print("Claude desktop: \"%s\" is not registered in %s (unchanged)" % (name, path))
        sys.exit(0)
    entry = servers.pop(name)
    action = "removed"

new_text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
if dry:
    verb = {"added": "add", "updated": "update", "removed": "remove"}[action]
    print("Claude desktop: would %s mcpServers[\"%s\"] in %s%s:" % (
        verb, name, path, " (after a backup)" if exists else " (new file)"))
    print(json.dumps({name: entry}, indent=2, ensure_ascii=False))
    sys.exit(0)
if exists:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup, n = "%s.bak-%s" % (path, stamp), 1
    while os.path.exists(backup):
        backup, n = "%s.bak-%s-%d" % (path, stamp, n), n + 1
    shutil.copy2(path, backup)
    print("Claude desktop: backup %s" % backup)
folder = os.path.dirname(path)
os.makedirs(folder, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=folder, prefix=".claude_desktop_config.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new_text)
    os.chmod(tmp, (os.stat(path).st_mode & 0o777) if exists else 0o644)
    os.replace(tmp, path)
except BaseException:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
print("Claude desktop: %s mcpServers[\"%s\"] in %s" % (action, name, path))
PY
}

# --------------------------------------------------------------------------- registration
if [ "$MODE" = "install" ]; then
    # Install the server script's dependencies once, so the first start stays within the clients' startup timeouts.
    run "$UV" sync --script "$SERVER"
fi

done_any=""

if [ -z "$EXPLICIT" ] || [ -n "$WANT_CODE" ]; then
    if command -v claude >/dev/null 2>&1; then
        try_remove claude mcp remove --scope user "$NAME"
        if [ "$MODE" = "install" ]; then
            if [ -n "$CAPTURES" ]; then
                run claude mcp add --scope user "$NAME" -e "MEMORIA_CAPTURES_DIR=$CAPTURES" -- "$UV" run --script "$SERVER"
            else
                run claude mcp add --scope user "$NAME" -- "$UV" run --script "$SERVER"
            fi
            echo "Claude Code: registered \"$NAME\" (user scope)."
        else
            echo "Claude Code: removed \"$NAME\" (user scope) if it was registered."
        fi
        done_any="1"
    else
        echo "Claude Code (claude) not found; skipped."
    fi
fi

if [ -z "$EXPLICIT" ] || [ -n "$WANT_CODEX" ]; then
    if command -v codex >/dev/null 2>&1; then
        try_remove codex mcp remove "$NAME"
        if [ "$MODE" = "install" ]; then
            if [ -n "$CAPTURES" ]; then
                run codex mcp add "$NAME" --env "MEMORIA_CAPTURES_DIR=$CAPTURES" -- "$UV" run --script "$SERVER"
            else
                run codex mcp add "$NAME" -- "$UV" run --script "$SERVER"
            fi
            echo "Codex: registered \"$NAME\"."
        else
            echo "Codex: removed \"$NAME\" if it was registered."
        fi
        done_any="1"
    else
        echo "Codex CLI (codex) not found; skipped."
    fi
fi

if [ -n "$WANT_DESKTOP" ] || { [ -z "$EXPLICIT" ] && [ -d "$(dirname "$DESKTOP_CONFIG")" ]; }; then
    if [ ! -d "$(dirname "$DESKTOP_CONFIG")" ]; then
        echo "Claude desktop app: config folder not found ($(dirname "$DESKTOP_CONFIG")). Install and open the app once." >&2
        exit 1
    fi
    desktop_config "$MODE"
    [ "$MODE" != "install" ] || echo "Claude desktop: quit the app completely (Cmd-Q) and open it again to load the server."
    done_any="1"
else
    echo "Claude desktop app not found; skipped."
fi

[ -n "$done_any" ] || { echo "None of Claude Code, Codex or the Claude desktop app was found." >&2; exit 1; }
if [ -n "$TOOLS" ]; then
    setup_tools
fi
[ -z "$DRY" ] || echo "(dry run: nothing was changed)"
if [ "$MODE" = "install" ]; then
    echo "Server: $SERVER"
    [ -z "$CAPTURES" ] || echo "Captures: $CAPTURES (MEMORIA_CAPTURES_DIR)"
    echo "Check: claude mcp get $NAME / codex mcp get $NAME / the desktop app's Settings > Developer"
fi
