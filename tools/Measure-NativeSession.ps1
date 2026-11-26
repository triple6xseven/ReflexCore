# Interactive comparison on one local desktop. Keep the original four-action
# Goal benchmark and change only the worker policy within each fixture length.
param([switch]$AllowVisibleUI,[switch]$Quick)
$ErrorActionPreference='Stop'
if(!$AllowVisibleUI){throw 'Use -AllowVisibleUI on an unlocked Windows desktop.'}
$ids=@()
$lengths=if($Quick){@(4)}else{@(4,1,20,100)}
$modes=if($Quick){@("disposable","session")}else{@("disposable","session","session","disposable")}
foreach($actions in $lengths){
    $runs=if(!$Quick -and $actions -eq 4){15}else{1}
    foreach($mode in $modes){
        $id=& (Join-Path $PSScriptRoot 'Run-ReflexBenchmark.ps1') -AllowVisibleUI -Actions $actions -Worker $mode -Runs $runs -Warmups 1 -PassThru
        if($LASTEXITCODE -or $id -cnotmatch '^[0-9a-f]{16}$'){throw "Incomplete $mode benchmark at $actions actions"}
        $ids+=$id
        Write-Host ("Session {0}: {1}, {2} actions" -f $id,$mode,$actions)
    }
}
& (Join-Path $PSScriptRoot 'Compare-NativeSession.ps1') -Sessions $ids | ConvertTo-Json -Depth 4
