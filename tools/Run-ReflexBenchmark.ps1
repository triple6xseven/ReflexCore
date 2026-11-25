# ReflexCore Measurement Lab 0.6.1 — repeatable, verified Windows UIA goal benchmark.
# Uses `reflexcore.exe agent demo --execute` and a run-scoped Flow report.
# Does not measure Qwen. Never captures/screenshots/logs window text or model output.
# The benchmark is opt-in because it temporarily opens and controls a known fixture window.
param(
    [ValidateRange(1,50)][int]$Runs=5,
    [ValidateRange(0,5)][int]$Warmups=1,
    [ValidateRange(15,180)][int]$TimeoutSeconds=90,
    [ValidateSet(1,4,20,100)][int]$Actions=4,
    [ValidateSet('disposable','session')][string]$Worker='disposable',
    [switch]$AllowVisibleUI,
    [switch]$SelfTest
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
$binary=Join-Path $root 'target\release\reflexcore.exe'
$fixture=Join-Path $root 'tools\ReflexCore-Fixture.ps1'
$flowFixture=Join-Path $root 'examples\smoke_flow.json'
$goalFixture=Join-Path $root 'examples\goal_agent_demo.json'
$base=Join-Path $env:LOCALAPPDATA 'ReflexCore\diagnostics\measurement-lab'
$runDir=Join-Path $base 'runs'
$history=Join-Path $base 'history.jsonl'
$progress=Join-Path $base 'progress.json'
$schema='reflexcore.benchmark.run.v1'
$task='windows-uia-fixture-goal-v1'
$utf8=New-Object System.Text.UTF8Encoding($false)
$stopSignal=Join-Path $root 'data\bridge\global-stop.signal'
$stopBaseline=if(Test-Path $stopSignal){(Get-Item $stopSignal).LastWriteTimeUtc}else{[DateTime]::MinValue}
function New-GlobalStop {return ((Test-Path $stopSignal) -and ((Get-Item $stopSignal).LastWriteTimeUtc -gt $stopBaseline))}
function Assert-File([string]$path) {
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ('Required file missing: '+(Split-Path $path -Leaf))}
}
function Get-Hash([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()}
function Write-JsonAtomic([string]$path,[object]$value){
    $parent=Split-Path $path -Parent
    if(-not(Test-Path -LiteralPath $parent)){[void](New-Item -ItemType Directory -Path $parent -Force)}
    $tmp=$path+'.reflex-tmp-'+[Guid]::NewGuid().ToString('N')
    $text=ConvertTo-Json -InputObject $value -Depth 15 -Compress
    try{
        [IO.File]::WriteAllText($tmp,$text,$utf8)
        if([IO.File]::Exists($path)){
            # File.Replace backup parameter must be a real path (not null) on Windows PowerShell 5.1.
            $safeBackup=$tmp+'.backup'
            try{[IO.File]::Replace($tmp,$path,$safeBackup)}finally{
                if([IO.File]::Exists($safeBackup)){[IO.File]::Delete($safeBackup)}
            }
        }else{[IO.File]::Move($tmp,$path)}
    }finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
}
function Read-Json([string]$path){
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try{return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)}catch{return $null}
}
function Read-RunReport([string]$path,[string]$runId){
    $report=Read-Json $path
    if($null -eq $report -or !$report.PSObject.Properties['schema'] -or !$report.PSObject.Properties['run_id']){return $null}
    if($report.schema -ceq 'reflexcore.flow.execution.v1' -and $report.run_id -ceq $runId){return $report}
    return $null
}
function Pctl([double[]]$numbers,[double]$q){
    if($numbers.Count -eq 0){return $null}
    $sorted=@($numbers|Sort-Object)
    return [Math]::Round([double]$sorted[[int][Math]::Max(0,[Math]::Ceiling($sorted.Count*$q)-1)],2)
}
function Write-Stage([string]$stage,[int]$iteration,[bool]$warmup,[int]$elapsed){
    Write-JsonAtomic $progress ([ordered]@{
        schema='reflexcore.benchmark.progress.v1';task=$task;session=$script:session
        stage=$stage;iteration=$iteration;total=$Runs;warmup=$warmup;elapsed_ms=$elapsed
        updated_utc=[DateTime]::UtcNow.ToString('o')
    })
}
foreach($file in @($binary,$fixture,$flowFixture,$goalFixture)){Assert-File $file}
$goal=Read-Json $goalFixture
$flow=Read-Json $flowFixture
if($null -eq $goal -or $goal.schema -ne 'reflexcore.goal.v1' -or $goal.skills.Count -ne 1 -or $goal.skills[0].flow -ne 'demo'){
    throw 'Goal fixture schema changed; revalidate benchmark before comparing durations.'
}
if($null -eq $flow -or $flow.schema -ne 'reflexcore.flow.v1' -or $flow.steps.Count -ne 4){
    throw 'UIA fixture schema changed; revalidate benchmark before comparing durations.'
}
$fixtureKey=('{0}:{1}:{2}' -f (Get-Hash $fixture),(Get-Hash $flowFixture),(Get-Hash $goalFixture))
$fixtureHashBytes=[Text.Encoding]::UTF8.GetBytes($fixtureKey)
if($Actions -ne 4){
    $task="windows-uia-fixture-$Actions-actions-v1"
    $fixtureHashBytes=[Text.Encoding]::UTF8.GetBytes("$fixtureKey/$Actions")
}
$sha=[Security.Cryptography.SHA256]::Create()
try {$fixtureHash=([BitConverter]::ToString($sha.ComputeHash($fixtureHashBytes))).Replace('-','')}
finally {$sha.Dispose()}
if($SelfTest){
    if((Pctl -numbers ([double[]]@(8,2,5,12,1)) -q 0.5) -ne 5){throw 'Pctl median test failed'}
    $reportPath=[IO.Path]::GetTempFileName()
    try {
        $id=[Guid]::NewGuid().ToString('N')
        $other=[Guid]::NewGuid().ToString('N')
        Write-JsonAtomic $reportPath @{schema='reflexcore.flow.execution.v1';run_id=$other}
        if($null -ne (Read-RunReport $reportPath $id)){throw 'An unrelated run was accepted'}
        if($null -eq (Read-RunReport $reportPath $other)){throw 'The matching run was rejected'}
        [IO.File]::WriteAllText($reportPath,'{')
        if($null -ne (Read-RunReport $reportPath $id)){throw 'A truncated report was accepted'}
    } finally {[IO.File]::Delete($reportPath)}
    Write-Host '[ReflexCore] Measurement Lab fixture, hashes and run correlation passed.'
    exit 0
}
if(-not $AllowVisibleUI){
    throw 'Visible Windows test requires explicit -AllowVisibleUI; it opens and operates ONLY the ReflexCore Test Window.'
}
$script:session=[Guid]::NewGuid().ToString('N').Substring(0,16)
if(-not(Test-Path -LiteralPath $runDir)){[void](New-Item -ItemType Directory -Path $runDir -Force)}
$binaryHash=Get-Hash $binary
$values=New-Object 'System.Collections.Generic.List[double]'
$ok=0
$failed=0
function Execute-One([int]$iteration,[bool]$warmup){
    $runId=[Guid]::NewGuid().ToString('N')
    $startUtc=[DateTime]::UtcNow
    $flowReport=Join-Path $root "data/benchmark-runs/$runId.json"
    $proc=New-Object Diagnostics.Process
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$binary
    $info.Arguments='agent demo --execute'
    if($Actions -ne 4){$info.Arguments="flow measure-fixture --execute $Actions"}
    $info.WorkingDirectory=$root
    $info.EnvironmentVariables["REFLEXCORE_BENCHMARK_RUN_ID"]=$runId
    $info.EnvironmentVariables["REFLEXCORE_UIA_WORKER"]=$Worker
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardInput=$false
    $info.RedirectStandardOutput=$false
    $info.RedirectStandardError=$false
    $proc.StartInfo=$info
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $samples=New-Object 'System.Collections.Generic.List[object]'
    $cpuMs=0.0;$peakPrivate=0.0;$peakWorking=0.0
    $exitCode=$null;$reason='UNKNOWN';$timedOut=$false;$stopped=$false
    $flowData=$null;$verified=$false
    Write-Stage 'running_goal' $iteration $warmup 0
    try{
        if(-not $proc.Start()){throw 'Rust goal agent process refused to start'}
        do{
            if($proc.WaitForExit(150)){break}
            if(New-GlobalStop){
                $stopped=$true
                # Cancel only the subprocess launched by this benchmark, including its fixture.
                try{& taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null}catch{}
                try{if(-not $proc.HasExited){$proc.Kill()}}catch{}
                break
            }
            $proc.Refresh()
            try{
                $cpuMs=$proc.TotalProcessorTime.TotalMilliseconds
                $private=[Math]::Round($proc.PrivateMemorySize64/1MB,2)
                $working=[Math]::Round($proc.WorkingSet64/1MB,2)
                $peakPrivate=[Math]::Max($peakPrivate,$private)
                $peakWorking=[Math]::Max($peakWorking,$working)
                $samples.Add([ordered]@{t_ms=[Math]::Round($watch.Elapsed.TotalMilliseconds,1);cpu_total_ms=[Math]::Round($cpuMs,2);private_mb=$private;working_mb=$working})
            }catch{} # Process may have exited between WaitForExit and Refresh.
            if($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds){
                $timedOut=$true
                # Kill only this benchmark-owned process tree, including its test fixture.
                try{& taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null}catch{}
                try{if(-not $proc.HasExited){$proc.Kill()}}catch{}
                break
            }
        }while($true)
        if($timedOut -or $stopped){[void]$proc.WaitForExit(2500)}
        $watch.Stop()
        if($proc.HasExited){$exitCode=$proc.ExitCode}
        try{
            $proc.Refresh()
            $cpuMs=$proc.TotalProcessorTime.TotalMilliseconds
            $peakWorking=[Math]::Max($peakWorking,[Math]::Round($proc.PeakWorkingSet64/1MB,2))
        }catch{}
        # The report is written by the real Flow engine, not fabricated by the benchmark.
        $flowData=Read-RunReport $flowReport $runId
        $matched=$null -ne $flowData
        $verified=(-not $stopped -and -not $timedOut -and $matched -and $null -ne $exitCode -and $exitCode -eq 0 -and
            $flowData.outcome -eq 'passed' -and [int]$flowData.completed_steps -eq $Actions -and
            [int]$flowData.total_steps -eq $Actions -and $flowData.steps.Count -eq $Actions)
        $reason=if($stopped){'USER_STOP'}elseif($timedOut){'TIMEOUT'}elseif($null -eq $exitCode){'PROCESS_NO_EXIT'}elseif($exitCode -ne 0){'AGENT_PROCESS_FAILED'}elseif(-not $matched){'FLOW_REPORT_MISSING_OR_UNMATCHED'}elseif(-not $verified){'FLOW_GOAL_UNVERIFIED'}else{'UIA_GOAL_VERIFIED'}
    }catch{
        $reason='BENCHMARK_PROCESS_ERROR'
        $watch.Stop()
        try{if(-not $proc.HasExited){$proc.Kill()}}catch{}
    }finally{$proc.Dispose();[IO.File]::Delete($flowReport)}
    $details=@()
    if($null -ne $flowData){
        foreach($step in @($flowData.steps)){
            $act=[string]$step.action
            if($act -notin @('set-value','assert-value','invoke','inspect','assert-name','focus','toggle','select')){$act='unknown'}
            $ver=[string]$step.verification
            if($ver -notin @('verified','not_applicable','unknown','unverified')){$ver='other'}
            $details+=,[ordered]@{
                index=[int]$step.index;action=$act;attempts=[int]$step.attempts
                adapter_us=if($step.PSObject.Properties['adapter_us']){[long]$step.adapter_us}else{$null}
                phases=if($step.PSObject.Properties['phases']){@($step.phases)}else{$null}
                duration_ms=[double]$step.duration_ms;status=([string]$step.status -replace '[^a-z_]','')
                verification=$ver
                evidence=if($act -like 'assert-*' -and $ver -eq 'verified'){'ASSERTION_READBACK_VERIFIED'}
                         elseif($act -eq 'invoke'){'COMMAND_ISSUED_FINAL_ASSERTION_REQUIRED'}
                         elseif([string]$step.status -eq 'issued'){'ACTION_ISSUED_NOT_GOAL_PROOF'}
                         else{'CHECK_FLOW_REPORT'}
            }
        }
    }
    $duration=[Math]::Round($watch.Elapsed.TotalMilliseconds,2)
    $flowMs=if($null -ne $flowData -and $verified){[double]$flowData.duration_ms}else{$null}
    $overhead=if($null -ne $flowMs){[Math]::Max(0,[Math]::Round($duration-$flowMs,2))}else{$null}
    $record=[ordered]@{
        schema=$schema;task=$task;session=$script:session;run_id=$runId;iteration=$iteration;warmup=$warmup;worker=$Worker
        started_utc=$startUtc.ToString('o');success=[bool]$verified;reason_code=$reason
        total_ms=$duration;flow_ms=$flowMs;non_flow_ms=$overhead
        fixture_ready_us=if($null -ne $flowData -and $flowData.PSObject.Properties['fixture_ready_us']){[long]$flowData.fixture_ready_us}else{$null}
        process_cpu_ms=[Math]::Round($cpuMs,2);peak_private_mb=$peakPrivate;peak_working_mb=$peakWorking
        exit_code=$exitCode;fixture_sha256=$fixtureHash;rust_sha256=$binaryHash
        steps=$details;resource_samples=@($samples.ToArray())
        limits=@{cpu_ram_scope='root_rust_process_only';qwen_measured=$false;ui_automation=$true;mouse_control=$false}
    }
    if(-not $warmup){
        Write-JsonAtomic (Join-Path $runDir ($runId+'.json')) $record
        # Append from a single local benchmark process only; do not persist console/UI output.
        if(Test-Path -LiteralPath $history){
            if((Get-Item -LiteralPath $history).Length -gt 1048576){
                $archive=Join-Path $base ('history-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.jsonl')
                [IO.File]::Move($history,$archive)
            }
        }
        $small=[ordered]@{schema=$schema;task=$task;session=$script:session;run_id=$runId;iteration=$iteration;
            started_utc=$record.started_utc;success=$record.success;reason_code=$record.reason_code;
            total_ms=$record.total_ms;flow_ms=$record.flow_ms;non_flow_ms=$record.non_flow_ms;
            peak_private_mb=$record.peak_private_mb;process_cpu_ms=$record.process_cpu_ms;
            fixture_sha256=$fixtureHash;rust_sha256=$binaryHash}
        [IO.File]::AppendAllText($history,((ConvertTo-Json -InputObject $small -Depth 5 -Compress)+[Environment]::NewLine),$utf8)
    }
    $label=if($warmup){'warmup'}else{'measured'}
    Write-Host ('[ReflexCore] '+$label+' #'+$iteration+': '+$duration+' ms | '+$reason+' | UIA flow='+$flowMs+' ms')
    return $record
}
$mutex=New-Object Threading.Mutex($false,'Local\ReflexCoreMeasurementLab')
$owns=$false
try{
    $owns=$mutex.WaitOne(0)
    if(-not $owns){throw 'Another Measurement Lab benchmark is running.'}
    Write-Host "[ReflexCore] WinForms fixture: $Actions UIA operations with independent readback."
    Write-Host ('[ReflexCore] Warmups='+$Warmups+'; measured runs='+$Runs+'; per-run timeout='+$TimeoutSeconds+' sec; no Qwen requests.')
    for($w=1;$w -le $Warmups;$w++){
        if(New-GlobalStop){throw 'Benchmark cancelled by global stop'}
        $warming=Execute-One $w $true
        if(-not $warming.success){throw 'Warmup did not verify the goal; aborting this session.'}
    }
    for($r=1;$r -le $Runs;$r++){
        if(New-GlobalStop){throw 'Benchmark cancelled by global stop'}
        $row=Execute-One $r $false
        if($row.success){$ok++;$values.Add([double]$row.total_ms)}else{$failed++}
    }
    $median=Pctl -numbers ($values.ToArray()) -q 0.5
    $p95=Pctl -numbers ($values.ToArray()) -q 0.95
    $sum=0.0;foreach($val in $values){$sum+=$val}
    $mean=if($values.Count -gt 0){[Math]::Round($sum/$values.Count,2)}else{$null}
    $review=[ordered]@{schema='reflexcore.benchmark.session.v1';task=$task;session=$script:session;
        measured_runs=$Runs;warmups=$Warmups;success=$ok;failed=$failed;
        success_pct=[Math]::Round(100*$ok/$Runs,1);p50_ms=$median;p95_ms=$p95;mean_ms=$mean;
        fixture_sha256=$fixtureHash;rust_sha256=$binaryHash;recorded_utc=[DateTime]::UtcNow.ToString('o');
        note='Verified Windows UIA goal. Excludes Qwen. CPU/RAM counters cover root Rust process only.'}
    Write-JsonAtomic (Join-Path $base ('session-'+$script:session+'.json')) $review
    Write-JsonAtomic (Join-Path $base 'latest-session.json') $review
    if($failed -gt 0){Write-Stage 'failed' $Runs $false 0}
    else{Write-Stage 'finished' $Runs $false 0}
    Write-Host ('[ReflexCore] BENCHMARK: verified='+$ok+'/'+$Runs+', p50='+$median+' ms, p95='+$p95+' ms, mean='+$mean+' ms')
    Write-Host ('[ReflexCore] Local results: '+$base)
    # The command deliberately fails when any measured run did not verify the goal.
    if($failed -gt 0){exit 2}
}catch{
    try{Write-Stage 'failed' 0 $false 0}catch{}
    throw
}finally{
    if($owns){$mutex.ReleaseMutex()}
    $mutex.Dispose()
}
