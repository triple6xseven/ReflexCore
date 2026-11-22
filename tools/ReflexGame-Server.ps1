param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
try {
    Add-Type -AssemblyName System.Web.Extensions, System.Security -ErrorAction Stop
    $sources = @( (Join-Path $root 'tools\ReflexGame-Server.cs'), (Join-Path $root 'tools\ReflexGame-RustBridge.cs') )
    Add-Type -Path $sources -ReferencedAssemblies @('System.Web.Extensions.dll', 'System.Security.dll', 'System.Core.dll') -ErrorAction Stop
    if ($SelfTest) { [ReflexCore.Citadel.Server]::SelfTest($root); exit 0 }
    [ReflexCore.Citadel.Server]::Run($root)
} catch {
    $path=Join-Path $root 'data\bridge\citadel-startup-error.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
    [IO.File]::WriteAllText($path, $_.Exception.ToString())
    Write-Error $_
    exit 1
}
