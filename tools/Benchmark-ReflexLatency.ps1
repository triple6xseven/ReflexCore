# ReflexCore synthetic IPC benchmark: test the *release binary* and fail on stale CLI.
# Never launches a browser/model, sends Windows input or stores private UI values.
# Windows PowerShell 5.1, .NET Framework 4.5+ async stdout with bounded timeout.
param([int]$Samples=30)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if($Samples -lt 5 -or $Samples -gt 200){throw 'Samples must be 5..200'}
$root=Split-Path $PSScriptRoot -Parent
$binary=Join-Path $root 'target\release\reflexcore.exe'
if(-not (Test-Path -LiteralPath $binary -PathType Leaf)){throw 'Rust release executable not found; build first'}
# Entire fixture contains synthetic, non-personal game data only.
$world=@{
 phase='deploy';mission='destroy-core';elapsed=0;budget=260;spent=0;remaining=260;coreHp=480
 buildings=@(@{id='core';type='core';x=880;y=356;hp=480;max=480})
 units=@();stats=@{deployed=0;lost=0;damage=0}
 plan=@{remaining=@{giant=2;archer=2;sapper=1;raider=0;medic=0}}
 cooldowns=@{sonar=0;heal=0;rage=0};sonar=$false;overdrive=$false;focusTargetId=$null
}
$psi=New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName=$binary
$psi.Arguments='citadel-bridge serve'
$psi.WorkingDirectory=$root
$psi.UseShellExecute=$false
$psi.CreateNoWindow=$true
$psi.RedirectStandardInput=$true
$psi.RedirectStandardOutput=$true
# Rust errors go to an in-memory pipe. Never save raw stderr or paths in repository.
$psi.RedirectStandardError=$true
$proc=New-Object System.Diagnostics.Process
$proc.StartInfo=$psi
$ms=New-Object 'System.Collections.Generic.List[double]'
$script:seq=0
function Get-ProcessState {
    if($proc.HasExited){return ('exited with code '+$proc.ExitCode)}
    return 'process is still running'
}
function Send-Request([string]$op) {
    $script:seq++
    $msg=@{schema='reflexcore.citadel.bridge.v1';op=$op;seq=$script:seq;world=$world}|ConvertTo-Json -Depth 12 -Compress
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        if($proc.HasExited){throw ('RUST_PROCESS_EXITED before '+$op+' ('+(Get-ProcessState)+')')}
        $proc.StandardInput.WriteLine($msg)
        $proc.StandardInput.Flush()
        $read=$proc.StandardOutput.ReadLineAsync()
        if(-not $read.Wait(7500)) {throw ('RUST_IPC_TIMEOUT at '+$op+' ('+(Get-ProcessState)+')')}
        $line=$read.Result
        $watch.Stop()
        if($null -eq $line){throw ('RUST_IPC_EOF at '+$op+' ('+(Get-ProcessState)+')')}
        if([string]::IsNullOrWhiteSpace($line)){
            throw ('RUST_IPC_EMPTY_LINE at '+$op+' ('+(Get-ProcessState)+'); probable stale release CLI')
        }
        try {$data=ConvertFrom-Json -InputObject $line -ErrorAction Stop}
        catch {throw ('RUST_IPC_NOT_JSON at '+$op+'; probable stale release CLI')}
        if($data.schema -ne 'reflexcore.citadel.bridge.v1'){
            throw ('RUST_IPC_WRONG_SCHEMA at '+$op+'; verify release binary contains citadel-bridge')
        }
        if(-not $data.ok){throw ('RUST_IPC_REJECTED at '+$op+': '+$data.error)}
        return @{time=$watch.Elapsed.TotalMilliseconds;data=$data}
    }catch {
        # Diagnostics show stage + exit code, never full stderr, prompts, window titles or paths.
        Write-Host ('[ReflexCore] IPC diagnostic: operation='+$op+'; seq='+$script:seq+'; '+(Get-ProcessState)) -ForegroundColor Yellow
        throw
    }
}
try {
    if(-not $proc.Start()){throw 'Rust release process did not start'}
    $start=Send-Request 'start'
    if($start.data.code -ne 'RUST_GOAL_AGENT_READY'){throw 'RUST_IPC_HANDSHAKE_INVALID'}
    for($i=0;$i -lt $Samples;$i++){
        $reply=Send-Request 'next'
        $ms.Add([double]$reply.time)
        if($null -ne $reply.data.action){
            # Simulated readback is confined to the benchmark, not evidence of live UI actions.
            $a=$reply.data.action
            if($a.kind -eq 'deploy'){
                $costs=@{giant=55;archer=25;sapper=40;raider=30;medic=35}
                if(-not $costs.ContainsKey($a.type)){throw 'UNEXPECTED_DEPLOY_TYPE'}
                $cost=$costs[$a.type]
                $world.spent+=$cost
                $world.remaining-=$cost
                $world.stats.deployed++
                $world.plan.remaining[$a.type]--
                $world.units+=@{id=$world.stats.deployed;type=$a.type;x=$a.x;y=$a.y;hp=100;max=100}
            }elseif($a.kind -eq 'focus'){$world.focusTargetId=$a.id}
            elseif($a.kind -eq 'skill'){$world.cooldowns[$a.name]=10}
            else{throw 'UNEXPECTED_ACTION_KIND'}
            $commit=Send-Request 'commit'
            if(-not $commit.data.verified){throw 'RUST_COMMIT_NOT_VERIFIED'}
        }
    }
    $sorted=@($ms.ToArray()|Sort-Object)
    $p50=$sorted[[int][Math]::Floor(($sorted.Count-1)*0.50)]
    $p95=$sorted[[int][Math]::Floor(($sorted.Count-1)*0.95)]
    $diag=Join-Path $env:LOCALAPPDATA 'ReflexCore\diagnostics'
    New-Item -ItemType Directory -Force -Path $diag|Out-Null
    $result=[ordered]@{schema='reflexcore.performance.v1';mode='rust_ipc_synthetic_only';samples=$ms.Count;p50_ms=[Math]::Round($p50,3);p95_ms=[Math]::Round($p95,3);cold_start_ms=[Math]::Round($start.time,3);real_windows_input_verified=$false;llm_measured=$false}
    $result|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $diag 'rust-ipc-latency.json') -Encoding UTF8
    Write-Host ('[ReflexCore] Rust JSONL IPC baseline: p50='+$result.p50_ms+' ms, p95='+$result.p95_ms+' ms; cold-start='+$result.cold_start_ms+' ms')
    Write-Host '[ReflexCore] Synthetic protocol benchmark only; NOT a Qwen or Windows UI speed measurement.'
}finally{
    try{$proc.StandardInput.Close()}catch{}
    try{if(-not $proc.WaitForExit(2500)){$proc.Kill()}}catch{}
    $proc.Dispose()
}
