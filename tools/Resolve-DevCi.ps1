#Requires -Version 5.1
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[1-9][0-9]{0,19}$')][string]$RunId,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{40}$')][string]$Commit,
    [ValidateRange(1,1000)][int]$Attempt=1
)
$ErrorActionPreference='Stop'
$repo='triple6xseven/ReflexCore'
$observed=Invoke-RestMethod "https://api.github.com/repos/$repo/actions/runs/$RunId/attempts/$Attempt" -TimeoutSec 12
if([string]$observed.id -cne $RunId -or $observed.head_sha -cne $Commit -or
    $observed.repository.full_name -cne $repo -or $observed.run_attempt -ne $Attempt){
    throw 'The response does not match the requested repository, commit, run, and attempt.'
}
$root=Split-Path $PSScriptRoot -Parent
$private=& git -C $root rev-parse --absolute-git-dir
if($LASTEXITCODE){throw 'Development worktree unavailable'}
$path=Join-Path $private 'reflex-ci-observations-v1.json'
$entry=[ordered]@{id=$RunId;commit=$Commit;attempt=$Attempt;status=$observed.status;conclusion=$observed.conclusion;observed_utc=[datetime]::UtcNow.ToString('o')}
$pin=[IO.File]::Open($path+'.lock','OpenOrCreate','Write','None')
$tmp=$path+'.'+[guid]::NewGuid().ToString('N')
try{
    $prior=@()
    if([IO.File]::Exists($path)){
        if((Get-Item -LiteralPath $path).Length -gt 8192){throw 'CI snapshot exceeds its budget'}
        $ledger=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json
        if($ledger.repo -cne $repo){throw 'Foreign CI snapshot'}
        $prior=@($ledger.runs | Where-Object {$_.id -cne $RunId -or $_.attempt -ne $Attempt} | Select-Object -First 23)
    }
    $data=[ordered]@{repo=$repo;runs=@($entry)+$prior}
    [IO.File]::WriteAllText($tmp,($data|ConvertTo-Json -Depth 5 -Compress))
    if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,($path+'.previous'))}
    else{[IO.File]::Move($tmp,$path)}
}finally{
    if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}
    $pin.Dispose()
}
$entry|ConvertTo-Json -Compress
