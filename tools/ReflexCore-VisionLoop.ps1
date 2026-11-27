#requires -Version 5.1
<#
ReflexCore 0.7.0 VISION-LOOP PREVIEW3 FIX2 (GAC compile references)
Read-only local visual observation and an explicitly authorized, narrowly scoped Notepad task.
No screenshots, model prompts, raw responses, window titles or personal paths are persisted.
Usage:
  -Action SelfTest              offline guards (no Ollama or input)
  -Action Probe -Mode Headless  two synthetic RGB/JPEG challenges through real Ollama VLM
  -Action Observe              focus an existing Notepad window during the countdown
  -Action DemoNotepad -AllowInput   open a new, uniquely named file in Notepad, type, save, verify disk contents
  -Action Stop                  cooperative request (for another PowerShell window)
  -Action Status                sanitized last stage
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest','Probe','Observe','DemoNotepad','Status','Stop')][string]$Action='SelfTest',
    [ValidateSet('Visible','Headless')][string]$Mode='Visible',
    [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9_.:/-]{0,127}\z')][string]$Model='qwen3-vl:2b-instruct',
    [ValidateRange(320,1024)][int]$ImageWidth=640,
    [ValidateRange(30,240)][int]$TimeoutSec=120,
    [ValidateRange(0,15)][int]$CaptureDelaySec=4,
    [switch]$AllowInput,
    [switch]$UnloadModelAfter,
    [ValidateSet('Auto','Visual')][string]$Route='Auto',
    [switch]$TestFixture,
    [switch]$UnicodeFixture,
    [ValidatePattern('\A[0-9a-f]{32}\z')][string]$CompositionRun,
    [switch]$TestNativeInput
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path -Path $PSScriptRoot -Parent
$runtime=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ReflexCore\runtime'
$statusPath=Join-Path $runtime 'vision-loop-status.json'
$activityPath=Join-Path $runtime 'activity.json'
$stopPath=Join-Path $runtime 'vision-stop.signal'
$globalStop=Join-Path $root 'data\bridge\global-stop.signal'
$utf8=New-Object System.Text.UTF8Encoding($false)
$startedUtc=[DateTime]::UtcNow
$sequence=0
$watch=[Diagnostics.Stopwatch]::StartNew()
$mutex=$null
$mutexHeld=$false
$ownedPath=''
$demoCreated=$false
$script:lastTps=0.0
$script:lastOutputTokens=0
$script:modelLoadedAtStart=$null
$script:apiRequests=0
$script:loadRequested=$false
$hudCapturePath=Join-Path $runtime 'hud-capture.signal'

