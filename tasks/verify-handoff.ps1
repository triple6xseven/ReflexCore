$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $project
try {
    & (Join-Path $project 'target\release\reflexcore.exe') handoff --queued
    exit $LASTEXITCODE
} finally { Pop-Location }
