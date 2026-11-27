#Requires -Version 5.1
# Explicit one-shot probe. This connection owns no model thread or turn.
$ErrorActionPreference = 'Stop'
$command = Get-Command codex.exe -ErrorAction SilentlyContinue
if (!$command) {
    '{"v":1,"source":"managed_app_server","state":"unavailable","windows":[],"forecast":null}'
    return
}
$cli = $command.Source
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = $cli
$start.Arguments = 'app-server --listen stdio://'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$child = New-Object Diagnostics.Process
$child.StartInfo = $start
$clock = [Diagnostics.Stopwatch]::StartNew()
function Receive([int]$id) {
    for ($i=0; $i -lt 32; $i++) {
        $line = $child.StandardOutput.ReadLineAsync()
        $remaining = [int](12000 - $clock.ElapsedMilliseconds)
        if ($remaining -le 0 -or !$line.Wait($remaining) -or !$line.Result -or $line.Result.Length -gt 65536) { throw 'Unavailable' }
        $message = $line.Result | ConvertFrom-Json
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
    [ordered]@{v=1;source='managed_app_server';state=$state;observed_utc=[DateTime]::UtcNow.ToString('o');windows=$windows;forecast=$null} | ConvertTo-Json -Depth 4 -Compress
} catch {
    '{"v":1,"source":"managed_app_server","state":"unavailable","windows":[],"forecast":null}'
} finally {
    if ($started) {
        $child.StandardInput.Close()
        if (!$child.WaitForExit(1000)) { $child.Kill(); $child.WaitForExit() }
    }
    $child.Dispose()
}
