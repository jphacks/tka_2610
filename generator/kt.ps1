# kt launcher: UTF-8 mode (Katachi reads JSON with the default encoding) + the tools venv.
$env:PYTHONUTF8 = '1'
$env:PYTHONPATH = $PSScriptRoot
& "$PSScriptRoot\.venv\Scripts\python.exe" -m kt @args
exit $LASTEXITCODE
