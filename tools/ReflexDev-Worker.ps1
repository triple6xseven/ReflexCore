param([ValidateSet('apply', 'recover', 'selftest')][string]$Mode='apply')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'ReflexDev-Lib.ps1')
$root = Get-RcRoot
$dev = Join-Path $root 'data\dev'
$pending = Join-Path $dev 'pending'
$active = Join-Path $dev 'active'
$failed = Join-Path $dev 'failed'
foreach ($dir in @($dev, $pending, $active, $failed)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$mutex = [System.Threading.Mutex]::new($false, 'Local\ReflexCoreDevBridgePatch')
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Another DevBridge transaction is running' }

    if ($Mode -eq 'selftest') {
        $tests = 0
        if ((Get-RcRelativePath 'src/test.rs') -ne 'src/test.rs') { throw 'Path normalize failed' }; $tests++
        foreach ($invalid in @('../secret.txt', 'data/secrets.json', 'src/../oops.rs', 'tools/ReflexDev-Worker.ps1', 'src/a.exe')) {
            $rejected = $false
            try { $null = Get-RcRelativePath $invalid } catch { $rejected = $true }
            if (-not $rejected) { throw "Invalid path accepted: $invalid" }
            $tests++
        }
        $valid = Join-Path $dev 'selftest-manifest.json'
        $probePath = 'examples/reflex_dev_selftest_probe.rs'
        $probeTarget = Resolve-RcTarget $root $probePath
        if (Test-Path -LiteralPath $probeTarget) { throw 'Selftest probe file already exists' }
        Write-RcJson $valid ([ordered]@{
            schema='reflexcore.devpatch.v1'; name='selftest'; writes=@(
                [ordered]@{path=$probePath; content='fn main() {}'; expected_sha256=$null}
            )
        })
        try {
            $m = Read-RcManifest $valid $root
            if ($m.writes.Count -ne 1) { throw 'Selftest manifest validation failed' }
            $tests++
        } finally {
            if (Test-Path -LiteralPath $valid) { Remove-Item $valid -Force }
        }
        # Exercise actual rollback in a temporary sandbox, never on the user's source.
        $sandbox = Join-Path $dev ('selftest-' + [guid]::NewGuid().ToString('N'))
        $sandSrc = Join-Path $sandbox 'src'
        $sandBackup = Join-Path $sandbox 'backups\original'
        $sandDev = Join-Path $sandbox 'data\dev'
        New-Item -ItemType Directory -Path $sandSrc,$sandBackup,$sandDev -Force | Out-Null
        try {
            $target = Join-Path $sandSrc 'probe.rs'
            $backupFile = Join-Path $sandBackup 'src\probe.rs'
            New-Item -ItemType Directory -Path (Split-Path $backupFile -Parent) -Force | Out-Null
            [IO.File]::WriteAllText($target, 'before', (Get-RcUtf8))
            [IO.File]::Copy($target, $backupFile)
            [IO.File]::WriteAllText($target, 'changed', (Get-RcUtf8))
            Write-RcJson (Join-Path $sandDev 'inflight.json') ([ordered]@{
                schema='reflexcore.devbridge.rollback.v1'
                id='selftest'
                backup_dir=$sandBackup
                files=@([ordered]@{path='src/probe.rs'; existed=$true})
            })
            if (-not (Invoke-RcRecover $sandbox)) { throw 'Rollback did not run' }
            if ([IO.File]::ReadAllText($target) -ne 'before') { throw 'Rollback did not restore original' }
            $tests++
        } finally {
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "[ReflexDev] Selftest PASS: $tests checks."
        exit 0
    }

    $recovered = Invoke-RcRecover $root
    # A forcibly stopped job is never silently resumed, even if stopped before
    # the journal was written. Any stale active request is quarantined.
    foreach ($leftover in @(Get-ChildItem -LiteralPath $active -Filter '*.json' -File)) {
        Move-Item -LiteralPath $leftover.FullName -Destination (Join-Path $failed $leftover.Name) -Force
    }
    if ($recovered) {
        Write-Host '[ReflexDev] Recovered interrupted transaction.'
    }
    if ($Mode -eq 'recover') {
        if (-not $recovered) { Write-Host '[ReflexDev] No interrupted transaction.' }
        exit 0
    }

    $next = Get-ChildItem -LiteralPath $pending -Filter '*.json' -File |
        Sort-Object Name | Select-Object -First 1
    if ($null -eq $next) {
        Write-Host '[ReflexDev] No pending patch manifests.'
        exit 0
    }
    $activePath = Join-Path $active $next.Name
    Move-Item -LiteralPath $next.FullName -Destination $activePath -ErrorAction Stop
    $start = [Diagnostics.Stopwatch]::StartNew()
    $backup = $null
    $manifest = $null
    $stage = 'validate'
    try {
        $manifest = Read-RcManifest $activePath $root
        $id = [guid]::NewGuid().ToString('N')
        $backup = Join-Path $root ('backups\devpatch-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $id)
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        $records = @()
        foreach ($w in $manifest.writes) {
            if ($w.existed) {
                $backupRelative = ([string]$w.path).Replace('/', [IO.Path]::DirectorySeparatorChar)
                $original = Join-Path $backup $backupRelative
                New-Item -ItemType Directory -Path (Split-Path $original -Parent) -Force | Out-Null
                [IO.File]::Copy($w.target, $original, $false)
            }
            $records += [ordered]@{path=$w.path; existed=[bool]$w.existed}
        }
        # The journal is durable before any tracked project file is touched.
        $journal = Join-Path $dev 'inflight.json'
        $journalTemp = $journal + '.tmp'
        Write-RcJson $journalTemp ([ordered]@{
            schema='reflexcore.devbridge.rollback.v1'
            id=$id
            backup_dir=$backup
            files=@($records)
        })
        [IO.File]::Move($journalTemp, $journal)
        $stage = 'write'
        $utf8 = Get-RcUtf8
        foreach ($w in $manifest.writes) {
            $dir = Split-Path $w.target -Parent
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $temp = $w.target + '.reflex-tmp-' + $id
            [IO.File]::WriteAllText($temp, [string]$w.content, $utf8)
            if ($w.existed) {
                # Replace is atomic on NTFS for an existing target.
                # REFLEXCORE_WRITE_FALLBACK_V022
                # Prefer atomic replace. Some synced Windows folders do not support it;
                # the durable rollback journal and source backup protect the fallback.
                try {
                    [IO.File]::Replace($temp, $w.target, $null)
                } catch {
                    [IO.File]::Copy($temp, $w.target, $true)
                    [IO.File]::Delete($temp)
                }
            } else {
                [IO.File]::Move($temp, $w.target)
            }
        }
        Push-Location -LiteralPath $root
        try {
            $logDir = Join-Path $dev 'logs'
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            foreach ($spec in @(
                @{label='cargo-test'; arguments=@('test', '--all-targets')},
                @{label='cargo-release'; arguments=@('build', '--release')}
            )) {
                $stage = [string]$spec.label
                $log = Join-Path $logDir ($stage + '-latest.txt')
                $previousEap = $ErrorActionPreference
                try {
                    # Cargo writes regular progress to stderr; don't promote it to a terminating PS error.
                    $ErrorActionPreference = 'Continue'
                    $cargoArgs = [string[]]$spec.arguments
                    & cargo @cargoArgs 2>&1 | Out-File -LiteralPath $log -Encoding UTF8
                    $code = $LASTEXITCODE
                } finally { $ErrorActionPreference = $previousEap }
                if ($code -ne 0) { throw "$stage failed (exit $code). Local log: $log" }
            }
        } finally { Pop-Location }
        $stage = 'commit'
        Remove-Item -LiteralPath $journal -Force
        Remove-Item -LiteralPath $activePath -Force
        Write-RcDevStatus $root 'completed' 'verified' 0 $manifest.writes.Count $start.ElapsedMilliseconds
        Write-Host "[ReflexDev] PATCH VERIFIED: $($manifest.writes.Count) files, $($start.ElapsedMilliseconds) ms."
        exit 0
    }
    catch {
        $message = $_.Exception.Message
        # Detailed error stays in ignored local data/, never in the public repo.
        try {
            $diagnostic = Join-Path $dev 'last_error.txt'
            [IO.File]::WriteAllText($diagnostic, ("stage=" + $stage + "`r`n" + $message), (Get-RcUtf8))
        } catch { }
        $revertOk = $true
        try { $null = Invoke-RcRecover $root } catch { $revertOk = $false }
        if (Test-Path -LiteralPath $activePath) {
            Move-Item -LiteralPath $activePath -Destination (Join-Path $failed ([IO.Path]::GetFileName($activePath))) -Force
        }
        if ($revertOk) {
            Write-RcDevStatus $root 'failed_rolled_back' $stage 1 0 $start.ElapsedMilliseconds
        } else {
            Write-RcDevStatus $root 'recovery_required' $stage 2 0 $start.ElapsedMilliseconds
        }
        Write-Error "[ReflexDev] Patch failed at stage $stage. $message. Rollback successful: $revertOk"
        exit 1
    }
}
catch {
    Write-Error "[ReflexDev] $($_.Exception.Message)"
    exit 1
}
finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}