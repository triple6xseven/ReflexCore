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
    $packet = & (Join-Path $root 'tools/Invoke-DevObserver.ps1') -ObserverArgs @('resume',$session,$scope) | ConvertFrom-Json
    if($packet.pending_ci.run_id -or $session -ne 'auto'){
        Push-Location $root
        try {$private=& git rev-parse --absolute-git-dir 2>$null}finally{Pop-Location}
        if($private){
            if($packet.pending_ci.run_id){
                $path=Join-Path $private 'reflex-ci-observations-v1.json'
                try {
                    if((Get-Item -LiteralPath $path -ErrorAction Stop).Length -le 8192){
                        $observations=Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
                        $entry=@($observations.runs | Where-Object {$_.id -ceq $packet.pending_ci.run_id -and $_.commit -ceq $packet.pending_ci.commit})
                        if($observations.repo -ceq 'triple6xseven/ReflexCore' -and $entry.Count -eq 1 -and $entry[0].attempt -gt 0){
                            $status=switch($entry[0].status){
                                'in_progress' {'pending'}
                                'queued' {'pending'}
                                'completed' {
                                    switch($entry[0].conclusion){'success' {'successful'} 'failure' {'failed'} default {'unknown'}}
                                }
                                default {'unknown'}
                            }
                            $packet.pending_ci.outcome=$status
                            $packet.pending_ci | Add-Member -NotePropertyName attempt -NotePropertyValue ([int]$entry[0].attempt)
                        }
                    }
                } catch {}
            }
            if($session -ne 'auto'){
                $path=Join-Path $private 'reflex-managed-turn-v1.json'
                try {
                    if((Get-Item -LiteralPath $path -ErrorAction Stop).Length -le 2048){
                        $receipt=Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
                        if($receipt.v -eq 1 -and $receipt.thread -ceq $session){
                            $packet | Add-Member -NotePropertyName managed_turn -NotePropertyValue $receipt
                        }
                    }
                } catch {}
            }
        }
    }
    return ($packet|ConvertTo-Json -Depth 9 -Compress)
}
[ReflexCore.Bridge.McpServer]::Run($RuntimeRoot,$check,$DeveloperTools.IsPresent,$reader,$separateRuntime)
