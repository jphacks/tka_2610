#!/usr/bin/env bash
# One-time setup for macOS / Linux (Windows: setup.ps1): tools venv + Katachi Loop Studio (editable, from its
# local folder) + requirements.txt.
#   ./setup.sh [folder that contains Katachi's pyproject.toml]
#   PYTHON=python3.12 ./setup.sh ...     to choose the Python (Katachi needs 3.11 - 3.14)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
katachi="${1:-$HOME/Downloads/KatachiLoopStudio_0.5.0_Python/KatachiLoopStudio}"
if [ ! -f "$katachi/pyproject.toml" ]; then
    echo "Katachi Loop Studio not found at '$katachi'. Pass the folder that contains its pyproject.toml." >&2
    exit 1
fi
py="${PYTHON:-python3}"
"$py" -c 'import sys; v = sys.version_info; sys.exit(0 if (3, 11) <= v[:2] < (3, 15) else f"Python {v.major}.{v.minor}: Katachi needs 3.11 - 3.14 (set PYTHON=...)")'
if [ ! -x "$here/.venv/bin/python" ]; then
    echo "creating .venv"
    "$py" -m venv "$here/.venv"
fi
vpy="$here/.venv/bin/python"
"$vpy" -m pip install --disable-pip-version-check -q -e "$katachi[render,test]"
"$vpy" -m pip install --disable-pip-version-check -q -r "$here/requirements.txt"
PYTHONUTF8=1 "$vpy" -c "import katachi, rembg; print('ok: katachi at', katachi.__file__)"
echo "setup done. Run ./kt.sh --help. The rembg model (~179 MB) downloads on the first segmentation run."
