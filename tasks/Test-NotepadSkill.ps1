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
        $e=$result.skill
        if($e.run_id -cnotmatch '\A[0-9a-f]{32}\z' -or $e.adapter -cne 'notepad' -or
           $e.skill_id -cne 'artifact.verify_saved_text' -or $e.skill_version -ne 1 -or
           $e.verifier_version -ne 1 -or $e.outcome -cne 'verified'){throw 'Missing bound skill receipt'}
        $folder=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ReflexCore/runtime/fixtures'
        $path=Join-Path $folder ('ReflexCore-VisionLoop-'+$e.run_id+'.txt')
        $expected=if($opts.UnicodeFixture){'ReflexCore '+[char]0x0416+[char]0x03A9+[char]::ConvertFromUtf32(0x1f600)}else{'ReflexCore is operational'}
        if(![string]::Equals([IO.File]::ReadAllText($path),$expected,[StringComparison]::Ordinal)){throw 'External disk check failed'}
        if(!$Visual -and $result.model_calls -ne 0){throw 'Deterministic route called a model'}
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
