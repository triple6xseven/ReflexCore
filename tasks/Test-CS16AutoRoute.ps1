#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][ValidatePattern('^de_[a-z0-9_]{1,29}$')][string]$Map,
    [ValidateRange(1024,65534)][int]$Port=27125,
    [switch]$Match,
    [string]$SavedRoute,
    [string]$EvidenceDirectory,
    [switch]$CancelInRound,
    [switch]$Record,
    [switch]$Coach,
    [switch]$PublishMcpSummary,
    [string]$CoachVisionReport
)
if($SavedRoute -and (!$Match -or $Map -cne 'de_reflex_lab')){throw 'SavedRoute requires the original match'}
if($CancelInRound -and (!$Match -or !$EvidenceDirectory)){throw 'Cancellation requires match evidence output'}
if($Record -and (!$EvidenceDirectory -or $Port -eq 65534)){throw 'Recording requires evidence output and a spare adjacent port'}
if($PublishMcpSummary -and (!$Match -or $SavedRoute)){throw 'MCP summaries require an automatic offline match'}
$ErrorActionPreference='Stop'
if($CoachVisionReport -and !$Coach){throw '-CoachVisionReport requires -Coach'}
$serverPath=(Resolve-Path -LiteralPath $Server).Path
$lab=Split-Path -Parent $serverPath
$root=Split-Path -Parent $PSScriptRoot
$exe=Join-Path $root 'target/release/reflexcore.exe'
$mail=Join-Path $lab 'cstrike/addons/amxmodx/data/reflexcore'
foreach($file in $exe,(Join-Path $lab 'cstrike/rc-practice.cfg'),(Join-Path $lab "cstrike/maps/$Map.bsp")){
    if(!(Test-Path -LiteralPath $file -PathType Leaf)){throw 'Missing the local release binary, fixture config or map'}
}
if((Split-Path -Leaf $serverPath) -ine 'hlds.exe'){throw 'Select the isolated HLDS executable'}
if(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue){throw 'Local practice port occupied'}
foreach($name in 'controller.lock','command.txt'){
    if(Test-Path -LiteralPath (Join-Path $mail $name)){throw 'The practice mailbox is busy or needs owner recovery'}
}
$stamp=[DateTime]::UtcNow
$environment = @{SteamAppId=$env:SteamAppId;SteamGameId=$env:SteamGameId;REFLEX_LEARNING_MODE=$env:REFLEX_LEARNING_MODE}
$env:SteamAppId='10'
$env:SteamGameId='10'
$env:REFLEX_LEARNING_MODE='off'
$process=$null
$console=Join-Path $lab 'qconsole.log'
$offset=if(Test-Path -LiteralPath $console){(Get-Item -LiteralPath $console).Length}else{0}
$report=$null
$parsed=$null
$logConfirmed=$false
$coachEvidence=$null
$runId=[guid]::NewGuid().ToString('N')
$artifact=$null
if($EvidenceDirectory){$artifact=Join-Path ([IO.Directory]::CreateDirectory($EvidenceDirectory).FullName) $runId}
$worker=$null
$recorder=$null
$recordingState="not_requested"
$stopConfigs=@()
$peak=0L
$log=Join-Path ([IO.Path]::GetTempPath()) ('reflex-route-'+[guid]::NewGuid().ToString('N')+'.log')
Push-Location $root
try{
    $arguments="-console -game cstrike -nomaster -insecure -condebug -dll addons/metamod/dlls/metamod.dll +ip 127.0.0.1 +sv_lan 1 +maxplayers 4 +log on +servercfgfile rc-practice.cfg -port $Port +map $Map"
    $process=Start-Process -FilePath $serverPath -WorkingDirectory $lab -WindowStyle Hidden -PassThru -ArgumentList $arguments
    $state=Join-Path $mail 'state.txt'
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.Elapsed.TotalSeconds -lt 15){
        if($process.HasExited){throw 'Owned server exited'}
        $listener=@(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue)
        if($listener.Count -gt 0 -and ($listener.Count -ne 1 -or $listener[0].LocalAddress -ne '127.0.0.1' -or $listener[0].OwningProcess -ne $process.Id)){
            throw 'Practice endpoint is not exclusively owned on loopback'
        }
        if($listener.Count -eq 1 -and (Test-Path -LiteralPath $state) -and [IO.File]::GetLastWriteTimeUtc($state) -ge $stamp){
            try{if([IO.File]::ReadAllText($state).StartsWith("reflexcore_cs16_practice_v1 $Map ")){break}}catch [IO.IOException]{}
        }
        Start-Sleep -Milliseconds 150
    }
    if($clock.Elapsed.TotalSeconds -ge 15){throw 'No fresh map state'}
    if($Record){
        $tv=Join-Path $lab 'hltv.exe'
        if(!(Test-Path -LiteralPath $tv -PathType Leaf) -or
           (Get-NetUDPEndpoint -LocalPort ($Port+1) -ErrorAction SilentlyContinue)){
            $recordingState='recorder_unavailable'
        }else{
            $stopName="rc-$runId-stop.cfg"
            $stopConfigs=@((Join-Path $lab $stopName),(Join-Path $lab "cstrike/$stopName"))
            foreach($path in $stopConfigs){[IO.File]::WriteAllText($path,'')}
            $recordArgs="-ip 127.0.0.1 -port $($Port+1) -nomaster -noipx +delay 0 +name ReflexCoreRecorder +connect 127.0.0.1:$Port +record rc-$runId +loopcmd 2 1 exec $stopName"
            $recorder=Start-Process $tv -WorkingDirectory $lab -WindowStyle Hidden -PassThru -ArgumentList $recordArgs
            $recordingState='started'
            Start-Sleep -Seconds 3
        }
    }
    $route=if($SavedRoute){(Resolve-Path -LiteralPath $SavedRoute).Path}else{'auto'}
    $opponent=if($Match){'--match'}else{'--stationary-opponent'}
    if($artifact){
        $cancel=$artifact+'.cancel'
        $arguments='cs16 practice "'+$mail+'" "'+$route+'" --allow-offline '+$opponent+' --cancel-file "'+$cancel+'"'
        $worker=Start-Process $exe -WorkingDirectory $root -WindowStyle Hidden -PassThru -ArgumentList $arguments -RedirectStandardOutput ($artifact+'.result.json') -RedirectStandardError ($artifact+'.stderr.txt')
        $null=$worker.Handle
        while(!$worker.WaitForExit(100)){
            $worker.Refresh();$peak=[Math]::Max($peak,$worker.PeakWorkingSet64)
            if($CancelInRound -and ![IO.File]::Exists($cancel)){
                try {
                    $signals=[IO.File]::ReadAllText((Join-Path $mail 'match-state.txt')).Trim() -split ' '
                    $snapshot=[IO.File]::ReadAllText($state).Trim() -split ' '
                    if($signals[0] -ceq 'reflexcore_cs16_match_v2' -and $signals[5] -ceq '1' -and $snapshot[5] -ceq '1' -and $snapshot[-1] -ceq 'moved'){
                        [IO.File]::WriteAllText($cancel,'stop')
                    }
                }catch [IO.IOException]{}
            }
            if($clock.Elapsed.TotalSeconds -gt 185){throw 'Controller deadline expired'}
        }
        $result=$worker.ExitCode
        $output=Get-Content -LiteralPath ($artifact+'.result.json')
        @{run_id=$runId;map=$Map;exit_code=$result;peak_worker_bytes=$peak;cancelled_requested=[IO.File]::Exists($cancel)} |
            ConvertTo-Json | Set-Content -LiteralPath ($artifact+'.trial.json') -Encoding UTF8
    } else {
        $output=& $exe cs16 practice $mail $route --allow-offline $opponent
        $result=$LASTEXITCODE
    }
    $output | Write-Output
    $report=($output -join [Environment]::NewLine)|ConvertFrom-Json
    if(!$report -or $report.map -cne $Map){throw 'Controller evidence missing'}
    $file=[IO.File]::Open($console,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{
        if($file.Length -lt $offset -or $file.Length-$offset -gt 512KB){throw 'Invalid fresh game log range'}
        $file.Position=$offset
        $reader=[IO.StreamReader]::new($file)
        try{[IO.File]::WriteAllText($log,$reader.ReadToEnd())}finally{$reader.Dispose()}
    }finally{$file.Dispose()}
    if($artifact){Copy-Item -LiteralPath $log -Destination ($artifact+'.log')}
    if($report.engine_subject_id -eq 0){throw "Actor setup failed: $($report.outcome)"}
    $benchmarkArgs=@('cs16','benchmark',$log,'--player',$report.engine_subject_id)
    if($Match -and !$SavedRoute -and !$CancelInRound){$benchmarkArgs+='--require-completed-round'}
    $evidence=& $exe @benchmarkArgs
    if($artifact){$evidence | Set-Content -LiteralPath ($artifact+'.benchmark.json') -Encoding UTF8}
    if($LASTEXITCODE -ne 0){throw 'Independent game log parser failed'}
    $evidence | Write-Output
    $parsed=($evidence -join [Environment]::NewLine)|ConvertFrom-Json
    if($CancelInRound){
        if($report.outcome -cne 'cancelled'){throw 'Cancellation was not observed'}
    }elseif($Match -and !$SavedRoute){
        if($result -ne 0 -or !$report.round_completed -or $parsed.verified_completed_actor_rounds -ne 1 -or
           $parsed.verified_completed_actor_wins -ne [int]$report.verified_round_win -or
           $parsed.verified_plants -ne [int]$report.verified_plant){throw "Round not verified: $($report.outcome)"}
    }elseif($SavedRoute){
        if($result -ne 0 -or $parsed.verified_plant_bot_round_wins -ne 1){throw 'Original lab match regression failed'}
    }elseif($result -ne 0 -or $parsed.verified_plants -lt 1){throw 'Automatic drill did not verify a plant'}
    if($Match -and !$SavedRoute -and !$CancelInRound){$logConfirmed=$true}
    if($Coach){$coachEvidence=$evidence -join [Environment]::NewLine}
}finally{
    if($recorder){
        if(!$recorder.HasExited){
            foreach($path in $stopConfigs){[IO.File]::WriteAllLines($path,@('stoprecording','quit'))}
            if(!$recorder.WaitForExit(5500)){$recorder.Kill();$recorder.WaitForExit();$recordingState='recorder_timeout'}
        }
        if($recordingState -ne 'recorder_timeout'){
            $demos=@(Get-ChildItem -LiteralPath $lab,(Join-Path $lab 'cstrike') -Filter "rc-$runId*.dem" -File)
            if($demos.Count -eq 1 -and $demos[0].Length -gt 544){
                Move-Item -LiteralPath $demos[0].FullName -Destination ($artifact+'.dem')
                $recordingState='saved'
            }else{$recordingState='no_finalized_demo'}
        }
        $recorder.Dispose()
    }
    foreach($path in $stopConfigs){[IO.File]::Delete($path)}
    if($artifact){$recordingState|Set-Content -LiteralPath ($artifact+'.replay.txt') -Encoding ASCII}
    if($worker -and !$worker.HasExited){$worker.Kill();$worker.WaitForExit()}
    if($null -ne $process){
        if(!$process.HasExited){$process.Kill();$process.WaitForExit()}
        $process.Dispose()
    }
    foreach($key in $environment.Keys){[Environment]::SetEnvironmentVariable($key,$environment[$key],'Process')}
    [IO.File]::Delete($log)
    Pop-Location
    if($PublishMcpSummary){
        $kind=if($logConfirmed){'completed'}
            elseif($report.outcome -ceq 'cancelled'){'cancelled'}
            elseif($report -and $report.engine_subject_id -gt 0 -and !$report.round_completed){'truncated'}
            else{'infrastructure_failure'}
        $death=$null;$win=$null;$plant=$null
        if($logConfirmed){
            $completed=@($parsed.rounds | Where-Object {
                $_.close -ceq 'round_end' -and $null -ne $_.terrorist_win -and
                $null -ne $_.c4_acquired_from_round_start_seconds
            })
            if($completed.Count -ne 1){throw 'Independent round evidence is ambiguous'}
            $death=$null -ne $completed[0].player_death_from_round_start_seconds
            $win=$parsed.verified_completed_actor_wins -eq 1
            $plant=$parsed.verified_plants -eq 1
        }
        $summary=@{
            schema='reflexcore.lab.run.v1';run_id=$runId;map=$Map;termination=$kind
            server_log_confirmed=$logConfirmed;contacts=$report.contacts;shot_requests=$report.match_shots
            discharges=$report.combat.shots;hits=$report.combat.hits;defender_discharges=$report.combat.defender_shots
            observation_p95_us=$report.observation_us.p95;decision_p95_us=$report.decision_us.p95
            win=$win;plant=$plant;death=$death
        }
        $directory=[IO.Directory]::CreateDirectory((Join-Path $root 'data/private/mcp-lab')).FullName
        $target=Join-Path $directory ($runId+'.json')
        $temp=$target+'.tmp'
        try{
            [IO.File]::WriteAllText($temp,($summary | ConvertTo-Json -Compress))
            [IO.File]::Move($temp,$target)
        }finally{[IO.File]::Delete($temp)}
    }
}
if($Coach){
    $coachInput=$log+'.json'
    try{
        [IO.File]::WriteAllText($coachInput,$coachEvidence)
        $params=@{BenchmarkReport=$coachInput}
        if($CoachVisionReport){$params.VisionReport=$CoachVisionReport}
        & (Join-Path $root 'tools/ReflexCore-CS16Coach.ps1') @params
    }finally{[IO.File]::Delete($coachInput)}
}
