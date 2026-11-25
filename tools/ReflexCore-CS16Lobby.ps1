#requires -Version 5.1
[CmdletBinding()]
param([switch]$UiSmoke,[switch]$Probe,[switch]$ProbeRound,[switch]$ProbeClient,[switch]$InstallKeys,[string]$Client)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$assets=Join-Path $root 'games/cs16-practice'
$private=Join-Path $env:LOCALAPPDATA 'ReflexCore'
$second=Join-Path $private 'CS16ReplayClient/hl.exe'
$port=27164
function Set-LobbyKeys([string]$Exe){
    if(!(Test-Path -LiteralPath $Exe -PathType Leaf) -or (Split-Path $Exe -Leaf) -ine 'hl.exe'){throw 'Choose hl.exe from Counter-Strike 1.6.'}
    $game=Join-Path (Split-Path $Exe -Parent) 'cstrike'
    if(!(Test-Path -LiteralPath $game -PathType Container)){throw 'Missing cstrike folder.'}
    Copy-Item -LiteralPath (Join-Path $assets 'reflexcore-lobby.cfg') -Destination (Join-Path $game 'reflexcore-lobby.cfg') -Force
    $cfg=Join-Path $game 'userconfig.cfg'
    if(Test-Path -LiteralPath $cfg){
        if(Select-String -LiteralPath $cfg -Pattern '^\s*exec\s+"?reflexcore-lobby\.cfg"?\s*$' -Quiet){return}
        Copy-Item -LiteralPath $cfg -Destination ($cfg+'.'+[guid]::NewGuid().ToString('N')+'.bak')
    }
    [IO.File]::AppendAllText($cfg,[Environment]::NewLine+'exec reflexcore-lobby.cfg'+[Environment]::NewLine,[Text.Encoding]::ASCII)
}
if($InstallKeys){Set-LobbyKeys $Client;return}

