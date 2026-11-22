# ReflexCore 0.6.2 | Fixed Qwen JSON task, same prompt/policy every run, no Windows UI input.
# Text-only benchmark; it cannot stand in for VLM image capture or task success in the real world.
[CmdletBinding()]
param([ValidateRange(1,30)][int]$Runs=3,[ValidateRange(0,3)][int]$Warmups=1,[switch]$SelfTest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
$config=Join-Path $root 'data\settings\ollama-local.json'
$diag=Join-Path $env:LOCALAPPDATA 'ReflexCore\diagnostics\model-bench'
$fmt='reflexcore.model.benchmark.v1'
$task='qwen-fixed-json-text-v1'
function Pct([double[]]$a,[double]$q){if($a.Count -eq 0){return $null};$b=@($a|Sort-Object);return [Math]::Round([double]$b[[int]([Math]::Ceiling($b.Count*$q)-1)],3)}
function Get-Val([object]$obj,[string]$name,[object]$fallback,[double]$lo,[double]$hi){
 try{$v=[double]$obj.$name;if($v -lt $lo -or $v -gt $hi -or [double]::IsNaN($v)){return $fallback};return $v}catch{return $fallback}
}
function Milli($obj,[string]$name){try{return [Math]::Round(([double]$obj.$name / 1000000),3)}catch{return $null}}
if($SelfTest){
 if((Pct ([double[]]@(2,9,4,8,5)) 0.50) -ne 5){throw 'p50 regression'}
 if((Pct ([double[]]@(2,9,4,8,5)) 0.95) -ne 9){throw 'p95 regression'}
 Write-Host '[ReflexCore] Fixed Qwen benchmark metrics/fixture self-test PASSED. No request made.'
 exit 0
}
$model='qwen3-vl:2b-instruct'
$opts=[ordered]@{num_ctx=2048;num_predict=40;temperature=0;top_p=0.9;top_k=40;repeat_penalty=1.1}
$keep=30
if(Test-Path $config){
 $raw=Get-Content -LiteralPath $config -Raw -Encoding UTF8
 if($raw.Length -gt 16384){throw 'Model settings size exceeded'}
 $cfg=$raw|ConvertFrom-Json -ErrorAction Stop
 if($cfg.schema -ne 'reflexcore.ollama.settings.v1'){throw 'Settings schema mismatch'}
 if(([string]$cfg.model) -match '^[a-zA-Z0-9_.:/-]{1,128}$' -and ([string]$cfg.model) -notmatch '\.\.'){ $model=[string]$cfg.model }
 $opts.num_ctx=[int](Get-Val $cfg 'num_ctx' 2048 512 8192)
 $opts.num_predict=[int](Get-Val $cfg 'num_predict' 40 1 512)
 $opts.temperature=(Get-Val $cfg 'temperature' 0 0 2)
 $opts.top_p=(Get-Val $cfg 'top_p' .9 .05 1)
 $opts.top_k=[int](Get-Val $cfg 'top_k' 40 1 100)
 $opts.repeat_penalty=(Get-Val $cfg 'repeat_penalty' 1.1 .8 2)
 $threads=[int](Get-Val $cfg 'num_thread' 0 0 32);if($threads -gt 0){$opts.num_thread=$threads}
 $gpu=[int](Get-Val $cfg 'num_gpu' -1 -1 99);if($gpu -ge 0){$opts.num_gpu=$gpu}
 $seed=[int](Get-Val $cfg 'seed' -1 -1 2147483647);if($seed -ge 0){$opts.seed=$seed}
 $keep=[int](Get-Val $cfg 'keep_alive_minutes' 30 1 240)
}
# Fixed scenario, no private data, no image. Cannot be considered intelligence or vision benchmark.
$prompt='Fixed local evaluation task. You are given NO screenshot, NO visual information, and no game state. Use strict JSON only with exactly two keys. Since no scene is visible, action must be WAIT and at_bombsite must be unknown. Never invent visual evidence.'
$schema=[ordered]@{type='object';properties=[ordered]@{action=@{type='string';enum=@('WAIT','FORWARD','TURN_LEFT','TURN_RIGHT')};at_bombsite=@{type='string';enum=@('yes','no','unknown')}};required=@('action','at_bombsite');additionalProperties=$false}
$payload=[ordered]@{model=$model;prompt=$prompt;format=$schema;stream=$false;keep_alive=($keep.ToString()+'m');options=$opts}
$serialized=ConvertTo-Json -InputObject $payload -Depth 12 -Compress
$hash=[Security.Cryptography.SHA256]::Create();try{$configHash=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($serialized))).Replace('-','')}finally{$hash.Dispose()}
$start=[DateTime]::UtcNow
$api='http://127.0.0.1:11434/api/generate'
Add-Type -AssemblyName System.Net.Http
$handler=New-Object Net.Http.HttpClientHandler;$handler.UseProxy=$false
$client=[System.Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(180)
$lat=New-Object 'System.Collections.Generic.List[double]'
$promptTimes=New-Object 'System.Collections.Generic.List[double]'
$evalTimes=New-Object 'System.Collections.Generic.List[double]'
$passed=0;$failed=0;$cancelled=$false
$stopPath=Join-Path $root 'data\bridge\global-stop.signal'
$baseline=if(Test-Path $stopPath){(Get-Item $stopPath).LastWriteTimeUtc}else{[DateTime]::MinValue}
try{
 for($i=0;$i -lt $Runs+$Warmups;$i++){
  if((Test-Path $stopPath) -and (Get-Item $stopPath).LastWriteTimeUtc -gt $baseline){$cancelled=$true;break}
  $sw=[Diagnostics.Stopwatch]::StartNew();$good=$false;$obj=$null
  try{
   $content=[System.Net.Http.StringContent]::new($serialized,[Text.Encoding]::UTF8,'application/json')
   $reply=$null
   try{$reply=$client.PostAsync($api,$content).GetAwaiter().GetResult()}finally{$content.Dispose()}
   try{
    if(-not $reply.IsSuccessStatusCode){throw ('Ollama HTTP '+[int]$reply.StatusCode)}
    $body=$reply.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if($body.Length -gt 200000){throw 'Response too large'}
    $obj=$body|ConvertFrom-Json -ErrorAction Stop
   }finally{$reply.Dispose()}
   $answer=([string]$obj.response)|ConvertFrom-Json -ErrorAction Stop
   $good=$answer.action -ceq 'WAIT' -and $answer.at_bombsite -ceq 'unknown' -and @($answer.PSObject.Properties).Count -eq 2
  }catch{}
  finally{$sw.Stop()}
  if($i -ge $Warmups){
   if($good){
    $passed++
    $lat.Add($sw.Elapsed.TotalMilliseconds)
    $pm=Milli $obj 'prompt_eval_duration';$em=Milli $obj 'eval_duration'
    if($null -ne $pm){$promptTimes.Add([double]$pm)}
    if($null -ne $em){$evalTimes.Add([double]$em)}
   }else{$failed++}
  }
 }
}finally{$client.Dispose();$handler.Dispose()}
$summary=[ordered]@{
 schema=$fmt;task=$task;model=$model;config_sha256=$configHash;
 started_utc=$start.ToString('o');runs=$Runs;warmups=$Warmups;success=$passed;failed=$failed;cancelled=$cancelled;
 p50_ms=(Pct ($lat.ToArray()) 0.50);p95_ms=(Pct ($lat.ToArray()) 0.95);
 mean_ms=if($lat.Count){[Math]::Round((($lat.ToArray()|Measure-Object -Average).Average),3)}else{$null};
 prompt_p50_ms=(Pct ($promptTimes.ToArray()) 0.50);eval_p50_ms=(Pct ($evalTimes.ToArray()) 0.50);
 notes='Synthetic text-only verified JSON task; NOT image VLM speed, Windows UI completion or general intelligence.'
}
if(-not(Test-Path $diag)){[void](New-Item -ItemType Directory -Path $diag -Force)}
$file=Join-Path $diag 'latest.json';$temp=$file+'.reflex-tmp-'+[guid]::NewGuid().ToString('N')
$utf8=[Text.UTF8Encoding]::new($false)
try{
 [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $summary -Depth 7 -Compress),$utf8)
 if(Test-Path $file){$bak=$temp+'.bak';try{[IO.File]::Replace($temp,$file,$bak)}finally{if(Test-Path $bak){Remove-Item $bak -Force}}}
 else{[IO.File]::Move($temp,$file)}
}finally{if(Test-Path $temp){Remove-Item $temp -Force}}
$history=Join-Path $diag 'history.jsonl'
if((Test-Path $history) -and (Get-Item $history).Length -gt 1048576){Move-Item -LiteralPath $history -Destination ($history+'.previous') -Force}
[IO.File]::AppendAllText($history,(ConvertTo-Json -InputObject $summary -Compress)+[Environment]::NewLine,$utf8)
# Public stdout contains only bounded metrics; never the model's answer or fixed prompt.
$summary|ConvertTo-Json -Depth 7 -Compress
if($cancelled -or $failed){exit 2}