function Write-Stage([string]$stage,[string]$result='pending') {
    $valid=@('ready','observing','capturing','thinking','deciding','executing','awaiting_effect','verifying','verified','completed','failed','stopped')
    if($valid -cnotcontains $stage -or @('pending','pass','fail','stopped') -cnotcontains $result) {throw 'Internal telemetry enum rejected'}
    $script:sequence++
    if(-not (Test-Path -LiteralPath $runtime)) {New-Item -ItemType Directory -Path $runtime -Force|Out-Null}
    $now=[DateTime]::UtcNow.ToString('o')
    $ev=[ordered]@{schema='reflexcore.visionloop.status.v1';stage=$stage;result=$result;elapsed_ms=[long]$watch.ElapsedMilliseconds;last_tps=$script:lastTps;last_output_tokens=$script:lastOutputTokens;at_utc=$now}
    $activity=[ordered]@{schema='reflexcore.activity.v1';source='vision_loop';stage=$stage;action=$(if($Action -eq 'DemoNotepad'){'focus'}else{'none'});sequence=$script:sequence;elapsed_ms=[long]$watch.ElapsedMilliseconds;last_tps=$script:lastTps;last_output_tokens=$script:lastOutputTokens;at_utc=$now}
    foreach($pair in @([pscustomobject]@{File=$statusPath;Data=$ev},[pscustomobject]@{File=$activityPath;Data=$activity})) {
        $temporary=$pair.File+'.reflex-tmp-'+[guid]::NewGuid().ToString('N')
        try {
            [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $pair.Data -Compress -Depth 5),$utf8)
            Move-Item -LiteralPath $temporary -Destination $pair.File -Force
        } finally {if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
    }
}
function Require-NotStopped {
    if(Test-QueueCancelled){throw 'Stopped by operator; queue claim cancelled or interrupted.'}
    foreach($path in @($stopPath,$globalStop)) {
        if(Test-Path -LiteralPath $path -PathType Leaf) {
            $modified=(Get-Item -LiteralPath $path).LastWriteTimeUtc
            if($modified -ge $startedUtc) {throw 'Stopped by operator; no further input permitted.'}
        }
    }
}
function Test-StopRequested {
    if(Test-QueueCancelled){return $true}
    foreach($signal in @($stopPath,$globalStop)) {
        if([IO.File]::Exists($signal) -and [IO.File]::GetLastWriteTimeUtc($signal) -ge $startedUtc){return $true}
    }
    return $false
}
function Test-QueueCancelled {
    $claim=$env:REFLEXCORE_QUEUE_MANIFEST
    if(!$claim){return $false}
    if($claim -cnotmatch '^[0-9]{17}-[0-9a-f]{32}\.job$'){return $true}
    $bridge=Join-Path $root 'data/bridge'
    return (![IO.File]::Exists((Join-Path (Join-Path $bridge 'running') $claim)) -or
        [IO.File]::Exists((Join-Path (Join-Path $bridge 'queue-requests') ($claim.Replace('.job','.cancel')))))
}
function Test-ModelName([string]$name) {
    if ($name -notmatch '\A[A-Za-z0-9][A-Za-z0-9_.:/-]{0,127}\z') {return $false}
    if ($name -match '(\.\.|//|::|:/|/\z|:\z)') {return $false}
    return $true
}
function Test-ResponseShape([object]$obj,[bool]$probe) {
    if ($null -eq $obj) {throw 'Missing Ollama JSON object'}
    if($probe) {
        if (@('red','blue','unknown') -cnotcontains [string]$obj.dominant_color) {throw 'VLM probe enum rejected'}
        return [string]$obj.dominant_color
    }
    # Normalize only unambiguous app names. Never interpret partial or compound
    # classifications as a positive authorization for keyboard input.
    $app=([string]$obj.application).Trim().ToLowerInvariant()
    switch($app) {
        'notepad' {$app='notepad';break}
        'windows notepad' {$app='notepad';break}
        'microsoft notepad' {$app='notepad';break}
        'notepad.exe' {$app='notepad';break}
        'other' {$app='other';break}
        'uncertain' {$app='uncertain';break}
        'unknown' {$app='uncertain';break}
        default {throw 'VLM application enum rejected'}
    }
    $editable=([string]$obj.editable_area).Trim().ToLowerInvariant()
    switch($editable) {
        'yes' {$editable='yes';break}
        'no' {$editable='no';break}
        'unknown' {$editable='unknown';break}
        'uncertain' {$editable='unknown';break}
        default {throw 'VLM editability enum rejected'}
    }
    return @($app,$editable)
}
function Get-VisualPrompt {
    return 'Inspect the supplied screenshot of a Windows application window. You must report what is VISIBLE in the pixels, not guess from this prompt. Return a JSON object with exactly two string properties: application and editable_area. For application, choose EXACTLY one of these single words: notepad, other, uncertain. For editable_area, choose EXACTLY one of: yes, no, unknown. Example for a visibly confirmed Notepad editor: {"application":"notepad","editable_area":"yes"}. Example when not sure: {"application":"uncertain","editable_area":"unknown"}. Never join choices with | or commas. Do not include explanations or other properties.'
}
function Assert-Config {
    if(-not(Test-ModelName $Model)) {throw 'Invalid local model identifier'}
    if ($AllowInput -and $Action -ne 'DemoNotepad') {throw '-AllowInput is accepted only with -Action DemoNotepad'}
    if ($Action -eq 'DemoNotepad' -and -not $AllowInput) {throw 'Explicit -AllowInput is mandatory before typing into Notepad'}
    if($Mode -eq 'Headless' -and @('DemoNotepad','Observe') -ccontains $Action) {throw 'This preview can interact with a desktop only in Visible mode. Headless supports Probe/SelfTest.'}
}
function Resolve-FrameworkAssemblyPath([string]$name) {
    # Windows PowerShell 5.1 Add-Type / CSharpCodeProvider may NOT resolve
    # unqualified GAC metadata references such as UIAutomationClient.dll.
    # Resolve the real framework assembly first, then give its full path to
    # the C# compiler. Never download DLLs or search the user's PATH.
    $found=[AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -ieq $name } |
        Select-Object -First 1
    if($null -eq $found) {
        try { Add-Type -AssemblyName $name -ErrorAction Stop }
        catch { throw ('Required Windows .NET Framework assembly '+$name+' could not be loaded: '+$_.Exception.Message) }
        $found=[AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { $_.GetName().Name -ieq $name } |
            Select-Object -First 1
    }
    if($null -eq $found) {throw ('Assembly load returned no matching reference: '+$name)}
    $location=[string]$found.Location
    if([string]::IsNullOrWhiteSpace($location) -or -not [IO.File]::Exists($location)) {
        throw ('Framework assembly location unavailable: '+$name)
    }
    return $location
}
function Load-VisionHost {
    $path=Join-Path $PSScriptRoot 'ReflexCore-VisionHost.cs'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)) {throw 'VisionHost C# source is missing'}
    $hostType='ReflexCore.VisionLoop.Host' -as [type]
    if($null -eq $hostType) {
        $source=[IO.File]::ReadAllText($path)
        # Each reference is resolved to an actual system DLL. The original
        # Preview3 passed bare 'UIAutomationClient.dll' and failed to compile.
        $refs=@(
            'System', 'System.Core', 'System.Drawing',
            'UIAutomationClient', 'UIAutomationTypes', 'WindowsBase'
        ) | ForEach-Object { Resolve-FrameworkAssemblyPath $_ }
        Add-Type -TypeDefinition $source -ReferencedAssemblies $refs -ErrorAction Stop
    } elseif($null -eq $hostType.GetMethod('CaptureJpeg')) {throw 'Incompatible VisionHost already loaded in this PowerShell process'}
}
function Test-ModelAlreadyLoaded {
    # A failed /api/ps query is NOT proof the model was unloaded.
    $handler=$null; $client=$null
    try {
        Add-Type -AssemblyName System.Net.Http
        $handler=New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy=$false
        $handler.AllowAutoRedirect=$false
        $client=[System.Net.Http.HttpClient]::new($handler)
        $client.Timeout=[TimeSpan]::FromSeconds(3)
        $http=$client.GetAsync('http://127.0.0.1:11434/api/ps').GetAwaiter().GetResult()
        try {
            if(-not $http.IsSuccessStatusCode){return $null}
            $value=ConvertFrom-Json -InputObject ($http.Content.ReadAsStringAsync().GetAwaiter().GetResult()) -ErrorAction Stop
            if($value.PSObject.Properties.Name -notcontains 'models'){return $null}
            foreach($m in @($value.models)) {
                if(([string]$m.name) -ceq $Model -or ([string]$m.model) -ceq $Model){return $true}
            }
            return $false
        } finally {$http.Dispose()}
    } catch {return $null}
    finally {if($null -ne $client){$client.Dispose()};if($null -ne $handler){$handler.Dispose()}}
}
function Try-UnloadOwnedModel {
    if($script:apiRequests -lt 1 -and !$script:loadRequested){return}
    if(-not $UnloadModelAfter -and $script:modelLoadedAtStart -cne $false){
        Write-Host '[ReflexCore] Ollama model preserved: preloaded or ownership unknown.'
        return
    }
    $handler=$null;$client=$null;$content=$null;$http=$null
    try {
        Add-Type -AssemblyName System.Net.Http
        $handler=New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy=$false
        $handler.AllowAutoRedirect=$false
        $client=[System.Net.Http.HttpClient]::new($handler)
        $client.Timeout=[TimeSpan]::FromSeconds(8)
        # This unloads ONLY the selected local model, not Ollama and not arbitrary processes.
        $data=ConvertTo-Json -InputObject ([ordered]@{model=$Model;keep_alive=0;stream=$false}) -Compress
        $content=[System.Net.Http.StringContent]::new($data,[Text.Encoding]::UTF8,'application/json')
        $http=$client.PostAsync('http://127.0.0.1:11434/api/generate',$content).GetAwaiter().GetResult()
        if(-not $http.IsSuccessStatusCode){throw ('HTTP '+[int]$http.StatusCode)}
        Write-Host '[ReflexCore] VisionLoop requested unload of its selected Ollama model.'
    } catch {
        Write-Warning ('Ollama model unload not confirmed: '+$_.Exception.Message)
    } finally {
        if($null -ne $http){$http.Dispose()};if($null -ne $content){$content.Dispose()}
        if($null -ne $client){$client.Dispose()};if($null -ne $handler){$handler.Dispose()}
    }
}
function Send-GuardedModelRequest($client,$content) {
    $cancel=[Threading.CancellationTokenSource]::new()
    try{
        Require-NotStopped
        $pending=$client.PostAsync('http://127.0.0.1:11434/api/generate',$content,$cancel.Token)
        while(!$pending.IsCompleted){
            if(!$pending.Wait(150) -and (Test-StopRequested)){
                $cancel.Cancel()
                throw 'Stopped by operator during local inference.'
            }
        }
        $reply=$pending.GetAwaiter().GetResult()
        try{Require-NotStopped}catch{$reply.Dispose();throw}
        return $reply
    }finally{$cancel.Dispose()}
}
function Initialize-VisualModel {
    if($script:modelLoadedAtStart -cne $false){return}
    Require-NotStopped
    Add-Type -AssemblyName System.Net.Http
    $handler=[Net.Http.HttpClientHandler]::new()
    $handler.UseProxy=$false
    $handler.AllowAutoRedirect=$false
    $client=[Net.Http.HttpClient]::new($handler)
    $client.Timeout=[TimeSpan]::FromSeconds($TimeoutSec)
    $body=@{model=$Model;stream=$false;options=$modelOptions;keep_alive='2m'}
    $content=[Net.Http.StringContent]::new(($body|ConvertTo-Json -Compress -Depth 5),[Text.Encoding]::UTF8,'application/json')
    try{
        $script:loadRequested=$true
        $res=Send-GuardedModelRequest $client $content
        try{if(!$res.IsSuccessStatusCode){throw 'Local model preload failed'}}finally{$res.Dispose()}
        Require-NotStopped
    }finally{$content.Dispose();$client.Dispose()}
}
function Capture-WithoutHud([string]$token) {
    # Tray owns a small overlay; suppress it while screenshot pixels are captured.
    [IO.File]::WriteAllText($hudCapturePath,[DateTime]::UtcNow.ToString('o'),$utf8)
    try {
        Start-Sleep -Milliseconds 750
        Require-NotStopped
        return [ReflexCore.VisionLoop.Host]::CaptureJpeg($token,$ImageWidth)
    } finally {
        try {if(Test-Path -LiteralPath $hudCapturePath){Remove-Item -LiteralPath $hudCapturePath -Force}}catch{}
    }
}
function Invoke-LocalVision([byte[]]$jpeg,[string]$prompt,[bool]$structured=$false) {
    if($null -eq $jpeg -or $jpeg.Length -lt 500 -or $jpeg.Length -gt 512KB) {throw 'Image size safety guard rejected frame'}
    if($prompt.Length -gt 900) {throw 'Prompt size safety guard rejected request'}
    Require-NotStopped
    $schema=[ordered]@{
        type='object'
        properties=[ordered]@{
            application=[ordered]@{type='string';enum=@('notepad','other','uncertain')}
            editable_area=[ordered]@{type='string';enum=@('yes','no','unknown')}
        }
        required=@('application','editable_area')
        additionalProperties=$false
    }
    $body=[ordered]@{
        model=$Model;prompt=$prompt;images=@([Convert]::ToBase64String($jpeg));stream=$false
        format=$(if($structured){$schema}else{'json'})
        options=$modelOptions
    }
    if($null -ne $modelKeep){$body.keep_alive=$modelKeep}
    $data=ConvertTo-Json -InputObject $body -Compress -Depth 8
    $jpeg=$null
    $body=$null
    if($data.Length -gt 786432) {throw 'Request exceeded bounded in-memory size'}
    Add-Type -AssemblyName System.Net.Http
    $handler=New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy=$false
    $handler.AllowAutoRedirect=$false
    $client=[System.Net.Http.HttpClient]::new($handler)
    $client.Timeout=[TimeSpan]::FromSeconds($TimeoutSec)
    $response=$null
    $content=$null
    try {
        $content=[System.Net.Http.StringContent]::new($data,[Text.Encoding]::UTF8,'application/json')
        $script:apiRequests++
        $response=Send-GuardedModelRequest $client $content
        if(-not $response.IsSuccessStatusCode) {throw ('Local Ollama HTTP '+[int]$response.StatusCode)}
        $raw=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if($raw.Length -gt 262144) {throw 'Ollama output too large'}
        $json=ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        if($json.done -ne $true -or [string]::IsNullOrWhiteSpace([string]$json.response)) {throw 'Ollama incomplete or empty result'}
        $parsed=ConvertFrom-Json -InputObject ([string]$json.response) -ErrorAction Stop
        $rate=0.0
        $count=0
        if($null -ne $json.eval_count){$count=[int]$json.eval_count}
        if($null -ne $json.eval_duration -and [double]$json.eval_duration -gt 0 -and $count -ge 0){
            $rate=[math]::Round(($count * 1000000000.0)/[double]$json.eval_duration,1)
        }
        if($rate -ge 0 -and $rate -le 1000){$script:lastTps=$rate;$script:lastOutputTokens=$count}
        Write-Stage 'verifying'
        Require-NotStopped
        return [pscustomobject]@{Parsed=$parsed;TotalMs=[math]::Round(([double]$json.total_duration/1000000),2);PromptTokens=$json.prompt_eval_count;OutputTokens=$json.eval_count}
    } finally {
        if($null -ne $response){$response.Dispose()}
        if($null -ne $content){$content.Dispose()}
        $client.Dispose();$handler.Dispose()
    }
}
function Invoke-VisualClassification([byte[]]$jpeg,[string]$token) {
    $prompt=Get-VisualPrompt
    for($attempt=1;$attempt -le 2;$attempt++) {
        Require-NotStopped
        if(-not [ReflexCore.VisionLoop.Host]::IsForeground($token)) {
            throw 'Notepad lost foreground focus during visual classification; input blocked.'
        }
        try {
            # First call uses Ollama JSON Schema. If the model rejects this
            # format or returns an invalid enum, retry once with format=json.
            $reply=Invoke-LocalVision $jpeg $prompt ($attempt -eq 1)
            $labels=@(Test-ResponseShape $reply.Parsed $false)
            return [pscustomobject]@{Labels=$labels;Reply=$reply;Attempts=$attempt}
        } catch {
            $reason=$_.Exception.Message
            $recoverable=($reason -match 'VLM (application|editability) enum rejected|Local Ollama HTTP 400|JSON|incomplete or empty result')
            if($attempt -ne 1 -or -not $recoverable) {throw}
            Write-Host '[ReflexCore] Structured visual output invalid; one read-only JSON retry (no input).' -ForegroundColor Yellow
        }
    }
    throw 'Visual classification failed; input blocked.'
}
# The model is a fallible image classifier, not the Windows process authority. For
# this ONE explicitly authorized demo, independent OS UIA plus the per-key
# process/title/focus checks in VisionHost remain mandatory before any input.
# Never use this policy for general app control or for model-proposed actions.
function Get-NotepadDemoGate([string]$app,[string]$editable,[bool]$osEditable) {
    if(@('notepad','other','uncertain') -cnotcontains $app -or
       @('yes','no','unknown') -cnotcontains $editable) {return 'deny_invalid'}
    if(-not $osEditable) {return 'deny_os'}
    if($editable -ceq 'no') {return 'deny_visual_editor'}
    # A classifier's 'other' is not proof of process identity. A conflict may
    # proceed only when the model DID see an editable area and the OS verified
    # an editor inside the exact token-bound foreground notepad.exe window.
    if($app -ceq 'other') {
        if($editable -cne 'yes') {return 'deny_visual_conflict'}
        return 'uia_conflict'
    }
    if($app -ceq 'notepad' -and $editable -ceq 'yes') {return 'vlm_and_uia'}
    return 'uia_uncertain'
}