function Start-Lobby {
    $ErrorActionPreference='Stop'
    $env:SteamAppId="10";$env:SteamGameId="10"
    $settings=Get-Content (Join-Path $root 'data/settings/cs16-practice.json') -Raw | ConvertFrom-Json
    $server=(Resolve-Path -LiteralPath $settings.server_exe).ProviderPath
    $lab=Split-Path $server -Parent
    $game=Join-Path $lab 'cstrike'
    if((Split-Path $server -Leaf) -ine 'hlds.exe' -or !(Test-Path (Join-Path $game 'rc-practice.cfg'))){throw 'Configure the owned CS 1.6 practice server first.'}
    if((Get-Process hlds -ErrorAction SilentlyContinue | Where-Object Path -eq $server) -or (Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue)){throw 'The lab server or lobby port is busy.'}
    $addons=Join-Path $game 'addons'
    $bot=Join-Path $addons 'yapb'
    if(!(Test-Path $bot)){
        $stage=Join-Path $private ('staging/lobby-'+[guid]::NewGuid())
        [void][IO.Directory]::CreateDirectory($stage)
        $archive=Join-Path $stage 'bot.zip'
        Invoke-WebRequest -UseBasicParsing 'https://github.com/yapb/yapb/releases/download/4.4.957/yapb-4.4.957-windows.zip' -OutFile $archive
        if((Get-FileHash $archive).Hash -ne 'C32A5B4D77C08C3C59C417568C5719F9227238C6D627D478CFB1D9F7D9C113F4'){throw 'YaPB package checksum mismatch.'}
        Expand-Archive -LiteralPath $archive -DestinationPath $stage
        $package=Join-Path $stage 'addons/yapb'
        $cfg=Join-Path $package 'conf/yapb.cfg'
        [IO.File]::WriteAllText($cfg,([IO.File]::ReadAllText($cfg) -replace '(?m)^yb_quota "9"','yb_quota "0"'))
        Move-Item -LiteralPath $package -Destination $bot
        Remove-Item -LiteralPath $archive
    }
    if(!(Test-Path (Join-Path $bot 'data/graph/de_dust2.graph'))){throw 'Missing YaPB Dust II navigation graph.'}
    if((Get-FileHash (Join-Path $bot 'bin/yapb.dll')).Hash -ne '7F4C2F661E8F177FB3AA14B54FE370482C74A00AF432C884CB928B76CDDF4504'){throw 'The installed YaPB version differs from the supported 4.4.957 build.'}
    $lobby=Join-Path $addons 'reflex-lobby'
    [void][IO.Directory]::CreateDirectory($lobby)
    $compiler=Join-Path $addons 'amxmodx/scripting/amxxpc.exe'
    $binary=Join-Path $addons 'amxmodx/plugins/reflexcore_lobby.amxx'
    & $compiler (Join-Path $assets 'reflexcore_lobby.sma') ("-i"+(Split-Path $compiler)+"/include") ("-o"+$binary) | Out-Null
    if($LASTEXITCODE -ne 0){throw 'The lobby menu did not compile.'}
    [IO.File]::WriteAllLines((Join-Path $lobby 'meta.ini'),[string[]]@('win32 addons/amxmodx/dlls/amxmodx_mm.dll','win32 addons/yapb/bin/yapb.dll'))
    [IO.File]::WriteAllText((Join-Path $lobby 'core.ini'),"amxx_plugins addons/reflex-lobby/plugins.ini`r`n")
    [IO.File]::WriteAllText((Join-Path $lobby 'plugins.ini'),"reflexcore_lobby.amxx`r`n")
    $commands=@('hostname "ReflexCore | Local team play"','sv_lan 1','rc_practice_enabled 0','mp_autoteambalance 0','mp_limitteams 0','mp_freezetime 1','mp_startmoney 16000','mp_logdetail 3','yb_quota 0','log on','meta list','amxx plugins')
    if($ProbeRound){$commands+='mp_roundtime 1';$commands+='mp_c4timer 15'}
    if($ProbeClient){$commands+='rc_lobby_probe_client 1'}
    if($Probe -or $ProbeRound){$commands+='rc_lobby_probe'}
    $configName=if($Probe -or $ProbeClient -or $ProbeRound){'rc-lobby-probe.cfg'}else{'rc-lobby.cfg'}
    [IO.File]::WriteAllLines((Join-Path $game $configName),[string[]]$commands)
    $argsLine="-console -game cstrike -nomaster -insecure -condebug -dll addons/metamod/dlls/metamod.dll +localinfo mm_pluginsfile addons/reflex-lobby/meta.ini +localinfo amxx_cfg addons/reflex-lobby/core.ini +localinfo amxx_plugins addons/reflex-lobby/plugins.ini +ip 127.0.0.1 +sv_lan 1 -port $port +maxplayers 8 +servercfgfile $configName +map de_dust2"
    $script:logPath=Join-Path $lab 'qconsole.log'
    $script:offset=if(Test-Path $logPath){(Get-Item $logPath).Length}else{0}
    $proc=Start-Process -FilePath $server -ArgumentList $argsLine -WorkingDirectory $lab -WindowStyle Hidden -PassThru
    try{
        for($i=0;$i -lt 40;$i++){
            if($proc.HasExited){throw 'Lobby server exited during startup.'}
            if((Get-NetUDPEndpoint -LocalPort $port -LocalAddress '127.0.0.1' -OwningProcess $proc.Id -ErrorAction SilentlyContinue) -and (Test-Path $logPath)){
                $stream=[IO.File]::Open($logPath,'Open','Read','ReadWrite')
                try{
                    $stream.Position=[Math]::Max([long]$offset,$stream.Length-65536)
                    $reader=New-Object IO.StreamReader($stream)
                    $recent=$reader.ReadToEnd()
                }finally{$stream.Dispose()}
                if($recent -match 'YaPB\s+RUN' -and $recent -match 'ReflexCore Local Lobby[^\r\n]*running'){return $proc}
            }
            Start-Sleep -Milliseconds 200
        }
        throw 'The loopback server and lobby plugins did not become ready.'
    }catch{if(!$proc.HasExited){$proc.Kill()};throw}
}

