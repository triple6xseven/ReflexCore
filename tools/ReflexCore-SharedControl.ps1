param([switch]$SelfTest)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
try {
    if (-not $SelfTest) {
        try { & (Join-Path $root 'tools\Ensure-ReflexCore-Tray.ps1') }
        catch { Write-Warning 'Tray not started; main UI will still open.' }
    }
    $src=Join-Path $root 'tools\ReflexCore-SharedControl.cs'
    Add-Type -TypeDefinition ([IO.File]::ReadAllText($src)) -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll','System.Core.dll','System.Web.Extensions.dll','System.Net.Http.dll') -ErrorAction Stop
    if($SelfTest){[ReflexCore.SharedControl.Lab]::SelfTest($root);exit 0}
    [ReflexCore.SharedControl.Lab]::Run($root)
} catch {
    $dir=Join-Path $root 'data\bridge'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir 'cs16-shared-control-error.txt'),$_.Exception.GetType().Name+': '+$_.Exception.Message)
    Write-Error $_
    exit 1
}
