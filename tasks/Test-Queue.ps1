[CmdletBinding()]
param([switch]$AllowInput,[switch]$VisualCancellation,[switch]$UiaFixture)
$ErrorActionPreference='Stop'
if($VisualCancellation -and !$AllowInput){throw 'Use -AllowInput for the visible cancellation test'}
$root=Split-Path $PSScriptRoot -Parent
$tempBase=[IO.Path]::GetTempPath()
$fixture=Join-Path $tempBase ('ReflexCore-Queue-'+[guid]::NewGuid().ToString('N'))
$bridge=Join-Path $fixture 'data/bridge'
foreach($dir in 'tools','tasks','data/bridge/pending','data/bridge/running'){
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture $dir))
}
$tray=$null
function Put-Task($name,$source){[IO.File]::WriteAllText((Join-Path $fixture ('tasks/'+$name+'.ps1')),$source)}
function Assert-Queue($ok,$reason){if(!$ok){throw $reason}}
function Tick-Queue{[void]$pump.Invoke($tray,@())}
function Wait-Queue([scriptblock]$condition,$reason,[int]$seconds=40){
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.Elapsed.TotalSeconds -lt $seconds){
        Tick-Queue
        if(& $condition){return}
        Start-Sleep -Milliseconds 65
    }
    throw $reason
}
function Is-State($id,$state){return [bool]($store.Snapshot()|Where-Object {$_.Id -ceq $id -and $_.State -ceq $state})}
function Wait-Verified($id){
    Wait-Queue {
        if(Is-State $id 'failed'){
            $row=$store.Snapshot()|Where-Object Id -ceq $id
            $flow=Join-Path $fixture 'data/flow_last_run.json'
            if(Test-Path -LiteralPath $flow){Write-Host ([IO.File]::ReadAllText($flow))}
            $detail=Join-Path $fixture 'fixture-stage'
            if(Test-Path -LiteralPath $detail){throw ('Fixture failed at '+[IO.File]::ReadAllText($detail))}
            throw ('Queued fixture exited unsuccessfully: '+$row.Reason)
        }
        Is-State $id 'completed'
    } 'Queued fixture did not complete'
}
try {
    Add-Type -Path @((Join-Path $root 'tools/ReflexCore-Queue.cs'),(Join-Path $root 'tools/ReflexCore-Tray.cs'),(Join-Path $root 'tools/ReflexCore-Companion.cs'),(Join-Path $root 'tools/ReflexCore-CompanionHost.cs'),(Join-Path $root 'tools/ReflexCore-MenuStyle.cs')) -ReferencedAssemblies System.Windows.Forms.dll,System.Drawing.dll,System.Core.dll,System.Management.dll,System.Web.Extensions.dll
    Copy-Item -LiteralPath (Join-Path $root 'tools/ReflexCore-QueuedWorker.ps1') -Destination (Join-Path $fixture 'tools')
    Put-Task 'short' '[IO.File]::AppendAllText((Join-Path (Split-Path $PSScriptRoot -Parent) "trace"),"s")'
    Put-Task 'bad' 'exit 7'
    Put-Task 'other' '[IO.File]::WriteAllText((Join-Path (Split-Path $PSScriptRoot -Parent) "other-entered"),"")'
    Put-Task 'notepad-save' @'
$project=Split-Path $PSScriptRoot -Parent
$bridge=Join-Path $project 'data/bridge'
$id=[IO.Path]::GetFileNameWithoutExtension($env:REFLEXCORE_QUEUE_MANIFEST)
[IO.File]::WriteAllText((Join-Path $project 'entered'),'')
$timer=[Diagnostics.Stopwatch]::StartNew()
while($timer.Elapsed.TotalSeconds -lt 25){
    if([IO.File]::Exists((Join-Path $bridge ('queue-requests/'+$id+'.cancel')))){exit 2}
    Start-Sleep -Milliseconds 50
}
exit 9
'@
    $store=[ReflexCore.Bridge.QueueStore]::new($fixture)
    $old=$store.Submit('short',$true)
    $orphan=$store.Submit('short',$true)
    [IO.File]::Move((Join-Path $bridge ('pending/'+$orphan+'.job')),(Join-Path $bridge ('running/'+$orphan+'.job')))
    $null=$store.Request($old,'approve')
    [IO.File]::SetCreationTimeUtc((Join-Path $bridge ('pending/'+$old+'.job')),[DateTime]::UtcNow.AddDays(-1))
    $type=[ReflexCore.Bridge.TrayHost].Assembly.GetType('ReflexCore.Bridge.TrayWindow',$true)
    $constructor=$type.GetConstructor([type[]]@([string],[bool]))
    $tray=$constructor.Invoke([object[]]@([string]$fixture,$true))
    $pump=$type.GetMethod('Pump',[Reflection.BindingFlags]'Instance,NonPublic')
    Tick-Queue
    Assert-Queue (Is-State $old 'pending') 'Old RUN started without fresh approval'
    Assert-Queue (Is-State $orphan 'interrupted') 'Lost claim was replayed or forgotten'
    Assert-Queue ($store.Request($old,'approve')) 'Approval rejected'
    Wait-Queue {Is-State $old 'completed'} 'Approved job did not finish'
    Assert-Queue (($store.Snapshot()|Where-Object Id -ceq $old).Verification -ceq 'not_confirmed') 'Exit code zero became verified'
    $active=$store.Submit('notepad-save',$true)
    Wait-Queue {Test-Path -LiteralPath (Join-Path $fixture 'entered')} 'Worker did not enter task'
    # Emulate a worker from another supervisor generation competing in the same desktop session.
    $other=$store.Submit('other',$true)
    $otherClaim=Join-Path $bridge ('running/'+$other+'.job')
    [IO.File]::Move((Join-Path $bridge ('pending/'+$other+'.job')),$otherClaim)
    $worker=Join-Path $fixture 'tools/ReflexCore-QueuedWorker.ps1'
    $competing=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$worker+'" -Manifest '+$other+'.job') -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 1300
    Assert-Queue (!$competing.HasExited -and !(Test-Path -LiteralPath (Join-Path $fixture 'other-entered'))) 'Second process entered an occupied desktop'
    $waiting=$store.Submit('short',$true)
    $drop=$store.Submit('short',$false)
    Assert-Queue ($store.Request($drop,'cancel')) 'Pending cancellation rejected'
    Wait-Queue {Is-State $drop 'cancelled'} 'Pending job was not cancelled during another job'
    Assert-Queue (Is-State $waiting 'pending') 'Concurrent job started'
    Assert-Queue ($store.Request($active,'cancel')) 'Active cancellation rejected'
    Wait-Queue {Is-State $active 'cancelled'} 'Active job did not acknowledge stop'
    Assert-Queue ($competing.WaitForExit(12000) -and $competing.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $fixture 'other-entered'))) 'Waiting process did not acquire released desktop'
    $competing.Dispose()
    $store.Finish($otherClaim,'completed')
    Wait-Queue {Is-State $waiting 'completed'} 'Next job did not run after cancellation'
    $failed=$store.Submit('bad',$true)
    Wait-Queue {Is-State $failed 'failed'} 'Nonzero exit was treated as success'
    Assert-Queue ([IO.File]::ReadAllText((Join-Path $fixture 'trace')) -ceq 'ss') 'Unexpected task replay'
    Assert-Queue (!$store.Request($waiting,'cancel')) 'Terminal job accepted cancellation'
    $future=$store.Submit('short',$false)
    $emergency=$type.GetMethod('EmergencyStopAgents',[Reflection.BindingFlags]'Instance,NonPublic')
    [void]$emergency.Invoke($tray,@())
    [void]$emergency.Invoke($tray,@())
    Assert-Queue (Test-Path -LiteralPath (Join-Path $bridge 'global-stop.signal')) 'Emergency stop did not broadcast to participants'
    Wait-Queue {Is-State $future 'cancelled'} 'Emergency stop skipped a queued job'
    Put-Task 'unresponsive' @'
