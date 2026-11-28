#Requires -Version 5.1
param([switch]$Interactive,[ValidateRange(1,20)][int]$Runs=5)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$exe=(Resolve-Path (Join-Path $repo 'target/release/reflexcore.exe')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('ReflexDiscovery-'+[guid]::NewGuid().ToString('N'))
$tools=[IO.Directory]::CreateDirectory((Join-Path $root 'tools'))
Copy-Item -LiteralPath (Join-Path $repo 'tools/ReflexCore-Fixture.ps1') -Destination $tools.FullName
$descriptor=Get-Content -Raw -LiteralPath (Join-Path $repo 'examples/discover-document-preview.json')
if($Interactive){
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DiscoveryFocus {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
}
function Invoke-Discovery([string]$InputJson,[bool]$Accepted,[string]$Reason){
    $launch=[Diagnostics.ProcessStartInfo]::new($exe,'learning discover')
    $launch.WorkingDirectory=$root
    $launch.UseShellExecute=$false
    $launch.CreateNoWindow=$true
    $launch.RedirectStandardInput=$true
    $launch.RedirectStandardOutput=$true
    $launch.RedirectStandardError=$true
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $foreground=if($Accepted){[DiscoveryFocus]::GetForegroundWindow()}
    $proc=[Diagnostics.Process]::Start($launch)
    try{
        $null=$proc.Handle
        $stdout=$proc.StandardOutput.ReadToEndAsync()
        $stderr=$proc.StandardError.ReadToEndAsync()
        $proc.StandardInput.Write($InputJson)
        $proc.StandardInput.Close()
        $peak=0L
        $focusChanged=$false
        do {
            $proc.Refresh()
            if($Accepted -and [DiscoveryFocus]::GetForegroundWindow() -ne $foreground){$focusChanged=$true}
            if(!$proc.HasExited){
                try{$peak=[Math]::Max($peak,$proc.PrivateMemorySize64)}catch{}
            }
        }while(!$proc.WaitForExit(15) -and $clock.ElapsedMilliseconds -lt 15000)
        if(!$proc.HasExited){throw 'Discovery deadline exceeded'}
        $elapsed=$clock.ElapsedMilliseconds
        $out=$stdout.GetAwaiter().GetResult()
        $errorText=$stderr.GetAwaiter().GetResult()
        if(!$Accepted){
            if($proc.ExitCode -eq 0 -or $out.Trim() -or $errorText -notmatch $Reason){throw ('Invalid candidate was accepted or rejected for the wrong reason: '+$errorText)}
            return
        }
        if($proc.ExitCode){throw $errorText}
        if($focusChanged -or $foreground -eq [IntPtr]::Zero){throw 'Interactive foreground changed or was unavailable'}
        $reply=$out|ConvertFrom-Json
        if($reply.schema -cne 'reflexcore.discovery.candidate.v1' -or $reply.status -cne 'candidate' -or
           $reply.effect_verification -cne 'pending' -or $reply.operation.id -cne 'artifact.verify_saved_text' -or
           $reply.binding_evidence -cne 'owned_window_value_readback_v1' -or !$reply.binding.background -or
           $reply.model_calls -ne 0 -or $reply.inputs.Count -ne 2 -or $reply.capabilities.Count -ne 2){
            throw 'Candidate contract differs'
        }
        [pscustomobject]@{elapsed_ms=$elapsed;root_cpu_ms=$proc.TotalProcessorTime.TotalMilliseconds;
            uia_cpu_us=$reply.observation_metrics.uia_cpu_us;root_sampled_private_bytes=$peak;
            root_and_uia_sampled_private_bytes=$reply.observation_metrics.uia_and_parent_sampled_private_bytes;
            response_bytes=[Text.Encoding]::UTF8.GetByteCount($out)}
    }finally{
        if(!$proc.HasExited){$proc.Kill();[void]$proc.WaitForExit(5000)}
        $proc.Dispose()
    }
}
try{
    $ambiguous=$descriptor.Replace('"applications": ["reflexcore.document-preview-fixture.v1"]','"applications": ["reflexcore.document-preview-fixture.v1", "another"]')
    Invoke-Discovery $ambiguous $false 'one recognized'
    Invoke-Discovery ($descriptor.Replace('document-preview-fixture','unrecognized-fixture')) $false 'one recognized'
    Invoke-Discovery ($descriptor.Replace('"reopen_disk"','"probe_motion"')) $false 'Capability declaration'
    Invoke-Discovery ($descriptor.Replace(', "reopen_disk"','')) $false 'Capability declaration'
    Invoke-Discovery ($descriptor.Replace('bounded_ordinal_disk_readback_v1','unsupported_verifier')) $false 'independent registered verifier'
    Invoke-Discovery ($descriptor -replace ',\s*"verifier": "\w+"','') $false 'missing field'
    Invoke-Discovery (' '*4097) $false 'exceeds 4096'
    if($Interactive){$rows=@(1..$Runs|ForEach-Object {Invoke-Discovery $descriptor $true ''});ConvertTo-Json -InputObject $rows -Compress}
    if(Get-ChildItem -LiteralPath $root -Force|Where-Object Name -ne 'tools'){throw 'Discovery left persistent state in the fixture root'}
    'PASS: seven rejected inputs. Discovery did not persist queue or registry state.'
}finally{
    $owned=[IO.Path]::GetFullPath($root)
    if([IO.Path]::GetDirectoryName($owned) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and
       [IO.Path]::GetFileName($owned) -cmatch '^ReflexDiscovery-[a-f0-9]{32}$'){Remove-Item -LiteralPath $owned -Recurse -Force}
}
