#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Preview','BenchmarkGame','BenchmarkFixture','SelfTest','Stop')][string]$Action = 'Preview',
    [ValidateRange(0,2147483647)][int]$GamePid,
    [ValidateRange(1,65535)][int]$GamePort = 27015,
    [ValidateRange(256,640)][int]$Width = 480,
    [ValidateRange(10,400)][int]$Samples = 100,
    [ValidateSet('Direct','CpuScale')][string]$Capture = 'Direct'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if ($Action -eq 'Stop') {
    try {
        $signal = [Threading.EventWaitHandle]::OpenExisting('Local\ReflexVisionStop')
    } catch [Threading.WaitHandleCannotBeOpenedException] {
        Write-Output 'ReflexVision is stopped.'
        return
    }
    try { [void]$signal.Set(); Write-Output 'ReflexVision stop requested.' }
    finally { $signal.Dispose() }
    return
}

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Start ReflexVision from Windows PowerShell with -STA.'
}

$fixture = $Action -eq 'BenchmarkFixture'
$window = 0L
$lobbyLease = $null
if ($Action -in 'Preview','BenchmarkGame') {
    $games = @(Get-Process -Name hl,cstrike -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne [IntPtr]::Zero -and ($GamePid -eq 0 -or $_.Id -eq $GamePid)
    })
    $settingsPath = Join-Path $root 'data/settings/cs16-practice.json'
    $eligible = @()
    if (Test-Path -LiteralPath $settingsPath) {
        try { $configured = (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).server_exe }
        catch { $configured = $null }
        $serverProcess = @(Get-Process hlds -ErrorAction SilentlyContinue | Where-Object Path -eq $configured)
        if ($serverProcess.Count -eq 1) {
            $folder = Join-Path (Split-Path $configured) 'cstrike/addons/reflex-lobby'
            foreach ($candidate in $games) {
                foreach ($endpoint in @(Get-NetUDPEndpoint -OwningProcess $candidate.Id -ErrorAction SilentlyContinue)) {
                    $lease = Get-Item -LiteralPath (Join-Path $folder ("client-{0}.live" -f $endpoint.LocalPort)) -ErrorAction SilentlyContinue
                    if ($lease -and $lease.LastWriteTimeUtc -ge $serverProcess[0].StartTime.ToUniversalTime() -and
                        $lease.LastWriteTimeUtc -ge [DateTime]::UtcNow.AddSeconds(-3)) {
                        $eligible += [pscustomobject]@{Game=$candidate;Lease=$lease.FullName}
                        break
                    }
                }
            }
        }
    }
    if ($eligible.Count) {
        $selected = $eligible[0]
        if ($eligible.Count -gt 1) {
            Add-Type -AssemblyName System.Windows.Forms
            $picker = New-Object Windows.Forms.Form
            $picker.Text='Choose the lobby window to preview'
            $list=New-Object Windows.Forms.ListBox
            $list.Dock='Fill'
            foreach ($entry in $eligible) { [void]$list.Items.Add(('{0} (PID {1})' -f $entry.Game.MainWindowTitle,$entry.Game.Id)) }
            $list.SelectedIndex=0
            $open=New-Object Windows.Forms.Button
            $open.Text='Show preview'; $open.Dock='Bottom'; $open.DialogResult='OK'
            $picker.Controls.Add($list); $picker.Controls.Add($open); $picker.AcceptButton=$open
            try { if ($picker.ShowDialog() -ne 'OK') { return }; $selected=$eligible[$list.SelectedIndex] } finally { $picker.Dispose() }
        }
        $games=@($selected.Game)
        $lobbyLease=$selected.Lease
    }
    if ($games.Count -ne 1) { throw 'Open a windowed local Counter-Strike 1.6 match, or select its process by -GamePid.' }
    $game = $games[0]
    try { $GamePid = $game.Id; $window = $game.MainWindowHandle.ToInt64() }
    finally { $game.Dispose() }
    if (!$lobbyLease) {
        $engine = Join-Path $root 'target/release/reflexcore.exe'
        if (!(Test-Path -LiteralPath $engine -PathType Leaf)) { throw 'Build ReflexCore with cargo build --release --locked first.' }
        $probe = & $engine cs16 probe --port $GamePort --pid $GamePid
        if ($LASTEXITCODE -ne 0) { throw 'A CS 1.6 listen server must be running in the selected game process.' }
        $server = $probe | ConvertFrom-Json
        if (($server.players - $server.bots) -ne 1) { throw 'Open a private local match with one human player.' }
    }
}

Add-Type -AssemblyName System.Windows.Forms,System.Drawing,System.Web.Extensions
if (!('ReflexCore.Vision.Preview' -as [type])) {
    $paths = @('ReflexVision-Capture.cs','ReflexVision-Detector.cs','ReflexVision-Preview.cs') |
        ForEach-Object { Join-Path $PSScriptRoot $_ }
    $parameters = New-Object System.CodeDom.Compiler.CompilerParameters
    $parameters.CompilerOptions = '/unsafe /optimize+'
    $parameters.ReferencedAssemblies.AddRange([string[]]@(
        'System.dll','System.Core.dll','System.Windows.Forms.dll','System.Drawing.dll','System.Web.Extensions.dll'))
    Add-Type -Path $paths -CompilerParameters $parameters
}
if ($Action -eq 'SelfTest') {
    [ReflexCore.Vision.Preview]::SelfTest()
    return
}
[Windows.Forms.Application]::EnableVisualStyles()
$frames = if ($Action -eq 'Preview') { 0 } else { $Samples }
$result = [ReflexCore.Vision.Preview]::Run($root,$GamePid,$window,$Width,($Capture -eq 'CpuScale'),$frames,$fixture,[string]$lobbyLease)
if ($frames) {
    $result
    if (!($result | ConvertFrom-Json).completed) { throw 'Benchmark ended before collecting the requested frames.' }
}
