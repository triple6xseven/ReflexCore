# ReflexCore 0.6.0: one tray per user session. No Windows-login autostart.
param([switch]$SelfTest)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$tray=Join-Path $root 'tools\ReflexCore-Tray.ps1'
if (-not (Test-Path -LiteralPath $tray -PathType Leaf)) {throw 'Tray launcher not found.'}
if ($SelfTest) {Write-Host '[ReflexCore] Tray launcher found; no tray spawned during self-test.';exit 0}
$owned=$null
try {
    $owned=[Threading.Mutex]::OpenExisting('Local\ReflexCoreAgentTray')
    return # Already present; do not start a second tray process.
} catch [System.Threading.WaitHandleCannotBeOpenedException] {
    # Start below.
} catch [System.UnauthorizedAccessException] {
    return # An instance exists but is not accessible; do not interfere.
} finally {
    if ($owned) {$owned.Dispose()}
}
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$tray+'"'
Start-Process -FilePath $ps -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Hidden | Out-Null
