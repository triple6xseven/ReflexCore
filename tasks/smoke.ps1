# Supervised task: validates Rust core and runs the real UIA smoke scenario.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $root
try {
    & cargo test
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & cargo run -- flow demo --execute
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally { Pop-Location }
exit 0