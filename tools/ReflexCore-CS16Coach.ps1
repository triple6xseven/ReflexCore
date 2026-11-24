#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BenchmarkReport,
    [string]$VisionReport,
    [ValidateSet('measured','synthetic')][string]$VisionScope='measured',
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.:/-]{0,95}$')][string]$Model='qwen3-vl:2b-instruct',
    [switch]$SelfTest
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot

function Read-Report([string]$Path,[int]$Limit){
    $item=Get-Item -LiteralPath $Path
    if($item.PSIsContainer -or $item.Length -gt $Limit){throw 'Report is missing or exceeds its size budget'}
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}
function Count-Value($Value,[int]$Limit){
    if(($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt 0 -or $Value -gt $Limit){
        throw 'Invalid evidence count'
    }
    return [int]$Value
}
function New-Context($Benchmark,$Vision,$Registry,[string]$Scope){
    if($Benchmark.schema -cne 'reflexcore.cs16.benchmark.v1' -or $Benchmark.evidence -cne 'goldsrc_server_log'){
        throw 'Expected the Rust GoldSrc benchmark output'
    }
    $rounds=Count-Value $Benchmark.rounds_observed 10000
    $plants=Count-Value $Benchmark.verified_plants $rounds
    $wins=Count-Value $Benchmark.verified_plant_bot_round_wins $plants
    $shotEvidence=$null
    if($null -ne $Vision){
        $frames=Count-Value $Vision.frames 100000
        if($frames -eq 0){throw 'Vision report contains no frames'}
        $match=Count-Value $Vision.byScene.match $frames
        $negative=Count-Value $Vision.negativeFramesWithBoxes $frames
        $shotEvidence=[ordered]@{
            scope=$Scope; frames=$frames; match_frames=$match; negative_frames_with_boxes=$negative
            tp=(Count-Value $Vision.tp 2000000); fp=(Count-Value $Vision.fp 2000000); fn=(Count-Value $Vision.fn 2000000)
        }
    }
    $motion=$null
    if($null -ne $Registry){
        $skill=@($Registry.skills|Where-Object {$_.id -ceq 'cs16.advance' -and $_.version -eq 1})
        if($skill.Count -ne 1){throw 'Unexpected CS16 skill registry'}
        $entry=@($Registry.bounded_replay_statistics|Where-Object {
            $_.environment -ceq 'cs16_offline_v1' -and $_.skill -ceq $skill[0].id -and $_.version -eq 1
        })
        if($entry.Count -gt 1){throw 'Unexpected duplicate skill context'}
        $trials=0
        $verified=0
        if($entry.Count -eq 1){
            $trials=Count-Value $entry[0].trials 1024
            $verified=Count-Value $entry[0].verified_one_pulse $trials
        }
        $motion=[ordered]@{skill='cs16.advance';version=1;sample_count=$trials;verified_displacements=$verified}
    }
    [ordered]@{
        engine=[ordered]@{rounds=$rounds;verified_plants=$plants;verified_plant_kill_wins=$wins;shot_metrics_available=$false}
        vision=$shotEvidence
        skills=$motion
    }
}
function Get-Candidates($Context){
    if($Context.vision -and $Context.vision.scope -eq 'measured' -and $Context.vision.negative_frames_with_boxes -gt 0){
        'audit_vision_negatives'
    }
    if($Context.engine.verified_plants -gt 0){'measure_shot_outcomes'}
    if($Context.engine.verified_plants -eq 0){'repeat_route_baseline'}
    if($Context.skills -and $Context.skills.sample_count -gt $Context.skills.verified_displacements){
        'inspect_unverified_motion'
    }
}
function Resolve-Advice($Context,[scriptblock]$Request){
    $choices=@(Get-Candidates $Context)
    $choice=$choices[0]
    $source='deterministic_fallback'
    try{
        $reply=& $Request $Context $choices
        if($reply -isnot [string] -or $reply.Length -gt 256){throw 'Invalid model output size'}
        $value=$reply | ConvertFrom-Json
        if(@($value.PSObject.Properties).Count -ne 1 -or $value.next_experiment -isnot [string] -or
           $choices -cnotcontains $value.next_experiment){
            throw 'Model returned an unsupported experiment'
        }
        $choice=$value.next_experiment
        $source='ollama'
    }catch{}
    [ordered]@{schema='reflexcore.cs16.coach.v1';source=$source;next_experiment=$choice;evidence=$Context}
}
function Invoke-Coach($Context,$Choices){
    Add-Type -AssemblyName System.Net.Http
    $handler=[System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy=$false
    $handler.AllowAutoRedirect=$false
    $client=[System.Net.Http.HttpClient]::new($handler)
    $client.Timeout=[TimeSpan]::FromSeconds(45)
    $client.MaxResponseContentBufferSize=65536
    $format=@{type='object';required=@('next_experiment');additionalProperties=$false
        properties=@{next_experiment=@{type='string';enum=@($Choices)}}}
    $request=@{
        model=$Model;stream=$false
        prompt="Choose one next controlled offline CS 1.6 experiment from the provided options. Use GoldSrc for outcomes. Vision is a separate dataset. Synthetic vision cannot diagnose a live match. Skill counts measure displacement, not route success. Prefer measuring gunfire before tuning weapons. Choices: $($Choices -join ', '). Evidence: $(ConvertTo-Json -InputObject $Context -Depth 6 -Compress)"
        format=$format;options=@{temperature=0;num_ctx=2048;num_predict=64}
    }
    $base='http://127.0.0.1:11434'
    $content=$null
    $response=$null
    try{
        $loaded=$client.GetStringAsync("$base/api/ps").GetAwaiter().GetResult() | ConvertFrom-Json
        if(!$loaded.PSObject.Properties['models']){throw 'Cannot determine Ollama residency'}
        if(@($loaded.models|Where-Object {$_.name -ceq $Model -or $_.model -ceq $Model}).Count -eq 0){
            if(@($loaded.models|Where-Object {$_}).Count -gt 0){throw 'Another model is resident'}
            $request.keep_alive='30s'
        }
        $content=[System.Net.Http.StringContent]::new((ConvertTo-Json -InputObject $request -Depth 8 -Compress),[Text.Encoding]::UTF8,'application/json')
        $response=$client.PostAsync("$base/api/generate",$content).GetAwaiter().GetResult()
        if(!$response.IsSuccessStatusCode){throw 'Local Ollama request failed'}
        $result=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if($result.done -ne $true){throw 'Incomplete local model response'}
        return $result.response
    }finally{
        if($response){$response.Dispose()}
        if($content){$content.Dispose()}
        $client.Dispose()
    }
}

if($SelfTest){
    $benchmark='{"schema":"reflexcore.cs16.benchmark.v1","evidence":"goldsrc_server_log","rounds_observed":1,"verified_plants":1,"verified_plant_bot_round_wins":0}'|ConvertFrom-Json
    $vision='{"frames":5,"byScene":{"match":3},"tp":2,"fp":1,"fn":0,"negativeFramesWithBoxes":1}'|ConvertFrom-Json
    $registry='{"skills":[{"id":"cs16.advance","version":1}],"bounded_replay_statistics":[{"environment":"cs16_offline_v1","skill":"cs16.advance","version":1,"trials":10,"verified_one_pulse":8}]}'|ConvertFrom-Json
    $context=New-Context $benchmark $vision $registry 'measured'
    $accepted=Resolve-Advice $context {'{"next_experiment":"measure_shot_outcomes"}'}
    if($accepted.source -ne 'ollama' -or $accepted.next_experiment -ne 'measure_shot_outcomes'){throw 'Valid advice rejected'}
    $denied=Resolve-Advice $context {'{"next_experiment":"fire","command":"shell"}'}
    if($denied.source -ne 'deterministic_fallback' -or $denied.next_experiment -ne 'audit_vision_negatives'){throw 'Invalid advice accepted'}
    $synthetic=New-Context $benchmark $vision $registry 'synthetic'
    if(@(Get-Candidates $synthetic) -contains 'audit_vision_negatives'){throw 'Synthetic evidence was treated as live'}
    'CS16 coach self-test passed: evidence projection, valid advice, fallback and synthetic isolation.'
    return
}
if(!$BenchmarkReport){throw 'Pass -BenchmarkReport from reflexcore cs16 benchmark'}
if($Model.Contains('..') -or $Model.Contains('//') -or $Model.Contains('::') -or $Model.EndsWith('/') -or $Model.EndsWith(':')){throw 'Invalid local model name'}
$benchmark=Read-Report $BenchmarkReport 1048576
$vision=if($VisionReport){Read-Report $VisionReport 16384}
$registry=$null
$binary=Join-Path $root 'target/release/reflexcore.exe'
Push-Location $root
try{
    if(Test-Path -LiteralPath $binary -PathType Leaf){
        $raw=& $binary learning registry 2>$null
        if($LASTEXITCODE -eq 0){$registry=($raw -join "`n") | ConvertFrom-Json}
    }
}finally{Pop-Location}
$context=New-Context $benchmark $vision $registry $VisionScope
Resolve-Advice $context ${function:Invoke-Coach} | ConvertTo-Json -Depth 8
