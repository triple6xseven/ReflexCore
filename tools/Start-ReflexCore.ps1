# Documented entry point: launch Control Center, which ensures a single tray.
param([ValidateSet('ControlCenter','SharedControl','TrayOnly','Diagnostics')][string]$Mode='ControlCenter')
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
if ($Mode -in 'TrayOnly','SharedControl') { & (Join-Path $root 'tools\Ensure-ReflexCore-Tray.ps1') }
if ($Mode -eq 'TrayOnly') {return}
$target=if($Mode -eq 'SharedControl'){'ReflexCore-SharedControl.ps1'}else{'ReflexCore-ControlCenter.ps1'}
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script=Join-Path $root ('tools\'+$target)
$initial=if($Mode -eq 'Diagnostics'){'Diagnostics'}else{'Agent'}
$arg='-NoProfile -ExecutionPolicy Bypass -File "'+$script+'"'
if($target -eq 'ReflexCore-ControlCenter.ps1'){$arg+=' -InitialTab '+$initial}
Start-Process -FilePath $ps -ArgumentList $arg -WorkingDirectory $root -WindowStyle Hidden | Out-Null
