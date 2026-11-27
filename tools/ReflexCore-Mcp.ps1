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
. (Join-Path $PSScriptRoot 'ReflexCore-DevGuard.ps1')
$check = [Func[string]]{
    $record = & (Join-Path $root 'tools/Measure-DevBuild.ps1') -Action Check
    return $record
}
$reader = [Func[string,string,string,System.Collections.Generic.Dictionary[string,object],string]]{
    param($name,$session,$scope,$request)
    if($name -eq 'get_usage_status'){
        $action=if($session -eq 'refresh'){'Usage'}else{'Cached'}
        return (& (Join-Path $root 'tools/Read-DevUsage.ps1') -Action $action)
    }
    if(!$request.ContainsKey('cwd') -or !$request.ContainsKey('branch')){
        throw [ArgumentException]::new('Provide the active session cwd and intended branch for development recovery.')
    }
    foreach($key in 'cwd','branch','preflight','historical_head'){
        if($request.ContainsKey($key) -and ($request[$key] -isnot [string] -or $request[$key].Length -gt 512)){
            throw [ArgumentException]::new('Invalid development binding.')
        }
    }
    if($request.ContainsKey('preflight') -and $request['preflight'] -cne 'yes'){
        throw [ArgumentException]::new('Use preflight=yes at a development boundary.')
    }
    try {
        $target=Resolve-DevTarget $root $request
        $launcherPin=Join-Path (Get-DevGit $root @('rev-parse','--absolute-git-dir')) 'reflex-observer/active-v2'
        $targetPin=Join-Path $target.private 'reflex-observer/active-v2'
        if([IO.File]::ReadAllText($launcherPin) -cne [IO.File]::ReadAllText($targetPin)){throw 'Installed observer differs from the launcher observer'}
        $observerArguments=@('resume',$session,$scope)
        if($request.ContainsKey('memory_topic')){
            $topic=$request['memory_topic']
            if($topic -isnot [string] -or $topic -cnotmatch '^[A-Za-z0-9-]{1,64}$'){throw 'Invalid engineering memory topic'}
            $operation='recall'
            if($request.ContainsKey('memory_history')){
                if($request['memory_history'] -cne 'yes'){throw 'Use memory_history=yes to request historical records'}
                $operation='recall-history'
            }
            $observerArguments=@($operation,$topic,$scope)
            if($request.ContainsKey('since_commit')){
                if($request['since_commit'] -isnot [string] -or $request['since_commit'] -cnotmatch '^[a-f0-9]{40}$'){throw 'Invalid comparison commit'}
                $observerArguments+=@($request['since_commit'])
            }
        }elseif($request.ContainsKey('since_commit') -or $request.ContainsKey('memory_history')){
            throw 'A comparison commit requires a memory topic'
        }
        $packet = & (Join-Path $root 'tools/Invoke-DevObserver.ps1') -Worktree $target.root -RequireGuard -ObserverArgs $observerArguments | ConvertFrom-Json
        $expectedTree=Get-DevHash ('\\?\'+$target.private)
        if($packet.tree -and $packet.tree -cne $expectedTree){throw 'Observer returned a foreign worktree identity'}
        $scopeInfo=@{tree=$expectedTree;head=$target.head;branch=$target.branch;historical=$target.historical}
        $packet | Add-Member -NotePropertyName binding -NotePropertyValue $scopeInfo
        if(!$request.ContainsKey('memory_topic') -and $name -in 'get_development_context','get_validation_evidence'){
            $evidence=$null
            try { $evidence=& (Join-Path $root 'tools/Measure-DevBuild.ps1') -Action Check -Worktree $target.root | ConvertFrom-Json } catch {}
            if(!$evidence){$evidence=@{build='unknown';worktree_recovery_test='unknown'}}
            $packet | Add-Member -NotePropertyName release_build -NotePropertyValue $evidence.build
            $packet | Add-Member -NotePropertyName worktree_recovery_test -NotePropertyValue $evidence.worktree_recovery_test
        }
        if($request['preflight'] -ceq 'yes'){
            $scopeInfo.preflight=Get-DevPreflight -Target $target -Launcher $root -Runtime $RuntimeRoot
        }
        $current=Resolve-DevTarget $root $request
        if($current.private -ne $target.private -or $current.head -cne $target.head -or $current.branch -cne $target.branch){throw 'Worktree changed during recovery'}
    } catch {
        $message=$_.Exception.Message
        if($message -notmatch '^(Development worktree|Current branch|Historical HEAD|Intended branch|Configured directory|Session directory|Installed observer|Observer returned|Worktree changed)'){ $message='Development binding, observer or evidence unavailable.' }
        throw [ArgumentException]::new($message)
    }
    $private=$target.private
    if($packet.pending_ci.run_id -or $packet.session_key){
        if($private){
            if($packet.pending_ci.run_id){
                $path=Join-Path $private 'reflex-ci-observations-v1.json'
                try {
                    if((Get-Item -LiteralPath $path -ErrorAction Stop).Length -le 8192){
                        $observations=Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
                        $entry=@($observations.runs | Where-Object {$_.id -ceq $packet.pending_ci.run_id -and $_.commit -ceq $packet.pending_ci.commit -and $_.attempt -eq 1})
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
            if($packet.session_key -cmatch '^[a-f0-9]{64}$'){
                $path=Join-Path $private ('reflex-managed-turns/'+$packet.session_key+'.json')
                try {
                    if((Get-Item -LiteralPath $path -ErrorAction Stop).Length -le 2048){
                        $receipt=Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
                         . (Join-Path $PSScriptRoot 'ReflexCore-ManagedEvents.ps1')
                        if($receipt.v -eq 1 -and $receipt.thread -cmatch '^[a-zA-Z0-9-]{1,64}$' -and (Get-ReflexManagedKey $receipt.thread) -ceq $packet.session_key){
                            $packet | Add-Member -NotePropertyName managed_turn -NotePropertyValue $receipt
                        }
                    }
                } catch {}
            }
        }
    }
    return ($packet|ConvertTo-Json -Depth 9 -Compress)
}
$runtimeCheck=[Func[string]]{
    & (Join-Path $root 'tools/Measure-DevBuild.ps1') -Action Check -Worktree $RuntimeRoot
}
[ReflexCore.Bridge.McpServer]::Run($RuntimeRoot,$check,$DeveloperTools.IsPresent,$reader,$separateRuntime,$runtimeCheck)
