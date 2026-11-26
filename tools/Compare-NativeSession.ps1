# Summarize compatible benchmark records. Pass explicit session IDs to keep
# development probes and warmups outside a paired comparison.
param([Parameter(Mandatory=$true)][string[]]$Sessions)
$ErrorActionPreference='Stop'
$dir=Join-Path $env:LOCALAPPDATA 'ReflexCore/diagnostics/measurement-lab'
$rows=@()
$history=Get-ChildItem -LiteralPath $dir -Filter 'history*.jsonl'
foreach($id in ($Sessions|Select-Object -Unique)){
    if($id -cnotmatch '^[0-9a-f]{16}$'){throw 'Invalid benchmark session ID'}
    $summary=Get-Content -Raw -LiteralPath (Join-Path $dir "session-$id.json")|ConvertFrom-Json
    $entries=@(Get-Content -LiteralPath $history.FullName | Where-Object {$_.Contains($id)} | ForEach-Object {$_|ConvertFrom-Json} | Where-Object {$_.session -ceq $id})
    if($entries.Count -ne $summary.measured_runs){throw "Incomplete local history for $id"}
    foreach($entry in $entries){
        if($entry.run_id -cnotmatch '^[0-9a-f]{32}$'){throw 'Invalid run ID'}
        $r=Get-Content -Raw -LiteralPath (Join-Path $dir "runs/$($entry.run_id).json")|ConvertFrom-Json
        if($r.run_id -cne $entry.run_id -or $r.session -cne $id -or $r.warmup -or $r.fixture_sha256 -cne $summary.fixture_sha256 -or $r.rust_sha256 -cne $summary.rust_sha256){throw 'Incompatible evidence'}
        $rows+=,$r
    }
}
if(@($rows.rust_sha256|Select-Object -Unique).Count -ne 1){throw 'Select sessions from the same binary'}
function Rank($values,[double]$q){
    $v=@($values|Where-Object {$null -ne $_}|Sort-Object)
    if($v.Count){return $v[[Math]::Ceiling($v.Count*$q)-1]}
    return $null
}
foreach($group in ($rows|Group-Object task,worker,fixture_sha256)){
    $g=@($group.Group)
    $steps=@($g|ForEach-Object {$_.steps})
    $p=@($steps|ForEach-Object {$_.phases})
    $cpu=@(foreach($r in $g){
        $v=@($r.steps|ForEach-Object {$_.phases}|ForEach-Object {$_.child_cpu_us}|Where-Object {$null -ne $_})
        if($v.Count){if($r.worker -eq 'session'){$v[-1]}else{($v|Measure-Object -Sum).Sum}}
    })
    [pscustomobject]@{
        task=$g[0].task;worker=$g[0].worker;runs=$g.Count;verified=@($g|Where-Object success).Count
        total_p50_ms=Rank $g.total_ms .50;total_p95_ms=Rank $g.total_ms .95;total_p99_ms=Rank $g.total_ms .99;max_ms=Rank $g.total_ms 1
        flow_p50_ms=Rank $g.flow_ms .50;action_p50_us=Rank $steps.adapter_us .50
        fixture_p50_us=Rank $g.fixture_ready_us .50;child_cpu_p50_us=Rank $cpu .50;root_cpu_p50_ms=Rank $g.process_cpu_ms .50
        root_private_max=Rank $p.root_private_bytes 1;child_private_max=Rank $p.child_private_bytes 1;concurrent_private_max=Rank $p.concurrent_private_bytes 1
        creations=@($p|Where-Object {$_.spawn_us -gt 0}).Count
        phases_p50_us=[ordered]@{}
    } | ForEach-Object {
        $out=$_
        foreach($key in @('request_us','resolve_us','spawn_us','startup_from_spawn_us','com_us','uia_us','discovery_us','operation_us','verification_us','response_write_us','validate_us','cleanup_us','exit_us','ack_us')){
            $data=if($key -in @('spawn_us','startup_from_spawn_us','com_us','uia_us')){@($p|Where-Object {$_.spawn_us -gt 0})}else{$p}
            $out.phases_p50_us[$key]=Rank ($data|ForEach-Object {$_.$key}) .50
        }
        $out
    }
}
