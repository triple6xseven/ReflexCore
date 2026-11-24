#requires -Version 5.1
[CmdletBinding()]
param([ValidateRange(1,40)][int]$Runs=8,[string]$SourceRoot)
$ErrorActionPreference='Stop'
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ReflexCore-Stop-'+[guid]::NewGuid().ToString('N'))
$bridge=Join-Path $fixture 'data/bridge'
$tray=$null
$heartbeat=$null
try {
    foreach($relative in 'tasks','tools','data/bridge/pending','data/bridge/running'){
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture $relative))
    }
    $sources=@('ReflexCore-Queue.cs','ReflexCore-Tray.cs','ReflexCore-Companion.cs','ReflexCore-CompanionHost.cs')
    Add-Type -Path ($sources|ForEach-Object {Join-Path $SourceRoot "tools/$_"}) -ReferencedAssemblies System.Windows.Forms.dll,System.Drawing.dll,System.Core.dll,System.Management.dll,System.Web.Extensions.dll
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'tools/ReflexCore-QueuedWorker.ps1') -Destination (Join-Path $fixture 'tools')
    @'
$root=Split-Path $PSScriptRoot -Parent
$id=[IO.Path]::GetFileNameWithoutExtension($env:REFLEXCORE_QUEUE_MANIFEST)
$marker=Join-Path $root "data/bridge/queue-requests/$id.cancel"
[IO.File]::WriteAllText((Join-Path $root "entered-$id"),'')
$elapsed=[Diagnostics.Stopwatch]::StartNew()
while($elapsed.Elapsed.TotalSeconds -lt 20){
    if([IO.File]::Exists($marker)){
        [IO.File]::WriteAllText((Join-Path $root "ack-$id"),'')
        exit 2
    }
    Start-Sleep -Milliseconds 30
}
[IO.File]::WriteAllText((Join-Path $root "late-effect-$id"),'')
exit 9
'@ | Set-Content -LiteralPath (Join-Path $fixture 'tasks/probe.ps1') -Encoding Ascii
    $store=[ReflexCore.Bridge.QueueStore]::new($fixture)
    $type=[ReflexCore.Bridge.TrayHost].Assembly.GetType('ReflexCore.Bridge.TrayWindow',$true)
    $tray=$type.GetConstructor([type[]]@([string],[bool])).Invoke([object[]]@([string]$fixture,$true))
    $pump=$type.GetMethod('Pump',[Reflection.BindingFlags]'Instance,NonPublic')
    $cooperativeStop=$type.GetMethod('PollStop',[Reflection.BindingFlags]'Instance,NonPublic')
    $heartbeat=[Windows.Forms.Timer]::new()
    $heartbeat.Interval=20
    $script:stopHeartbeats=0
    $heartbeat.add_Tick({$script:stopHeartbeats++})
    $heartbeat.Start()
    $records=@(1..$Runs|ForEach-Object {
        $id=$store.Submit('probe',$true)
        $startup=[Diagnostics.Stopwatch]::StartNew()
        while(!(Test-Path -LiteralPath (Join-Path $fixture "entered-$id"))){
            [void]$pump.Invoke($tray,@())
            if($startup.Elapsed.TotalSeconds -gt 12){throw 'Test worker did not start'}
            Start-Sleep -Milliseconds 20
        }
        $script:stopHeartbeats=0
        $elapsed=[Diagnostics.Stopwatch]::StartNew()
        $command=[Diagnostics.Stopwatch]::StartNew()
        $control=Join-Path $bridge 'control.txt'
        [IO.File]::WriteAllText($control,'stop-all')
        [void]$pump.Invoke($tray,@())
        $command.Stop()
        $maxPump=0.0
        do {
            $one=[Diagnostics.Stopwatch]::StartNew()
            [void]$pump.Invoke($tray,@())
            $maxPump=[Math]::Max($maxPump,$one.Elapsed.TotalMilliseconds)
            [Windows.Forms.Application]::DoEvents()
            $entry=$store.Snapshot() | Where-Object Id -ceq $id
            if($elapsed.Elapsed.TotalSeconds -gt 10){throw 'Missing terminal cancellation'}
            if($entry.State -ne 'cancelled'){Start-Sleep -Milliseconds 20}
        } until($entry.State -eq 'cancelled')
        $ack=Test-Path -LiteralPath (Join-Path $fixture "ack-$id")
        if(Test-Path -LiteralPath (Join-Path $fixture "late-effect-$id")){throw 'Test worker produced an effect after stop'}
        if($cooperativeStop -and !$ack){throw 'The cooperative worker did not acknowledge cancellation'}
        [pscustomobject]@{terminal_ms=$elapsed.Elapsed.TotalMilliseconds;stop_handler_ms=$command.Elapsed.TotalMilliseconds
            max_poll_ms=$maxPump;ui_heartbeats=$script:stopHeartbeats;worker_ack=$ack}
    })
    function Percentile($values,[double]$p){
        $sorted=@($values|Sort-Object)
        [Math]::Round($sorted[[Math]::Max(0,[int][Math]::Ceiling($sorted.Count*$p)-1)],2)
    }
    [pscustomobject]@{
        runs=$records.Count; terminal_p50_ms=(Percentile $records.terminal_ms .50); terminal_p95_ms=(Percentile $records.terminal_ms .95)
        stop_handler_p95_ms=(Percentile $records.stop_handler_ms .95); poll_p95_ms=(Percentile $records.max_poll_ms .95)
        samples_with_ui_heartbeat=@($records | Where-Object ui_heartbeats -gt 0).Count
        worker_acknowledgements=@($records | Where-Object worker_ack).Count
    } | ConvertTo-Json
} finally {
    if($heartbeat){$heartbeat.Stop();$heartbeat.Dispose()}
    if($tray){$tray.Dispose()}
    if(Test-Path -LiteralPath $fixture){
        $resolved=(Resolve-Path -LiteralPath $fixture).Path
        $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if([IO.Path]::GetDirectoryName($resolved) -eq $parent -and [IO.Path]::GetFileName($resolved) -like 'ReflexCore-Stop-*'){
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
