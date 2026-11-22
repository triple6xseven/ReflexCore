# Backward-compatible entry point: normal use routes to the integrated Control Center.
param([switch]$SelfTest)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(-not $SelfTest){
    & (Join-Path $root 'tools\ReflexCore-ControlCenter.ps1') -InitialTab Diagnostics
    return
}
try{
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'tools\ReflexCore-Diagnostics.cs'))) `
        -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll','System.Core.dll','System.Web.Extensions.dll') -ErrorAction Stop
    [ReflexCore.Diagnostics.Dashboard]::SelfTest($root)
}catch{
    Write-Error ('[ReflexCore] Measurement Lab self-test failed: '+$_.Exception.GetType().Name)
    exit 1
}
