# Supervised through ReflexCore Tray. Ctrl+Alt+P stops this process tree.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $root
try {
    $binary = Join-Path $root 'target\release\reflexcore.exe'
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'Release binary missing. Run cargo build --release.' }
    & $binary agent demo --execute
    exit $LASTEXITCODE
}
finally { Pop-Location }