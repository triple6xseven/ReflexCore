param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('inventory','preview','apply','status','recover','selftest','diagnostics')]
    [string]$Action,
    [string]$Manifest = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'ReflexDev-Lib.ps1')
$root = Get-RcRoot
# PS $PWD and .NET Environment.CurrentDirectory can differ.
# Resolve the caller's path before any .NET file operation.
if (-not [string]::IsNullOrWhiteSpace($Manifest)) {
    $Manifest = (Resolve-Path -LiteralPath $Manifest -ErrorAction Stop).ProviderPath
}
$dev = Join-Path $root 'data\dev'
New-Item -ItemType Directory -Path $dev -Force | Out-Null

switch ($Action) {
    'inventory' {
        $included = @('src','tests','examples','tools','tasks')
        $items = New-Object System.Collections.ArrayList
        foreach ($folder in $included) {
            $dir = Join-Path $root $folder
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
            foreach ($file in (Get-ChildItem -LiteralPath $dir -Recurse -File)) {
                if ($file.FullName -match '\\(target|data|\.git|backups)\\') { continue }
                [void]$items.Add([PSCustomObject]@{
                    path = $file.FullName.Substring($root.Length + 1).Replace('\','/')
                    bytes = $file.Length
                    sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                })
            }
        }
        foreach ($top in @('Cargo.toml','AGENTS.md')) {
            $file = Join-Path $root $top
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $item = Get-Item -LiteralPath $file
                [void]$items.Add([PSCustomObject]@{
                    path=$top; bytes=$item.Length
                    sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
                })
            }
        }
        $items | Sort-Object path | Format-Table -AutoSize
        Write-Host "[ReflexDev] $($items.Count) code files. No contents displayed."
        break
    }
    'preview' {
        if (-not $Manifest) { throw '-Manifest is required for preview' }
        $patch = Read-RcManifest $Manifest $root
        Write-Host "[ReflexDev] VALID PATCH: $($patch.name)"
        foreach ($w in $patch.writes) {
            $operation = if ($w.existed) { 'replace' } else { 'create' }
            Write-Host ('  {0,-8} {1,-48} {2,8} bytes' -f $operation,$w.path,$w.size_bytes)
        }
        Write-Host '[ReflexDev] Preview does not change files.'
        break
    }
    'apply' {
        if (-not $Manifest) { throw '-Manifest is required for apply' }
        $patch = Read-RcManifest $Manifest $root
        $pending = Join-Path $dev 'pending'
        New-Item -ItemType Directory -Path $pending -Force | Out-Null
        $id = [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff') + '-' + [guid]::NewGuid().ToString('N')
        $destination = Join-Path $pending ($id + '.json')
        $temporary = $destination + '.tmp'
        [IO.File]::Copy([IO.Path]::GetFullPath($Manifest), $temporary, $false)
        [IO.File]::Move($temporary, $destination)
        try {
            & (Join-Path $PSScriptRoot 'Submit-ReflexJob.ps1') -Task dev-apply -Run
        } catch {
            if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
            throw
        }
        Write-Host "[ReflexDev] Patch queued: $($patch.name), files: $($patch.writes.Count)"
        Write-Host '[ReflexDev] This may execute new code via cargo test; submit only reviewed manifests.'
        break
    }
    'status' {
        $bridgeStatus = Join-Path $root 'data\bridge\status.json'
        $devStatus = Join-Path $dev 'last_result.json'
        if (Test-Path -LiteralPath $bridgeStatus) {
            Write-Host '[Bridge]'
            Get-Content -LiteralPath $bridgeStatus -Raw
        }
        if (Test-Path -LiteralPath $devStatus) {
            Write-Host '[DevBridge]'
            Get-Content -LiteralPath $devStatus -Raw
        } else { Write-Host '[DevBridge] No completed patch yet.' }
        $count = @(Get-ChildItem -LiteralPath (Join-Path $dev 'pending') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
        Write-Host "[DevBridge] Pending manifests: $count"
        break
    }
    'recover' {
        & (Join-Path $PSScriptRoot 'ReflexDev-Worker.ps1') -Mode recover
        if ($LASTEXITCODE -ne 0) { throw 'Recovery failed' }
        break
    }
    'selftest' {
        & (Join-Path $PSScriptRoot 'ReflexDev-Worker.ps1') -Mode selftest
        if ($LASTEXITCODE -ne 0) { throw 'Selftest failed' }
        break
    }
    'diagnostics' {
        Write-Warning 'Local Cargo logs may contain file paths or private strings. Review before sharing.'
        $logs = Join-Path $dev 'logs'
        foreach ($name in @('cargo-test-latest.txt','cargo-release-latest.txt')) {
            $path = Join-Path $logs $name
            if (Test-Path -LiteralPath $path) {
                Write-Host "[$name]"
                Get-Content -LiteralPath $path -Tail 40
            }
        }
        break
    }
}