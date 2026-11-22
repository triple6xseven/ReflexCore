[CmdletBinding()]
param([Parameter(Mandatory)][string]$Project,[ValidateRange(3,60)][int]$Seconds=8)
$ErrorActionPreference='Stop'
$root=(Resolve-Path -LiteralPath $Project).Path
Add-Type -Path (Join-Path $root 'tools/ReflexCore-Diagnostics.cs') -ReferencedAssemblies @('System.Windows.Forms.dll','System.Drawing.dll','System.Core.dll','System.Web.Extensions.dll')
$form=[ReflexCore.Diagnostics.Dashboard]::new($root)
try {
    foreach($visible in @($false,$true)){
        if($visible){$form.Show()}
        $process=[Diagnostics.Process]::GetCurrentProcess()
        try{
            $watch=[Diagnostics.Stopwatch]::StartNew()
            $start=$process.TotalProcessorTime.TotalMilliseconds
            $peak=0
            while($watch.Elapsed.TotalSeconds -lt $Seconds){
                [Windows.Forms.Application]::DoEvents()
                $process.Refresh()
                $peak=[Math]::Max([long]$peak,$process.WorkingSet64)
                Start-Sleep -Milliseconds 50
            }
            [pscustomobject]@{visible=$visible;seconds=$Seconds;process_cpu_ms=[Math]::Round($process.TotalProcessorTime.TotalMilliseconds-$start);peak_working_set_mib=[Math]::Round($peak/1MB,1)}
        }finally{$process.Dispose()}
    }
}finally{$form.Dispose()}

