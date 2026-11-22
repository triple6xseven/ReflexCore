# ReflexCore DevBridge 0.2.0 - validated, local-only patch protocol.
Set-StrictMode -Version Latest

function Get-RcRoot {
    return [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
}

function Get-RcUtf8 {
    return (New-Object System.Text.UTF8Encoding($false))
}

function Get-RcRelativePath {
    param([Parameter(Mandatory=$true)][string]$Relative)
    $p = $Relative.Replace('\', '/')
    if ($p -eq 'Cargo.toml' -or $p -eq 'AGENTS.md') { return $p }
    if ($p -notmatch '^(src|tests|examples|tools|tasks)/[A-Za-z0-9_.\-/]+$') {
        throw "Disallowed patch path: $Relative"
    }
    $segments = $p.Split('/')
    foreach ($s in $segments) {
        if ($s -eq '' -or $s -eq '.' -or $s -eq '..') {
            throw "Invalid path segment: $Relative"
        }
    }
    if ($p -notmatch '\.(rs|cs|ps1|json|toml|md|txt)$') {
        throw "Unsupported source extension: $Relative"
    }
    $reserved = @(
        'tools/ReflexDev.ps1',
        'tools/ReflexDev-Lib.ps1',
        'tools/ReflexDev-Worker.ps1',
        'tasks/dev-apply.ps1'
    )
    foreach ($r in $reserved) {
        if ([string]::Equals($p, $r, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Updater self-modification is not supported: $Relative"
        }
    }
    return $p
}

function Resolve-RcTarget {
    param([string]$Root, [string]$Relative)
    $safe = Get-RcRelativePath $Relative
    $relWindows = $safe.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path $Root $relWindows))
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escaped project: $Relative"
    }
    # Reject symlink/junction traversal on every existing ancestor.
    $walk = $Root
    if ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Project root must not be a reparse point'
    }
    foreach ($part in $relWindows.Split([IO.Path]::DirectorySeparatorChar)) {
        $walk = Join-Path $walk $part
        if (Test-Path -LiteralPath $walk) {
            $item = Get-Item -LiteralPath $walk -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse points not allowed inside patch paths: $Relative"
            }
        }
    }
    return $full
}

function Read-RcManifest {
    param([string]$ManifestPath, [string]$Root)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Manifest file does not exist: $ManifestPath"
    }
    $info = Get-Item -LiteralPath $ManifestPath
    if ($info.Length -gt 16777216) { throw 'Manifest exceeds 16 MiB' }
    # ReadAllText uses the .NET working directory, which may differ from PS $PWD.
    $ManifestPath = (Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).ProviderPath
    $raw = [IO.File]::ReadAllText($ManifestPath, [Text.Encoding]::UTF8)
    $manifest = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $manifest) { throw 'Manifest must be a JSON object' }
    $required = @('schema', 'name', 'writes')
    foreach ($key in $required) {
        if ($null -eq $manifest.PSObject.Properties[$key]) {
            throw "Manifest field missing: $key"
        }
    }
    foreach ($property in $manifest.PSObject.Properties.Name) {
        if ($required -notcontains $property) { throw "Unknown manifest field: $property" }
    }
    if ($manifest.schema -cne 'reflexcore.devpatch.v1') { throw 'Unsupported patch schema' }
    if (-not ($manifest.name -is [string]) -or $manifest.name -notmatch '^[a-zA-Z0-9_.-]{1,70}$') {
        throw 'Invalid manifest name (use letters, digits, _, -, .)'
    }
    $writes = @($manifest.writes)
    if ($writes.Count -lt 1 -or $writes.Count -gt 128) { throw 'Manifest must contain 1..128 writes' }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $checked = New-Object System.Collections.ArrayList
    foreach ($w in $writes) {
        if ($null -eq $w -or $null -eq $w.PSObject) { throw 'Invalid write entry' }
        foreach ($field in @('path', 'content', 'expected_sha256')) {
            if ($null -eq $w.PSObject.Properties[$field]) { throw "Write missing: $field" }
        }
        foreach ($field in $w.PSObject.Properties.Name) {
            if (@('path', 'content', 'expected_sha256') -notcontains $field) {
                throw "Unknown write field: $field"
            }
        }
        if (-not ($w.path -is [string]) -or -not ($w.content -is [string])) {
            throw 'Each write requires string path and content'
        }
        $safe = Get-RcRelativePath $w.path
        if (-not $seen.Add($safe)) { throw "Duplicate write path: $safe" }
        $target = Resolve-RcTarget $Root $safe
        $size = [Text.Encoding]::UTF8.GetByteCount($w.content)
        if ($size -gt 4194304) { throw "One file exceeds 4 MiB: $safe" }
        $exists = Test-Path -LiteralPath $target -PathType Leaf
        if ((Test-Path -LiteralPath $target) -and (-not $exists)) {
            throw "Target exists but is not a regular file: $safe"
        }
        if ($exists) {
            if (-not ($w.expected_sha256 -is [string]) -or
                $w.expected_sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
                throw "Existing file requires expected_sha256: $safe"
            }
            $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            if (-not [string]::Equals($actual, $w.expected_sha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Source hash changed; refusing to overwrite: $safe"
            }
        } elseif ($null -ne $w.expected_sha256) {
            throw "New file must set expected_sha256 to null: $safe"
        }
        [void]$checked.Add([PSCustomObject]@{
            path=$safe
            target=$target
            content=$w.content
            existed=$exists
            size_bytes=$size
        })
    }
    return [PSCustomObject]@{
        name = [string]$manifest.name
        writes = @($checked.ToArray())
    }
}

