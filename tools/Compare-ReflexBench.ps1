# Compare recent verified benchmark sessions for the SAME exact fixture.
param([switch]$SelfTest)
$ErrorActionPreference='Stop'
$base=Join-Path $env:LOCALAPPDATA 'ReflexCore\diagnostics\measurement-lab'
if($SelfTest){
    $a=1000.0;$b=900.0
    if([Math]::Round(100.0*($b-$a)/$a,1) -ne -10){throw 'Comparison arithmetic failed'}
    Write-Host '[ReflexCore] Benchmark comparison self-test passed.'
    return
}
if(-not (Test-Path -LiteralPath $base)){Write-Host '[ReflexCore] No sessions yet.';return}
$records=@(Get-ChildItem -LiteralPath $base -Filter 'session-*.json' -File |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 30 | ForEach-Object {
        try{Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
    } | Where-Object {$_.schema -eq 'reflexcore.benchmark.session.v1'})
if($records.Count -lt 2){Write-Host '[ReflexCore] Two completed sessions are needed for comparison.';return}
$new=$records[0]
$old=@($records|Where-Object {$_.session -ne $new.session -and $_.task -eq $new.task -and $_.fixture_sha256 -eq $new.fixture_sha256}|Select-Object -First 1)
if($old.Count -eq 0){Write-Host '[ReflexCore] Fixture changed or no comparable previous session; do not compare numbers.';return}
$old=$old[0]
Write-Host ('[ReflexCore] Same-task benchmark: '+$new.task)
Write-Host ('[ReflexCore] Before: success='+$old.success+'/'+$old.measured_runs+', p50='+$old.p50_ms+' ms, p95='+$old.p95_ms+' ms')
Write-Host ('[ReflexCore] After:  success='+$new.success+'/'+$new.measured_runs+', p50='+$new.p50_ms+' ms, p95='+$new.p95_ms+' ms')
if($old.success -eq $old.measured_runs -and $new.success -eq $new.measured_runs -and
   $null -ne $old.p50_ms -and [double]$old.p50_ms -gt 0 -and $null -ne $new.p50_ms){
    $pct=[Math]::Round(100*([double]$new.p50_ms-[double]$old.p50_ms)/[double]$old.p50_ms,2)
    $direction=if($pct -lt 0){'faster'}elseif($pct -gt 0){'slower'}else{'unchanged'}
    Write-Host ('[ReflexCore] p50 change = '+$pct+'% ('+$direction+'); negative is faster.')
}else{
    Write-Warning 'Failures or missing medians prevent a reliable speed comparison.'
}
if($new.measured_runs -lt 5 -or $old.measured_runs -lt 5){Write-Warning 'Use >=5 measured runs per session; small samples have high variance.'}
if($new.rust_sha256 -eq $old.rust_sha256){Write-Host '[ReflexCore] Same Rust executable hash: changes may be warm-cache/system load, not a code optimization.'}
Write-Host '[ReflexCore] This does not measure Qwen intelligence, token throughput or Windows cursor use.'
