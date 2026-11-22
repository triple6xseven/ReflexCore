[CmdletBinding()]
param([ValidateRange(1,100)][int]$Runs=20,[switch]$AllowInput,[switch]$Visual)
$ErrorActionPreference='Stop'
if(!$AllowInput){throw 'Use -AllowInput for this visible Notepad test'}
$tool=Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/ReflexCore-VisionLoop.ps1'
$elapsed=@();$failed=0;$hits=0;$calls=0
for($run=0;$run -lt $Runs;$run++){
    try{
        $opts=@{Action='DemoNotepad';TestFixture=$true;AllowInput=$true;UnicodeFixture=($run%2 -eq 1)}
        if($Visual){$opts.Route='Visual'}
        $result=& $tool @opts
        if($result.schema -cne 'reflexcore.notepad.result.v1' -or !$result.verified){throw 'Missing disk evidence'}
        $elapsed+=[long]$result.elapsed_ms
        $calls+=$result.model_calls
        if($result.memory_hit){$hits++}
    }catch{
        if($_.Exception.ToString() -match 'Stopped by operator'){throw}
        $failed++;Write-Warning ('Fixture '+($run+1)+' failed: '+$_.Exception.Message)
    }
}
$sorted=@($elapsed|Sort-Object)
function Percentile($q){if($sorted.Count){return $sorted[[int][Math]::Ceiling($q*$sorted.Count)-1]}}
[pscustomobject]@{runs=$Runs;verified=$elapsed.Count;failed=$failed;verified_model_calls=$calls;memory_hits=$hits;p50_ms=(Percentile .50);p95_ms=(Percentile .95)}
if($failed){throw 'Notepad acceptance failed'}