$project=Split-Path $PSScriptRoot -Parent
[IO.File]::WriteAllText((Join-Path $project 'unresponsive-entered'),'')
Start-Sleep -Seconds 30
[IO.File]::WriteAllText((Join-Path $project 'unresponsive-late-effect'),'')
'@
    $unresponsive=$store.Submit('unresponsive',$true)
    Wait-Queue {Test-Path -LiteralPath (Join-Path $fixture 'unresponsive-entered')} 'Unresponsive worker did not start'
    Assert-Queue ($store.Request($unresponsive,'cancel')) 'Unresponsive worker stop rejected'
    Tick-Queue
    Assert-Queue (Is-State $unresponsive 'stopping') 'Outstanding stop was reported as terminal'
    Wait-Queue {Is-State $unresponsive 'cancelled'} 'Owned-worker fallback did not finish'
    $forced=$store.Snapshot()|Where-Object Id -ceq $unresponsive
    Assert-Queue ($forced.Verification -ceq 'unknown' -and $forced.Reason -ceq 'cleanup_unconfirmed') 'Forced stop falsely confirmed effects'
    Assert-Queue (!(Test-Path -LiteralPath (Join-Path $fixture 'unresponsive-late-effect'))) 'Worker acted after forced stop'
    $sentinel=Join-Path $bridge 'queue-history/leave-me.txt'
    [IO.File]::WriteAllText($sentinel,'fixture')
    for($i=0;$i -lt 104;$i++){
        $id=$store.Submit('short',$false)
        $store.Finish((Join-Path $bridge ('pending/'+$id+'.job')),'cancelled')
    }
    Assert-Queue ((Get-ChildItem -LiteralPath (Join-Path $bridge 'queue-history') -File).Count -eq 101) 'History retention exceeded bound or touched unrelated file'
    Assert-Queue (Test-Path -LiteralPath $sentinel) 'Non-receipt removed'
    Assert-Queue (@($store.Snapshot() | Where-Object State -eq 'cancelled').Count -le 100) 'History exceeded display limit'
    Assert-Queue ($store.Snapshot().Count -eq 100) 'Unrelated file consumed a history slot'
    Write-Output 'Queue passed restart recovery, approval, single worker, active and pending cancellation, failure, stop-all and history retention.'
    if($UiaFixture){
        $binaryDir=[IO.Directory]::CreateDirectory((Join-Path $fixture 'target/release'))
        Copy-Item -LiteralPath (Join-Path $root 'target/release/reflexcore.exe') -Destination $binaryDir.FullName
        Copy-Item -LiteralPath (Join-Path $root 'tools/ReflexCore-Fixture.ps1') -Destination (Join-Path $fixture 'tools')
        Copy-Item -LiteralPath (Join-Path $root 'tasks/agent-demo.ps1') -Destination (Join-Path $fixture 'tasks')
        $uia=$store.Submit('agent-demo',$true)
        Wait-Verified $uia
        $result=$store.Snapshot()|Where-Object Id -ceq $uia
        Assert-Queue ($result.Verification -ceq 'verified' -and $result.Reason -ceq 'verified_goal') 'Verified Goal receipt was missing'
        Write-Output 'Owned UIA fixture passed independent output readback and delivered a verified queue receipt.'
    }
    if($AllowInput){
        foreach($file in 'ReflexCore-VisionHost.cs','ReflexCore-VisionLoop.ps1','ReflexCore-SkillMemory.ps1'){
            Copy-Item -LiteralPath (Join-Path $root ('tools/'+$file)) -Destination (Join-Path $fixture 'tools')
        }
        Put-Task 'notepad-save' @'
$project=Split-Path $PSScriptRoot -Parent
try{$result=& (Join-Path $project 'tools/ReflexCore-VisionLoop.ps1') -Action DemoNotepad -AllowInput -TestFixture -UnicodeFixture}
catch{
    $stage=switch -Regex ($_.Exception.Message){
        'focus|foreground|identity' {'ownership';break}
        'disk|readback' {'verification';break}
        'empty|editor' {'editor';break}
        'Stopped' {'stop';break}
        default {'other'}
    }
    [IO.File]::WriteAllText((Join-Path $project 'fixture-stage'),$stage)
    throw
}
if(!$result.verified -or $result.schema -cne 'reflexcore.notepad.result.v1'){throw 'Missing disk readback'}
[IO.File]::AppendAllText((Join-Path $project 'evidence'),('verified '+[int]$result.memory_hit+' '+$result.model_calls+[Environment]::NewLine))
'@
        $first=$store.Submit('notepad-save',$true)
        $binaryDir=[IO.Directory]::CreateDirectory((Join-Path $fixture 'target/release'))
        Copy-Item -LiteralPath (Join-Path $root 'target/release/reflexcore.exe') -Destination $binaryDir.FullName
        Copy-Item -LiteralPath (Join-Path $root 'tools/ReflexCore-Fixture.ps1') -Destination (Join-Path $fixture 'tools')
        Copy-Item -LiteralPath (Join-Path $root 'tasks/agent-demo.ps1') -Destination (Join-Path $fixture 'tasks')
        $uia=$store.Submit('agent-demo',$true)
        $second=$store.Submit('notepad-save',$true)
        Wait-Verified $first
        Wait-Verified $uia
        Wait-Verified $second
        $results=[IO.File]::ReadAllLines((Join-Path $fixture 'evidence'))
        Assert-Queue ($results.Count -eq 2 -and $results[0] -cmatch '^verified [01] 0$' -and $results[1] -ceq 'verified 1 0') 'Queued skill memory or readback failed'
        Write-Output 'Queued Rust UIA goal passed. Two Notepad workers verified 2/2 files, reused the saved skill on the second run and made zero model calls.'
        if($VisualCancellation){
            Put-Task 'notepad-visual' @'
$project=Split-Path $PSScriptRoot -Parent
try{
    & (Join-Path $project 'tools/ReflexCore-VisionLoop.ps1') -Action DemoNotepad -Route Visual -AllowInput -TestFixture 6>&1 | ForEach-Object {
        if([string]$_ -ceq '[ReflexCore] Before local inference: owned_editor'){
            [IO.File]::WriteAllText((Join-Path $project 'visual-started'),'')
        }
    }
}catch{
    if($_.Exception.Message -like '*Stopped by operator during local inference*'){
        [IO.File]::WriteAllText((Join-Path $project 'visual-stop-ack'),'')
        exit 2
    }
    throw
}
'@
            $fixturesDir=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ReflexCore/runtime/fixtures'
            $prior=@([IO.Directory]::GetFiles($fixturesDir,'ReflexCore-VisionLoop-*.txt'))
            $visual=$store.Submit('notepad-visual',$true)
            Wait-Queue {Test-Path -LiteralPath (Join-Path $fixture 'visual-started')} 'Visual run did not reach inference' 120
            Start-Sleep -Milliseconds 350
            $clock=[Diagnostics.Stopwatch]::StartNew()
            Assert-Queue ($store.Request($visual,'cancel')) 'Visual cancellation rejected'
            Wait-Queue {Is-State $visual 'cancelled'} 'Visual process did not stop' 45
            $new=@([IO.Directory]::GetFiles($fixturesDir,'ReflexCore-VisionLoop-*.txt')|Where-Object {$_ -notin $prior})
            Assert-Queue ($new.Count -eq 1 -and [IO.FileInfo]::new($new[0]).Length -eq 0) 'Expected one empty fixture after cancellation'
            Assert-Queue (Test-Path -LiteralPath (Join-Path $fixture 'visual-stop-ack')) 'Model HTTP request did not observe cancellation'
            Write-Output ('Visual inference cancelled, empty file verified. Request to terminal receipt including model cleanup: '+$clock.ElapsedMilliseconds+' ms.')
        }
    }
}finally{
    if($tray){
        [void]$type.GetMethod('ExitTray',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($tray,@())
        $tray.Dispose()
    }
    $resolved=(Resolve-Path -LiteralPath $fixture).Path
    if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ceq $tempBase.TrimEnd('\') -and [IO.Path]::GetFileName($resolved) -cmatch '^ReflexCore-Queue-[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
