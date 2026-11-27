#Requires -Version 5.1
$ErrorActionPreference='Stop'
$source=(Resolve-Path (Join-Path $PSScriptRoot '../tools/ReflexCore-DevGuard.ps1')).Path
. $source
$base=Join-Path ([IO.Path]::GetTempPath()) ('reflex-guard-'+[guid]::NewGuid().ToString('N'))
$a=Join-Path $base 'launcher'
$b=Join-Path $base 'candidate'
$c=Join-Path $base 'unrelated'
[void][IO.Directory]::CreateDirectory($a)
[void][IO.Directory]::CreateDirectory($c)
function GitOk($root,[string[]]$arguments){$output=& git -C $root @arguments;if($LASTEXITCODE){throw 'Git fixture failed'};$output}
function Reject([scriptblock]$operation) {
    try { $null=& $operation } catch { return }
    throw 'An invalid worktree binding was accepted'
}
try{
    GitOk $a @('init','-q','-b','launcher')
    Set-Content -LiteralPath (Join-Path $a 'AGENTS.md') baseline
    GitOk $a @('add','AGENTS.md')
    GitOk $a @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','base')
    $initial=Get-DevGit $a @('rev-parse','HEAD')
    GitOk $a @('worktree','add','-qb','milestone',$b,'HEAD')
    GitOk $c @('init','-q')
    $private=Get-DevGit $a @('rev-parse','--absolute-git-dir')
    $policy=@{version=1;worktrees=@(@{root=$b;branch='milestone'})}
    [IO.File]::WriteAllText((Join-Path $private 'reflex-development-roots-v1.json'),($policy|ConvertTo-Json -Depth 4))
    $bound=Resolve-DevTarget $a @{cwd=$b;branch='milestone'}
    $launcher=Resolve-DevTarget $a @{cwd=$a;branch='launcher'}
    if($bound.private -eq $launcher.private -or $bound.head -cne $launcher.head){throw 'Worktree identity did not separate the shared HEAD'}
    Set-Content -LiteralPath (Join-Path $b 'AGENTS.md') 'operator draft'
    Reject { Resolve-DevTarget $a @{cwd=$b;branch='launcher'} }
    Reject { Resolve-DevTarget $a @{cwd=$c;branch='milestone'} }
    Reject { Resolve-DevTarget $a @{cwd=$b;branch='milestone';historical_head=$initial} }
    Set-Content -LiteralPath (Join-Path $a 'remote.txt') 'one change'
    GitOk $a @('add','remote.txt')
    GitOk $a @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','remote')
    $remote=Get-DevGit $a @('rev-parse','HEAD')
    GitOk $a @('update-ref','refs/remotes/origin/milestone',$remote)
    if((Get-DevRemote $b 'milestone' $initial $false).status -ne 'behind'){throw 'Expected behind'}
    if((Get-DevRemote $a 'milestone' $remote $false).status -ne 'current'){throw 'Expected current'}
    GitOk $b @('add','AGENTS.md')
    GitOk $b @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','local')
    $local=Get-DevGit $b @('rev-parse','HEAD')
    if((Get-DevRemote $b 'milestone' $local $false).status -ne 'diverged'){throw 'Expected divergence'}
    GitOk $a @('update-ref','refs/remotes/origin/milestone',$initial)
    if((Get-DevRemote $b 'milestone' $local $false).status -ne 'ahead'){throw 'Expected ahead'}
    Set-Content -LiteralPath (Join-Path $b 'AGENTS.md') 'unsaved work'
    $changed=Resolve-DevTarget $a @{cwd=$b;branch='milestone'}
    $changed.historical=$true # Exercise the local preflight view without using the network.
    $manifest=Join-Path $a 'plugins/reflexcore/.codex-plugin'
    [void][IO.Directory]::CreateDirectory($manifest)
    [IO.File]::WriteAllText((Join-Path $manifest 'plugin.json'),'{"version":"999.0.0"}')
    [void][IO.Directory]::CreateDirectory((Join-Path $a 'tools'))
    Copy-Item -LiteralPath $source -Destination (Join-Path $a 'tools/ReflexCore-Mcp.cs')
    $pinDir=Join-Path $changed.private 'reflex-observer'
    [void][IO.Directory]::CreateDirectory($pinDir)
    [IO.File]::WriteAllText((Join-Path $pinDir 'active-v2'),'fixture')
    $snapshot=Get-DevPreflight -Target $changed -Launcher $a -Runtime $a
    if(!$snapshot.dirty -or $snapshot.plugin_state -cne 'stale_or_unavailable'){throw 'Dirty or stale plugin state lost'}
    if((Get-Content -LiteralPath (Join-Path $b 'AGENTS.md') -Raw).Trim() -cne 'unsaved work'){throw 'Operator work changed'}
    'PASS: same HEAD isolation, rejected branches and roots, current/behind/diverged/ahead, preserved dirty files.'
}finally{
    $owned=[IO.Path]::GetFullPath($base)
    if([IO.Path]::GetDirectoryName($owned) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and [IO.Path]::GetFileName($owned) -match '^reflex-guard-[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $owned -Recurse -Force
    }
}