function Write-RcJson {
    param([string]$Path, [object]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 16 -Compress
    [IO.File]::WriteAllText($Path, $json, (Get-RcUtf8))
}

function Write-RcDevStatus {
    param([string]$Root, [string]$State, [string]$Stage, [int]$ExitCode, [int]$Files, [long]$DurationMs)
    $base = Join-Path $Root 'data\dev'
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    Write-RcJson (Join-Path $base 'last_result.json') ([ordered]@{
        schema='reflexcore.devbridge.v1'
        state=$State
        stage=$Stage
        exit_code=$ExitCode
        changed_files=$Files
        duration_ms=$DurationMs
        at_utc=[DateTime]::UtcNow.ToString('o')
    })
}

function Invoke-RcRecover {
    param([string]$Root)
    $dev = Join-Path $Root 'data\dev'
    $journal = Join-Path $dev 'inflight.json'
    if (-not (Test-Path -LiteralPath $journal -PathType Leaf)) { return $false }
    $entry = ([IO.File]::ReadAllText($journal) | ConvertFrom-Json)
    if ($entry.schema -ne 'reflexcore.devbridge.rollback.v1') { throw 'Unknown rollback journal version; stopping for manual review' }
    $backupRoot = [IO.Path]::GetFullPath([string]$entry.backup_dir)
    $safePrefix = [IO.Path]::GetFullPath((Join-Path $Root 'backups')) + [IO.Path]::DirectorySeparatorChar
    if (-not $backupRoot.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe rollback backup path; manual recovery required'
    }
    foreach ($record in @($entry.files)) {
        $target = Resolve-RcTarget $Root ([string]$record.path)
        if ([bool]$record.existed) {
            $originalRelative = ([string]$record.path).Replace('/', [IO.Path]::DirectorySeparatorChar)
            $original = Join-Path $backupRoot $originalRelative
            $original = [IO.Path]::GetFullPath($original)
            if (-not $original.StartsWith($backupRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Backup entry escaped backup directory'
            }
            if (-not (Test-Path -LiteralPath $original -PathType Leaf)) { throw "Missing backup for $($record.path)" }
            $dir = Split-Path $target -Parent
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [IO.File]::Copy($original, $target, $true)
        } else {
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                Remove-Item -LiteralPath $target -Force
            }
        }
        $temp = $target + '.reflex-tmp-' + [string]$entry.id
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force }
    }
    Remove-Item -LiteralPath $journal -Force
    $fileCount = @($entry.files).Count
    Write-RcDevStatus $Root 'recovered' 'rollback' 0 $fileCount 0
    return $true
}