param([switch]$DeveloperTools)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Add-Type -Path @((Join-Path $PSScriptRoot 'ReflexCore-Queue.cs'),(Join-Path $PSScriptRoot 'ReflexCore-Mcp.cs'),(Join-Path $PSScriptRoot 'ReflexCore-McpLab.cs')) -ReferencedAssemblies 'System.Core.dll','System.Web.Extensions.dll'
$check = [Func[string]]{
    $record = & (Join-Path $root 'tools/Measure-DevBuild.ps1') -Action Check
    return $record
}
$reader = [Func[string,string,string,string]]{
    param($name,$session,$scope)
    if($name -eq 'get_usage_status'){return (& (Join-Path $root 'tools/Read-DevUsage.ps1'))}
    return (& (Join-Path $root 'tools/Invoke-DevObserver.ps1') -ObserverArgs @('resume',$session,$scope))
}
[ReflexCore.Bridge.McpServer]::Run($root,$check,$DeveloperTools.IsPresent,$reader)
