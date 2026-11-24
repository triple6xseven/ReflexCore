# This mode uses the owned non-activating UIA fixture and independent file readback.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $root
try {
    & (Join-Path $root 'target/release/reflexcore.exe') agent verified-demo --execute --background
    exit $LASTEXITCODE
} finally { Pop-Location }
