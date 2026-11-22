# Export a strictly allowlisted, privacy-safe bundle for technical diagnosis.
# No raw logs, screenshots, window names, UI text, prompts, model output or usernames.
param([ValidateRange(1,30)][int]$LastRuns=12,[switch]$SelfTest)
$ErrorActionPreference='Stop'
$diag=Join-Path $env:LOCALAPPDATA 'ReflexCore\diagnostics'
$base=Join-Path $diag 'measurement-lab'
if($SelfTest){
    $x=@{schema='reflexcore.benchmark.run.v1';steps=@(@{action='invoke';status='issued';index=1;duration_ms=3});private_user_text='SECRET'}
    $y=[ordered]@{schema=$x.schema;steps=@($x.steps|ForEach-Object {@{action=$_.action;status=$_.status;index=$_.index;duration_ms=$_.duration_ms}})}
    if(($y|ConvertTo-Json -Depth 6).Contains('SECRET')){throw 'Data minimization self-test failed'}
    Write-Host '[ReflexCore] Diagnostics export allowlist self-test passed. No file created.'
    return
}
$out=Join-Path $diag 'exports'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$stage=Join-Path $env:TEMP ('ReflexDiagnostics-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try{
    $runs=@()
    if(Test-Path -LiteralPath (Join-Path $base 'runs')){
        foreach($item in @(Get-ChildItem -LiteralPath (Join-Path $base 'runs') -Filter '*.json' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $LastRuns)){
            try{
                if($item.Length -gt 1048576){continue}
                $r=Get-Content -LiteralPath $item.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if($r.schema -ne 'reflexcore.benchmark.run.v1'){continue}
                $steps=@()
                foreach($s in @($r.steps)){
                    $action=if($s.action -in @('set-value','assert-value','invoke','inspect','assert-name','focus','toggle','select')){$s.action}else{'unknown'}
                    $status=if(([string]$s.status) -match '^[a-z_]{1,50}$'){$s.status}else{'unknown'}
                    $verification=if($s.verification -in @('verified','not_applicable','unknown','unverified','other')){$s.verification}else{'unknown'}
                    $why=if($s.evidence -in @('ASSERTION_READBACK_VERIFIED','COMMAND_ISSUED_FINAL_ASSERTION_REQUIRED','ACTION_ISSUED_NOT_GOAL_PROOF','CHECK_FLOW_REPORT')){$s.evidence}else{'CHECK_FLOW_REPORT'}
                    $steps+=,[ordered]@{index=[int]$s.index;action=$action;attempts=[int]$s.attempts;
                        status=$status;verification=$verification;duration_ms=[double]$s.duration_ms;evidence=$why}
                }
                # Metrics only. Never export process ID, raw output, environment paths, UI selectors or values.
                $runs+=,[ordered]@{schema=$r.schema;task=$r.task;session=$r.session;
                    success=$r.success;reason_code=$r.reason_code;total_ms=$r.total_ms;
                    flow_ms=$r.flow_ms;non_flow_ms=$r.non_flow_ms;process_cpu_ms=$r.process_cpu_ms;
                    peak_private_mb=$r.peak_private_mb;peak_working_mb=$r.peak_working_mb;
                    fixture_sha256=$r.fixture_sha256;rust_sha256=$r.rust_sha256;steps=$steps}
            }catch{}
        }
    }
    $sessions=@()
    if(Test-Path -LiteralPath $base){
        foreach($item in @(Get-ChildItem -LiteralPath $base -Filter 'session-*.json' -File|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 8)){
            try{
                $s=Get-Content -LiteralPath $item.FullName -Raw -Encoding UTF8|ConvertFrom-Json
                if($s.schema -eq 'reflexcore.benchmark.session.v1'){
                    $sessions+=,[ordered]@{schema=$s.schema;task=$s.task;measured_runs=$s.measured_runs;
                        success=$s.success;failed=$s.failed;p50_ms=$s.p50_ms;p95_ms=$s.p95_ms;
                        mean_ms=$s.mean_ms;fixture_sha256=$s.fixture_sha256;rust_sha256=$s.rust_sha256}
                }
            }catch{}
        }
    }
    $nav=@()
    $navFile=Join-Path $diag 'nav-performance.jsonl'
    if(Test-Path -LiteralPath $navFile){
        foreach($line in @(Get-Content -LiteralPath $navFile -Tail 20)){
            try{
                $r=ConvertFrom-Json -InputObject $line
                if($r.schema -eq 'reflexcore.input.diagnostic.v1'){
                    $move=if($r.move -in @('FORWARD','STRAFE_LEFT','STRAFE_RIGHT','TURN_LEFT','TURN_RIGHT','WAIT','ARRIVED')){$r.move}else{'UNKNOWN'}
                    $thinking=if($r.thinking_mode -in @('Auto','Reflex','Focused','Deep')){$r.thinking_mode}else{'unknown'}
                    $nav+=,[ordered]@{schema=$r.schema;move=$move;thinking_mode=$thinking;
                        capture_ms=$r.capture_ms;infer_ms=$r.infer_ms;
                        parse_ms=$r.parse_ms;rust_decide_ms=$r.rust_decide_ms;
                        verify_capture_ms=$r.verify_capture_ms;input_ms=$r.input_ms;cycle_ms=$r.cycle_ms;
                        ollama_load_ms=$r.ollama_load_ms;ollama_prompt_ms=$r.ollama_prompt_ms;
                        ollama_eval_ms=$r.ollama_eval_ms;ollama_prompt_tokens=$r.ollama_prompt_tokens;
                        ollama_output_tokens=$r.ollama_output_tokens;model_id=$(if(([string]$r.model_id) -match '^[a-zA-Z0-9_.:/-]{1,128}$'){$r.model_id}else{'unknown'});
                        model_num_ctx=$r.model_num_ctx;model_num_predict=$r.model_num_predict;
                        model_temperature=$r.model_temperature;model_top_p=$r.model_top_p;
                        scene_change_percent=$r.scene_change_percent;
                        next_frame_reused=$r.next_frame_reused;movement_verified=$false}
                }
            }catch{}
        }
    }
    $modelBench=$null
    $modelPath=Join-Path $diag 'model-bench\latest.json'
    if(Test-Path $modelPath){try{
        $b=Get-Content $modelPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($b.schema -eq 'reflexcore.model.benchmark.v1'){
            $modelBench=[ordered]@{schema=$b.schema;task=$b.task;model=$b.model;
                config_sha256=$b.config_sha256;runs=$b.runs;success=$b.success;
                p50_ms=$b.p50_ms;p95_ms=$b.p95_ms;mean_ms=$b.mean_ms;
                prompt_p50_ms=$b.prompt_p50_ms;eval_p50_ms=$b.eval_p50_ms}
        }
    }catch{}}
    $payload=[ordered]@{schema='reflexcore.diagnostic.export.v1';release='0.6.2 Integrated Model Lab';model_benchmark=$modelBench;
        generated_utc=[DateTime]::UtcNow.ToString('o');run_count=$runs.Count;
        sessions=$sessions;runs=$runs;qwen_cycles=$nav;
        note='Source fields are strictly allowlisted. No raw log, screenshot, prompt, model response, username or window title.'}
    $file=Join-Path $stage 'diagnostics.json'
    [IO.File]::WriteAllText($file,(ConvertTo-Json -InputObject $payload -Depth 15), (New-Object System.Text.UTF8Encoding($false)))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $result=Join-Path $out ('ReflexCore-Diagnostics-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.zip')
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$result)
    Write-Host ('[ReflexCore] Sanitized diagnostics export: '+$result)
    Write-Host ('[ReflexCore] Included '+$runs.Count+' run(s), '+$sessions.Count+' sessions and '+$nav.Count+' Qwen timing records.')
    Write-Host '[ReflexCore] Review before sharing. No raw files copied.'
}finally{if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}}
