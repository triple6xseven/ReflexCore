#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Usage','Qualify','Resume','Cached','QualifyTurn','Develop')][string]$Action='Usage',
    [ValidatePattern('^[A-Za-z0-9-]{1,64}$')][string]$ThreadId,
    [ValidateLength(1,320)][string]$Objective,
    [ValidateLength(1,320)][string]$Next
)
if (($Action -eq 'Resume') -ne [bool]$ThreadId) { throw 'Resume requires one explicit thread ID' }
if($Action -eq 'Develop' -and (!$Objective -or !$Next -or $Objective -match '[\x00-\x1f]' -or $Next -match '[\x00-\x1f]')){throw 'Develop requires a bounded objective and next step'}
# Usage and resume actions send no model prompt.
$ErrorActionPreference = 'Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location $root
try { $private=& git rev-parse --absolute-git-dir 2>$null } finally { Pop-Location }
$usagePath=if($private -and (Test-Path -LiteralPath $private -PathType Container)){Join-Path $private 'reflex-managed-usage-v1.json'}
if($Action -eq 'Cached'){
    $cached=[ordered]@{v=1;source='local_snapshot';state='unavailable';windows=@();forecast=$null}
    try {
        if($usagePath -and (Test-Path -LiteralPath $usagePath) -and (Get-Item -LiteralPath $usagePath).Length -le 8192){
            $snapshot=Get-Content -Raw -LiteralPath $usagePath|ConvertFrom-Json
            $age=[DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse($snapshot.observed_utc)
            if($snapshot.v -eq 1 -and $snapshot.source -eq 'managed_app_server' -and $age.TotalSeconds -ge 0){
                $cached.state=if($age.TotalSeconds -le 120){'recent_snapshot'}else{'stale_snapshot'}
                $cached.account_identity='unverified'
                $cached.observed_utc=$snapshot.observed_utc
                $cached.age_seconds=[long]$age.TotalSeconds
                $cached.windows=@($snapshot.windows)
            }
        }
    } catch {}
    $cached|ConvertTo-Json -Depth 4 -Compress
    return
}
$command = Get-Command codex.exe -ErrorAction SilentlyContinue
if (!$command) {
    '{"v":1,"source":"managed_app_server","state":"unavailable","windows":[],"forecast":null}'
    return
}
$cli = $command.Source
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = $cli
$start.WorkingDirectory = $root
$start.Arguments = 'app-server --listen stdio://'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$child = New-Object Diagnostics.Process
$child.StartInfo = $start
$clock = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'ReflexCore-ManagedEvents.ps1')
$turnState=[ordered]@{v=1;thread=$null;turn=$null;state='unknown';failure=$null;retry_reported=$false;plan_steps=0;plan_completed=0;total_tokens=$null}
$turnPath=if($private){Join-Path $private 'reflex-managed-turn-v1.json'}
function Save-ManagedTurn {
    if(!$turnPath){return}
    $tmp=$turnPath+'.'+[guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($tmp,($turnState | ConvertTo-Json -Compress))
        if([IO.File]::Exists($turnPath)){[IO.File]::Replace($tmp,$turnPath,($turnPath+'.previous'))}
        else{[IO.File]::Move($tmp,$turnPath)}
    } finally {if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
}
$notifications = New-Object 'System.Collections.Generic.List[object]'
function Observe($message) {
    if($turnState.thread -and (Update-ReflexManagedTurn $turnState $message)){
        $notifications.Add([ordered]@{kind=$message.method})
        Save-ManagedTurn
    }
    switch ($message.method) {
        'thread/started' {
            $id=$message.params.thread.id
            if($id -cmatch '^[a-zA-Z0-9-]{1,64}$') {
                $notifications.Add([ordered]@{kind='thread_started';thread=$id})
            }
        }
        'account/rateLimits/updated' { $notifications.Add([ordered]@{kind='rate_limits_updated'}) }
    }
}
function Receive([int]$id) {
    for ($i=0; $i -lt 128; $i++) {
        $line = $child.StandardOutput.ReadLineAsync()
        $budget=if($Action -in 'QualifyTurn','Develop'){30000}else{12000}
        $remaining = [int]($budget - $clock.ElapsedMilliseconds)
        if ($remaining -le 0 -or !$line.Wait($remaining) -or !$line.Result -or $line.Result.Length -gt 65536) { throw 'Unavailable' }
        $message = $line.Result | ConvertFrom-Json
        if ($message.method) { Observe $message }
        if($id -eq -1 -and $message.method -ceq "turn/completed" -and $message.params.threadId -ceq $turnState.thread -and $message.params.turn.id -ceq $turnState.turn){return}
        if ($message.id -eq $id) {
            if ($message.error -or !$message.result) { throw 'Unsupported' }
            return $message.result
        }
    }
    throw 'Unavailable'
}
$started = $false
try {
    $started = $child.Start()
    $child.BeginErrorReadLine()
    $child.StandardInput.WriteLine('{"id":1,"method":"initialize","params":{"clientInfo":{"name":"reflexcore","version":"0.3"}}}')
    $null = Receive 1
    $child.StandardInput.WriteLine('{"method":"initialized"}')
    $child.StandardInput.WriteLine('{"id":2,"method":"account/rateLimits/read","params":{}}')
    $result = Receive 2
    $thread=$null
    if($Action -in 'Qualify','QualifyTurn','Develop'){
        $request=@{id=3;method='thread/start';params=@{ephemeral=($Action -ne 'Develop');cwd=$root}}
        $child.StandardInput.WriteLine(($request|ConvertTo-Json -Depth 4 -Compress))
        $thread=(Receive 3).thread.id
        # A following response drains messages sent immediately after thread creation.
        $child.StandardInput.WriteLine('{"id":4,"method":"thread/read","params":{"threadId":"'+$thread+'","includeTurns":false}}')
        if((Receive 4).thread.id -cne $thread){throw 'Thread identity mismatch'}
    }
    if ($Action -eq 'Resume') {
        $child.StandardInput.WriteLine('{"id":3,"method":"thread/read","params":{"threadId":"'+$ThreadId+'","includeTurns":false}}')
        $candidate=(Receive 3).thread
        $root=(Resolve-Path (Split-Path $PSScriptRoot -Parent)).Path
        if ($candidate.id -cne $ThreadId -or [IO.Path]::GetFullPath($candidate.cwd) -ne $root) { throw 'Thread outside the worktree' }
        $child.StandardInput.WriteLine('{"id":4,"method":"thread/resume","params":{"threadId":"'+$ThreadId+'","excludeTurns":true}}')
        if ((Receive 4).thread.id -cne $ThreadId) { throw 'Resume identity mismatch' }
        $thread=$ThreadId
    }
    if($Action -in 'QualifyTurn','Develop'){
        if($thread -cnotmatch '^[a-zA-Z0-9-]{1,64}$'){throw 'Invalid managed thread'}
        $turnState.thread=$thread
        $prompt='Reply with OK only. Do not use tools.'
        if($Action -eq 'Develop'){
            if(!$private){throw 'Managed development requires a worktree'}
            $store=Join-Path $private 'reflex-managed-turns'
            [void][IO.Directory]::CreateDirectory($store)
            $turnPath=Join-Path $store ((Get-ReflexManagedKey $thread)+'.json')
            & (Join-Path $PSScriptRoot 'Invoke-DevObserver.ps1') -ObserverArgs @('declare',$thread,'bridge',$Objective,$Next)|Out-Null
            $prompt=$Objective
        }
        Save-ManagedTurn
        $request=@{id=5;method='turn/start';params=@{threadId=$thread;approvalPolicy='never';sandboxPolicy=@{type='readOnly'};input=@(@{type='text';text=$prompt})}}
        $child.StandardInput.WriteLine(($request|ConvertTo-Json -Depth 6 -Compress))
        $issued=Receive 5
        if($issued.turn.id -cnotmatch '^[a-zA-Z0-9-]{1,64}$' -or ($turnState.turn -and $turnState.turn -cne $issued.turn.id)){throw 'Invalid managed turn'}
        $turnState.turn=$issued.turn.id
        if($turnState.state -notin 'completed','interrupted','failed'){Receive -1}
    }
    if($Action -in 'QualifyTurn','Develop' -and ($notifications | Where-Object {$_.kind -ceq 'rate_limits_updated'})){
        # Updates can be sparse. Fetch one full official snapshot after the managed turn.
        $child.StandardInput.WriteLine('{"id":6,"method":"account/rateLimits/read","params":{}}')
        $result=Receive 6
    }
    $buckets = @($result.rateLimits)
    if ($result.rateLimitsByLimitId) { $buckets = @($result.rateLimitsByLimitId.psobject.Properties | ForEach-Object { $_.Value }) }
    $windows = @(foreach ($bucket in ($buckets | Select-Object -First 16)) {
        foreach ($window in @($bucket.primary,$bucket.secondary)) {
            if ($null -eq $window -or $null -eq $window.usedPercent) { continue }
            $used = [double]$window.usedPercent
            if ($used -lt 0 -or $used -gt 100) { continue }
            $label = $bucket.limitId
            if ($label -notmatch '^[a-zA-Z0-9_.-]{1,64}$') { $label = $null }
            [ordered]@{limit=$label;used_percent=$used;remaining_percent=100-$used;window_minutes=$window.windowDurationMins;reset_unix=$window.resetsAt}
        }
    })
    $state = if ($windows.Count) { 'observed' } else { 'unavailable' }
    $record=[ordered]@{v=1;source='managed_app_server';state=$state;observed_utc=[DateTime]::UtcNow.ToString('o');windows=$windows;forecast=$null}
    if($Action -in 'Qualify','QualifyTurn','Develop'){
        $record.thread_notification=@($notifications | Where-Object {$_.kind -eq 'thread_started' -and $_.thread -ceq $thread}).Count -gt 0
        $record.observed_notifications=@($notifications | ForEach-Object {$_.kind} | Select-Object -Unique)
    }
    if($Action -in 'QualifyTurn','Develop'){ $record.managed_turn=$turnState }
    if($Action -eq 'Resume'){ $record.thread_resumed=$true }
    if($state -eq 'observed'){
        # Keep only the latest sanitized snapshot in this worktree.
        if($usagePath){
            $dest=$usagePath
            $temp=$dest+'.'+[guid]::NewGuid().ToString('N')
            try {
                [IO.File]::WriteAllText($temp,($record | ConvertTo-Json -Depth 4 -Compress))
                if([IO.File]::Exists($dest)){[IO.File]::Replace($temp,$dest,($dest+'.previous'))}
                else{[IO.File]::Move($temp,$dest)}
                $record.saved=$true
            } catch { $record.saved=$false } finally { if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)} }
        }
    }
    $record | ConvertTo-Json -Depth 4 -Compress
} catch {
    if($Action -in 'QualifyTurn','Develop'){
        [ordered]@{v=1;state='unavailable';managed_turn=$turnState;observed_notifications=@($notifications | ForEach-Object {$_.kind} | Select-Object -Unique)}|ConvertTo-Json -Depth 4 -Compress
    }else{
        '{"v":1,"source":"managed_app_server","state":"unavailable","windows":[],"forecast":null}'
    }
} finally {
    if ($started) {
        $child.StandardInput.Close()
        if (!$child.WaitForExit(1000)) { $child.Kill(); $child.WaitForExit() }
    }
    $child.Dispose()
}
