param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$bridge = Join-Path $root 'data\bridge'
try {
    Add-Type -Path @((Join-Path $root 'tools/ReflexCore-Queue.cs'),(Join-Path $root 'tools/ReflexCore-Tray.cs')) -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll','System.Core.dll') -ErrorAction Stop
    if ($SelfTest) {
        [ReflexCore.Bridge.TrayHost]::SelfTest($root)
        exit 0
    }
    [ReflexCore.Bridge.TrayHost]::Run($root)
} catch {
    New-Item -ItemType Directory -Path $bridge -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $bridge 'startup-error.txt'), $_.Exception.ToString())
    Write-Error $_
    exit 1
}