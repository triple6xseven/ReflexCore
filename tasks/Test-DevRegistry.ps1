#Requires -Version 5.1
# Run on a disposable CI/development checkout with MCP disabled.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $root
$marker = Join-Path $root 'data/settings/mcp.enabled'
$owned = $false
$probe = Join-Path $root ('src/dev-check-' + [guid]::NewGuid().ToString('N') + '.rs')
function Calls([switch]$Developer) {
    $messages = @(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}',
        '{"jsonrpc":"2.0","method":"notifications/initialized"}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_validation_evidence","arguments":{}}}',
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_skills","arguments":{}}}'
    )
    $flags = @()
    if ($Developer) { $flags += '-DeveloperTools' }
    $lines = $messages | powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/ReflexCore-Mcp.ps1 @flags
    if ($LASTEXITCODE -or $lines.Count -ne 4) { throw 'Unexpected MCP response sequence' }
    $lines | ForEach-Object { $_ | ConvertFrom-Json }
}
try {
    [void][IO.Directory]::CreateDirectory((Split-Path $marker))
    $handle = [IO.File]::Open($marker,'CreateNew','Write','None')
    $owned = $true
    $handle.Dispose()
    $record = .\tools\Measure-DevBuild.ps1 -Action Build | ConvertFrom-Json
    if ($record.build -ne 'matching') { throw 'Build evidence unavailable' }
    $default = @(Calls)
    if ($default[1].result.tools.name -contains 'get_validation_evidence') { throw 'Unexpected developer schema' }
    if (!$default[2].result.isError) { throw 'Disabled developer tool callable' }
    if (!$default[3].result.structuredContent.skills) { throw ('Matched registry missing: ' + $default[3].result.content[0].text) }
    [IO.File]::WriteAllText($probe,'// Owned stale-source fixture.')
    $changed = @(Calls -Developer)
    if ($changed[1].result.tools.name -notcontains 'get_validation_evidence' -or $changed[2].result.structuredContent.build -ne 'stale' -or !$changed[3].result.isError -or $changed[3].result.content[0].text -notlike 'Build stale.*') { throw 'Stale registry result accepted' }
    'PASS: default schema, matched release, optional evidence and stale registry rejection.'
} finally {
    if ([IO.File]::Exists($probe)) { [IO.File]::Delete($probe) }
    if ($owned) { [IO.File]::Delete($marker) }
    Pop-Location
}
