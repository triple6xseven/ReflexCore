#Requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$exe=(Resolve-Path (Join-Path $repo 'target/release/reflex-observer.exe')).Path
. (Join-Path $repo 'tools/ReflexCore-DevGuard.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('reflex-durable-'+[guid]::NewGuid().ToString('N'))
$up=Join-Path $fixture 'remote'
$local=Join-Path $fixture 'clone'
[void][IO.Directory]::CreateDirectory($up)
function GitOk([string[]]$parameters){$r=& git @parameters;if($LASTEXITCODE){throw 'Git fixture failed'};$r}
function Commit([string]$root,[string]$message){
    GitOk @('-C',$root,'add','.')|Out-Null
    GitOk @('-C',$root,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm',$message)|Out-Null
}
function Require($ok,$message){if(!$ok){throw $message}}
function Recall {
    Push-Location $local
    try {$raw=& $exe recall policy bridge;if($LASTEXITCODE){throw 'Observer failed'};$raw|ConvertFrom-Json}
    finally{Pop-Location}
}
try{
    GitOk @('-C',$up,'init','-q','-b','milestone')|Out-Null
    [void][IO.Directory]::CreateDirectory((Join-Path $up 'docs'))
    [IO.File]::WriteAllText((Join-Path $up 'docs/CODEX-INTEGRATION.md'),'Recovery is independent of the current runtime.')
    Commit $up 'decision source'
    $base=GitOk @('-C',$up,'rev-parse','HEAD')
    $record=@{id='policy-01';component='bridge';topic='policy';kind='decision';statement='Pin the observer';rationale='Recovery survives failed runtime builds.';
       reference='docs/CODEX-INTEGRATION.md';commit=$base;dependencies=@('docs/CODEX-INTEGRATION.md');created='2026-11-28';validated='2026-11-28'}
    [IO.File]::WriteAllText((Join-Path $up 'docs/engineering-knowledge.json'),(@{schema=1;records=@($record)}|ConvertTo-Json -Depth 5))
    Commit $up 'durable record'
    GitOk @('clone','-q','--no-local',$up,$local)|Out-Null
    $head=GitOk @('-C',$local,'rev-parse','HEAD')
    $tracking=GitOk @('-C',$local,'rev-parse','refs/remotes/origin/milestone')
    $time=[Diagnostics.Stopwatch]::StartNew()
    $packet=Recall
    $cold=$time.ElapsedMilliseconds
    Require ($packet.knowledge[0].status -ceq 'active' -and $packet.knowledge[0].commit -ceq $base) 'Fresh clone did not recover original rationale'
    $index=Join-Path $local '.git/reflex-knowledge-index-v1.sqlite'
    Remove-Item -LiteralPath $index
    Require ((Recall).knowledge[0].rationale -ceq $record.rationale) 'Deleted index did not rebuild'
    $time.Restart()
    $null=Recall
    $warm=$time.ElapsedMilliseconds
    [IO.File]::WriteAllText((Join-Path $up 'docs/CODEX-INTEGRATION.md'),'New contract')
    Commit $up 'advance only the remote'
    $remote=GitOk @('-C',$up,'rev-parse','HEAD')
    [IO.File]::WriteAllText((Join-Path $local 'docs/CODEX-INTEGRATION.md'),'Uncommitted operator draft.')
    Require ((Recall).knowledge[0].status -ceq 'stale') 'Changed dependency remained active'
    $fetch=Get-DevAncestry $local 'milestone' $head $remote ([Uri]::new($up).AbsoluteUri)
    Require ($fetch.fetched -and $fetch.status -ceq 'behind' -and $fetch.introduced[0] -ceq $remote -and $fetch.affected_components -contains 'contracts') 'Unknown remote object did not reconcile'
    Require ((GitOk @('-C',$local,'rev-parse','HEAD')) -ceq $head) 'Fetch changed checkout HEAD'
    Require ((GitOk @('-C',$local,'rev-parse','refs/remotes/origin/milestone')) -ceq $tracking) 'Fetch changed a tracking ref'
    Require ([IO.File]::ReadAllText((Join-Path $local 'docs/CODEX-INTEGRATION.md')) -ceq 'Uncommitted operator draft.') 'Fetch overwrote dirty file'
    [pscustomobject]@{result='pass';cold_ms=$cold;warm_ms=$warm;bytes=[Text.Encoding]::UTF8.GetByteCount(($packet|ConvertTo-Json -Depth 9 -Compress));index_bytes=(Get-Item -LiteralPath $index).Length}|ConvertTo-Json -Compress
}finally{
    $owned=[IO.Path]::GetFullPath($fixture)
    if([IO.Path]::GetDirectoryName($owned) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and [IO.Path]::GetFileName($owned) -match '^reflex-durable-[a-f0-9]{32}$'){Remove-Item -LiteralPath $owned -Recurse -Force}
}
