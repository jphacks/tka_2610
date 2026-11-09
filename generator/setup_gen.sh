#!/usr/bin/env bash
# Shape generator for `kt gen` / `kt auto` on macOS (Apple silicon GPU through MPS) or Linux (NVIDIA, CUDA).
# Windows: setup_gen.ps1. Same layout, outside the repo, in $KT_HY3D_HOME or ~/.cache/katachi-tools/hy3d (about 11-12 GB):
#   venv/            Python 3.10 - 3.12 (the pipeline pins numpy < 2) + torch + the packages the shape pipeline imports
#   Hunyuan3D-2.1/   code (git clone --depth 1; only hy3dshape is used, unchanged; MPS needs are patched at run time
#                    by kt/hy3d_worker.py)
#   models/          weights: Hugging Face tencent/Hunyuan3D-2.1, folder hunyuan3d-dit-v2-1 only (7.37 GB)
# Hunyuan3D 2.1 is under the Tencent Hunyuan 3D 2.1 Community License (not valid in the EU, UK and South Korea;
# outputs must not be used to improve other AI models; see Hunyuan3D-2.1/LICENSE).
#   PYTHON=python3.12 ./setup_gen.sh
set -euo pipefail
root="${KT_HY3D_HOME:-$HOME/.cache/katachi-tools/hy3d}"
py="${PYTHON:-python3}"
"$py" -c 'import sys; v = sys.version_info; sys.exit(0 if (3, 10) <= v[:2] <= (3, 12) else f"Python {v.major}.{v.minor}: the generator needs 3.10 - 3.12 (numpy < 2). macOS: brew install python@3.12, then PYTHON=python3.12 ./setup_gen.sh")'
mkdir -p "$root"
if [ ! -x "$root/venv/bin/python" ]; then
    echo "== venv"
    "$py" -m venv "$root/venv"
fi
vpy="$root/venv/bin/python"
"$vpy" -m pip install --upgrade pip -q
if [ "$(uname)" = Darwin ]; then
    echo "== torch (MPS)"
    "$vpy" -m pip install -q 'torch>=2.6' torchvision          # newer torch covers more operations on MPS
else
    echo "== torch 2.5.1 (CUDA 12.4)"
    "$vpy" -m pip install -q torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu124
fi
echo "== shape pipeline packages"
"$vpy" -m pip install -q 'numpy<2' 'transformers==4.46.3' 'diffusers==0.30.0' 'accelerate==1.1.1' einops omegaconf pyyaml \
    tqdm trimesh pymeshlab scikit-image opencv-python-headless timm safetensors huggingface_hub pillow
if [ ! -d "$root/Hunyuan3D-2.1" ]; then
    echo "== Hunyuan3D-2.1 code"
    git clone --quiet --depth 1 https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1 "$root/Hunyuan3D-2.1"
fi
echo "== weights hunyuan3d-dit-v2-1 (7.37 GB)"
"$vpy" -c "from huggingface_hub import snapshot_download; snapshot_download('tencent/Hunyuan3D-2.1', allow_patterns=['hunyuan3d-dit-v2-1/*'], local_dir='$root/models/tencent/Hunyuan3D-2.1')"
"$vpy" -c "import torch; print('torch', torch.__version__, '| cuda', torch.cuda.is_available(), '| mps', torch.backends.mps.is_available())"
echo "shape generator ready in $root"
