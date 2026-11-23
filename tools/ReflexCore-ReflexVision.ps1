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
if ($Action -in 'Preview','BenchmarkGame') {
    $games = @(Get-Process -Name hl,cstrike -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne [IntPtr]::Zero -and ($GamePid -eq 0 -or $_.Id -eq $GamePid)
    })
    if ($games.Count -ne 1) { throw 'Open a windowed local Counter-Strike 1.6 match, or select its process by -GamePid.' }
    $game = $games[0]
    try { $GamePid = $game.Id; $window = $game.MainWindowHandle.ToInt64() }
    finally { $game.Dispose() }
    $engine = Join-Path $root 'target/release/reflexcore.exe'
    if (!(Test-Path -LiteralPath $engine -PathType Leaf)) { throw 'Build ReflexCore with cargo build --release --locked first.' }
    $probe = & $engine cs16 probe --port $GamePort --pid $GamePid
    if ($LASTEXITCODE -ne 0) { throw 'A CS 1.6 listen server must be running in the selected game process.' }
    $server = $probe | ConvertFrom-Json
    if (($server.players - $server.bots) -ne 1) { throw 'Open a private local match with one human player.' }
}

Add-Type -AssemblyName System.Windows.Forms,System.Drawing,System.Web.Extensions
if (!('ReflexCore.Vision.Preview' -as [type])) {
    $paths = @('ReflexVision-Capture.cs','ReflexVision-Detector.cs','ReflexVision-Preview.cs') |
        ForEach-Object { Join-Path $PSScriptRoot $_ }
    $parameters = New-Object System.CodeDom.Compiler.CompilerParameters
    $parameters.CompilerOptions = '/unsafe'
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
$result = [ReflexCore.Vision.Preview]::Run($root,$GamePid,$window,$Width,($Capture -eq 'CpuScale'),$frames,$fixture)
if ($frames) {
    $result
    if (!($result | ConvertFrom-Json).completed) { throw 'Benchmark ended before collecting the requested frames.' }
}
