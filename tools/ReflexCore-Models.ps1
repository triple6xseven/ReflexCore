# ReflexCore 0.6.2 local Ollama model lifecycle; NO external URLs, shell commands from models, or process kills.
# All output is bounded operational metadata (model names, not prompts or responses).
[CmdletBinding()]
param(
 [ValidateSet('List','Load','Stop','StopAll','Watch','SelfTest')][string]$Action='List',
 [string]$Model='',
 [ValidateRange(1,240)][int]$Minutes=15,
 [string]$LeaseId='',
 [switch]$SelfTest
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
$runtime=Join-Path $env:LOCALAPPDATA 'ReflexCore\runtime'
$leasePath=Join-Path $runtime 'model-lease.json'
$api='http://127.0.0.1:11434'
$utf8=[Text.UTF8Encoding]::new($false)
function Valid-Model([string]$name){return ($name.Length -ge 1 -and $name.Length -le 128 -and $name -cmatch '\A(?!.*:/)(?!.*//)(?!.*::)(?!.*\.\.)(?!.*[/:]\z)[A-Za-z0-9][A-Za-z0-9_.:/-]*\z')}
function Read-Lease {
 if(-not (Test-Path -LiteralPath $leasePath -PathType Leaf)){return $null}
 try{ return (Get-Content -LiteralPath $leasePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)} catch {return $null}
}
function Put-Lease([object]$lease){
 if(-not(Test-Path $runtime)){[void](New-Item -ItemType Directory -Path $runtime -Force)}
 $tmp=$leasePath+'.reflex-tmp-'+[guid]::NewGuid().ToString('N')
 try{
  [IO.File]::WriteAllText($tmp,($lease | ConvertTo-Json -Depth 5 -Compress),$utf8)
  if(Test-Path $leasePath){Move-Item -LiteralPath $tmp -Destination $leasePath -Force}
  else{[IO.File]::Move($tmp,$leasePath)}
 }finally{if(Test-Path $tmp){Remove-Item -LiteralPath $tmp -Force}}
}
function Api([string]$method,[string]$path,[object]$body=$null,[int]$seconds=30){
 Add-Type -AssemblyName System.Net.Http
 $handler=New-Object System.Net.Http.HttpClientHandler
 $handler.UseProxy=$false
 $client=[System.Net.Http.HttpClient]::new($handler)
 $client.Timeout=[TimeSpan]::FromSeconds($seconds)
 $response=$null
 try{
  $uri=$api+$path
  if($method -eq 'GET'){$response=$client.GetAsync($uri).GetAwaiter().GetResult()}
  else{
   $json=ConvertTo-Json -InputObject $body -Depth 8 -Compress
   $content=[System.Net.Http.StringContent]::new($json,[Text.Encoding]::UTF8,'application/json')
   try{$response=$client.PostAsync($uri,$content).GetAwaiter().GetResult()}finally{$content.Dispose()}
  }
  if(-not $response.IsSuccessStatusCode){throw ('Ollama HTTP '+[int]$response.StatusCode)}
  $s=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  if($s.Length -gt 524288){throw 'Ollama metadata response exceeded limit'}
  return ($s | ConvertFrom-Json -ErrorAction Stop)
 }finally{if($response){$response.Dispose()};$client.Dispose();$handler.Dispose()}
}
function Models([string]$kind){
 $o=Api 'GET' $kind
 if($null -eq $o.models){return @()}
 return @($o.models | ForEach-Object {
  $name=if($_.name){[string]$_.name}elseif($_.model){[string]$_.model}else{''}
  if(Valid-Model $name){$name}
 } | Where-Object{$_} | Select-Object -Unique)
}
# Private, bounded status events: no prompts, screenshots, window titles or file paths.
$eventDir=Join-Path $env:LOCALAPPDATA 'ReflexCore\diagnostics\models'
$eventPath=Join-Path $eventDir 'lease-events.jsonl'
function Lease-Event([string]$code,[string]$model=''){
 try{
  if(-not(Test-Path $eventDir)){[void](New-Item -ItemType Directory -Path $eventDir -Force)}
  if((Test-Path $eventPath) -and (Get-Item $eventPath).Length -gt 262144){
   Move-Item -LiteralPath $eventPath -Destination ($eventPath+'.previous') -Force
  }
  $value=[ordered]@{schema='reflexcore.model.lease.event.v1';at_utc=[DateTime]::UtcNow.ToString('o');code=$code;model=$model}
  [IO.File]::AppendAllText($eventPath,((ConvertTo-Json -InputObject $value -Compress)+[Environment]::NewLine),$utf8)
 }catch{}
}
function Lease-Refresh-Needed([DateTime]$expires,[DateTime]$deadline,[DateTime]$now){
 # Reassert only if another client shortened Ollama's independent keep_alive.
 return (($deadline-$now).TotalSeconds -gt 18 -and ($expires-$now).TotalSeconds -lt 16)
}
function Unload([string]$name){
 if(-not(Valid-Model $name)){throw 'Invalid model id'}
 [void](Api 'POST' '/api/generate' ([ordered]@{model=$name;prompt='';stream=$false;keep_alive=0}) 90)
}
function Clear-Lease([string]$specific=''){
 $prev=Read-Lease
 if($null -ne $prev -and ($specific -eq '' -or $prev.model -eq $specific)){
  try{Remove-Item -LiteralPath $leasePath -Force -ErrorAction Stop}catch{}
 }
}
# Keep both supported forms: -Action SelfTest (original public API) and
# -SelfTest (installer convention). Never allow a conflicting action to run.
if($SelfTest){
 if($PSBoundParameters.ContainsKey('Action') -and $Action -ne 'SelfTest'){throw 'Conflicting self-test and model action'}
 $Action='SelfTest'
}
if($Action -eq 'SelfTest'){
 foreach($bad in @('../cmd','foo bar','https://evil','http:/evil','foo//bar','foo/','/foo','foo:','foo::tag','foo..bar','foo\bar','a|b','foo`nbar')){if(Valid-Model $bad){throw ('Model id guard failed for invalid fixture: '+$bad)}}
 foreach($good in @('qwen3-vl:2b-instruct','namespace/model:tag','registry.example:5000/library/model:1.0','llama3.2:latest')){if(-not(Valid-Model $good)){throw ('Valid model rejected: '+$good)}}
 if($Minutes -lt 1 -or $Minutes -gt 240){throw 'Duration guard failed'}
 if(-not(Lease-Refresh-Needed ([DateTime]::UtcNow.AddSeconds(5)) ([DateTime]::UtcNow.AddMinutes(15)) ([DateTime]::UtcNow))){throw 'Lease shortening regression'}
 Write-Host '[ReflexCore] Model manager guard self-test passed; no Ollama request or process created.'
 exit 0
}
if($Action -eq 'Watch'){
 if($LeaseId -notmatch '^[a-f0-9]{32}$'){throw 'Invalid lease id'}
 $wasLoaded=$false
 while($true){
  $l=Read-Lease
  if($null -eq $l -or [string]$l.schema -ne 'reflexcore.model.lease.v1' -or [string]$l.id -ne $LeaseId){exit 0}
  $name=[string]$l.model
  if(-not(Valid-Model $name)){exit 2}
  $end=[DateTime]::Parse([string]$l.until_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
  $now=[DateTime]::UtcNow
  if($now -ge $end){
   # Never unload an unrelated, newer lease. Other Ollama clients may share this model.
   $current=Read-Lease
   if($current -and $current.id -eq $LeaseId){
    try{Unload $name;Lease-Event 'lease_deadline_unloaded' $name}catch{Lease-Event 'lease_deadline_unload_failed' $name}
    $last=Read-Lease;if($last -and $last.id -eq $LeaseId){Clear-Lease}
   }
   exit 0
  }
  try{
   $ps=Api 'GET' '/api/ps' $null 5
   $models=@($ps.models)
   $loaded=$null
   foreach($entry in $models){
    if($null -eq $entry){continue}
    if(([string]$entry.name -ceq $name) -or ([string]$entry.model -ceq $name)){$loaded=$entry;break}
   }
   if($null -eq $loaded){
    # Respect an external manual unload: do NOT silently restart a model.
    Lease-Event 'unloaded_before_deadline' $name
    $current=Read-Lease;if($current -and $current.id -eq $LeaseId){Clear-Lease}
    exit 0
   }
   $wasLoaded=$true
   $expires=[DateTime]::MinValue
   $rawExpires=[string]$loaded.expires_at
   if(-not [DateTime]::TryParse($rawExpires,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$expires)){
    $expires=$now.AddSeconds(15)
   }
   if(Lease-Refresh-Needed ($expires.ToUniversalTime()) $end $now){
    $current=Read-Lease
    if($current -and $current.id -eq $LeaseId){
     $remaining=[Math]::Max(1,[Math]::Ceiling(($end-[DateTime]::UtcNow).TotalSeconds))
     [void](Api 'POST' '/api/generate' ([ordered]@{model=$name;prompt='';stream=$false;keep_alive=('{0}s' -f $remaining)}) 60)
     Lease-Event 'keep_alive_reasserted' $name
    }
   }
  }catch{
   Lease-Event 'status_probe_failed' $name
   # A transient Ollama outage is not proof that the model should be restarted.
  }
  Start-Sleep -Seconds ([Math]::Max(1,[Math]::Min(4,[Math]::Ceiling(($end-[DateTime]::UtcNow).TotalSeconds))))
 }
}
if($Action -eq 'List'){
 $installed=@(Models '/api/tags')
 $loaded=@(Models '/api/ps')
 $lease=Read-Lease
 $safeLease=$null
 if($lease -and $lease.schema -eq 'reflexcore.model.lease.v1' -and (Valid-Model ([string]$lease.model))){
  $safeLease=[ordered]@{model=[string]$lease.model;until_utc=[string]$lease.until_utc}
 }
 $result=[ordered]@{schema='reflexcore.models.status.v1';installed=@($installed);loaded=@($loaded);lease=$safeLease}
 ConvertTo-Json -InputObject $result -Depth 5 -Compress
 exit 0
}
if($Action -eq 'Load'){
 if(-not (Valid-Model $Model)){throw 'Invalid model id'}
 $installed=@(Models '/api/tags')
 if($installed -cnotcontains $Model){throw 'Model is not installed locally; use Ollama to pull it first'}
 # Cancel the earlier managed lease; Ollama independently enforces the same idle timeout.
 Clear-Lease
 $duration=('{0}m' -f $Minutes)
 [void](Api 'POST' '/api/generate' ([ordered]@{model=$Model;prompt='';stream=$false;keep_alive=$duration}) 180)
 $confirmed=$false
 for($attempt=0;$attempt -lt 3;$attempt++){
  $active=@(Models '/api/ps')
  if($active -ccontains $Model){$confirmed=$true;break}
  Start-Sleep -Seconds 1
 }
 if(-not $confirmed){Lease-Event 'load_not_present_in_ollama_ps' $Model;throw 'Ollama did not confirm model residency in /api/ps'}
 $id=[guid]::NewGuid().ToString('N')
 $expires=[DateTime]::UtcNow.AddMinutes($Minutes).ToString('o')
 Put-Lease ([ordered]@{schema='reflexcore.model.lease.v1';id=$id;model=$Model;until_utc=$expires})
 Lease-Event 'lease_started_confirmed' $Model
 # Enforce a wall-clock deadline even if the model remains busy. Survives closing the main UI/tray.
 $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Action Watch -LeaseId '+$id
 try{[void](Start-Process -FilePath $ps -ArgumentList $args -WorkingDirectory $root -WindowStyle Hidden -PassThru)}
 catch {Clear-Lease $Model;Unload $Model;throw 'Timed lease supervisor could not start; model unloaded for safety'}
 ConvertTo-Json -InputObject ([ordered]@{schema='reflexcore.models.action.v1';ok=$true;action='load';model=$Model;verified_loaded=$true;until_utc=$expires}) -Compress
 exit 0
}
if($Action -eq 'Stop'){
 if(-not(Valid-Model $Model)){throw 'Invalid model id'}
 Clear-Lease $Model
 Unload $Model
 Write-Output '{"schema":"reflexcore.models.action.v1","ok":true,"action":"stop"}'
 exit 0
}
if($Action -eq 'StopAll'){
 # Stop only known local Reflex tasks and locally loaded Ollama models, not unrelated Windows processes.
 $bridge=Join-Path $root 'data\bridge'
 if(-not(Test-Path $bridge)){[void](New-Item -ItemType Directory -Path $bridge -Force)}
 $stamp=[DateTime]::UtcNow.ToString('o')
 [IO.File]::WriteAllText((Join-Path $bridge 'control.txt'),'stop-all',$utf8)
 [IO.File]::WriteAllText((Join-Path $bridge 'global-stop.signal'),$stamp,$utf8)
 # Tell the Citadel native bridge to stop but never assume it stops browser JS by itself.
 try{[void](Api 'POST' '/api/agent/stop' ([ordered]@{}) 2)}catch{}
 Clear-Lease
 $reachable=$true
 try{$all=@(Models '/api/ps')}catch{$reachable=$false;$all=@()}
 $errors=0
 foreach($m in $all){try{Unload $m}catch{$errors++}}
 ConvertTo-Json -InputObject ([ordered]@{schema='reflexcore.models.action.v1';ok=($errors -eq 0);action='stop-all';unload_attempts=$all.Count;unload_errors=$errors;ollama_reachable=$reachable;tasks_stop_requested=$true}) -Compress
 if($errors){exit 2}
 exit 0
}
throw 'Unsupported operation'
