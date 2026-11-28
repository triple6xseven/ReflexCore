#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Executable)
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path -LiteralPath $Executable).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('reflex-context-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $root 'repo'
$other = Join-Path $root 'other'
function GitOk { & git @args | Out-Null; if ($LASTEXITCODE) { throw 'Git fixture failed' } }
function Context { $raw = & $exe dev-context @args; if ($LASTEXITCODE) { throw 'Context failed' }; $raw | ConvertFrom-Json }
[void][IO.Directory]::CreateDirectory($repo)
Push-Location $repo
try {
    GitOk init -q
    Set-Content AGENTS.md initial
    GitOk add AGENTS.md
    GitOk -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial
    GitOk worktree add --detach $other HEAD
    $a = Context record alpha bridge mutation-started
    if ($a.checkpoint -ne 'matching' -or $a.effect -ne 'unknown') { throw 'Interrupted operation misclassified' }
    Set-Content AGENTS.md changed
    if ((Context status alpha bridge).checkpoint -ne 'changed') { throw 'Same-HEAD edit missed' }
    GitOk add AGENTS.md
    $b = Context record alpha bridge mutation-returned
    New-Item -ItemType Directory tools | Out-Null
    Set-Content tools/ReflexCore-Mcp.cs independent
    if ((Context status alpha bridge).revision -ne $b.revision) { throw 'Unrelated scope invalidated' }
    if ((Context status beta bridge).checkpoint -ne 'absent') { throw 'Foreign session reused' }
    Push-Location $other
    try {
        Set-Content AGENTS.md alternate
        $c = Context status alpha bridge
        if ($c.tree -eq $a.tree -or $c.checkpoint -ne 'absent') { throw 'Foreign worktree reused' }
    } finally { Pop-Location }
    Write-Output 'PASS: interrupted operation, dirty and indexed input, scope, session and worktree isolation.'
} finally {
    Pop-Location
    $owned = [IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($owned) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and [IO.Path]::GetFileName($owned) -match '^reflex-context-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $owned -Recurse -Force
    }
}
