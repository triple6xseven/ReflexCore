param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-zA-Z0-9_-]{1,70}$')][string]$Task,
    [switch]$Run
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$script = Join-Path (Join-Path $root 'tasks') ($Task + '.ps1')
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "Task not found in tasks/: $Task" }
if ((Get-Item -LiteralPath $script).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Symlink task not allowed' }
$pending = Join-Path $root 'data\bridge\pending'
New-Item -ItemType Directory -Path $pending -Force | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')
$id = [guid]::NewGuid().ToString('N')
$dst = Join-Path $pending ($stamp + '-' + $id + '.job')
$tmp = $dst + '.tmp'
$mode = if ($Run) { 'RUN' } else { 'REVIEW' }
[IO.File]::WriteAllText($tmp, ($mode + "`n" + $Task + '.ps1'), (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmp -Destination $dst -ErrorAction Stop
Write-Host "[ReflexCore] Job queued: $Task (mode=$mode)"
if ($Run) {
    Write-Host '[ReflexCore] Tray will start it automatically if already running.'
} else {
    Write-Host '[ReflexCore] Right-click the tray icon -> Run next pending job.'
}
Write-Host '[ReflexCore] Status: .\tools\ReflexCore-Control.ps1 -Action status'