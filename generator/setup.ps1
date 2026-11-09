# One-time setup: tools venv + Katachi Loop Studio (editable, from its local folder) + rembg.
# Usage: .\setup.ps1 [-KatachiPath <folder that contains Katachi's pyproject.toml>]
param(
    [string]$KatachiPath = "$env:USERPROFILE\Downloads\KatachiLoopStudio_0.5.0_Python\KatachiLoopStudio"
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path (Join-Path $KatachiPath 'pyproject.toml'))) {
    throw "Katachi Loop Studio not found at '$KatachiPath'. Pass -KatachiPath <folder with pyproject.toml>."
}
$venvPython = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPython)) {
    Write-Host 'creating .venv'
    py -3 -m venv (Join-Path $PSScriptRoot '.venv')
    if ($LASTEXITCODE -ne 0) { throw 'venv creation failed (is the py launcher installed?)' }
}
& $venvPython -m pip install --disable-pip-version-check -q -e "$KatachiPath[render,test]"
if ($LASTEXITCODE -ne 0) { throw 'installing Katachi Loop Studio failed' }
& $venvPython -m pip install --disable-pip-version-check -q -r (Join-Path $PSScriptRoot 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'installing requirements.txt failed' }
$env:PYTHONUTF8 = '1'
& $venvPython -c "import katachi, rembg; print('ok: katachi at', katachi.__file__)"
Write-Host 'setup done. The rembg model (~179 MB) downloads on the first segmentation run.'
