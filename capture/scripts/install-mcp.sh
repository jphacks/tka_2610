#!/bin/sh
# Registers the memoria-capture MCP server (mcp-server/memoria_mcp.py of this checkout) at user scope
# for Claude Code and Codex CLI, so it is available from any project. Safe to run again.
#
#   scripts/install-mcp.sh              register (replaces an existing "memoria-capture" entry)
#   scripts/install-mcp.sh --uninstall  remove the entries
#   scripts/install-mcp.sh --dry-run    only print the commands
#
# The checkout's absolute path is computed here at run time; nothing machine-specific is committed.
set -eu

NAME="memoria-capture"
MODE="install"
DRY=""
for arg in "$@"; do
    case "$arg" in
        --uninstall) MODE="uninstall" ;;
        --dry-run) DRY="1" ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
SERVER="$REPO/mcp-server/memoria_mcp.py"
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

UV=""
if [ "$MODE" = "install" ]; then
    UV="$(command -v uv || true)"
    if [ -z "$UV" ]; then
        echo "uv is required: https://docs.astral.sh/uv/ (brew install uv)" >&2
        exit 1
    fi
    # Install the script's dependencies once, so the first start stays within the clients' startup timeouts.
    run "$UV" sync --script "$SERVER"
fi

done_any=""

if command -v claude >/dev/null 2>&1; then
    try_remove claude mcp remove --scope user "$NAME"
    if [ "$MODE" = "install" ]; then
        run claude mcp add --scope user "$NAME" -- "$UV" run --script "$SERVER"
        echo "Claude Code: registered \"$NAME\" (user scope)."
    else
        echo "Claude Code: removed \"$NAME\" (user scope) if it was registered."
    fi
    done_any="1"
else
    echo "Claude Code (claude) not found; skipped."
fi

if command -v codex >/dev/null 2>&1; then
    try_remove codex mcp remove "$NAME"
    if [ "$MODE" = "install" ]; then
        run codex mcp add "$NAME" -- "$UV" run --script "$SERVER"
        echo "Codex: registered \"$NAME\"."
    else
        echo "Codex: removed \"$NAME\" if it was registered."
    fi
    done_any="1"
else
    echo "Codex CLI (codex) not found; skipped."
fi

[ -n "$done_any" ] || { echo "Neither claude nor codex was found." >&2; exit 1; }
[ -z "$DRY" ] || echo "(dry run: nothing was changed)"
if [ "$MODE" = "install" ]; then
    echo "Server: $SERVER"
    echo "Check: claude mcp get $NAME / codex mcp get $NAME"
fi
