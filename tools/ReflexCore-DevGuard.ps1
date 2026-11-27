#Requires -Version 5.1
function Get-DevHash([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-DevDirectory([string]$Path) {
    if($Path -notmatch '^[a-zA-Z]:[\\/]'){throw 'Expected an absolute local worktree path'}
    $item=Get-Item -LiteralPath ([IO.Path]::GetFullPath($Path)) -Force -ErrorAction Stop
    if(!$item.PSIsContainer){throw 'Expected a directory'}
    $canonical=$item.FullName
    for($part=$item;$part;$part=$part.Parent){
        if($part.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected worktree paths are unsupported'}
    }
    $canonical
}

function Get-DevGit([string]$Root,[string[]]$Arguments) {
    $value=& git -C $Root @Arguments 2>$null
    if($LASTEXITCODE){throw 'Git worktree metadata unavailable'}
    $value
}

function Resolve-DevTarget([string]$Launcher,$Request) {
    $launcherPrivate=Get-DevGit $Launcher @('rev-parse','--absolute-git-dir')
    $requested=if($Request.ContainsKey('cwd')){[string]$Request['cwd']}else{$Launcher}
    $path=[IO.Path]::GetFullPath($requested)
    $approved=@([pscustomobject]@{root=$Launcher;branch=$null})
    $file=Join-Path $launcherPrivate 'reflex-development-roots-v1.json'
    if([IO.File]::Exists($file)){
        if((Get-Item -LiteralPath $file).Length -gt 8192){throw 'Development root configuration exceeds its budget'}
        $policy=Get-Content -Raw -LiteralPath $file|ConvertFrom-Json
        if($policy.version -ne 1 -or @($policy.worktrees).Count -gt 12){throw 'Invalid development root configuration'}
        $approved+=@($policy.worktrees)
    }
    # Lexically restrict the requested directory before touching candidate paths.
    $entry=@($approved | Where-Object {
        $r=[IO.Path]::GetFullPath($_.root).TrimEnd('\')
        $path -eq $r -or $path.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object {$_.root.Length} -Descending | Select-Object -First 1)
    if(!$entry.Count){throw 'Development worktree is outside the configured roots'}
    $cwd=Get-DevDirectory $path
    $root=Get-DevDirectory $entry[0].root
    $metadata=@(Get-DevGit $cwd @('rev-parse','--path-format=absolute','--show-toplevel','--absolute-git-dir','--git-common-dir','HEAD'))
    if($metadata.Count -ne 4 -or (Get-DevDirectory $metadata[0]) -ne $root){throw 'Session directory belongs to a different worktree'}
    $common=Get-DevDirectory $metadata[2]
    $launchCommon=Get-DevGit $Launcher @('rev-parse','--path-format=absolute','--git-common-dir')
    if($common -ne (Get-DevDirectory $launchCommon)){throw 'Configured directory belongs to a different repository'}
    $branch=Get-DevGit $root @('rev-parse','--abbrev-ref','HEAD')
    $wanted=if($Request.ContainsKey('branch')){[string]$Request['branch']}else{$branch}
    if($wanted -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,120}$' -or $wanted.Contains('..')){throw 'Invalid intended branch'}
    if($entry[0].branch -and $entry[0].branch -cne $wanted){throw 'Intended branch differs from the configured branch'}
    $historical=$Request.ContainsKey('historical_head')
    if($historical){
        if($branch -cne 'HEAD' -or $Request['historical_head'] -cne $metadata[3]){throw 'Historical HEAD does not match the detached worktree'}
    }elseif($branch -ceq 'HEAD' -or $branch -cne $wanted){throw 'Current branch differs from the intended development branch'}
    [pscustomobject]@{root=$root;cwd=$cwd;private=(Get-DevDirectory $metadata[1]);common=$common;head=$metadata[3];branch=$wanted;historical=$historical}
}

function Get-DevRemote([string]$Root,[string]$Branch,[string]$Head,[bool]$Refresh) {
    $sha=$null
    $status='unknown'
    if($Refresh){
        $origin=Get-DevGit $Root @('remote','get-url','origin')
        if($origin -cnotmatch '^https://github\.com/triple6xseven/ReflexCore(?:\.git)?$'){return @{revision=$null;status='unknown'}}
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=(Get-Command git.exe).Source
        $start.Arguments="ls-remote --exit-code https://github.com/triple6xseven/ReflexCore.git refs/heads/$Branch"
        $start.WorkingDirectory=$Root
        $start.UseShellExecute=$false
        $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true
        $start.RedirectStandardError=$true
        $start.EnvironmentVariables['GIT_TERMINAL_PROMPT']='0'
        $proc=[Diagnostics.Process]::Start($start)
        try{
            $out=$proc.StandardOutput.ReadToEndAsync()
            $err=$proc.StandardError.ReadToEndAsync()
            if(!$proc.WaitForExit(6000)){
                $proc.Kill()
                return @{revision=$null;status='offline'}
            }
            if($proc.ExitCode -eq 2){return @{revision=$null;status='unknown'}}
            if($proc.ExitCode){return @{revision=$null;status='offline'}}
            if($out.GetAwaiter().GetResult().Trim() -cmatch '^([a-f0-9]{40})\s+refs/heads/[A-Za-z0-9._/-]+$'){$sha=$Matches[1]}
        } finally {$proc.Dispose()}
    }else{
        $candidate=& git -C $Root rev-parse --verify "refs/remotes/origin/$Branch" 2>$null
        if(!$LASTEXITCODE -and $candidate -cmatch '^[a-f0-9]{40}$'){$sha=$candidate}
    }
    if($sha -ceq $Head){$status='current'}
    elseif($sha){
        $counts=& git -C $Root rev-list --left-right --count "$Head...${sha}" 2>$null
        if(!$LASTEXITCODE -and $counts -match '^(\d+)\s+(\d+)$'){
            $status=if($Matches[1] -eq '0'){'behind'}elseif($Matches[2] -eq '0'){'ahead'}else{'diverged'}
        }
    }
    @{revision=$sha;status=$status;source=$(if($Refresh){'remote'}else{'tracking_ref'})}
}

function Get-DevPreflight($Target,[string]$Launcher,[string]$Runtime) {
    $dirty=@(Get-DevGit $Target.root @('status','--porcelain=v1','--untracked-files=normal'))
    $instructions=[ordered]@{}
    $dir=Get-Item -LiteralPath $Target.cwd
    while($dir){
        $path=Join-Path $dir.FullName 'AGENTS.override.md'
        if(!(Test-Path -LiteralPath $path -PathType Leaf)){$path=Join-Path $dir.FullName 'AGENTS.md'}
        if(Test-Path -LiteralPath $path -PathType Leaf){
            $info=Get-Item -LiteralPath $path
            if(($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $info.Length -gt 2097152){throw 'Instruction revision unavailable'}
            $name=$path.Substring($Target.root.Length).TrimStart('\').Replace('\','/')
            $instructions[$name]=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
        }
        if($dir.FullName -eq $Target.root){break}
        $dir=$dir.Parent
    }
    $protocol='reflex.guard.1'
    $pin=Join-Path $Target.private 'reflex-observer/active-v2'
    $manifest=Join-Path $Launcher 'plugins/reflexcore/.codex-plugin/plugin.json'
    $version=(Get-Content -Raw -LiteralPath $manifest|ConvertFrom-Json).version
    $userDir=if($env:CODEX_HOME){$env:CODEX_HOME}else{Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'}
    $installed=Join-Path $userDir "plugins/cache/reflexcore-local/reflexcore/$version/.codex-plugin/plugin.json"
    $plugin=if([IO.File]::Exists($installed) -and (Get-FileHash -LiteralPath $installed).Hash -ceq (Get-FileHash -LiteralPath $manifest).Hash){'matching_cache'}else{'stale_or_unavailable'}
    if($plugin -eq 'matching_cache'){
        $cache=Split-Path (Split-Path $installed -Parent) -Parent
        $source=Join-Path $Launcher 'plugins/reflexcore'
        foreach($skill in 'reflex-continue','reflex-resume','reflex-validate','release-check','offline-lab-evidence'){
            $relative="skills/$skill/SKILL.md"
            $cached=Join-Path $cache $relative
            if(![IO.File]::Exists($cached) -or (Get-FileHash -LiteralPath $cached).Hash -cne (Get-FileHash -LiteralPath (Join-Path $source $relative)).Hash){$plugin='stale_or_unavailable';break}
        }
    }
    $globalInstruction=Join-Path $userDir 'AGENTS.override.md'
    if(![IO.File]::Exists($globalInstruction)){$globalInstruction=Join-Path $userDir 'AGENTS.md'}
    $runtimeExecutable=Join-Path $Runtime 'target/release/reflexcore.exe'
    @{
        repository='triple6xseven/ReflexCore'
        repository_key=(Get-DevHash $Target.common)
        cwd_key=(Get-DevHash $Target.cwd)
        dirty=($dirty.Count -gt 0)
        instructions=$instructions
        global_instructions=$(if([IO.File]::Exists($globalInstruction)){(Get-FileHash -LiteralPath $globalInstruction).Hash.ToLowerInvariant()})
        mcp_implementation=(Get-FileHash -LiteralPath (Join-Path $Launcher 'tools/ReflexCore-Mcp.cs')).Hash.ToLowerInvariant()
        observer_protocol=$protocol
        observer_implementation=[IO.File]::ReadAllText($pin).ToLowerInvariant()
        plugin_version=$version
        plugin_state=$plugin
        runtime_key=(Get-DevHash $Runtime)
        runtime_head=(& git -C $Runtime rev-parse HEAD 2>$null)
        runtime_executable=$(if([IO.File]::Exists($runtimeExecutable)){(Get-FileHash -LiteralPath $runtimeExecutable).Hash.ToLowerInvariant()})
        remote=(Get-DevRemote -Root $Target.root -Branch $Target.branch -Head $Target.head -Refresh (!$Target.historical))
    }
}
