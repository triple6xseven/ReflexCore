[CmdletBinding()]
param([switch]$Benchmark,[switch]$Mcp,[ValidateRange(1,20)][int]$Sessions=4,
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
function Terminal-Job([string]$id) {
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
    Require ($r.task_id -ceq $id -and $r.run_id -ceq $id) 'Foreign or missing receipt'
    return $r
}
function Run-Job([string]$report,[string]$expectedOutcome) {
    Check-Offline
    $id=$store.SubmitHandoff($folder,$list,$report)
    $r=Terminal-Job $id
    Require ($r.stage -ceq 'handoff') 'Incorrect stage'
    Require ($r.outcome -ceq $expectedOutcome) ("Unexpected outcome: "+$r.outcome+"/"+$r.reason)
    Require ($r.metrics.model_calls -eq 0 -and $null -ne $r.metrics.worker_startup_us) 'Missing or invalid worker measurement'
    Require (!$r.PSObject.Properties['path'] -and !$r.PSObject.Properties['folder'] -and !$r.PSObject.Properties['checklist']) 'Private input in shared receipt'
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
    foreach($f in 'tools/ReflexCore-QueuedWorker.ps1','tools/ReflexCore-ExtensionRename.cs','tasks/rename-extensions.ps1','tasks/verify-handoff.ps1','target/release/reflexcore.exe'){
        Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $fixture $f)
    }
    $sources=@('Queue','Tray','Companion','CompanionHost','MenuStyle')|ForEach-Object{Join-Path $root ("tools/ReflexCore-"+$_+".cs")}
    $assembly=Join-Path $fixture 'QueueFixture.dll'
    Add-Type -Path $sources -OutputAssembly $assembly -ReferencedAssemblies System.Windows.Forms.dll,System.Drawing.dll,System.Core.dll,System.Management.dll,System.Web.Extensions.dll
    $null=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assembly))
    $workflowSources=@('ExtensionRename','HandoffDraft','FolderWorkflow')|ForEach-Object{Join-Path $root ("tools/ReflexCore-"+$_+".cs")}
    Add-Type -Path $workflowSources -ReferencedAssemblies @($assembly,'System.Web.Extensions.dll')
    $store=[ReflexCore.Bridge.QueueStore]::new($fixture)
    $type=[ReflexCore.Bridge.TrayHost].Assembly.GetType('ReflexCore.Bridge.TrayWindow',$true)
    $constructor=$type.GetConstructor([type[]]@([string],[bool]))
    $pump=$type.GetMethod('Pump',[Reflection.BindingFlags]'Instance,NonPublic')
    Open-Tray
    $unicode=([char]0x96ea).ToString()+'.txt'
    [IO.File]::WriteAllText((Join-Path $folder $unicode),'test')
    $good=(Get-FileHash -LiteralPath (Join-Path $folder $unicode)).Hash
    if($Mcp){
        foreach($f in 'ReflexCore-Mcp.ps1','ReflexCore-Mcp.cs','ReflexCore-McpLab.cs','ReflexCore-Queue.cs'){
            Copy-Item -LiteralPath (Join-Path $root "tools/$f") -Destination (Join-Path $fixture "tools/$f")
        }
        $settings=Join-Path $fixture 'data/settings'
        [void][IO.Directory]::CreateDirectory($settings)
        [IO.File]::WriteAllText((Join-Path $settings 'mcp-scope.txt'),$fixture)
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=(Join-Path $PSHOME 'powershell.exe')
        $start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $fixture 'tools/ReflexCore-Mcp.ps1')+'"'
        $start.UseShellExecute=$false
        $start.RedirectStandardInput=$true
        $start.RedirectStandardOutput=$true
        $child=[Diagnostics.Process]::Start($start)
        $script:requestId=0
        function Invoke-Mcp($method,$params,[switch]$Notification){
            $body=@{jsonrpc='2.0';method=$method;params=$params}
            if(!$Notification){$body.id=++$script:requestId}
            $child.StandardInput.WriteLine(($body|ConvertTo-Json -Compress -Depth 8))
            if($Notification){return}
            $read=$child.StandardOutput.ReadLineAsync()
            Require ($read.Wait(12000) -and $read.Result) 'No MCP reply'
            $response=$read.Result|ConvertFrom-Json
            Require ($response.id -eq $body.id -and !$response.error) 'Invalid MCP reply'
            return $response.result
        }
        function Invoke-Tool($name,$arguments){
            Invoke-Mcp 'tools/call' @{name=$name;arguments=$arguments}
        }
        try{
            $hello=Invoke-Mcp 'initialize' @{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='test';version='1'}}
            Require ($hello.serverInfo.name -eq 'reflexcore') 'MCP server identity not found'
            Invoke-Mcp 'notifications/initialized' @{} -Notification
            Require ((Invoke-Mcp 'tools/list' @{}).tools.Count -eq 10) 'Wrong MCP tools'
            Require ((Invoke-Tool 'list_skills' @{}).isError) 'MCP did not honor the off switch'
            [IO.File]::WriteAllText((Join-Path $settings 'mcp.enabled'),'on')
            $catalog=(Invoke-Tool 'list_skills' @{}).content[0].text|ConvertFrom-Json
            $chain=@($catalog.compositions|Where-Object id -eq 'editor.derive_chain')
            Require ($chain.Count -eq 1 -and $chain[0].steps.Count -eq 6 -and $chain[0].submission -ceq 'direct_cli') 'Incorrect composition discovery contract'
            $saved=@($catalog.skills|Where-Object id -ceq 'artifact.verify_saved_text')
            Require ($catalog.schema -ceq 'reflexcore.skill_catalog.v1' -and $saved.Count -eq 1 -and
                $saved[0].bindings.adapter -ccontains 'notepad' -and $saved[0].bindings.adapter -ccontains 'winforms') 'Missing saved-text skill bindings'
            foreach($variant in 'valid','foreign','unsupported'){
                $editorId=[datetime]::UtcNow.ToString('yyyyMMddHHmmssfff')+'-'+[guid]::NewGuid().ToString('N')
                $run=[guid]::NewGuid().ToString('N')
                $e=@{schema='reflexcore.skill.evidence.v1';skill_id='artifact.verify_saved_text';skill_version=1
                    run_id=$run;adapter='notepad';adapter_version=1;verifier_version=1;outcome='verified';readback_us=5}
                if($variant -eq 'foreign'){$e.run_id=[guid]::NewGuid().ToString('N')}
                if($variant -eq 'unsupported'){$e.verifier_version=2}
                $record=@{schema='reflexcore.task.receipt.v1';task_id=$editorId;run_id=$run;stage='notepad'
                    outcome='verified';verification='verified';reason='disk_readback';skill=$e}
                $history=Join-Path $bridge "queue-history/$editorId.completed"
                [IO.File]::WriteAllLines($history,@('RUN','notepad-save.ps1',($record|ConvertTo-Json -Depth 4 -Compress)))
                $reply=Invoke-Tool 'get_task_result' @{task_id=$editorId}
                if($variant -eq 'valid'){
                    Require ($reply.structuredContent.receipt.skill.run_id -ceq $run) 'Missing retained editor evidence'
                    Require ((Invoke-Tool 'cancel_task' @{task_id=$editorId}).isError) 'Editor discovery expanded cancellation authority'
                }else{Require ($reply.isError) 'Foreign or unsupported skill evidence was accepted'}
            }
            $mapping=@{reflexcore=$fixture;zxclaglab=$folder}
            [IO.File]::WriteAllText((Join-Path $settings 'mcp-projects.json'),($mapping|ConvertTo-Json -Compress))
            $projects=(Invoke-Tool 'list_projects' @{}).content[0].text|ConvertFrom-Json
            Require ($projects.projects.Count -eq 2) 'MCP project discovery failed'
            Require ((Invoke-Tool 'submit_handoff_check' @{folder='.';checklist='checklist.json';report='unknown.json'}).isError) 'MCP chose an ambiguous project'
            Checklist @(@{path='absent'})
            [IO.File]::WriteAllText((Join-Path $settings 'mcp-handoff-presets.json'),'{"reflexcore":{"release":"folder"}}')
            $presetRoot=Join-Path $fixture 'data/private/mcp-checklists'
            [void][IO.Directory]::CreateDirectory($presetRoot)
            Copy-Item -LiteralPath $list -Destination (Join-Path $presetRoot 'reflexcore.release.json')
            $projects=Invoke-Tool 'list_projects' @{}
            Require ($projects.structuredContent.projects[0].presets[0] -eq 'release') 'Saved preset not present in structured discovery'
            $saved=Invoke-Tool 'submit_saved_handoff' @{project='reflexcore';preset='release'}
            $savedId=$saved.structuredContent.task_id
            $pending=Invoke-Tool 'get_task_result' @{task_id=$savedId}
            Require ($pending.structuredContent.state -eq 'pending_approval' -and $pending.structuredContent.next_action -eq 'approve_in_studio') 'Missing approval state'
            Require ($store.Request($savedId,'approve')) 'Saved workflow could not be approved'
            $savedReceipt=Terminal-Job $savedId
            $savedResult=Invoke-Tool 'get_task_result' @{task_id=$savedId}
            Require ($savedResult.structuredContent.folder_verdict -eq 'needs_attention') 'Saved workflow lost folder verdict'
            Evaluate ($store.ReadFolderResult($savedId).report) $savedReceipt @(@{path='absent'}) @('missing') 'Needs attention'
            $feedback=(Invoke-Tool 'list_skills' @{}).structuredContent.handoff_feedback
            Require ($feedback.verified -eq 1 -and $feedback.verified_needs_attention -eq 1) 'Verified negative finding was not retained as workflow evidence'
            $changed=(Invoke-Tool 'submit_saved_handoff' @{project='reflexcore';preset='release'}).structuredContent
            $changedId=$changed.task_id
            [IO.File]::AppendAllText((Join-Path $presetRoot 'reflexcore.release.json'),' ')
            Require ($store.Request($changedId,'approve')) 'Changed-checklist job could not be approved for rejection'
            $changedReceipt=Terminal-Job $changedId
            Require ($changedReceipt.verification -ne 'verified' -and !(Test-Path -LiteralPath ($store.ReadFolderResult($changedId).report))) 'Edited checklist was accepted after approval'

            $lab=Join-Path $fixture 'data/private/mcp-lab'
            [void][IO.Directory]::CreateDirectory($lab)
            $labId='1'*32
            $testRun=@{schema='reflexcore.lab.run.v1';map='de_dust2';run_id=$labId;termination='truncated';
                server_log_confirmed=$false;shot_requests=1;discharges=0;hits=0;private_path='hidden'}
            [IO.File]::WriteAllText((Join-Path $lab ($labId+'.json')),($testRun|ConvertTo-Json -Compress))
            [IO.File]::WriteAllText((Join-Path $lab (('2'*32)+'.json')),($testRun|ConvertTo-Json -Compress))
            $runs=(Invoke-Tool 'list_lab_runs' @{}).structuredContent.runs
            Require ($runs.Count -eq 1 -and $runs[0].termination -eq 'truncated' -and
                $runs[0].shot_requests -eq 1 -and $runs[0].discharges -eq 0 -and
                $null -eq $runs[0].win -and !$runs[0].PSObject.Properties['private_path']) 'Invalid or private lab evidence escaped the adapter'

            $combat=Join-Path $fixture 'data/private/mcp-combat'
            [void][IO.Directory]::CreateDirectory($combat)
            $baselineId='3'*32;$candidateId='4'*32
            $record=@{schema='reflexcore.lab.combat.v1';map='de_reflex_lab';run_id=$baselineId;suite_id=('5'*32);
                scenario='stationary';policy='baseline';termination='completed';reason='weapon_timer_active';
                verifier='goldsrc_weapon_trace_v1';attacker_requests=1;discharges=0;playback_events=0;
                action_id=5;generation=1;reaction_us=100;observation_age_ms=10;damage_events=0;model_calls=0;
                memory_status='ineligible';private_path='hidden'}
            [IO.File]::WriteAllText((Join-Path $combat ($baselineId+'.json')),($record|ConvertTo-Json -Compress))
            $record.run_id=$candidateId;$record.policy='candidate';$record.reason='clip_decreased'
            $record.discharges=1;$record.playback_events=1
            [IO.File]::WriteAllText((Join-Path $combat ($candidateId+'.json')),($record|ConvertTo-Json -Compress))
            $compare=@{baseline_run_id=$baselineId;candidate_run_id=$candidateId}
            $paired=(Invoke-Tool 'compare_combat_runs' $compare).structuredContent
            Require ($paired.discharge_change -eq 1 -and $paired.damage_event_change -eq 0 -and !$paired.candidate.PSObject.Properties['private_path']) 'Combat comparison lost outcome or exposed private data'
            $record.suite_id='6'*32
            [IO.File]::WriteAllText((Join-Path $combat ($candidateId+'.json')),($record|ConvertTo-Json -Compress))
            Require ((Invoke-Tool 'compare_combat_runs' $compare).isError) 'MCP combined incompatible combat trials'
            $argsForCheck=@{project='reflexcore';folder='folder';checklist='checklist.json';report='mcp-report.json'}
            $outside=@{project='zxclaglab';folder='..';checklist='checklist.json';report='mcp-report.json'}
            Require ((Invoke-Tool 'submit_handoff_check' $outside).isError) 'MCP accepted a path outside the scope'
            $job=(Invoke-Tool 'submit_handoff_check' $argsForCheck).content[0].text|ConvertFrom-Json
            $id=$job.task_id
            Require ($job.state -eq 'pending_approval') 'MCP did not request approval'
            [void]$pump.Invoke($tray,@())
            Require (!(Test-Path (Join-Path $fixture $argsForCheck.report))) 'MCP executed without approval'
            Require ($store.Request($id,'approve')) 'Could not approve MCP task'
            $receipt=Terminal-Job $id
            $result=(Invoke-Tool 'get_task_result' @{task_id=$id}).content[0].text|ConvertFrom-Json
            Require ($receipt.verification -eq 'verified' -and $result.receipt.run_id -eq $id -and $result.receipt.handoff.missing -eq 1 -and $result.receipt.metrics.model_calls -eq 0) 'Wrong MCP handoff receipt'
            Evaluate (Join-Path $fixture $argsForCheck.report) $receipt @(@{path='absent'}) @('missing') 'Needs attention'
            $argsForCheck.report='mcp-cancelled.json'
            $cancelJob=(Invoke-Tool 'submit_handoff_check' $argsForCheck).content[0].text|ConvertFrom-Json
            $cancel=(Invoke-Tool 'cancel_task' @{task_id=$cancelJob.task_id}).content[0].text|ConvertFrom-Json
            Require ($cancel.cancellation_requested) 'MCP cancellation not accepted'
            $cancelReceipt=Terminal-Job $cancelJob.task_id
            Require ($cancelReceipt.outcome -eq 'cancelled' -and !(Test-Path (Join-Path $fixture $argsForCheck.report))) 'MCP task did not cancel before execution'
            Write-Host '[ReflexCore] MCP tested through the actual queue, worker and report readback.'
        }finally{
            $child.StandardInput.Close()
            if(!$child.WaitForExit(1500)){$child.Kill()}
            $child.Dispose()
        }
    }
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
    [string[]]$flowFiles=@(); [string]$old=''; [string]$new=''
    $sentence='Check README.md, then change .txt to .log.'
    Require ([ReflexCore.Control.FolderWorkflow]::TryBuild($sentence,[ref]$flowFiles,[ref]$old,[ref]$new)) 'English workflow request not recognized'
    Require ($flowFiles.Count -eq 1 -and $flowFiles[0] -ceq 'README.md' -and $old -ceq '.txt' -and $new -ceq '.log') 'Wrong workflow fields'
    $ru='Проверь, что в папке есть README.md, затем поменяй .txt на .log'
    Require ([ReflexCore.Control.FolderWorkflow]::TryBuild($ru,[ref]$flowFiles,[ref]$old,[ref]$new)) 'Russian workflow request not recognized'
    Checklist @(@{path='README.md'})
    $guard=[ReflexCore.Bridge.FolderResultLink]::new()
    $guard.folder=$folder;$guard.checklist=$list;$guard.checklist_sha256=(Get-FileHash -LiteralPath $list).Hash
    $guard.old_extension='.txt';$guard.new_extension='.log'
    foreach($ready in $false,$true){
        if($ready){[IO.File]::WriteAllText((Join-Path $folder 'README.md'),'ready')}
        $guard.report=Join-Path $fixture "workflow-$ready.json"
        $task=$store.SubmitFolderCheck($guard)
        [void](Terminal-Job $task)
        $row=$store.Snapshot()|Where-Object Id -ceq $task
        $link=$store.ReadFolderResult($task)
        $valid=[ReflexCore.Control.FolderWorkflow]::MatchesReport($link.report,$row.Receipt)
        Require $valid 'Local report did not match its receipt'
        Require (([ReflexCore.Control.FolderWorkflow]::CanContinue($row.Receipt,$link,$valid)) -eq $ready) 'Readiness gate failed'
        Require ($row.Receipt.handoff.present -eq [int]$ready -and $row.Receipt.handoff.missing -eq [int](!$ready)) 'Wrong card summary'
        if($ready){
            $other=Join-Path $fixture 'workflow-False.json'
            Require (![ReflexCore.Control.FolderWorkflow]::MatchesReport($other,$row.Receipt)) 'Foreign report accepted'
        }
    }
    $plan=[ReflexCore.Control.ExtensionRename]::Preview($folder,'.txt','.log')
    [IO.File]::Delete((Join-Path $folder 'README.md'))
    $blocked=$store.SubmitRename($folder,'.txt','.log',$plan.Fingerprint(),$link)
    $r=Terminal-Job $blocked
    Require ($r.outcome -ceq 'failed' -and $r.renamed -eq 0 -and [IO.File]::Exists((Join-Path $folder $unicode))) 'Stale readiness allowed a rename'
    [IO.File]::WriteAllText((Join-Path $folder 'README.md'),'ready')
    $renamed=$store.SubmitRename($folder,'.txt','.log',$plan.Fingerprint(),$link)
    $r=Terminal-Job $renamed
    Require ($r.stage -ceq 'rename' -and $r.outcome -ceq 'verified' -and $r.renamed -eq 1) 'Queued rename failed'
    Require ([IO.File]::ReadAllText((Join-Path $folder ([IO.Path]::ChangeExtension($unicode,'.log')))) -ceq 'test') 'Wrong renamed artifact'
    $journal=Join-Path ([ReflexCore.Control.ExtensionRename]::JournalDirectory) "$renamed.jsonl"
    try { Require ([ReflexCore.Control.ExtensionRename]::ConfirmedCount($renamed) -eq 1) 'Journal count mismatch' }
    finally { [IO.File]::Delete($journal) }
    $pending=$store.SubmitRename($folder,'.txt','.log',$plan.Fingerprint(),$link)
    Require ($store.Request($pending,'cancel')) 'Cancellation was not accepted'
    $r=Terminal-Job $pending
    Require ($r.outcome -ceq 'cancelled') 'Pending rename was not cancelled'
    Write-Output 'Folder workflow passed both languages, result binding, readiness gating, queued rename and pending cancellation.'
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
