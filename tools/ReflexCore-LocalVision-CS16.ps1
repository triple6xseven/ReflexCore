# ReflexCore 0.4.4: LOCAL VISION PROBE for private/offline Counter-Strike 1.6.
# Screenshot from foreground HL window -> localhost Ollama -> JSON observation. NO INPUT IS SENT.
param(
    [ValidateSet('SelfTest','Status','TextProbe','Analyze','Plan','Navigate','Warmup')][string]$Action = 'Analyze',
    [string]$Model = 'qwen3-vl:2b-instruct',
    [ValidateRange(256,768)][int]$ImageWidth = 512,
    [ValidateRange(20,600)][int]$TimeoutSec = 150,
    [ValidateRange(0,5)][int]$CaptureDelaySec = 5,
    [ValidateRange(1,30)][int]$FocusWaitSec = 20,
    [string]$RequestId = '',
    [string]$DecisionFile = ''
)
$ErrorActionPreference = 'Stop'
if((-not [string]::IsNullOrEmpty($DecisionFile)) -and $Action -notin @('Plan','Navigate')) { throw 'DecisionFile is allowed only with -Action Plan or -Action Navigate.' }
$localEndpoint = 'http://127.0.0.1:11434'
$cs = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Diagnostics;

namespace ReflexCore.LocalVision {
  public static class Capture {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr h, ref POINT p);
    public static bool Allowed(string processName) {
      return string.Equals(processName, "hl", StringComparison.OrdinalIgnoreCase) ||
             string.Equals(processName, "cstrike", StringComparison.OrdinalIgnoreCase);
    }
    public static void SelfTest() {
      if(!Allowed("hl") || !Allowed("CSTRIKE") || Allowed("explorer") || Allowed("chrome"))
        throw new Exception("Capture process allowlist failed");
      Console.WriteLine("[ReflexCore] Local Vision C# foreground guard passed");
    }
    public static bool IsGameForeground() {
      IntPtr h=GetForegroundWindow();if(h==IntPtr.Zero)return false;
      uint pid;GetWindowThreadProcessId(h,out pid);if(pid==0)return false;
      try {using(Process p=Process.GetProcessById((int)pid))return Allowed(p.ProcessName);}
      catch {return false;}
    }
    public static byte[] ForegroundJpeg(int requestedWidth) {
      IntPtr hwnd=GetForegroundWindow(); if(hwnd==IntPtr.Zero)throw new Exception("No active window");
      uint pid;GetWindowThreadProcessId(hwnd,out pid);if(pid==0)throw new Exception("No active process");
      string name;
      using(Process process=Process.GetProcessById((int)pid)) name=process.ProcessName;
      if(!Allowed(name)) throw new Exception("Focus Counter-Strike 1.6 (hl.exe) first; active: "+name);
      RECT rect; if(!GetClientRect(hwnd,out rect)) throw new Exception("GetClientRect failed");
      POINT pos=new POINT(); if(!ClientToScreen(hwnd,ref pos)) throw new Exception("ClientToScreen failed");
      int w=rect.Right-rect.Left,h=rect.Bottom-rect.Top;
      if(w<100||h<100||w>8192||h>8192)throw new Exception("Unexpected game viewport");
      using(Bitmap original=new Bitmap(w,h,PixelFormat.Format24bppRgb)) {
        using(Graphics source=Graphics.FromImage(original))
          source.CopyFromScreen(pos.X,pos.Y,0,0,new Size(w,h),CopyPixelOperation.SourceCopy);
        int tw=Math.Min(requestedWidth,w),th=Math.Max(1,(int)Math.Round((double)h*tw/w));
        using(Bitmap small=new Bitmap(tw,th,PixelFormat.Format24bppRgb)) {
          using(Graphics g=Graphics.FromImage(small)) {
            g.InterpolationMode=InterpolationMode.HighQualityBilinear;
            g.DrawImage(original,new Rectangle(0,0,tw,th),new Rectangle(0,0,w,h),GraphicsUnit.Pixel);
          }
          // Exclusive fullscreen often produces a black screenshot: reject, don't trust model.
          int nearlyBlack=0,total=0;
          for(int y=0;y<th;y+=Math.Max(1,th/16))for(int x=0;x<tw;x+=Math.Max(1,tw/16)){
            Color p=small.GetPixel(x,y);if(p.R<7&&p.G<7&&p.B<7)nearlyBlack++;total++;
          }
          if(total>0&&nearlyBlack>(int)(total*.97))throw new Exception("Captured mostly black pixels; switch CS to windowed/borderless mode.");
          using(MemoryStream mem=new MemoryStream()) {
            ImageCodecInfo jpeg=null;
            foreach(ImageCodecInfo encoder in ImageCodecInfo.GetImageEncoders())
              if(encoder.MimeType=="image/jpeg")jpeg=encoder;
            if(jpeg==null)throw new Exception("JPEG encoder unavailable");
            using(EncoderParameters opts=new EncoderParameters(1)) {
              opts.Param[0]=new EncoderParameter(System.Drawing.Imaging.Encoder.Quality,65L);
              small.Save(mem,jpeg,opts);
            }
            return mem.ToArray();
          }
        }
      }
    }
  }
}
'@
# Reuse this Win32 capture type within the same PowerShell process.
# Repeated invocations in Windows PowerShell 5.1 must not recompile the same type.
$loadedCapture = 'ReflexCore.LocalVision.Capture' -as [type]
if ($null -eq $loadedCapture) {
    Add-Type -TypeDefinition $cs -ReferencedAssemblies @('System.Drawing.dll','System.dll') -ErrorAction Stop
} elseif ($null -eq $loadedCapture.GetMethod('ForegroundJpeg') -or $null -eq $loadedCapture.GetMethod('SelfTest')) {
    throw 'Previously loaded Capture type is incompatible; start a fresh PowerShell process.'
}
# ReflexCore 0.4.5: pure deterministic action gate. NEVER runs model-generated commands.
function Get-ReflexDecision {
    param([string]$HasC4, [string]$AtBombsite)
    $valid = @('yes','no','unknown')
    if ($valid -notcontains $HasC4 -or $valid -notcontains $AtBombsite) {
        throw 'Rejected model observation: invalid or missing state.'
    }
    if ($HasC4 -eq 'yes' -and $AtBombsite -eq 'yes') {
        return 'REQUEST_HUMAN_APPROVAL' # Not an instruction for SendInput.
    }
    if ($HasC4 -eq 'no') { return 'WAIT_NO_C4' }
    return 'WAIT_UNCERTAIN'
}
function New-ReflexPlanRecord {
    param([string]$Id,[string]$HasC4,[string]$AtBombsite,[string]$Decision)
    if($Id -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid request id.' }
    if($Decision -cne (Get-ReflexDecision -HasC4 $HasC4 -AtBombsite $AtBombsite)) {
        throw 'Mismatch between observation and verified decision.'
    }
    return @{
        schema='reflexcore.cs16.vision.plan.v1'
        request_id=$Id
        has_c4=$HasC4
        at_bombsite=$AtBombsite
        decision=$Decision
        created_utc=[DateTime]::UtcNow.ToString('o')
    }
}
function Write-ReflexPlanRecord {
    param([string]$Id,[string]$Path,[string]$HasC4,[string]$AtBombsite,[string]$Decision)
    if([string]::IsNullOrWhiteSpace($Path)) { return }
    $dir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\data\private\cs16-auto'))
    $canonical=[IO.Path]::GetFullPath($Path)
    if((Split-Path $canonical -Parent).TrimEnd('\') -ine $dir.TrimEnd('\')) { throw 'DecisionFile must stay inside data/private/cs16-auto.' }
    if((Split-Path $canonical -Leaf) -cne ("plan-$Id.json")) { throw 'Unexpected decision file name.' }
    $record=New-ReflexPlanRecord -Id $Id -HasC4 $HasC4 -AtBombsite $AtBombsite -Decision $Decision
    [IO.Directory]::CreateDirectory($dir)|Out-Null
    $temp=$canonical+'.tmp'
    [IO.File]::WriteAllText($temp,($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $canonical -ErrorAction Stop
}
# Navigation decisions are written as enumerated states only. Never serialize arbitrary model text.
function Get-ReflexNavDecision {
    param([string]$Move,[string]$AtBombsite)
    $moves=@('FORWARD','TURN_LEFT','TURN_RIGHT','STRAFE_LEFT','STRAFE_RIGHT','WAIT','ARRIVED')
    if($moves -cnotcontains $Move -or @('yes','no','unknown') -cnotcontains $AtBombsite) { throw 'Invalid navigation model decision' }
    # A visible bombsite can be several meters away. Never turn a planned movement into ARRIVED.
    if($Move -eq 'ARRIVED' -and $AtBombsite -ne 'yes') { return 'WAIT' }
    return $Move
}
function Write-ReflexNavRecord {
    param([string]$Id,[string]$Path,[string]$Move,[string]$AtBombsite)
    if([string]::IsNullOrWhiteSpace($Path)) { return }
    if($Id -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid navigation request id.' }
    $dir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\data\private\cs16-auto'))
    $canonical=[IO.Path]::GetFullPath($Path)
    if((Split-Path $canonical -Parent).TrimEnd('\') -ine $dir.TrimEnd('\')) { throw 'Navigation record directory rejected' }
    if((Split-Path $canonical -Leaf) -cne ('plan-'+$Id+'.json')) { throw 'Navigation filename rejected' }
    $move=Get-ReflexNavDecision -Move $Move -AtBombsite $AtBombsite
    $record=@{schema='reflexcore.cs16.navigation.v1';request_id=$Id;move=$move;at_bombsite=$AtBombsite;created_utc=[DateTime]::UtcNow.ToString('o')}
    [IO.Directory]::CreateDirectory($dir)|Out-Null
    $temp=$canonical+'.tmp'
    [IO.File]::WriteAllText($temp,($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $canonical -ErrorAction Stop
}
function Test-ReflexNavDecision {
    foreach($test in @(
       @('FORWARD','unknown','FORWARD'),
       @('TURN_LEFT','no','TURN_LEFT'),
       @('ARRIVED','unknown','WAIT'),
       @('FORWARD','yes','FORWARD'),
       @('WAIT','yes','WAIT'),
       @('ARRIVED','yes','ARRIVED')
    )) {
       if((Get-ReflexNavDecision -Move $test[0] -AtBombsite $test[1]) -cne $test[2]) {throw 'Navigation gate mismatch'}
    }
    $rejected=$false
    try { [void](Get-ReflexNavDecision -Move 'ALT_F4' -AtBombsite 'no') } catch {$rejected=$true}
    if(-not $rejected){ throw 'Dangerous navigation token accepted' }
    Write-Host '[ReflexCore] Navigation: 7 policy checks passed (no forced ARRIVED).' -ForegroundColor Green
}
function Test-ReflexDecision {
    $cases = @(
        @('yes','yes','REQUEST_HUMAN_APPROVAL'),
        @('yes','unknown','WAIT_UNCERTAIN'),
        @('unknown','yes','WAIT_UNCERTAIN'),
        @('unknown','unknown','WAIT_UNCERTAIN'),
        @('no','yes','WAIT_NO_C4'),
        @('no','unknown','WAIT_NO_C4')
    )
    foreach ($c in $cases) {
        $actual = Get-ReflexDecision -HasC4 $c[0] -AtBombsite $c[1]
        if ($actual -ne $c[2]) { throw ('Decision gate test failed: ' + ($c -join '/')) }
    }
    $invalidRejected = $false
    try { [void](Get-ReflexDecision -HasC4 'plant' -AtBombsite 'yes') } catch { $invalidRejected=$true }
    if (-not $invalidRejected) { throw 'Decision gate did not reject unknown tokens.' }
    $id='0123456789abcdef0123456789abcdef'
    $p=New-ReflexPlanRecord -Id $id -HasC4 'yes' -AtBombsite 'yes' -Decision 'REQUEST_HUMAN_APPROVAL'
    if ($p.schema -ne 'reflexcore.cs16.vision.plan.v1' -or $p.request_id -ne $id) { throw 'Plan record failed.' }
    $blocked=$false
    try { [void](New-ReflexPlanRecord -Id $id -HasC4 'unknown' -AtBombsite 'yes' -Decision 'REQUEST_HUMAN_APPROVAL') } catch { $blocked=$true }
    if(-not $blocked) { throw 'Uncertain plan was accepted.' }
    Write-Host '[ReflexCore] Vision Gate 0.4.6: 9 policy tests passed.' -ForegroundColor Green
}
if ($Action -eq 'SelfTest') {
    [ReflexCore.LocalVision.Capture]::SelfTest()
    Test-ReflexDecision
    Test-ReflexNavDecision
    exit 0
}
# v0.4.4.1 -- bounded requests with periodic progress. No files or secrets are sent.
function Show-Gpu {
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        & nvidia-smi --query-gpu=name,memory.used,memory.total,driver_version --format=csv,noheader
    }
}
function Get-OllamaModels {
    try { return (Invoke-RestMethod -Uri "$localEndpoint/api/ps" -TimeoutSec 4 -ErrorAction Stop).models }
    catch { return @() }
}
function Invoke-LocalInference {
    param([Parameter(Mandatory=$true)][hashtable]$Request, [int]$Limit = 150)
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $http = [System.Net.Http.HttpClient]::new($handler)
    $http.Timeout = [TimeSpan]::FromSeconds($Limit)
    $json = $Request | ConvertTo-Json -Depth 9 -Compress
    $body = [System.Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $nextReport = 8
    try {
        $task = $http.PostAsync("$localEndpoint/api/generate", $body)
        while (-not $task.IsCompleted) {
            Start-Sleep -Milliseconds 500
            if ($watch.Elapsed.TotalSeconds -ge $nextReport) {
                $models = @(Get-OllamaModels)
                $loaded = @($models | Where-Object { $_.name -eq $Model })
                $location = if ($loaded.Count -gt 0) {
                    $m = $loaded[0]
                    $vram = [Math]::Round(([double]$m.size_vram / 1MB), 0)
                    "loaded, VRAM approx ${vram} MiB"
                } else { 'loading, queued or not yet reported' }
                Write-Host ("[ReflexCore] Waiting for Ollama: {0:n0}s / {1}s; {2}" -f $watch.Elapsed.TotalSeconds,$Limit,$location) -ForegroundColor DarkCyan
                $nextReport += 8
            }
        }
        # Raises any network errors, including the built-in HttpClient timeout.
        $reply = $task.GetAwaiter().GetResult()
        if (-not $reply.IsSuccessStatusCode) {
            $err = $reply.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw ("Ollama HTTP {0}: {1}" -f [int]$reply.StatusCode, $err.Substring(0,[Math]::Min($err.Length,400)))
        }
        $responseText = $reply.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($responseText)) { throw 'Ollama returned an empty HTTP body' }
        $response = $responseText | ConvertFrom-Json -ErrorAction Stop
        Write-Host ("[ReflexCore] Ollama responded in {0:n1}s." -f $watch.Elapsed.TotalSeconds) -ForegroundColor Green
        if ($null -ne $response.load_duration) {
            Write-Host ("[ReflexCore] Model load: {0:n1}s; prompt evaluation: {1}; output tokens: {2}" -f ($response.load_duration/1e9),$response.prompt_eval_count,$response.eval_count)
        }
        if ($null -ne $response.prompt_eval_duration -and $null -ne $response.prompt_eval_count -and $response.prompt_eval_duration -gt 0) {
            $speed = [math]::Round(([double]$response.prompt_eval_count * 1e9) / [double]$response.prompt_eval_duration, 1)
            Write-Host ("[ReflexCore] Prompt evaluation speed: {0} tokens/s" -f $speed) -ForegroundColor DarkCyan
        }
        return $response
    } catch {
        throw ("Local Ollama request failed after {0:n1}s (limit {1}s): {2}. Check 'ollama ps' and the Ollama server.log." -f $watch.Elapsed.TotalSeconds,$Limit,$_.Exception.Message)
    } finally {
        $watch.Stop()
        if ($null -ne $reply) { $reply.Dispose() }
        if ($null -ne $body) { $body.Dispose() }
        if ($null -ne $http) { $http.Dispose() }
        if ($null -ne $handler) { $handler.Dispose() }
    }
}
if ($Action -eq 'Status') {
    Write-Host '[ReflexCore] Checking local Ollama...' -ForegroundColor Cyan
    try {
        $tags = Invoke-RestMethod -Uri "$localEndpoint/api/tags" -TimeoutSec 5 -ErrorAction Stop
        $names = @($tags.models | ForEach-Object { $_.name })
        Write-Host ('Local models: '+($names -join ', '))
        if ($names -contains $Model) { Write-Host "[ReflexCore] $Model installed" -ForegroundColor Green }
        else { Write-Warning "Model not found. Run: ollama pull $Model" }
    } catch { throw "Ollama did not respond to /api/tags: $($_.Exception.Message)" }
    $running = @(Get-OllamaModels)
    if ($running.Count -eq 0) { Write-Host '[ReflexCore] No models currently loaded (or /api/ps unavailable).' }
    foreach ($m in $running) {
        Write-Host ("[ReflexCore] Active: {0}; VRAM {1:n0} MiB; context {2}" -f $m.name,([double]$m.size_vram/1MB),$m.context_length)
    }
    Show-Gpu
    exit 0
}
$tagResult = Invoke-RestMethod -Uri "$localEndpoint/api/tags" -TimeoutSec 5 -ErrorAction Stop
if (@($tagResult.models | ForEach-Object {$_.name}) -notcontains $Model) { throw "Model $Model is missing; run ollama pull $Model" }
if ($Action -eq 'Warmup') {
    Write-Host '[ReflexCore] Preloading Qwen locally for 10 minutes. Uses VRAM until unloaded or timed out.'
    $req=@{ model=$Model; stream=$false; keep_alive='10m'; options=@{num_ctx=2048;num_predict=8} }
    [void](Invoke-LocalInference -Request $req -Limit $TimeoutSec)
    Write-Host '[ReflexCore] WARMUP OK. Check ollama ps for GPU residency.' -ForegroundColor Green
    exit 0
}
if ($Action -eq 'TextProbe') {
    Write-Host "[ReflexCore] Text-only model check; timeout $TimeoutSec sec. No screenshots or input."
    $req=@{
        model=$Model; prompt='Answer with only the word READY.'
        stream=$false; keep_alive='5m'; options=@{num_ctx=2048;num_predict=12;temperature=0}
    }
    $answer=Invoke-LocalInference -Request $req -Limit $TimeoutSec
    Write-Host ('[ReflexCore] Text model response: '+[string]$answer.response) -ForegroundColor Green
    exit 0
}
Write-Host '[ReflexCore] Read-only vision. NO mouse/keyboard actions, NO screenshot file.' -ForegroundColor Cyan
Write-Host "[ReflexCore] In $CaptureDelaySec sec, capture foreground CS 1.6; width $ImageWidth px; timeout $TimeoutSec sec."
if($CaptureDelaySec -gt 0) { Start-Sleep -Seconds $CaptureDelaySec }
if ($Action -eq 'Navigate') {
    # A fixed five-second countdown is unreliable when focus passes through Explorer/taskbar.
    # Wait until the USER foregrounds CS. Never force focus or capture other applications.
    $focusTimer=[Diagnostics.Stopwatch]::StartNew()
    $lastNotice=-3
    while(-not [ReflexCore.LocalVision.Capture]::IsGameForeground()) {
        if($focusTimer.Elapsed.TotalSeconds -ge $FocusWaitSec) {
            throw "Focus timeout: Counter-Strike was not foreground within $FocusWaitSec sec. No screenshot or input sent."
        }
        $seconds=[int][Math]::Floor($focusTimer.Elapsed.TotalSeconds)
        if($seconds -ge $lastNotice+3) {
            Write-Host ("[ReflexCore] WAITING FOR CS: {0}/{1}s; activate the game window." -f $seconds,$FocusWaitSec) -ForegroundColor Yellow
            $lastNotice=$seconds
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Host '[ReflexCore] GAME FOCUSED. Capturing one frame.' -ForegroundColor Green
}
$image=[ReflexCore.LocalVision.Capture]::ForegroundJpeg($ImageWidth)
Write-Host ('[ReflexCore] Screenshot in RAM: '+$image.Length+' bytes. Sending to LOCAL Ollama.')
# Use a small output budget and a stable, concise policy prompt.
if ($Action -eq 'Navigate') {
    $prompt=@'
You see one Counter-Strike 1.6 screenshot. Goal: reach a visible bombsite on an offline map.
No map coordinates or invisible information. Decide ONE short, low-risk movement:
FORWARD (0.40 s), TURN_LEFT (small mouse turn), TURN_RIGHT, STRAFE_LEFT, STRAFE_RIGHT, WAIT, ARRIVED.
A bombsite marker visible in the distance does NOT mean you arrived. Set at_bombsite=yes ONLY if the player is standing on the marked planting area, not merely facing it. If uncertain, use unknown. If the marker is ahead with a clear path, prefer FORWARD; if blocked, TURN; if unsure, WAIT. Use ARRIVED only when visibly inside the planting zone.
Output only JSON: {"action":"FORWARD|TURN_LEFT|TURN_RIGHT|STRAFE_LEFT|STRAFE_RIGHT|WAIT|ARRIVED","at_bombsite":"yes|no|unknown"}.
'@
    $maxTokens=55
} else {
    $prompt=@'
CS 1.6 screenshot. Only visible evidence. If C4 or bombsite is unclear: unknown.
Reply JSON only: {"has_c4":"yes|no|unknown","at_bombsite":"yes|no|unknown","scene":"brief"}.
Do not invent details or give game commands.
'@
    $maxTokens=75
}
$req=@{
    model=$Model; prompt=$prompt
    images=@([Convert]::ToBase64String($image))
    format='json'; stream=$false; keep_alive='5m'
    options=@{num_ctx=2048;num_predict=$maxTokens;temperature=0}
}
$image=$null
$answer=Invoke-LocalInference -Request $req -Limit $TimeoutSec
if ([string]::IsNullOrWhiteSpace([string]$answer.response)) { throw 'Model generated no text (read Ollama logs for errors)' }
try { $data = $answer.response | ConvertFrom-Json -ErrorAction Stop }
catch { throw ('Model response not valid JSON: '+([string]$answer.response).Substring(0,[Math]::Min(300,([string]$answer.response).Length))) }
if ($Action -eq 'Navigate') {
    if(@('yes','no','unknown') -cnotcontains [string]$data.at_bombsite) { throw 'Navigation observation lacks valid at_bombsite state' }
    $rawAction=[string]$data.action
    $move=Get-ReflexNavDecision -Move $rawAction -AtBombsite ([string]$data.at_bombsite)
    Write-Host ("[ReflexCore] NAVIGATION: {0}, bombsite={1}. Raw={2}." -f $move,$data.at_bombsite,$rawAction) -ForegroundColor Green
    if(-not [string]::IsNullOrEmpty($DecisionFile)) {
        Write-ReflexNavRecord -Id $RequestId -Path $DecisionFile -Move $rawAction -AtBombsite ([string]$data.at_bombsite)
        Write-Host '[ReflexCore] Saved enumerated navigation decision only; no screenshot or landmarks.'
    }
    Write-Host '[ReflexCore] Only the Shared Control GUI may execute this plan; no input was sent.'
    exit 0
}
if (@('yes','no','unknown') -notcontains [string]$data.has_c4 -or @('yes','no','unknown') -notcontains [string]$data.at_bombsite) {
    throw 'Model response missing has_c4 or at_bombsite; no game actions taken.'
}
Write-Host "`n[ReflexCore] Vision model: $Model" -ForegroundColor Green
Write-Host ('Scene: '+[string]$data.scene)
Write-Host ('C4: '+[string]$data.has_c4+' | Bombsite: '+[string]$data.at_bombsite)
Write-Host '[ReflexCore] Minimal visual observation; no model confidence is trusted.'
if ($Action -eq 'Plan') {
    # Model-provided text does not cross the tool boundary. Enumerated values only.
    $decision = Get-ReflexDecision -HasC4 ([string]$data.has_c4) -AtBombsite ([string]$data.at_bombsite)
    Write-Host ('[ReflexCore] STRICT DECISION: ' + $decision) -ForegroundColor Cyan
    if (-not [string]::IsNullOrEmpty($DecisionFile)) {
        Write-ReflexPlanRecord -Id $RequestId -Path $DecisionFile -HasC4 ([string]$data.has_c4) -AtBombsite ([string]$data.at_bombsite) -Decision $decision
        Write-Host '[ReflexCore] Minimal plan record written. No image, text scene, or input commands persisted.'
    }
    if ($decision -eq 'REQUEST_HUMAN_APPROVAL') {
        Write-Host '[ReflexCore] C4 and bombsite appear visible. Human confirmation REQUIRED.' -ForegroundColor Yellow
        Write-Host '[ReflexCore] If correct, manually arm the existing Shared Control PLANT drill in the offline session.'
    } else {
        Write-Host '[ReflexCore] No action authorized. Reposition manually or capture another frame.' -ForegroundColor Yellow
    }
    Write-Host '[ReflexCore] No commands were dispatched to Shared Control.'
}
Write-Host '[ReflexCore] READ-ONLY; no game input was sent.' -ForegroundColor Yellow