function Get-LobbyClientPath {
    if(!(Test-Path -LiteralPath $second)){
        $saved=Join-Path $private 'cs16-replay-client.txt'
        if(Test-Path (Join-Path $private 'cs16-lobby-client.txt')){$saved=Join-Path $private 'cs16-lobby-client.txt'}
        if(!(Test-Path -LiteralPath $saved)){throw 'Choose your client using Install keys for my game first.'}
        $second=[IO.File]::ReadAllText($saved).Trim()
    }
    return (Resolve-Path -LiteralPath $second).ProviderPath
}
function Open-LobbyClient {
    $second=Get-LobbyClientPath
    $same=@(Get-Process hl -ErrorAction SilentlyContinue | Where-Object Path -eq $second)
    if($same.Count -gt 1 -or ($same.Count -eq 1 -and ($same[0].MainWindowTitle.StartsWith('[#]') -or
        $second -eq (Join-Path $private 'CS16ReplayClient\hl.exe')))){throw 'The second client is already open.'}
    Set-LobbyKeys $second
    $gameArgs="-game cstrike -windowed -w 800 -h 600 -steam -novid -nosound -condebug +clientport 27165 +exec reflexcore-lobby.cfg +connect 127.0.0.1:$port"
    if(Get-Process hl -ErrorAction SilentlyContinue){
        $launcher=Join-Path $env:ProgramFiles 'Sandboxie-Plus/Start.exe'
        if(!(Test-Path -LiteralPath $launcher)){throw 'This game build needs Sandboxie Plus to run a second copy.'}
        Start-Process $launcher -WorkingDirectory (Split-Path $second) -ArgumentList ('/box:DefaultBox "'+$second+'" '+$gameArgs)
    }else{
        Start-Process $second -WorkingDirectory (Split-Path $second) -ArgumentList $gameArgs
    }
}
if($Probe -or $ProbeClient -or $ProbeRound){
    if($ProbeClient){$expectedSecond=Get-LobbyClientPath}
    $proc=Start-Lobby
    $before=Get-Date
    try{
        if($ProbeClient){
            Open-LobbyClient
            $deadline=[DateTime]::UtcNow.AddSeconds(55)
            do{
                Start-Sleep -Milliseconds 500
                $stream=[IO.File]::Open($logPath,'Open','Read','ReadWrite')
                try{
                    $stream.Position=$offset
                    $reader=New-Object IO.StreamReader($stream)
                    $play=$reader.ReadToEnd()
                }finally{$stream.Dispose()}
                if($play -match 'Lobby menu verified Reflex side 1'){break}
            }while([DateTime]::UtcNow -lt $deadline)
        }
        elseif($ProbeRound){
            $deadline=[DateTime]::UtcNow.AddSeconds(105)
            do{
                Start-Sleep -Seconds 1
                $stream=[IO.File]::Open($logPath,'Open','Read','ReadWrite')
                try{$stream.Position=$offset;$reader=New-Object IO.StreamReader($stream);$play=$reader.ReadToEnd()}finally{$stream.Dispose()}
                if($play -match '(?s)World triggered "Round_Start".*Team "(CT|TERRORIST)" triggered "([^"]+)"'){break}
            }while([DateTime]::UtcNow -lt $deadline)
        }else{Start-Sleep -Seconds 38}
    }finally{
        if($ProbeClient){
            Get-Process hl -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $expectedSecond -and $_.StartTime -ge $before} | ForEach-Object {
                [void]$_.CloseMainWindow()
                if(!$_.WaitForExit(1500)){$_.Kill();$_.WaitForExit()}
            }
        }
        if(!$proc.HasExited){$proc.Kill();$proc.WaitForExit()}
    }
    $stream=[IO.File]::OpenRead($logPath)
    try{$stream.Position=$offset;$reader=New-Object IO.StreamReader($stream);$fresh=$reader.ReadToEnd()}finally{$stream.Dispose()}
    if($ProbeClient){
        if($fresh -notmatch 'Lobby local human connected'){throw 'A second window was launched but server admission was not confirmed.'}
        if($fresh -notmatch 'STEAM_ID_LAN.*joined team "CT"' -or $fresh -notmatch '"ReflexCore<.*joined team "CT"' -or $fresh -notmatch 'lab-opponent.*joined team "TERRORIST"'){throw 'The human, teammate and opponent team assignments were not confirmed.'}
        if($fresh -notmatch 'Lobby H command opened the team menu' -or $fresh -notmatch 'Lobby menu verified Reflex side 1'){throw 'The in-game menu did not confirm the side change.'}
        'Second client admitted, Reflex teammate and in-game side change verified.'
        return
    }
    if($fresh -notmatch 'ReflexCore Local Lobby' -or $fresh -notmatch '"ReflexCore<.*joined team "TERRORIST"' -or $fresh -notmatch 'Probe-CT.*joined team "CT"'){throw 'Lobby or bot join was not confirmed by the server.'}
    if($fresh -notmatch 'Lobby Reflex patrol displacement exceeded 160 units'){throw 'Reflex joined but map movement was not observed.'}
    if($ProbeRound){
        $round=[regex]::Match($fresh,'(?s)World triggered "Round_Start".*?Team "(CT|TERRORIST)" triggered "([^"]+)"')
        if(!$round.Success){throw 'No terminal team result was recorded before the round deadline.'}
        $hits=[regex]::Matches($round.Value,'"ReflexCore<[^"]+" attacked ').Count
        $kills=[regex]::Matches($round.Value,'"ReflexCore<[^"]+" killed ').Count
        "Round result: $($round.Groups[2].Value); Reflex damage events: $hits; kills: $kills"
    }
    'Local teams and independent Reflex movement verified.'
    return
}
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$form=New-Object Windows.Forms.Form
$form.Text='Local team play | ReflexCore'
$form.ClientSize=New-Object Drawing.Size(520,238)
$form.BackColor=[Drawing.ColorTranslator]::FromHtml('#211628')
$form.ForeColor=[Drawing.Color]::White
$form.StartPosition='CenterScreen'
$form.FormBorderStyle='FixedDialog'
$form.MaximizeBox=$false
function Label($text,$y,$height){
    $label=New-Object Windows.Forms.Label
    $label.SetBounds(18,$y,484,$height);$label.Text=$text;$form.Controls.Add($label)
    return $label
}
function Button($text,$x,$y,$width,$action){
    $b=New-Object Windows.Forms.Button
    $b.SetBounds($x,$y,$width,36);$b.Text=$text;$b.FlatStyle='Flat'
    $b.BackColor=[Drawing.ColorTranslator]::FromHtml('#492851')
    $b.Add_Click($action);$form.Controls.Add($b)
    return $b
}
[void](Label 'Dust II | Local team play' 15 23)
[void](Label 'Join T or CT, then press H to add ReflexCore on either side. Keep this window open while playing.' 43 40)
$status=Label 'Ready to start a private server.' 197 36
$address="connect 127.0.0.1:$port"
$script:owned=$null
$timer=New-Object Windows.Forms.Timer
$timer.Interval=250
$script:task=$null
$script:job=$null
$start=Button 'Start local server' 18 90 230 {
    if($owned -and !$owned.HasExited){
        $owned.Kill();$owned.WaitForExit()
        return
    }
    $script:lobbyStart=[DateTime]::UtcNow
    $start.Enabled=$false
    $status.Text='Preparing the server...'
    $script:job=[PowerShell]::Create()
    $body='param($root,$assets,$private,$port)'+[Environment]::NewLine+(Get-Command Start-Lobby).Definition
    [void]$job.AddScript($body).AddArgument($root).AddArgument($assets).AddArgument($private).AddArgument($port)
    $script:task=$job.BeginInvoke()
    $timer.Start()
}
$timer.Add_Tick({
    if($task -and $task.IsCompleted){
        try{
            $items=$job.EndInvoke($task)
            if($items.Count -ne 1 -or $items[0] -isnot [Diagnostics.Process]){throw 'The lobby worker returned no server process.'}
            $script:owned=$items[0]
            $start.Text="Stop local server";$start.Enabled=$true
            $secondBtn.Enabled=$true
            $copy.Enabled=$true
            $status.Text="Server running. Console: $address"
        }catch{$status.Text=$_.Exception.Message;$start.Enabled=$true}
        finally{$script:task=$null;$job.Dispose();$script:job=$null}
    }
    if($owned -and !$owned.HasExited -and [IO.File]::GetLastWriteTimeUtc((Join-Path $root 'data/bridge/global-stop.signal')) -ge $lobbyStart){
        $owned.Kill();$owned.WaitForExit()
    }
    if($owned -and $owned.HasExited){
        $start.Text="Start local server"
        $script:owned=$null;$start.Enabled=$true;$copy.Enabled=$false;$secondBtn.Enabled=$false
        $status.Text='Server stopped. Start a new lobby to play again.'
    }
})
$secondBtn=Button 'Open second game window' 263 90 238 {
    try{
        Open-LobbyClient
        $status.Text='Second client launched. Join a team or choose Spectate.'
    }catch{$status.Text=$_.Exception.Message}
}
$copy=Button 'Copy join command' 18 143 230 {
    [Windows.Forms.Clipboard]::SetText("exec reflexcore-lobby.cfg; $address");$status.Text='Paste in your existing game console.'
}
[void](Button 'Install keys for my game...' 263 143 238 {
    $picker=New-Object Windows.Forms.OpenFileDialog
    $picker.Filter='CS 1.6 client (hl.exe)|hl.exe'
    try{if($picker.ShowDialog($form) -eq 'OK'){Set-LobbyKeys $picker.FileName;[IO.File]::WriteAllText((Join-Path $private 'cs16-lobby-client.txt'),$picker.FileName);$status.Text='Keys installed. Run exec reflexcore-lobby.cfg in an open client.'}}catch{$status.Text=$_.Exception.Message}finally{$picker.Dispose()}
})
$secondBtn.Enabled=$false;$copy.Enabled=$false
if($UiSmoke){
    $form.Add_Shown({$start.PerformClick()})
    $timer.Add_Tick({if(!$task){$form.Close()}})
}
$form.Add_FormClosing({
    if($task){$_.Cancel=$true;$status.Text='Finishing server startup. Close the lobby once it is ready.'}
})
try{[void]$form.ShowDialog()}finally{$timer.Dispose();if($script:owned -and !$script:owned.HasExited){$script:owned.Kill();$script:owned.WaitForExit()};$form.Dispose()}

if($UiSmoke -and !$owned){throw "Lobby smoke failed: $($status.Text)"}
