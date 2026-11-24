$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $root 'tools/ReflexCore-HandoffDraft.cs')
$cases = [IO.File]::ReadAllText((Join-Path $root 'examples/handoff-language-evaluation.json')) | ConvertFrom-Json
$names = @{ Draft = 'draft'; Clarify = 'clarify'; OutsideScope = 'outside_scope' }
$counts = @{}
foreach ($case in $cases) {
    [string[]]$lines = @()
    $state = $names[[ReflexCore.Control.HandoffDraft]::Build($case.text, [ref]$lines).ToString()]
    if ($state -cne $case.state -or ($lines -join "`n") -cne ($case.lines -join "`n")) {
        throw "Unexpected draft or decision for fixture $($case.text). Got $state."
    }
    $counts[$state]++
}
$samples = New-Object 'System.Collections.Generic.List[double]'
foreach ($round in 1..20) {
    foreach ($case in $cases) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        [void][ReflexCore.Control.HandoffDraft]::Build($case.text, [ref]$lines)
        $samples.Add($watch.Elapsed.TotalMilliseconds)
    }
}
$sorted = @($samples | Sort-Object)
$p50 = $sorted[[int][math]::Ceiling($sorted.Count * .5) - 1]
$p95 = $sorted[[int][math]::Ceiling($sorted.Count * .95) - 1]
"Exact drafts: $($counts.draft); correct clarifications: $($counts.clarify); correct scope rejections: $($counts.outside_scope)"
"Warm samples: $($sorted.Count); p50: $p50 ms; p95: $p95 ms"
