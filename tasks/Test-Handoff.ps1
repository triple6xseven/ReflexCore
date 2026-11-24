[CmdletBinding()]
param([switch]$Benchmark,[ValidateRange(1,20)][int]$Sessions=4,
      [ValidateRange(1,30)][int]$WarmRuns=5,[string]$MetricsFile,[switch]$RequireOllamaStopped)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$temp=[IO.Path]::GetTempPath()
$fixture=Join-Path $temp ('ReflexHandoff-'+[guid]::NewGuid().ToString('N'))
$folder=Join-Path $fixture 'folder'
$list=Join-Path $fixture 'checklist.json'
$bridge=Join-Path $fixture 'data/bridge'
$observations=New-Object System.Collections.ArrayList
function Require($condition,$reason){if(!$condition){throw $reason}}
function Check-Offline {
    if($RequireOllamaStopped){Require (!(Get-Process -Name ollama -ErrorAction SilentlyContinue)) 'Ollama server must be stopped for this measurement'}
}
function Checklist($entries) {
    $doc=@{schema='reflexcore.handoff.checklist.v1';name='Synthetic handoff';files=@($entries)}
    [IO.File]::WriteAllText($list,($doc|ConvertTo-Json -Depth 5))
}
function Open-Tray {
    $script:tray=$constructor.Invoke([object[]]@([string]$fixture,$true))
}
function Close-Tray {
    if($script:tray){
        [void]$type.GetMethod('ExitTray',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($tray,@())
        $tray.Dispose();$script:tray=$null
    }
}
function Run-Job([string]$report,[string]$expectedOutcome) {
    Check-Offline
    $id=$store.SubmitHandoff($folder,$list,$report)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        [void]$pump.Invoke($tray,@())
        $file=@([IO.Directory]::GetFiles((Join-Path $bridge 'queue-history'),"$id.*"))
        if($file.Count){break}
        Start-Sleep -Milliseconds 20
    }while($timer.Elapsed.TotalSeconds -lt 30)
    Require ($file.Count -eq 1) 'Queue did not publish exactly one terminal history entry'
    $lines=[IO.File]::ReadAllLines($file[0]);Require ($lines.Length -eq 3) 'Missing terminal receipt'
    $r=$lines[2]|ConvertFrom-Json
    Require ($r.task_id -ceq $id -and $r.run_id -ceq $id -and $r.stage -ceq 'handoff') 'Foreign or missing receipt'
    Require ($r.outcome -ceq $expectedOutcome) ("Unexpected outcome: "+$r.outcome+"/"+$r.reason)
    Require ($r.metrics.model_calls -eq 0 -and $null -ne $r.metrics.worker_startup_us) 'Missing or invalid worker measurement'
    Require (!$lines[2].Contains($folder) -and !$lines[2].Contains('Synthetic handoff')) 'Private input in shared receipt'
    Require (!(Test-Path -LiteralPath (Join-Path $fixture "data/private/handoff/$id.json"))) 'Private request retained'
    if($r.outcome -ceq 'verified'){Require ($r.verification -ceq 'verified' -and $r.reason -ceq 'disk_readback') 'Unverified receipt'}
    Check-Offline
    return $r
}
function Evaluate($report,$receipt,$entries,$states,$verdict) {
    $doc=[IO.File]::ReadAllText($report)|ConvertFrom-Json
    Require ($doc.schema -ceq 'reflexcore.handoff.report.v1' -and $doc.run_id -ceq $receipt.run_id) 'Wrong report'
    Require ($doc.verdict -ceq $verdict -and $doc.results.Count -eq $entries.Count -and $doc.checklist.files.Count -eq $entries.Count) 'Wrong verdict or count'
    for($i=0;$i -lt $entries.Count;$i++){
        Require ($doc.checklist.files[$i].path -ceq $entries[$i].path -and $doc.checklist.files[$i].sha256 -ceq $entries[$i].sha256) 'Checklist changed'
        Require ($doc.results[$i].status -ceq $states[$i]) 'Wrong observation'
        if($entries[$i].sha256 -and $states[$i] -in 'present','mismatched'){
            $actual=(Get-FileHash -LiteralPath (Join-Path $folder $entries[$i].path)).Hash
            Require ($doc.results[$i].observed_sha256 -ieq $actual) 'Digest disagrees with external evaluator'
        }
    }
}
try{
    foreach($d in 'folder','tools','tasks','target/release','data/bridge/queue-history'){
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture $d))
    }
    foreach($f in 'tools/ReflexCore-QueuedWorker.ps1','tasks/verify-handoff.ps1','target/release/reflexcore.exe'){
        Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $fixture $f)
    }
    $sources=@('Queue','Tray','Companion','CompanionHost','MenuStyle')|ForEach-Object{Join-Path $root ("tools/ReflexCore-"+$_+".cs")}
    Add-Type -Path $sources -ReferencedAssemblies System.Windows.Forms.dll,System.Drawing.dll,System.Core.dll,System.Management.dll,System.Web.Extensions.dll
    $store=[ReflexCore.Bridge.QueueStore]::new($fixture)
    $type=[ReflexCore.Bridge.TrayHost].Assembly.GetType('ReflexCore.Bridge.TrayWindow',$true)
    $constructor=$type.GetConstructor([type[]]@([string],[bool]))
    $pump=$type.GetMethod('Pump',[Reflection.BindingFlags]'Instance,NonPublic')
    Open-Tray
    $unicode=([char]0x96ea).ToString()+'.txt'
    [IO.File]::WriteAllText((Join-Path $folder $unicode),'test')
    $good=(Get-FileHash -LiteralPath (Join-Path $folder $unicode)).Hash
    foreach($case in 'ready','missing','bad-hash','locked'){
        $entries=@(@{path=$unicode;sha256=$good});$states=@('present');$verdict='Ready';$outcome='verified';$lock=$null
        switch($case){
            'missing' {$entries+=@{path='absent'};$states+='missing';$verdict='Needs attention'}
            'bad-hash' {$entries[0].sha256='0'*64;$states=@('mismatched');$verdict='Needs attention'}
            'locked' {$lock=[IO.File]::Open((Join-Path $folder $unicode),'Open','ReadWrite','None');$states=@('unreadable');$outcome='unverified';$verdict='Needs attention'}
        }
        try{
            Checklist $entries
            $report=Join-Path $fixture "$case.json"
            $r=Run-Job $report $outcome
            Evaluate $report $r $entries $states $verdict
        }finally{if($lock){$lock.Dispose()}}
    }
    $existing=Join-Path $fixture 'ready.json';$before=(Get-FileHash -LiteralPath $existing).Hash
    [void](Run-Job $existing 'failed');Require ((Get-FileHash -LiteralPath $existing).Hash -ceq $before) 'Existing output overwritten'
    $outside=Join-Path $fixture 'outside'
    [void][IO.Directory]::CreateDirectory($outside)
    $junction=Join-Path $folder 'linked'
    [void](New-Item -ItemType Junction -Path $junction -Target $outside)
    try{
        foreach($path in '../checklist.json','linked/secret','NUL','data:stream'){
            Checklist @(@{path=$path});$report=Join-Path $fixture 'refused.json'
            [void](Run-Job $report 'failed');Require (!(Test-Path -LiteralPath $report)) 'Out-of-scope output published'
        }
    }finally{[IO.Directory]::Delete($junction)}
    Add-Type -Path (Join-Path $root 'tools/ReflexCore-HandoffDraft.cs')
    [string[]]$draftLines=@()
    $draft=[ReflexCore.Control.HandoffDraft]::Build(('Verify "'+$unicode+'" SHA256: '+$good+' and absent.txt.'),[ref]$draftLines)
    Require ($draft.ToString() -ceq 'Draft') 'Text draft was rejected'
    $draftEntries=@(foreach($line in $draftLines){
        $parts=$line -split ' \| ',2
        @{path=$parts[0];sha256=if($parts.Count -eq 2){$parts[1]}else{$null}}
    })
    Checklist $draftEntries
    $report=Join-Path $fixture 'from-text.json'
    $r=Run-Job $report 'verified'
    Evaluate $report $r @(@{path=$unicode;sha256=$good.ToLowerInvariant()},@{path='absent.txt'}) @('present','missing') 'Needs attention'
    Write-Output 'Text draft passed through the native verifier and published a verified report.'
    Close-Tray
    Write-Output 'Queue acceptance passed: ready, Unicode, missing, mismatch, unreadable, collision and scope rejection.'
    if($Benchmark){
        $bytes=New-Object byte[] 131072
        ([Random]::new(701242)).NextBytes($bytes)
        $meta=@();$hashed=@();$states=@()
        foreach($i in 1..100){
            $name="file-$i.bin";$path=Join-Path $folder $name
            [IO.File]::WriteAllBytes($path,$bytes)
            $meta+=@{path=$name};$hashed+=@{path=$name;sha256=(Get-FileHash -LiteralPath $path).Hash};$states+='present'
        }
        for($s=0;$s -lt $Sessions;$s++){
            $modes=if($s%2){'hash','metadata'}else{'metadata','hash'}
            foreach($mode in $modes){
                $entries=if($mode -ceq 'hash'){$hashed}else{$meta}
                Checklist $entries
                Open-Tray
                for($i=0;$i -le $WarmRuns;$i++){
                    $report=Join-Path $fixture "$s-$mode-$i.json"
                    $r=Run-Job $report 'verified'
                    Evaluate $report $r $entries $states 'Ready'
                    $phase=if($i){'warm'}else{'cold'}
                    [void]$observations.Add([pscustomobject]@{mode=$mode;phase=$phase;session=$s;run_id=$r.run_id;outcome=$r.outcome;metrics=$r.metrics})
                }
                Close-Tray
            }
        }
        if($MetricsFile){
            $json=ConvertTo-Json -InputObject @($observations) -Depth 5
            $writer=[IO.StreamWriter]::new([IO.File]::Open($MetricsFile,'CreateNew','Write','None'))
            try{$writer.Write($json)}finally{$writer.Dispose()}
        }
        foreach($group in ($observations|Group-Object mode,phase)){
            Write-Output ($group.Name+' verified='+$group.Count)
            foreach($field in 'queue_wait_us','worker_startup_us','check_us','write_us','readback_us','worker_us','peak_private_bytes','bytes_hashed','model_calls'){
                $v=@($group.Group|ForEach-Object{$_.metrics.$field}|Sort-Object)
                Write-Output ("{0} p50={1} p95={2} max={3}" -f $field,$v[[math]::Ceiling($v.Count*.5)-1],$v[[math]::Ceiling($v.Count*.95)-1],$v[-1])
            }
        }
    }
}finally{
    Close-Tray
    $resolved=[IO.Path]::GetFullPath($fixture)
    if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ceq $temp.TrimEnd('\') -and [IO.Path]::GetFileName($resolved) -cmatch '^ReflexHandoff-[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
