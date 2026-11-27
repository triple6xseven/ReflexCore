#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Worktree,[ValidateSet('bridge','mcp')][string]$Component='bridge')
# Codex hook payloads can contain private tool arguments. Retain only the event and session ID.
$ErrorActionPreference = 'Stop'
try {
    $chars = New-Object char[] 32769
    $size = [Console]::In.ReadBlock($chars,0,$chars.Length)
    if ($size -eq $chars.Length) { return }
    $event = (-join $chars[0..($size-1)]) | ConvertFrom-Json
    $root = [IO.Path]::GetFullPath($Worktree)
    if (!$event.cwd -or [IO.Path]::GetFullPath($event.cwd) -ne $root) { return }
    if ($event.session_id -notmatch '^[A-Za-z0-9-]{1,64}$') { return }
    $operation=$null
    if ($event.tool_name -in 'apply_patch','Edit','Write') { $operation='mutation' }
    if ($event.tool_name -in 'Bash','exec_command','shell_command') {
        $command=$event.tool_input.command
        if (!$command) { $command=$event.tool_input.cmd }
        if ($command -match '^\s*cargo\s+(build|test)\b' -and $command -notmatch '[;&|<>\r\n]') { $operation=($command.Trim() -split '\s+')[1] }
    }
    $kind = switch ($event.hook_event_name) {
        'PreToolUse'  { if ($operation) { "$operation-started" } }
        'PostToolUse' { if ($operation) { "$operation-returned" } }
        'PreCompact'  { 'compaction' }
        'Stop' { 'turn-ended' }
        'Interrupt' { 'interrupt' }
    }
    if (!$kind) { return }
    Push-Location -LiteralPath $root
    try {
        & (Join-Path $root 'tools/Invoke-DevObserver.ps1') -ObserverArgs @('record',$event.session_id,$Component,$kind) 2>$null | Out-Null
    } finally { Pop-Location }
} catch { }
exit 0
