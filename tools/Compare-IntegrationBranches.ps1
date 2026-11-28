#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Base='origin/main',
    [string[]]$Branches=@(
        'origin/feat/local-teammate-lobby',
        'origin/experiment/cs16-practice',
        'origin/feat/core-task-lifecycle',
        'origin/feat/repository-intelligence',
        'origin/feat/universal-skill-runtime',
        'origin/fix/p0-task-integrity',
        'origin/docs/reflexcore-1.0-blueprint'
    ),
    [switch]$Json
)
$ErrorActionPreference='Stop'
if($Branches.Count -lt 1 -or $Branches.Count -gt 32){throw 'Provide one to 32 branch names.'}
function Resolve-Revision([string]$Name) {
    if($Name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._/-]{0,159}\z' -or $Name.Contains('..')){throw 'Invalid revision name.'}
    $value=git rev-parse --verify "${Name}^{commit}" 2>$null
    if($LASTEXITCODE -or $value -cnotmatch '\A[0-9a-f]{40}\z'){throw "Local revision unavailable: $Name"}
    $value
}
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $baseSha=Resolve-Revision $Base
    $rows=@(foreach($name in $Branches){
        $sha=Resolve-Revision $name
        $pair="$baseSha...$sha"
        $counts=git rev-list --left-right --count $pair
        if($LASTEXITCODE -or $counts -notmatch '^([0-9]+)\s+([0-9]+)$'){throw "Unable to compare $name"}
        $behind=[int]$Matches[1]
        $ahead=[int]$Matches[2]
        $patches=@(git cherry $baseSha $sha)
        if($LASTEXITCODE){throw "Unable to compare patches for $name"}
        $changes=@($patches | Where-Object {$_ -match '^\+ [0-9a-f]{40}$'})
        [pscustomobject]@{
            branch=$name
            revision=$sha
            ahead=$ahead
            behind=$behind
            equivalent_patches=@($patches | Where-Object {$_ -match '^- [0-9a-f]{40}$'}).Count
            patch_differences=$changes.Count
            source_only_commits=@($changes | Select-Object -First 24 | ForEach-Object {$_.Substring(2)})
        }
    })
    if($Json){ConvertTo-Json -InputObject @{base=$Base;revision=$baseSha;branches=$rows} -Depth 4}
    else{$rows | Select-Object branch,ahead,behind,equivalent_patches,patch_differences | Format-Table -AutoSize}
}finally{Pop-Location}
