param([switch]$DeveloperTools,[string]$RuntimeRoot)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Split-Path $PSScriptRoot -Parent)).Path
$separateRuntime=[bool]$RuntimeRoot
if($separateRuntime){
    $RuntimeRoot=(Resolve-Path -LiteralPath $RuntimeRoot).Path
    if(!(Test-Path -LiteralPath (Join-Path $RuntimeRoot 'tools/ReflexCore-Mcp.ps1') -PathType Leaf)){throw 'Runtime installation unavailable'}
}else{$RuntimeRoot=$root}
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Add-Type -Path @((Join-Path $PSScriptRoot 'ReflexCore-Queue.cs'),(Join-Path $PSScriptRoot 'ReflexCore-Mcp.cs'),(Join-Path $PSScriptRoot 'ReflexCore-McpLab.cs')) -ReferencedAssemblies 'System.Core.dll','System.Web.Extensions.dll'
$check = [Func[string]]{
    $record = & (Join-Path $root 'tools/Measure-DevBuild.ps1') -Action Check
    return $record
}
$reader = [Func[string,string,string,string]]{
    param($name,$session,$scope)
    if($name -eq 'get_usage_status'){
        $action=if($session -eq 'refresh'){'Usage'}else{'Cached'}
        return (& (Join-Path $root 'tools/Read-DevUsage.ps1') -Action $action)
    }
    return (& (Join-Path $root 'tools/Invoke-DevObserver.ps1') -ObserverArgs @('resume',$session,$scope))
}
[ReflexCore.Bridge.McpServer]::Run($RuntimeRoot,$check,$DeveloperTools.IsPresent,$reader,$separateRuntime)
