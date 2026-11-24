#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][ValidatePattern('^de_[a-z0-9_]{1,29}$')][string]$Map,
    [ValidateRange(1024,65534)][int]$Port=27125
)
$ErrorActionPreference='Stop'
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
    $output=& $exe cs16 practice $mail auto --allow-offline --stationary-opponent
    $result=$LASTEXITCODE
    $output | Write-Output
    $report=($output -join [Environment]::NewLine)|ConvertFrom-Json
    if($result -ne 0 -or !$report.verified_plant -or $report.map -cne $Map){throw 'Automatic drill did not verify a plant'}
    $file=[IO.File]::Open($console,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{
        if($file.Length -lt $offset -or $file.Length-$offset -gt 512KB){throw 'Invalid fresh game log range'}
        $file.Position=$offset
        $reader=[IO.StreamReader]::new($file)
        try{[IO.File]::WriteAllText($log,$reader.ReadToEnd())}finally{$reader.Dispose()}
    }finally{$file.Dispose()}
    $evidence=& $exe cs16 benchmark $log --player $report.engine_subject_id
    if($LASTEXITCODE -ne 0){throw 'Independent game log parser failed'}
    $evidence | Write-Output
    $parsed=($evidence -join [Environment]::NewLine)|ConvertFrom-Json
    if($parsed.verified_plants -lt 1){throw 'Fresh game log did not verify a plant by the owned actor'}
}finally{
    if($null -ne $process){
        if(!$process.HasExited){$process.Kill();$process.WaitForExit()}
        $process.Dispose()
    }
    foreach($key in $environment.Keys){[Environment]::SetEnvironmentVariable($key,$environment[$key],'Process')}
    [IO.File]::Delete($log)
    Pop-Location
}