function Invoke-SkillReader([string]$arguments,[string]$text) {
    $info=[Diagnostics.ProcessStartInfo]::new($verifier,$arguments)
    $info.WorkingDirectory=$root
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    if($text){$info.EnvironmentVariables['REFLEXCORE_EXPECTED_TEXT']=$text}
    Require-NotStopped
    $worker=[Diagnostics.Process]::Start($info)
    try {
        $output=$worker.StandardOutput.ReadToEndAsync()
        $deadline=[Diagnostics.Stopwatch]::StartNew()
        while(!$worker.WaitForExit(75)){
            Require-NotStopped
            if($deadline.Elapsed.TotalSeconds -ge 11){throw 'Disk readback deadline exceeded; effect unknown'}
        }
        Require-NotStopped
        if($worker.ExitCode -ne 0){throw 'The requested saved-text skill could not be verified'}
        $json=$output.GetAwaiter().GetResult()
        if($json.Length -gt 1024){throw 'Invalid skill evidence'}
        return ($json | ConvertFrom-Json)
    } finally {
        if(!$worker.HasExited){$worker.Kill();$worker.WaitForExit()}
        $worker.Dispose()
    }
}

function Confirm-SavedText([string]$run,[string]$text) {
    $scope=if($TestFixture){'fixture'}else{'desktop'}
    $e=Invoke-SkillReader "learning verify-notepad $run $scope" $text
    if($e.schema -cne 'reflexcore.skill.evidence.v1' -or $e.run_id -cne $run -or
       $e.skill_id -cne 'artifact.verify_saved_text' -or $e.skill_version -ne 1 -or
       $e.adapter -cne 'notepad' -or $e.adapter_version -ne 1 -or $e.verifier_version -ne 1 -or
       $e.outcome -cne 'verified'){throw 'Unexpected disk evidence identity'}
    return $e
}

