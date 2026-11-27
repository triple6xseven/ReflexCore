$ErrorActionPreference='Stop'
$exe=Join-Path (Split-Path $PSScriptRoot -Parent) 'target/release/reflexcore.exe'
& $exe agent compose-claimed
exit $LASTEXITCODE
