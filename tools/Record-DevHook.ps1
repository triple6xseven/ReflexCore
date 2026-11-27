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
    $kind = switch ($event.hook_event_name) {
        'PreToolUse'  { if ($event.tool_name -in 'apply_patch','Edit','Write') { 'mutation-started' } }
        'PostToolUse' { if ($event.tool_name -in 'apply_patch','Edit','Write') { 'mutation-returned' } }
        'PreCompact'  { 'compaction' }
    }
    if (!$kind) { return }
    Push-Location -LiteralPath $root
    try {
        & (Join-Path $root 'target/release/reflexcore.exe') dev-context record $event.session_id $Component $kind 2>$null | Out-Null
    } finally { Pop-Location }
} catch { }
exit 0
