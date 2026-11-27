#Requires -Version 5.1
# Negative transport check. No lifecycle payload is generated.
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) 'target/release/reflex-observer.exe'
$root=[IO.Path]::Combine([IO.Path]::GetTempPath(),'reflex-hook-'+[guid]::NewGuid().ToString('N'))
$install=[IO.Directory]::CreateDirectory((Join-Path $root 'reflex-observer'))
try {
    $exe=Join-Path $install.FullName 'observer.exe'
    [IO.File]::Copy($source,$exe)
    if((& $exe hook-protocol) -ne 'reflex.hook.1'){throw 'Missing ingress protocol'}
    $output='invalid JSON' | & $exe diagnose $root
    if($LASTEXITCODE -ne 0 -or $output){throw 'Rejected input was not handled silently'}
    $journal=Join-Path $root 'reflex-hook-arrivals.sqlite'
    if(![IO.File]::Exists($journal)){throw 'No local diagnostic journal'}
    $bytes=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($journal))
    if(!$bytes.Contains('invalid_payload') -or $bytes.Contains('invalid JSON') -or $bytes.Contains('CREATE TABLE journal(')){throw 'Malformed input was stored or promoted to lifecycle evidence'}
} finally {
    $full=[IO.Path]::GetFullPath($root)
    if([IO.Path]::GetDirectoryName($full) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and [IO.Path]::GetFileName($full) -match '^reflex-hook-[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
'PASS: invalid input produced only a sanitized local rejection.'
