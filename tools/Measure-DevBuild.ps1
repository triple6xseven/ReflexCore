#Requires -Version 5.1
param([ValidateSet('Build','Check','VerifyRecovery')][string]$Action='Check',[string]$Worktree)
$ErrorActionPreference='Stop'
$root = if($Worktree){(Resolve-Path -LiteralPath $Worktree).Path}else{(Resolve-Path (Join-Path $PSScriptRoot '..')).Path}
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
        if($ordinal){
            $ordered=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
            foreach($candidate in $paths){[void]$ordered.Add([string]$candidate)}
            $paths=$ordered
        }else{
            $paths=@($paths|Sort-Object -Unique)
        }
        $entries = foreach ($path in $paths) {
            if ($path -notmatch '^[a-zA-Z0-9._/ -]+$') { throw 'Unsupported build input name' }
            if (Test-Path -LiteralPath $path -PathType Leaf) { $path + '=' + (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash }
            else { $path + '=missing' }
        }
        HashText ($entries -join "`n")
    }
    $tree = HashText $private
    if((Resolve-Path -LiteralPath (& git rev-parse --show-toplevel)).Path -ne $root){throw 'Expected exact worktree root'}
    $head = & git rev-parse HEAD
    if($Action -eq 'Check'){
        $early='unknown'
        if([IO.File]::Exists($stamp) -and [IO.File]::Exists($binary)){
            $saved=Get-Content -Raw -LiteralPath $stamp|ConvertFrom-Json
            if($saved.v -eq 1 -and $saved.tree -eq $tree -and $saved.head -eq $head){$early=$null}
            else{$early='stale'}
        }
        if($early){
            $test=if([IO.File]::Exists((Join-Path $private 'reflex-dev-recovery-test-v1.json')) -and $early -eq 'stale'){'stale'}else{'unknown'}
            [pscustomobject]@{schema=1;profile='release';build=$early;worktree_recovery_test=$test}|ConvertTo-Json -Compress
            return
        }
    }
    # Legacy stamps used the producing shell's collation. Keep them readable.
    $ordinal=$Action -eq 'Build'
    if(!$ordinal -and [IO.File]::Exists($stamp)){
        $prior=Get-Content -Raw -LiteralPath $stamp|ConvertFrom-Json
        $ordinal=$prior.order -ceq 'ordinal-v1'
    }
    $compiler = (& rustc -vV) -join "`n"
    if ($LASTEXITCODE) { throw 'Compiler identity unavailable' }
    $before = Revision
    if ($Action -eq 'Build') {
        if ($env:CARGO_TARGET_DIR -or $env:RUSTFLAGS -or $env:CARGO_ENCODED_RUSTFLAGS -or $env:CARGO_BUILD_TARGET) { throw 'Use the default local release configuration' }
        & cargo build --release --locked --bin reflexcore
        if ($LASTEXITCODE -or $before -ne (Revision) -or $head -ne (& git rev-parse HEAD)) { throw 'Build provenance uncertain' }
        $record = [ordered]@{v=1;order='ordinal-v1';tree=$tree;source=$before;head=$head;compiler=$compiler;profile='release';binary=(Get-FileHash $binary).Hash}
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
    $receipt = Join-Path $private 'reflex-dev-recovery-test-v1.json'
    $verifier = Join-Path $root 'tasks/Test-DevContext.ps1'
    function SaveReceipt($record) {
        $tmp = $receipt + '.' + [guid]::NewGuid().ToString('N')
        try {
            [IO.File]::WriteAllText($tmp,($record | ConvertTo-Json -Compress))
            if ([IO.File]::Exists($receipt)) { [IO.File]::Replace($tmp,$receipt,($receipt+'.previous')) }
            else { [IO.File]::Move($tmp,$receipt) }
        } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
    }
    if ($Action -eq 'VerifyRecovery') {
        if ($state -ne 'matching') { throw 'Build the current release before qualification' }
        $pins = New-Object 'System.Collections.Generic.List[System.IO.FileStream]'
        try {
            $pins.Add([IO.File]::Open(($receipt+'.lock'),'OpenOrCreate','Write','None'))
            foreach ($file in @($stamp,$binary,$verifier)) { $pins.Add([IO.File]::Open($file,'Open','Read','Read')) }
            $proof = [ordered]@{schema=1;run=[guid]::NewGuid().ToString('N');state='unknown';stamp=(Get-FileHash $stamp).Hash;verifier=(Get-FileHash $verifier).Hash}
            SaveReceipt $proof
            $locked = Get-Content -Raw $stamp | ConvertFrom-Json
            if ($locked.v -ne 1 -or $locked.tree -ne $tree -or $locked.profile -ne 'release' -or $locked.compiler -ne $compiler -or
                $locked.binary -ne (Get-FileHash $binary).Hash -or $locked.source -ne $before -or $before -ne (Revision) -or
                $locked.head -ne $head -or $head -ne (& git rev-parse HEAD)) { throw 'Build changed before qualification' }
            $result = @(& $verifier -Executable $binary)
            if ($result.Count -ne 1 -or $result[0] -cne 'PASS: interrupted operation, dirty and indexed input, scope, session and worktree isolation.') { throw 'Recovery fixture did not complete its independent assertions' }
            if ($before -ne (Revision) -or $head -ne (& git rev-parse HEAD)) { throw 'Source changed during qualification' }
            $proof.state='verified'
            SaveReceipt $proof
        } finally { foreach ($pin in $pins) { $pin.Dispose() } }
    }
    $qualification='unknown'
    if ([IO.File]::Exists($receipt)) {
        try {
            if ((Get-Item $receipt).Length -gt 2048) { throw 'Invalid receipt' }
            $q=Get-Content -Raw $receipt | ConvertFrom-Json
            if ($q.schema -eq 1 -and $q.run -cmatch '^[a-f0-9]{32}$' -and $q.state -eq 'verified') {
                $qualification='stale'
                if ($state -eq 'matching' -and $q.stamp -eq (Get-FileHash $stamp).Hash -and $q.verifier -eq (Get-FileHash $verifier).Hash) { $qualification='verified' }
            }
        } catch { $qualification='unknown' }
    }
    [pscustomobject]@{schema=1;profile='release';build=$state;worktree_recovery_test=$qualification} | ConvertTo-Json -Compress
} finally { Pop-Location }