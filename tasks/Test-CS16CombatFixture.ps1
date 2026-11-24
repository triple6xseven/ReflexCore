#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$Plugin,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [ValidateRange(1024,65534)][int]$Port=27147,
    [ValidateSet('stationary','moving','friendly','occluded','heldout_moving','heldout_occluded')][string[]]$Scenario,
    [ValidateSet('baseline','candidate')][string[]]$Policy=@('baseline','candidate'),
    [switch]$SkipCancellation,
    [switch]$Remember,
    [switch]$PublishMcpSummary
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$serverPath=(Resolve-Path -LiteralPath $Server).ProviderPath
$lab=Split-Path $serverPath -Parent
$pluginPath=(Resolve-Path -LiteralPath $Plugin).ProviderPath
$installed=Join-Path $lab 'cstrike/addons/amxmodx/plugins/reflexcore_practice.amxx'
$core=Join-Path $root 'target/release/reflexcore.exe'
$mapFile=Join-Path $lab 'cstrike/maps/de_reflex_lab.bsp'
$mail=Join-Path $lab 'cstrike/addons/amxmodx/data/reflexcore'
if((Split-Path $serverPath -Leaf) -ine 'hlds.exe' -or
   !(Test-Path -LiteralPath (Join-Path $lab 'cstrike/rc-practice.cfg')) -or
   !(Test-Path -LiteralPath $installed) -or !(Test-Path -LiteralPath $mapFile)){
    throw 'Select the owned, isolated ReflexCore GoldSrc lab.'
}
if(!$Scenario){$Scenario=@('stationary','moving','friendly','occluded','heldout_moving','heldout_occluded')}
if(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue){throw 'The loopback fixture port is occupied.'}
$existing=@(Get-Process hlds -ErrorAction SilentlyContinue | Where-Object Path -EQ $serverPath)
if($existing.Count -gt 0){throw 'Close the selected owned lab before running the fixture.'}
if((Test-Path -LiteralPath (Join-Path $mail 'controller.lock')) -or
   (Test-Path -LiteralPath (Join-Path $mail 'command.txt'))){throw 'The lab mailbox requires owner recovery.'}

