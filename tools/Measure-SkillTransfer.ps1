# Measure the same background save on two release binaries and one fixture.
param([Parameter(Mandatory)][string]$BaselineRoot,[ValidateRange(1,30)][int]$Runs=5)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$base=(Resolve-Path (Join-Path $BaselineRoot 'target/release/reflexcore.exe')).Path
$candidate=(Resolve-Path (Join-Path $root 'target/release/reflexcore.exe')).Path
$dir=Join-Path ([IO.Path]::GetTempPath()) ('reflex-transfer-'+[guid]::NewGuid().ToString('N'))
$rows=@()
Add-Type -Path (Join-Path $PSScriptRoot 'SkillBenchmarkJob.cs')
try {
    foreach($sub in 'data/bridge/running','tools'){[void][IO.Directory]::CreateDirectory((Join-Path $dir $sub))}
    $fixture=Join-Path $dir 'tools/ReflexCore-Fixture.ps1'
    Copy-Item -LiteralPath (Join-Path $root 'tools/ReflexCore-Fixture.ps1') -Destination $fixture
    $modes=@('baseline','disposable','session')
    for($iteration=0;$iteration -le $Runs;$iteration++){
        for($slot=0;$slot -lt $modes.Count;$slot++){
            $mode=$modes[($iteration+$slot)%3]
            $binary=if($mode -eq 'baseline'){$base}else{$candidate}
            $id=[datetime]::UtcNow.ToString('yyyyMMddHHmmssfff')+'-'+[guid]::NewGuid().ToString('N')
            $claim=Join-Path $dir "data/bridge/running/$id.job"
            [IO.File]::WriteAllText($claim,'')
            $info=[Diagnostics.ProcessStartInfo]::new($binary,'agent verified-demo --execute --background')
            $info.UseShellExecute=$false
            $info.CreateNoWindow=$true
            $info.WorkingDirectory=$dir
            $info.RedirectStandardOutput=$true
            $info.EnvironmentVariables['REFLEXCORE_QUEUE_MANIFEST']="$id.job"
            $info.EnvironmentVariables['REFLEXCORE_UIA_WORKER']=if($mode -eq 'session'){'session'}else{'disposable'}
            $info.EnvironmentVariables['REFLEXCORE_SKILL_TIMINGS']='1'
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $proc=[Diagnostics.Process]::Start($info)
            $job=$null
            try {
                $job=[ReflexCore.Measurement.SkillBenchmarkJob]::new($proc)
                $output=$proc.StandardOutput.ReadToEndAsync()
                $finished=$proc.WaitForExit(30000)
                $clock.Stop()
                if(!$finished){$job.Stop();$proc.WaitForExit()}
                $job.Sample()
                $receipt=$null
                $file=[IO.Path]::ChangeExtension($claim,'receipt.json')
                if([IO.File]::Exists($file)){$receipt=[IO.File]::ReadAllText($file)|ConvertFrom-Json}
                $verified=$finished -and $proc.ExitCode -eq 0 -and $receipt.task_id -ceq $id -and
                    $receipt.schema -ceq 'reflexcore.task.receipt.v1' -and $receipt.outcome -ceq 'verified' -and $receipt.verification -ceq 'verified'
                $timing=$null
                if($mode -ne 'baseline'){
                    $lines=@($output.GetAwaiter().GetResult().Split([char]10)|Where-Object {$_.StartsWith('{')}|ForEach-Object {$_|ConvertFrom-Json})
                    $timing=$lines|Where-Object schema -ceq 'reflexcore.skill.timing.v1'
                    $verified=$verified -and $receipt.skill.skill_id -ceq 'artifact.verify_saved_text' -and
                        $receipt.skill.adapter -ceq 'winforms' -and $receipt.skill.run_id -ceq $receipt.run_id -and $timing.run_id -ceq $receipt.run_id
                }
                $rows+=[pscustomobject]@{mode=$mode;warmup=($iteration -eq 0);task_id=$id;run_id=$receipt.run_id;verified=$verified
                    elapsed_ms=$clock.Elapsed.TotalMilliseconds;timing=$timing;readback_us=$receipt.skill.readback_us
                    tree_cpu_us=$job.CpuMicroseconds;tree_processes=$job.Processes;tree_peak_commit_bytes=$job.PeakCommitBytes}
            }finally{
                if(!$proc.HasExited){if($job){$job.Stop()}else{$proc.Kill()};$proc.WaitForExit()}
                if($job){$job.Dispose()};$proc.Dispose()
            }
        }
    }
    $private=[IO.Directory]::CreateDirectory((Join-Path $root 'data/private')).FullName
    $session=[guid]::NewGuid().ToString('N')
    $sessionFile=Join-Path $private "skill-transfer-$session.json"
    [IO.File]::WriteAllText($sessionFile,(@{schema='reflexcore.skill.comparison.v1';baseline_sha256=(Get-FileHash $base).Hash
        candidate_sha256=(Get-FileHash $candidate).Hash;fixture_sha256=(Get-FileHash $fixture).Hash;rows=$rows}|ConvertTo-Json -Depth 8))
    Write-Output "Private comparison: $session"
    foreach($mode in $modes){
        $g=@($rows|Where-Object {!$_.warmup -and $_.mode -eq $mode})
        $v=@($g.elapsed_ms|Sort-Object)
        [pscustomobject]@{mode=$mode;runs=$g.Count;verified=@($g|Where-Object verified).Count
            p50_ms=$v[[math]::Ceiling($v.Count*.50)-1];p95_ms=$v[[math]::Ceiling($v.Count*.95)-1]
            p99_ms=$v[[math]::Ceiling($v.Count*.99)-1];max_ms=$v[-1]}
    }
    if($rows.verified -contains $false){throw 'Transfer benchmark contains an unverified attempt'}
}finally{
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $full=[IO.Path]::GetFullPath($dir)
    if([IO.Path]::GetDirectoryName($full) -eq $tempRoot -and [IO.Path]::GetFileName($full) -match '^reflex-transfer-[0-9a-f]{32}$'){
        if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
    }
}