. (Join-Path $PSScriptRoot 'ReflexCore-SkillMemory.ps1')
if($TestNativeInput -and !$TestFixture){throw 'Native edit override requires the test fixture'}
if(($TestFixture -or $UnicodeFixture -or $PSBoundParameters.ContainsKey('Route')) -and $Action -ne 'DemoNotepad'){
    throw 'Notepad options require DemoNotepad'
}
$modelOptions=@{temperature=0;num_ctx=2048;num_predict=100}
$modelKeep=$null
if($Action -in 'Probe','Observe' -or ($Action -eq 'DemoNotepad' -and $Route -eq 'Visual')){
    $settingsPath=Join-Path $root 'data/settings/ollama-local.json'
    if([IO.File]::Exists($settingsPath)){
        if((Get-Item -LiteralPath $settingsPath).Length -gt 16384){throw 'Model settings too large'}
        $cfg=Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath | ConvertFrom-Json
        if($cfg.schema -cne 'reflexcore.ollama.settings.v1'){throw 'Model settings schema rejected'}
        if(!$PSBoundParameters.ContainsKey('Model')){$Model=[string]$cfg.model}
        foreach($entry in @(@('temperature',0,2),@('num_ctx',512,8192),@('num_predict',1,512),@('top_p',0.05,1),@('top_k',1,100),@('repeat_penalty',0.8,2),@('num_thread',1,32),@('num_gpu',0,99),@('seed',0,2147483647))){
            $key=$entry[0]
            if($cfg.PSObject.Properties[$key]){
                $v=$cfg.$key
                if(($v -is [ValueType]) -and $v -ge $entry[1] -and $v -le $entry[2]){$modelOptions[$key]=$v}
            }
        }
        if($cfg.PSObject.Properties['keep_alive_minutes'] -and $cfg.keep_alive_minutes -in (1..240)){$modelKeep=([string][int]$cfg.keep_alive_minutes)+'m'}
    }
}
Assert-Config
if($Action -eq 'Stop') {
    if(-not(Test-Path -LiteralPath $runtime)) {New-Item -ItemType Directory -Path $runtime -Force|Out-Null}
    [IO.File]::WriteAllText($stopPath,[DateTime]::UtcNow.ToString('o'),$utf8)
    Write-Host '[ReflexCore] Cooperative VISION-LOOP STOP signaled. A pending Ollama call may finish before observing it.'
    return
}
if($Action -eq 'Status') {
    if(Test-Path -LiteralPath $statusPath -PathType Leaf) {
        $s=Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if($s.schema -eq 'reflexcore.visionloop.status.v1') {
            Write-Host ('[ReflexCore] Vision Loop: '+$s.stage+' / '+$s.result+' / '+$s.elapsed_ms+' ms')
            return
        }
    }
    Write-Host '[ReflexCore] Vision Loop: no status.'
    return
}
Load-VisionHost
if($Action -eq 'SelfTest') {
    [ReflexCore.VisionLoop.Host]::SelfTest()
    foreach($invalid in @('../evil','http://evil','x y','foo//bar','foo::tag','bad/','')) {if(Test-ModelName $invalid){throw ('Model guard accepted '+$invalid)}}
    foreach($valid in @('qwen3-vl:2b-instruct','llama3.2:latest','registry.example:5000/library/model:1.0')) {if(-not(Test-ModelName $valid)){throw ('Model guard rejected '+$valid)}}
    $tested=@(Test-ResponseShape ([pscustomobject]@{application='Microsoft Notepad';editable_area='YES'}) $false)
    if($tested.Count -ne 2 -or $tested[0] -ne 'notepad' -or $tested[1] -ne 'yes') {throw 'Visual enum parse failed'}
    $blocked=$false
    try {[void](Test-ResponseShape ([pscustomobject]@{application='notepad';editable_area='execute'}) $false)}catch{$blocked=$true}
    if(-not $blocked){throw 'Arbitrary model action accepted'}
    foreach($invalidApp in @('notepad|other|uncertain','notepad,other','notepad or other','Microsoft Word','')) {
        $blocked=$false
        try {[void](Test-ResponseShape ([pscustomobject]@{application=$invalidApp;editable_area='yes'}) $false)}catch{$blocked=$true}
        if(-not $blocked){throw 'Compound or unknown model application accepted'}
    }
    $p=Get-VisualPrompt
    if($p -match 'notepad\|other\|uncertain' -or $p.Length -gt 900){throw 'Visual prompt not bounded or contains pipe-delimited enum'}

    if((Test-ResponseShape ([pscustomobject]@{dominant_color='red'}) $true) -ne 'red'){throw 'Synthetic probe guard failed'}
    # Offline policy matrix: disagreement is NOT VLM success and OS failures
    # must never authorize input. This test sends no keys and uses no screen.
    $cases=@(
        @{app='other';edit='yes';os=$true;want='uia_conflict'},
        @{app='other';edit='yes';os=$false;want='deny_os'},
        @{app='other';edit='no';os=$true;want='deny_visual_editor'},
        @{app='other';edit='unknown';os=$true;want='deny_visual_conflict'},
        @{app='notepad';edit='yes';os=$true;want='vlm_and_uia'},
        @{app='notepad';edit='yes';os=$false;want='deny_os'},
        @{app='notepad';edit='no';os=$true;want='deny_visual_editor'},
        @{app='notepad';edit='unknown';os=$true;want='uia_uncertain'},
        @{app='uncertain';edit='yes';os=$true;want='uia_uncertain'},
        @{app='uncertain';edit='unknown';os=$true;want='uia_uncertain'},
        @{app='invalid';edit='yes';os=$true;want='deny_invalid'}
    )
    foreach($c in $cases) {
        $actual=Get-NotepadDemoGate ([string]$c.app) ([string]$c.edit) ([bool]$c.os)
        if($actual -cne [string]$c.want){throw ('Notepad policy matrix failed: '+$c.app+'/'+$c.edit+'/'+$c.os)}
    }
    if(-not ([ReflexCore.VisionLoop.Host].GetMethod('ConfirmEditableForeground'))){throw 'OS UIA guard missing'}
    Write-Host '[ReflexCore] VisionLoop policy and response parser self-tests PASSED (no screen, Ollama or input).'
    return
}

