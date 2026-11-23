$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$icon = Join-Path $root 'assets\reflexcore.ico'
$source = Join-Path $PSScriptRoot 'ReflexCore-Launcher.cs'
$launcher = Join-Path $root 'ReflexCore.exe'
$staged = Join-Path $root ('ReflexCore-launcher-' + [guid]::NewGuid().ToString('N') + '.exe')
& $compiler /nologo /target:winexe /reference:System.Windows.Forms.dll "/win32icon:$icon" "/out:$staged" $source
if ($LASTEXITCODE -ne 0) { throw 'ReflexCore launcher compilation failed.' }
if ([IO.File]::Exists($launcher)) {
    [IO.File]::Replace($staged,$launcher,$launcher+'.previous')
} else {
    [IO.File]::Move($staged,$launcher)
}
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$path = Join-Path $desktop 'ReflexCore.lnk'
if (Test-Path -LiteralPath $path) {
    $backup = Join-Path $env:LOCALAPPDATA ('ReflexCore\backups\launcher-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($backup)
    Copy-Item -LiteralPath $path -Destination $backup
}
$link = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
$link.TargetPath = $launcher
$link.Arguments = ''
$link.WorkingDirectory = $root
$link.IconLocation = $launcher + ',0'
$link.WindowStyle = 1
$link.Save()
Write-Output 'ReflexCore desktop shortcut installed.'
