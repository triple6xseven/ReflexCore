#Requires -Version 5.1
param([ValidateSet('Inspect','Install','Remove')][string]$Action='Inspect',[switch]$Diagnostic,[string]$ReviewWorktree)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($ReviewWorktree) {
    if($Action -ne 'Inspect'){throw 'An alternate worktree supports review only'}
    $root=(Resolve-Path -LiteralPath $ReviewWorktree).Path
}
$dir=Join-Path $root '.codex'
$file=Join-Path $dir 'hooks.json'
$script=Join-Path (Join-Path $root 'tools') 'Record-DevHook.ps1'
$command='powershell.exe -NoProfile -NonInteractive -File "'+$script+'" -Worktree "'+$root+'"'

# Hook review pins the direct executable path. An observer upgrade requires fresh review.
if ($Action -eq 'Install') {
    if(Test-Path -LiteralPath $file){throw 'Existing hook configuration. Inspect and merge the proposed entries manually.'}
    & (Join-Path $PSScriptRoot 'Invoke-DevObserver.ps1') -Action Install
}
Push-Location $root
try { $private=& git rev-parse --absolute-git-dir; if($LASTEXITCODE){throw 'Worktree unavailable'} } finally {Pop-Location}
$install=Join-Path $private 'reflex-observer'
$hash=[IO.File]::ReadAllText((Join-Path $install 'active-v2'))
if($hash -cnotmatch '^[A-F0-9]{64}$'){throw 'Invalid observer pointer'}
$observer=Join-Path $install ($hash+'.exe')
if((Get-FileHash -LiteralPath $observer).Hash -cne $hash -or (& $observer hook-protocol) -cne 'reflex.hook.1'){throw 'Install the current observer before reviewing native hooks'}
if(($root+$observer) -match '[%!"\r\n]'){throw 'Unsupported command path'}
$mode=if($Diagnostic){'diagnose'}else{'capture'}
$native='cmd.exe /d /v:off /s /c ""'+$observer+'" '+$mode+' "'+$root+'""'
$config=[ordered]@{}
foreach($event in 'PreToolUse','PostToolUse','PreCompact','Interrupt','Stop'){
    $timeout = if ($event -eq 'Interrupt') { 3 } else { 8 }
    $entry=if($Diagnostic -or $event -eq 'Interrupt'){$native}else{$command}
    $handler=[ordered]@{type='command';command=$entry;timeout=$timeout}
    $item=[ordered]@{hooks=@($handler)}
    if($event -like '*ToolUse'){$item.matcher='^(apply_patch|Edit|Write|Bash)$'}
    $config[$event]=@($item)
}
$content=@{hooks=$config}|ConvertTo-Json -Depth 7
if($Action -eq 'Inspect'){return $content}
if($Action -eq 'Remove'){
    if((Test-Path -LiteralPath $file) -and [IO.File]::ReadAllText($file) -ceq $content){[IO.File]::Delete($file);return}
    throw 'Unrecognized configuration. Keep existing hooks and review manually.'
}
[void][IO.Directory]::CreateDirectory($dir)
$stream=[IO.File]::Open($file,'CreateNew','Write','None')
try{$bytes=[Text.Encoding]::UTF8.GetBytes($content);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
'Review project hooks in Codex before use.'
