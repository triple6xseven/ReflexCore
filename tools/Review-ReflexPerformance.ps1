# Read ONLY privacy-safe timing fields from existing local SharedControl diagnostics.
# This is a baseline report; it never calls Ollama, captures screens, or sends input.
param([int]$Tail=150)
$ErrorActionPreference='Stop'
if($Tail -lt 5 -or $Tail -gt 2000){throw 'Tail must be 5..2000'}
$diag=Join-Path $env:LOCALAPPDATA 'ReflexCore\diagnostics'
$file=Join-Path $diag 'nav-performance.jsonl'
if(-not(Test-Path -LiteralPath $file -PathType Leaf)){
    Write-Host '[ReflexCore] No real navigation samples yet. Run a supervised Qwen test in Shared Control first.'
    return
}
$rows=@()
foreach($line in (Get-Content -LiteralPath $file -Tail $Tail)){
    try {
        $o=$line|ConvertFrom-Json
        if($o.schema -eq 'reflexcore.input.diagnostic.v1') {$rows+=,$o}
    }catch{}
}
if($rows.Count -eq 0){Write-Host '[ReflexCore] No valid timing records yet.';return}
function Metric([string]$key){
    $nums=New-Object 'System.Collections.Generic.List[double]'
    foreach($o in $rows){
        $p=$o.PSObject.Properties[$key]
        if($null -ne $p -and $null -ne $p.Value){
            try {$v=[double]$p.Value; if(-not [double]::IsNaN($v) -and $v -ge 0 -and $v -le 600000){$nums.Add($v)}}catch{}
        }
    }
    if($nums.Count -eq 0){return $null}
    $sorted=@($nums.ToArray()|Sort-Object)
    return [ordered]@{samples=$nums.Count;p50_ms=[Math]::Round($sorted[[int][Math]::Floor(($nums.Count-1)*.50)],2);p95_ms=[Math]::Round($sorted[[int][Math]::Floor(($nums.Count-1)*.95)],2)}
}
$metrics=[ordered]@{}
foreach($key in @('capture_ms','infer_ms','parse_ms','rust_decide_ms','verify_capture_ms','input_ms','cycle_ms','ollama_load_ms','ollama_prompt_ms','ollama_eval_ms')){
    $measure=Metric $key
    if($null -ne $measure){$metrics[$key]=$measure}
}
$output=[ordered]@{schema='reflexcore.performance.review.v1';source='actual_local_nav_diagnostics';records_scanned=$rows.Count;metrics=$metrics;note='A visual change or SendInput success is not verification of task completion'}
New-Item -ItemType Directory -Force -Path $diag|Out-Null
($output|ConvertTo-Json -Depth 6)|Set-Content -LiteralPath (Join-Path $diag 'performance-review.json') -Encoding UTF8
Write-Host ('[ReflexCore] Reviewed '+$rows.Count+' local navigation records (p50/p95 milliseconds):')
foreach($key in $metrics.Keys){
 $m=$metrics[$key];Write-Host ('  '+$key+': '+$m.p50_ms+' / '+$m.p95_ms+'  (n='+$m.samples+')')
}
Write-Host '[ReflexCore] No screenshots/prompts/private text loaded or included in report.'
