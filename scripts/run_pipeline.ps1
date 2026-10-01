param([ValidateSet('etl','full','train','score','profile')][string]$Mode='etl')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
Set-Location -LiteralPath $projectRoot
$python=Join-Path $projectRoot '.venv\Scripts\python.exe'
if ($Mode -eq 'full') {
    & $python -X utf8 scripts\run.py etl --full
} else {
    & $python -X utf8 scripts\run.py $Mode
}
exit $LASTEXITCODE