try {
    $created=$false
    $mutex=[System.Threading.Mutex]::new($false,'Local\ReflexCoreVisionLoop',[ref]$created)
    try {$mutexHeld=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException] {$mutexHeld=$true}
    if(-not $mutexHeld) {throw 'Another VisionLoop session is active'}
    Require-NotStopped
    if($Action -ne 'DemoNotepad' -or $Route -eq 'Visual'){$script:modelLoadedAtStart=Test-ModelAlreadyLoaded}
    Write-Stage 'ready'
    if($Action -eq 'Probe') {
        $prompt='Classify the dominant BACKGROUND color in the supplied synthetic JPEG (ignore a small white rectangle in the middle). Respond with JSON only: {"dominant_color":"red"} or {"dominant_color":"blue"} or {"dominant_color":"unknown"}. Use pixel evidence.'
        foreach($case in @(@{red=$true;expected='red'},@{red=$false;expected='blue'})) {
            Require-NotStopped
            Write-Stage 'capturing'
            $frame=[ReflexCore.VisionLoop.Host]::SyntheticColorJpeg([bool]$case.red)
            Write-Stage 'thinking'
            $reply=Invoke-LocalVision $frame $prompt
            $answer=Test-ResponseShape $reply.Parsed $true
            $frame=$null
            if($answer -cne $case.expected){throw 'VISION NOT VERIFIED: actual JPEG color classification failed'}
            Write-Host ('[ReflexCore] Synthetic VLM '+$case.expected+': VERIFIED; '+$reply.TotalMs+' ms; image bytes were sent to localhost Ollama.')
        }
        Write-Stage 'completed' 'pass'
        Write-Host '[ReflexCore] Both synthetic image challenges verified (actual model response, not a text-path test).' -ForegroundColor Green
    }
    elseif($Action -eq 'Observe') {
        Write-Host ('[ReflexCore] Focus an existing Notepad window within '+$CaptureDelaySec+' sec. Local screenshot only; no input.')
        Start-Sleep -Seconds $CaptureDelaySec
        Require-NotStopped
        Write-Stage 'capturing'
        $frame=Capture-WithoutHud ''
        Write-Stage 'thinking'
        $vision=Invoke-VisualClassification $frame ''
        $reply=$vision.Reply
        $result=$vision.Labels
        $frame=$null
        if($result[0] -ne 'notepad') {throw 'Vision guard: model did not confirm Notepad; no input performed'}
        Write-Stage 'verified' 'pass'
        Write-Host ('[ReflexCore] Local observation: app='+$result[0]+'; editor='+$result[1]+'; model_ms='+$reply.TotalMs+'; input=NONE.') -ForegroundColor Green
        Write-Stage 'completed' 'pass'
    }
    elseif($Action -eq 'DemoNotepad') {
        if($Route -eq 'Visual'){
            Write-Stage 'thinking'
            Initialize-VisualModel
            Require-NotStopped
        }
        $verifier=Join-Path $root 'target/release/reflexcore.exe'
        if(![IO.File]::Exists($verifier)){throw 'Build the release runtime before starting the editor'}
        $bound=Invoke-SkillReader 'learning bind artifact.verify_saved_text 1 notepad foreground' ''
        if($bound.schema -cne 'reflexcore.skill.binding.v1' -or $bound.skill_id -cne 'artifact.verify_saved_text' -or
           $bound.skill_version -ne 1 -or $bound.binding.adapter -cne 'notepad' -or
           $bound.binding.contract_version -ne 1){throw 'Incompatible Notepad binding'}
        $skillRun=if($CompositionRun){
            if(!$TestFixture -or $env:REFLEXCORE_QUEUE_MANIFEST){throw 'Composition requires a direct fixture run'}
            $CompositionRun
        }elseif($env:REFLEXCORE_QUEUE_MANIFEST -and $null -ne $env:REFLEXCORE_EDITOR_RUN){
            if($env:REFLEXCORE_EDITOR_RUN -cnotmatch '\A[0-9a-f]{32}\z'){throw 'Invalid editor run identity'}
            $env:REFLEXCORE_EDITOR_RUN
        }else{[guid]::NewGuid().ToString('N')}
        $token='ReflexCore-VisionLoop-'+$skillRun+'.txt'
        if(-not [ReflexCore.VisionLoop.Host]::IsValidWindowToken($token)){throw 'Demo token generation rejected'}
        $desktop=if($TestFixture){[IO.Directory]::CreateDirectory((Join-Path $runtime 'fixtures')).FullName}else{[Environment]::GetFolderPath('Desktop')}
        if([string]::IsNullOrEmpty($desktop) -or -not(Test-Path -LiteralPath $desktop -PathType Container)) {throw 'Windows Desktop directory unavailable'}
        $ownedPath=Join-Path $desktop $token
        if([IO.File]::Exists($ownedPath)) {throw 'Random demo destination already exists; will not overwrite'}
        [IO.File]::Open($ownedPath,[IO.FileMode]::CreateNew).Dispose()
        $demoCreated=$true
        $notepad=Join-Path $env:WINDIR 'System32\notepad.exe'
        if(-not [IO.File]::Exists($notepad)) {throw 'Windows Notepad executable not found'}
        Write-Stage 'observing'
        Start-Process -FilePath $notepad -ArgumentList @('"'+$ownedPath+'"') -WorkingDirectory ([Environment]::SystemDirectory) -WindowStyle Normal
        $activation=[ReflexCore.VisionLoop.Host]::ActivateDemoTarget($token,15000)
        if($activation -cne 'ready'){throw ('Cannot securely identify and focus the Notepad demo window: '+$activation)}
        Require-NotStopped
        if($Route -eq 'Visual'){
            Write-Stage 'capturing'
            $frame=Capture-WithoutHud $token
            Write-Stage 'thinking'
            Write-Host ('[ReflexCore] Before local inference: '+[ReflexCore.VisionLoop.Host]::TargetEvidence($token))
            $vision=Invoke-VisualClassification $frame $token
            $frame=$null
            $afterInference=[ReflexCore.VisionLoop.Host]::TargetEvidence($token)
            Write-Host ('[ReflexCore] After local inference: '+$afterInference)
            if($afterInference -eq 'foreground_changed'){throw 'Foreground changed during inference; input blocked'}
        }
        # Reuse a proven method only after checking the current focused editor's ownership.
        # A missing cache entry or unfocused editor triggers full UIA discovery.
        $family='unknown'
        $skill=$null
        try {$family=[ReflexCore.VisionLoop.Host]::EditorFamily($token)}catch{}
        $memory=Join-Path $runtime ('notepad-v1-'+$family+'.json')
        $skill=Read-VerifiedSkill $memory $family
        if(!$skill){
            if(-not [ReflexCore.VisionLoop.Host]::ConfirmEditableForeground($token)){throw 'OS editor identity rejected'}
            $family=[ReflexCore.VisionLoop.Host]::EditorFamily($token)
            $memory=Join-Path $runtime ('notepad-v1-'+$family+'.json')
        }
        if($Route -eq 'Visual'){
            $gate=Get-NotepadDemoGate $vision.Labels[0] $vision.Labels[1] $true
            if($gate -like 'deny_*'){throw ('Visual evidence rejected: '+$gate)}
            Write-Host ('[ReflexCore] Visual evidence: '+$gate)
        }
        Write-Stage 'deciding'
        $preferred=if($TestNativeInput){'native'}elseif($skill){$skill.method}else{'discover'}
        $text=if($UnicodeFixture){'ReflexCore '+[char]0x0416+[char]0x03A9+[char]::ConvertFromUtf32(0x1f600)}else{'ReflexCore is operational'}
        Require-NotStopped
        Write-Stage 'executing'
        $used=[ReflexCore.VisionLoop.Host]::EditAndSave($token,$text,$preferred,[Func[bool]]{Test-StopRequested})
        Write-Stage 'awaiting_effect'
        Write-Stage 'verifying'
        $evidence=Confirm-SavedText $skillRun $text
        Require-NotStopped
        Write-Stage 'verified' 'pass'
        $memorySaved=$false
        try {if(!$TestNativeInput -and $family -ne 'unknown'){Save-VerifiedSkill $memory $family $used $skill; $memorySaved=$true}}
        catch {Write-Warning 'Verified on disk; skill memory could not be saved'}
        $hit=(!$TestNativeInput -and $null -ne $skill -and $preferred -ceq $used)
        Write-Host ('[ReflexCore] Verified Notepad disk readback. Method='+$used+'; learned route reused='+$hit+'; model calls='+$script:apiRequests)
        if($TestFixture){
            Require-NotStopped
            [ReflexCore.VisionLoop.Host]::CloseVerifiedTab($token)
        }
        [pscustomobject]@{schema='reflexcore.notepad.result.v1';verified=$true;skill=$evidence;method=$used;memory_hit=$hit;memory_saved=$memorySaved;model_calls=$script:apiRequests;elapsed_ms=$watch.ElapsedMilliseconds}
        Write-Stage 'completed' 'pass'
    }
} catch {
    $errorText=$_.Exception.Message
    try {
        if($errorText -like 'Stopped by operator*') {Write-Stage 'stopped' 'stopped'}
        else {Write-Stage 'failed' 'fail'}
    } catch {}
    Write-Host ('[ReflexCore] VisionLoop stopped/failed: '+$errorText) -ForegroundColor Red
    throw
} finally {
    try {Try-UnloadOwnedModel}catch{}
    if($mutexHeld -and $null -ne $mutex){try{$mutex.ReleaseMutex()}catch{}}
    if($null -ne $mutex){$mutex.Dispose()}
}
