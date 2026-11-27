#Requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('reflex-resume-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
Push-Location $root
function RunObserver([string[]]$Arguments){(& ./tools/Invoke-DevObserver.ps1 -ObserverArgs $Arguments)|ConvertFrom-Json}
function Fire($event,$tool,$inputData){
    @{cwd=$root;session_id='original';hook_event_name=$event;tool_name=$tool;tool_input=$inputData}|ConvertTo-Json -Compress | powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/Record-DevHook.ps1 -Worktree $root
}
function Resume {
    $OutputEncoding=New-Object Text.UTF8Encoding($false)
    $messages=@('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}','{"jsonrpc":"2.0","method":"notifications/initialized"}','{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_development_context","arguments":{}}}')
    $lines=$messages|powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/ReflexCore-Mcp.ps1 -DeveloperTools
    if($lines.Count -ne 2){throw 'Unexpected MCP transport'}
    ($lines[-1]|ConvertFrom-Json).result
}
try {
    git init -q
    foreach($dir in 'src','tools','data/settings','.git/reflex-observer'){[void][IO.Directory]::CreateDirectory((Join-Path $root $dir))}
    foreach($name in 'Record-DevHook.ps1','Invoke-DevObserver.ps1','ReflexCore-Mcp.ps1','ReflexCore-Mcp.cs','ReflexCore-Queue.cs','ReflexCore-McpLab.cs'){
        Copy-Item -LiteralPath (Join-Path $repo "tools/$name") -Destination tools
    }
    Set-Content src/main.rs 'fn main() {}'
    git add src/main.rs
    git -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm seed
    $exe=Join-Path $repo 'target/release/reflex-observer.exe'
    $hash=(Get-FileHash $exe).Hash
    Copy-Item -LiteralPath $exe -Destination ".git/reflex-observer/$hash.exe"
    [IO.File]::WriteAllText((Join-Path $root '.git/reflex-observer/active-v2'),$hash)
    $null=RunObserver @('declare','original','bridge','Test interrupted recovery','Inspect the changed entry point')
    Fire PreToolUse apply_patch @{}
    Add-Content src/main.rs '// fixture mutation'
    Fire PostToolUse apply_patch @{}
    Fire PreToolUse Bash @{command='cargo test --locked'}
    if(!(Resume).isError){throw 'Disabled integration exposed recovery'}
    [IO.File]::WriteAllText((Join-Path $root 'data/settings/mcp.enabled'),'')
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $packet=(Resume).structuredContent.packet
    $timer.Stop()
    if($packet.declared.next -ne 'Inspect the changed entry point' -or $packet.changed_inputs_since_declaration -notcontains 'src/main.rs' -or $packet.recent_events_newest_first[0] -ne 'test-started' -or $packet.effect -ne 'unknown'){throw 'Missing interrupted state'}
    $bytes=[Text.Encoding]::UTF8.GetByteCount(($packet|ConvertTo-Json -Depth 5 -Compress))
    if($bytes -gt 4096){throw 'Recovery exceeds budget'}
    "PASS: cold MCP recovery in $($timer.ElapsedMilliseconds) ms, $bytes UTF-8 packet bytes, no development target present."
    if($packet.release_build -ne 'unknown'){throw 'Unbuilt target received release evidence'}
    $null=RunObserver @('record','original','bridge','build-started','call-a')
    $null=RunObserver @('record','original','bridge','build-started','call-b')
    $null=RunObserver @('record','original','bridge','build-returned','call-b')
    $null=RunObserver @('record','original','bridge','build-returned','call-b')
    $active=(Resume).structuredContent.packet
    if($active.unresolved_operation_classes -notcontains 'build' -or @($active.recent_events_newest_first|Where-Object {$_ -eq 'build-returned'}).Count -ne 1){throw 'Concurrent or duplicate tool delivery misclassified'}
    Fire PreCompact '' @{}
    Fire Interrupt '' @{}
    Set-Content src/AGENTS.md 'Synthetic nested instruction'
    $after=(Resume).structuredContent.packet
    if($after.changed_inputs_since_declaration -notcontains 'src/AGENTS.md' -or $after.unresolved_operation_classes -notcontains 'test' -or $after.last_observed_return -ne 'build-returned'){throw 'Interruption lost the pending operation or changed instructions'}
    $null=RunObserver @('record','original','bridge','usage-limit')
    $null=RunObserver @('declare','another','bridge','Concurrent task','Keep separate')
    if((Resume).structuredContent.packet.checkpoint -ne 'ambiguous'){throw 'Ambiguous task selected'}
    [IO.File]::WriteAllText((Join-Path $root '.git/reflex-observer/active-v2'),'invalid')
    if(!(Resume).isError){throw 'Unknown observer executed'}
} finally {
    Pop-Location
    $owned=[IO.Path]::GetFullPath($root)
    if([IO.Path]::GetDirectoryName($owned) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and [IO.Path]::GetFileName($owned) -match '^reflex-resume-[a-f0-9]{32}$'){Remove-Item -LiteralPath $owned -Recurse -Force}
}
