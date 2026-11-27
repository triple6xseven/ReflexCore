#Requires -Version 5.1
$ErrorActionPreference='Stop'
$exe=(Resolve-Path (Join-Path $PSScriptRoot '../target/release/reflex-observer.exe')).Path
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('reflex-memory-'+[guid]::NewGuid().ToString('N'))
$a=Join-Path $fixture 'primary'
$b=Join-Path $fixture 'other'
[void][IO.Directory]::CreateDirectory($a)
function GitOk([string[]]$a) { & git @a | Out-Null; if($LASTEXITCODE){throw 'Fixture Git failed'} }
function Memory { $r=& $exe @args; if($LASTEXITCODE){throw 'Observer failed'}; $r|ConvertFrom-Json }
function Require($condition,$message) {if(!$condition){throw $message}}
Push-Location $a
try {
 GitOk @('init','-q','-b','fixture')
 New-Item -ItemType Directory docs|Out-Null
 Set-Content docs/UNIVERSAL-SKILL-RUNTIME.md 'Independent postconditions'
 Set-Content docs/BENCHMARKS.md 'Synthetic legacy measurement'
 GitOk @('add','docs')
 GitOk @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','initial')
 $base=& git rev-parse HEAD
 $null=Memory remember proof universal decision 'Require independent postconditions.' docs/UNIVERSAL-SKILL-RUNTIME.md
 $null=Memory remember perf universal performance 'Legacy timing used a different environment.' docs/BENCHMARKS.md
 $db=Join-Path (git rev-parse --absolute-git-dir) 'reflex-engineering-memory-v1.sqlite'
 $sizeBefore=(Get-Item -LiteralPath $db).Length
 Set-Content README.md 'Unrelated update'
 GitOk @('add','README.md')
 GitOk @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','unrelated')
 $watch=[Diagnostics.Stopwatch]::StartNew()
 $packet=Memory recall proof universal $base
 $watch.Stop()
 Require ($packet.records[0].status -ceq 'active' -and $packet.records[0].commit -ceq $base) 'Cross-commit decision was not recovered'
 Require ($packet.changes.affected.Count -eq 0) 'Unrelated commit invalidated the component'
 $lookup=[math]::Round($watch.Elapsed.TotalMilliseconds,1)
 $payload=[Text.Encoding]::UTF8.GetByteCount(($packet|ConvertTo-Json -Depth 10 -Compress))
 Set-Content docs/UNIVERSAL-SKILL-RUNTIME.md 'Revised postconditions'
 Set-Content docs/BENCHMARKS.md 'New measurements'
 $watch.Restart()
 $stale=Memory recall proof universal
 $watch.Stop()
 Require ($stale.records[0].status -ceq 'stale') 'Dirty dependency was accepted'
 $invalidation=[math]::Round($watch.Elapsed.TotalMilliseconds,1)
 Require ((Memory recall perf universal).records[0].status -ceq 'historical') 'Old measurements lost historical status'
 $null=Memory remember proof universal decision 'Require a typed independent verifier.' docs/UNIVERSAL-SKILL-RUNTIME.md
 $records=(Memory recall proof universal).records
 Require ($records.Count -eq 2 -and $records[0].status -ceq 'active' -and $records[1].status -ceq 'superseded') 'Superseded reasoning was not retained'
 GitOk @('worktree','add','-qb','isolated',$b,'HEAD')
 Push-Location $b
 try {
    Require ((Memory recall proof universal).records.Count -eq 0) 'Foreign memory leaked'
    GitOk @('checkout','-q','--ignore-other-worktrees','fixture')
    Require ((Memory recall proof universal).records.Count -eq 0) 'Shared branch leaked worktree memory'
    Require ((Memory recall-history proof universal).records[0].status -ceq 'historical') 'Foreign worktree record was not treated as history'
    $null=Memory remember proof universal decision 'Keep this as a distinct observation.' docs/UNIVERSAL-SKILL-RUNTIME.md
 }finally{Pop-Location}
 GitOk @('add','docs')
 GitOk @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','affected')
 $history=(Memory recall-history proof universal).records
 Require ($history[0].status -ceq 'historical' -and $history[1].status -ceq 'active') 'Foreign history superseded the local decision'
 $changes=(Memory recall proof universal $base).changes
 Require ($changes.affected -contains 'docs/UNIVERSAL-SKILL-RUNTIME.md' -and $changes.commits.Count -eq 1) 'Scoped commit range lost changed component evidence'
 $sizeAfter=(Get-Item -LiteralPath $db).Length
 [pscustomobject]@{result='pass';lookup_ms=$lookup;invalidation_ms=$invalidation;response_bytes=$payload;database_bytes_before=$sizeBefore;database_bytes_after=$sizeAfter}|ConvertTo-Json -Compress
}finally{
 Pop-Location
 $owned=[IO.Path]::GetFullPath($fixture)
 if([IO.Path]::GetDirectoryName($owned) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and [IO.Path]::GetFileName($owned) -match '^reflex-memory-[a-f0-9]{32}$'){Remove-Item -LiteralPath $owned -Recurse -Force}
}