$out=[IO.Directory]::CreateDirectory($EvidenceDirectory).FullName
$destination=Join-Path $out 'combat-fixture-results.json'
if(Test-Path -LiteralPath $destination){throw 'Choose a new evidence directory.'}
$hashes=[ordered]@{
    core=(Get-FileHash -LiteralPath $core).Hash
    plugin=(Get-FileHash -LiteralPath $pluginPath).Hash
    server=(Get-FileHash -LiteralPath $serverPath).Hash
    game_dll=(Get-FileHash -LiteralPath (Join-Path $lab 'cstrike/dlls/mp.dll')).Hash
    map=(Get-FileHash -LiteralPath $mapFile).Hash
    server_file_version=(Get-Item -LiteralPath $serverPath).VersionInfo.FileVersion
}
$hardware=[ordered]@{
    cpu=(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
    ram_bytes=(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    os=(Get-CimInstance Win32_OperatingSystem).Caption
}
$backup=[IO.File]::ReadAllBytes($installed)
$isolated=[IO.File]::ReadAllBytes($pluginPath)
$fixtureRoot=Join-Path $root 'data/private/mcp-combat'
$suiteId=[guid]::NewGuid().ToString('N')
function Invoke-CombatTrial([string]$Case,[string]$Variant,[bool]$Cancel){
    $id=[guid]::NewGuid().ToString('N')
    $prefix=Join-Path $out $id
    $marker=$prefix+'.cancel'
    $result=$prefix+'.trace.json'
    $baseline=Join-Path $lab 'qconsole.log'
    $logOffset=if(Test-Path -LiteralPath $baseline){(Get-Item -LiteralPath $baseline).Length}else{0L}
    $serverProcess=$null;$worker=$null;$peak=0L;$summary=$null
    $row=[ordered]@{
        schema='reflexcore.lab.combat.v1';run_id=$id;suite_id=$suiteId;map='de_reflex_lab';scenario=$Case;policy=$Variant
        termination='infrastructure_failure';reason='fixture_setup';verifier='goldsrc_weapon_trace_v1'
        attacker_requests=$null;discharges=$null;damage_events=$null;selection_errors=$null
        reaction_us=$null;observation_age_ms=$null;primary_attack_events=$null;playback_events=$null
        attack_command_events=$null;action_id=$null;generation=$null
        clip_before=$null;clip_after=$null;player_timer_ms=$null;weapon_timer_ms=$null
        target_displacement=$null;cancellation_acknowledged=$false;cancellation_boundary_verified=$false
        peak_worker_bytes=$null;model_calls=0;memory_status='not_requested';health_loss=$null
    }
    try{
        $argsLine="-console -game cstrike -nomaster -insecure -condebug -dll addons/metamod/dlls/metamod.dll +ip 127.0.0.1 +sv_lan 1 +maxplayers 4 +log on +servercfgfile rc-practice.cfg -port $Port +map de_reflex_lab"
        $stateFile=Join-Path $mail 'state.txt'
        $fresh=[DateTime]::UtcNow
        $serverProcess=Start-Process -FilePath $serverPath -WorkingDirectory $lab -WindowStyle Hidden -PassThru -ArgumentList $argsLine
        $deadline=[DateTime]::UtcNow.AddSeconds(12)
        $ready=$false
        do{
            if($serverProcess.HasExited){throw 'Owned server exited.'}
            if((Test-Path -LiteralPath $stateFile) -and [IO.File]::GetLastWriteTimeUtc($stateFile) -ge $fresh){
                $listeners=@(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue)
                if($listeners.Count -gt 0){
                    if($listeners.Count -ne 1 -or $listeners[0].LocalAddress -ne '127.0.0.1' -or
                       $listeners[0].OwningProcess -ne $serverProcess.Id){throw 'Fixture endpoint is not exclusively owned on loopback.'}
                    $ready=$true
                    break
                }
            }
            Start-Sleep -Milliseconds 75
        }while([DateTime]::UtcNow -lt $deadline)
        if(!$ready){throw 'No fresh owned server observation.'}
        $arguments='cs16 combat-fixture "'+$mail+'" '+$Case+' '+$Variant+' --allow-offline --cancel-file "'+$marker+'" --run-id '+$id
        if($Cancel){$arguments+=' --wait-for-cancel'}elseif($Remember){$arguments+=' --remember'}
        $worker=Start-Process -FilePath $core -WorkingDirectory $root -WindowStyle Hidden -PassThru -ArgumentList $arguments -RedirectStandardOutput $result -RedirectStandardError ($prefix+'.stderr.txt')
        $deadline=[DateTime]::UtcNow.AddSeconds(28)
        while(!$worker.WaitForExit(35)){
            $worker.Refresh()
            $peak=[Math]::Max($peak,$worker.PeakWorkingSet64)
            if($Cancel -and !(Test-Path -LiteralPath $marker)){
                try{
                    if([IO.File]::ReadAllText($marker+'.ready').Trim() -ceq $id){
                        [IO.File]::WriteAllText($marker,'stop')
                    }
                }catch [IO.IOException]{}
            }
            if([DateTime]::UtcNow -ge $deadline){$row.termination='timeout';$row.reason='worker_deadline';throw 'Fixture worker deadline expired.'}
        }
        $summary=Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
        if($summary.schema -cne 'reflexcore.cs16.combat-fixture.v1' -or $summary.run_id -cne $id -or $summary.scenario -cne $Case -or $summary.policy -cne $Variant){
            $row.termination='lost_evidence';$row.reason='foreign_trace';throw 'Worker trace does not match the trial.'
        }
        $row.termination=$summary.termination
        $row.reason=$summary.stage
        $row.attacker_requests=$summary.attack_requests
        $row.memory_status=$summary.memory_status
        $row.reaction_us=$summary.reaction_us
        $row.observation_age_ms=$summary.observation_age_ms
        $row.cancellation_acknowledged=$summary.cancellation_acknowledged
        if($Cancel -and $summary.cancellation_acknowledged -and $summary.attack_requests -eq 0 -and
           $summary.last_submitted_at_cancel -eq $summary.last_submitted_before_cleanup){
            for($read=0;$read -lt 6 -and !$row.cancellation_boundary_verified;$read++){
                try{
                    $fields=[IO.File]::ReadAllText((Join-Path $mail 'fixture-state.txt')).Trim() -split ' '
                    $row.cancellation_boundary_verified=$fields.Count -eq 26 -and $fields[12] -ceq 'waiting' -and
                        [int]$fields[3] -eq (1+$summary.last_submitted_at_cancel) -and $fields[15] -ceq '0' -and $fields[17] -ceq '0'
                }catch [IO.IOException]{}
                if(!$row.cancellation_boundary_verified){Start-Sleep -Milliseconds 25}
            }
        }
        if($summary.termination -eq 'completed'){
            $trace=$summary.final_trace
            $row.reason=$trace.reason
            $row.action_id=$trace.action_id
            $row.generation=$trace.generation
            $row.clip_before=$trace.clip_before
            $row.clip_after=$trace.clip_after
            $row.player_timer_ms=[Math]::Round($trace.player_timer_before_attack*1000,3)
            $row.weapon_timer_ms=[Math]::Round($trace.weapon_timer_before_attack*1000,3)
            $row.target_displacement=$trace.target_displacement
            $row.attack_command_events=$trace.attack_command_events
            $row.primary_attack_events=$trace.primary_attack_events
            $row.playback_events=$trace.playback_events
            $row.damage_events=$trace.damage_events
            if($trace.target_health_before -gt 0 -and $trace.reason -eq 'clip_decreased'){
                $row.health_loss=[Math]::Max(0,$trace.target_health_before-[Math]::Max(0,$trace.target_health_after))
            }
            $decrements=[Math]::Max(0,$trace.clip_before-$trace.clip_after)
            $row.discharges=if($decrements -eq $trace.playback_events){$decrements}else{$null}
            if($null -eq $row.discharges){
                $row.termination='lost_evidence'
                $row.reason='discharge_evidence_disagrees'
            }
            $expected=if($Case -eq 'friendly'){'friendly_target'}elseif($Case -like '*occluded'){'occluded_target'}else{$null}
            $row.selection_errors=if($expected){[int]($trace.reason -cne $expected -or $trace.attack_command_events -gt 0)}
                else{[int]($trace.reason -in @('friendly_target','occluded_target','identity_changed'))}
        }
    }catch{
        [IO.File]::AppendAllText(($prefix+'.harness-error.txt'),($_.Exception.Message + [Environment]::NewLine))
    }finally{
        if($worker){if(!$worker.HasExited){$worker.Kill();$worker.WaitForExit()};$worker.Dispose()}
        if($serverProcess){if(!$serverProcess.HasExited){$serverProcess.Kill();$serverProcess.WaitForExit()};$serverProcess.Dispose()}
        if($peak -gt 0){$row.peak_worker_bytes=$peak}
        if(Test-Path -LiteralPath $baseline){
            $log=[IO.File]::OpenRead($baseline)
            try{
                if($log.Length -ge $logOffset -and $log.Length-$logOffset -le 1MB){
                    $log.Position=$logOffset
                    $copy=[IO.File]::Create($prefix+'.server.log')
                    try{$log.CopyTo($copy)}finally{$copy.Dispose()}
                }
            }finally{$log.Dispose()}
        }
    }
    if($PublishMcpSummary){
        [void][IO.Directory]::CreateDirectory($fixtureRoot)
        $file=Join-Path $fixtureRoot ($id+'.json')
        [IO.File]::WriteAllText(($file+'.tmp'),($row|ConvertTo-Json -Compress))
        [IO.File]::Move(($file+'.tmp'),$file)
    }
    [pscustomobject]$row
}

$previousAppId=$env:SteamAppId
$previousGameId=$env:SteamGameId
$env:SteamAppId='10'
$env:SteamGameId='10'
try{
    [IO.File]::WriteAllBytes($installed,$isolated)
    $runs=@(
        foreach($case in $Scenario){
            foreach($variant in $Policy){Invoke-CombatTrial $case $variant $false}
        }
        if(!$SkipCancellation){Invoke-CombatTrial 'stationary' 'candidate' $true}
    )
    $suite=[ordered]@{
        schema='reflexcore.cs16.combat-suite.v1';suite_id=$suiteId;created_at=[DateTime]::UtcNow.ToString('o')
        hardware=$hardware;builds=$hashes;seed=$null;controlled_spawn=$true;runs=$runs
    }
    [IO.File]::WriteAllText($destination,($suite|ConvertTo-Json -Depth 6))
    $runs | Format-Table scenario,policy,termination,reason,attacker_requests,discharges,damage_events,reaction_us
    Write-Output $destination
    if(@($runs|Where-Object {$_.termination -notin @('completed','cancelled')}).Count -gt 0 -or
       (!$SkipCancellation -and !($runs|Where-Object cancellation_boundary_verified))){exit 1}
}finally{
    [IO.File]::WriteAllBytes($installed,$backup)
    $env:SteamAppId=$previousAppId
    $env:SteamGameId=$previousGameId
}
