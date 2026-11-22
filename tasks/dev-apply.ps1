# The tray supervises this worker; Ctrl+Alt+P stops its whole process tree.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
& (Join-Path $root 'tools\ReflexDev-Worker.ps1') -Mode apply
exit $LASTEXITCODE