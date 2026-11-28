#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$checker = (Resolve-Path (Join-Path $PSScriptRoot '../tools/Measure-DevBuild.ps1')).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('reflex-provenance-' + [guid]::NewGuid().ToString('N'))
$a = Join-Path $root 'a'
$b = Join-Path $root 'b'
function GitOk { & git @args | Out-Null; if ($LASTEXITCODE) { throw 'Git fixture failed' } }
function State($action) { (& ./tools/Measure-DevBuild.ps1 -Action $action | ConvertFrom-Json).build }
[void][IO.Directory]::CreateDirectory($a)
Push-Location $a
try {
    GitOk init -q
    [void][IO.Directory]::CreateDirectory((Join-Path $a 'tools'))
    [void][IO.Directory]::CreateDirectory((Join-Path $a 'src'))
    Copy-Item -LiteralPath $checker -Destination tools
    Set-Content Cargo.toml "[package]`nname='reflexcore'`nversion='0.0.1'`nedition='2021'"
    Set-Content src/main.rs 'fn main() {}'
    & cargo generate-lockfile --offline
    if ($LASTEXITCODE) { throw 'Fixture lockfile unavailable' }
    GitOk add .
    GitOk -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm baseline
    GitOk worktree add --detach $b HEAD
    Set-Content src/main.rs 'fn main() { println!("A"); }'
    if ((State Build) -ne 'matching') { throw 'Producer evidence missing' }
    $stamp = Join-Path (& git rev-parse --absolute-git-dir) 'reflex-dev-build-v1.json'
    Push-Location $b
    try {
        Set-Content src/main.rs 'fn main() { println!("B"); }'
        $release = [IO.Directory]::CreateDirectory((Join-Path $b 'target/release'))
        Copy-Item -LiteralPath (Join-Path $a 'target/release/reflexcore.exe') -Destination $release.FullName
        if ((State Check) -ne 'unknown') { throw 'Unbuilt worktree received evidence' }
        Copy-Item -LiteralPath $stamp -Destination (Join-Path (& git rev-parse --absolute-git-dir) 'reflex-dev-build-v1.json')
        if ((State Check) -ne 'stale') { throw 'Foreign dirty build accepted' }
        Copy-Item -LiteralPath (Join-Path $a 'src/main.rs') -Destination src/main.rs -Force
        if ((State Check) -ne 'stale') { throw 'Foreign worktree identity accepted' }
    } finally { Pop-Location }
    if ((State Check) -ne 'matching') { throw 'Original evidence damaged' }
    'PASS: only the producing worktree accepted its binary and stamp.'
} finally {
    Pop-Location
    $owned = [IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($owned) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and [IO.Path]::GetFileName($owned) -match '^reflex-provenance-[a-f0-9]{32}$') { Remove-Item -LiteralPath $owned -Recurse -Force }
}
