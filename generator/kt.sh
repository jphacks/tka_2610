#!/usr/bin/env bash
# kt launcher for macOS / Linux (Windows: kt.ps1): UTF-8 mode (Katachi reads JSON with the default encoding)
# + the tools venv made by setup.sh.
here="$(cd "$(dirname "$0")" && pwd)"
export PYTHONUTF8=1
export PYTHONPATH="$here${PYTHONPATH:+:$PYTHONPATH}"
exec "$here/.venv/bin/python" -m kt "$@"
