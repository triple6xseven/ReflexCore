#Requires -Version 5.1
param([ValidateSet('Inspect','Install','Remove')][string]$Action='Inspect')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dir=Join-Path $root '.codex'
$file=Join-Path $dir 'hooks.json'
$script=Join-Path $PSScriptRoot 'Record-DevHook.ps1'
$command='powershell.exe -NoProfile -NonInteractive -File "'+$script+'" -Worktree "'+$root+'"'
$handler=[ordered]@{type='command';command=$command;timeout=8}
$config=[ordered]@{}
foreach($event in 'PreToolUse','PostToolUse','PreCompact','Interrupt','Stop'){
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
if(Test-Path -LiteralPath $file){throw 'Existing hook configuration. Inspect and merge the proposed entries manually.'}
& (Join-Path $PSScriptRoot 'Invoke-DevObserver.ps1') -Action Install
[void][IO.Directory]::CreateDirectory($dir)
$stream=[IO.File]::Open($file,'CreateNew','Write','None')
try{$bytes=[Text.Encoding]::UTF8.GetBytes($content);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
'Review project hooks in Codex before use.'
