#Requires -Version 5.1
param([ValidateSet('Build','Check')][string]$Action='Check')
$ErrorActionPreference='Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $root
try {
    $private = (& git rev-parse --absolute-git-dir)
    if ($LASTEXITCODE) { throw 'Worktree unavailable' }
    $stamp = Join-Path $private 'reflex-dev-build-v1.json'
    $binary = Join-Path $root 'target/release/reflexcore.exe'
    function HashText([string]$value) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($value)))).Replace('-','') }
        finally { $sha.Dispose() }
    }
    function Revision {
        $paths = @(& git -c core.quotepath=false ls-files --cached --others --exclude-standard -- src Cargo.lock Cargo.toml build.rs .cargo)
        if ($LASTEXITCODE -or $paths.Count -gt 4096) { throw 'Uncertain source inventory' }
        $entries = foreach ($path in ($paths | Sort-Object -Unique)) {
            if ($path -notmatch '^[a-zA-Z0-9._/ -]+$') { throw 'Unsupported build input name' }
            if (Test-Path -LiteralPath $path -PathType Leaf) { $path + '=' + (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash }
            else { $path + '=missing' }
        }
        HashText ($entries -join "`n")
    }
    $tree = HashText $private
    $head = & git rev-parse HEAD
    $compiler = (& rustc -vV) -join "`n"
    if ($LASTEXITCODE) { throw 'Compiler identity unavailable' }
    $before = Revision
    if ($Action -eq 'Build') {
        if ($env:CARGO_TARGET_DIR -or $env:RUSTFLAGS -or $env:CARGO_ENCODED_RUSTFLAGS -or $env:CARGO_BUILD_TARGET) { throw 'Use the default local release configuration' }
        & cargo build --release --locked --bin reflexcore
        if ($LASTEXITCODE -or $before -ne (Revision) -or $head -ne (& git rev-parse HEAD)) { throw 'Build provenance uncertain' }
        $record = [ordered]@{v=1;tree=$tree;source=$before;head=$head;compiler=$compiler;profile='release';binary=(Get-FileHash $binary).Hash}
        $tmp = $stamp + '.' + [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($tmp,($record | ConvertTo-Json -Compress))
        if ([IO.File]::Exists($stamp)) { [IO.File]::Replace($tmp,$stamp,($stamp + '.previous')) } else { [IO.File]::Move($tmp,$stamp) }
    }
    $state='unknown'
    if ((Test-Path -LiteralPath $stamp) -and (Test-Path -LiteralPath $binary)) {
        $r = Get-Content -Raw -LiteralPath $stamp | ConvertFrom-Json
        $state='stale'
        if ($r.v -eq 1 -and $r.tree -eq $tree -and $r.source -eq $before -and $r.head -eq $head -and $r.compiler -eq $compiler -and $r.binary -eq (Get-FileHash $binary).Hash -and (Revision) -eq $before) { $state='matching' }
    }
    [pscustomobject]@{schema=1;profile='release';build=$state} | ConvertTo-Json -Compress
} finally { Pop-Location }
