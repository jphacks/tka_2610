# Sets up the shape generator used by `kt gen` / `kt auto` (Hunyuan3D-2.1, shape only, NVIDIA GPU with ~10 GB).
# Everything goes outside the repo, to $env:KT_HY3D_HOME or %USERPROFILE%\.cache\katachi-tools\hy3d (about 11-12 GB):
#   venv\            Python 3.11 + torch 2.5.1 (CUDA 12.4) + the packages the shape pipeline imports
#   Hunyuan3D-2.1\   code (git clone --depth 1; only hy3dshape is used)
#   models\          weights: Hugging Face tencent/Hunyuan3D-2.1, folder hunyuan3d-dit-v2-1 only (7.37 GB)
# Hunyuan3D 2.1 is under the Tencent Hunyuan 3D 2.1 Community License (not valid in the EU, UK and South Korea;
# outputs must not be used to improve other AI models; see Hunyuan3D-2.1\LICENSE).
# Re-running is safe: finished steps are skipped by pip / git / the downloader.
# Native tools write progress and warnings to stderr; success is judged by their exit codes only.
$ErrorActionPreference = 'Continue'
function Step([string]$what, [scriptblock]$cmd) {
    Write-Output "== $what"
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "setup_gen: '$what' failed (exit $LASTEXITCODE)" }
}
$root = if ($env:KT_HY3D_HOME) { $env:KT_HY3D_HOME } else { Join-Path $env:USERPROFILE '.cache\katachi-tools\hy3d' }
New-Item -ItemType Directory -Force $root | Out-Null
$venv = Join-Path $root 'venv'
$py = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $py)) { Step 'venv (Python 3.11)' { py -3.11 -m venv $venv } }
Step 'pip' { & $py -m pip install --upgrade pip --quiet }
Step 'torch 2.5.1 (CUDA 12.4)' { & $py -m pip install --quiet torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu124 }
Step 'shape pipeline packages' { & $py -m pip install --quiet 'numpy<2' 'transformers==4.46.3' 'diffusers==0.30.0' 'accelerate==1.1.1' `
    einops omegaconf pyyaml tqdm trimesh pymeshlab scikit-image opencv-python-headless timm safetensors huggingface_hub pillow }
$code = Join-Path $root 'Hunyuan3D-2.1'
if (-not (Test-Path $code)) { Step 'Hunyuan3D-2.1 code' { git clone --quiet --depth 1 https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1 $code } }
$models = Join-Path $root 'models\tencent\Hunyuan3D-2.1'
Step 'weights hunyuan3d-dit-v2-1 (7.37 GB)' { & $py -c "from huggingface_hub import snapshot_download; snapshot_download('tencent/Hunyuan3D-2.1', allow_patterns=['hunyuan3d-dit-v2-1/*'], local_dir=r'$models')" }
Step 'check' { & $py -c "import torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else '')" }
Write-Output "shape generator ready in $root"
