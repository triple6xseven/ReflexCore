param([ValidateSet('status','stop','exit')][string]$Action='status')
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$bridge = Join-Path $root 'data\bridge'
New-Item -ItemType Directory -Path $bridge -Force | Out-Null
if ($Action -eq 'status') {
    $status = Join-Path $bridge 'status.json'
    if (Test-Path -LiteralPath $status) { Get-Content -LiteralPath $status -Raw }
    else { Write-Warning 'No tray status. Start ReflexCore-Tray.ps1 first.' }
} else {
    [IO.File]::WriteAllText((Join-Path $bridge 'control.txt'), $Action)
    Write-Host "[ReflexCore] $Action requested."
}