# The tray passes only a previously claimed local manifest, never caller-supplied script arguments.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,100}\.job$')][string]$Manifest)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bridge=Join-Path $root 'data/bridge'
$claim=Join-Path (Join-Path $bridge 'running') $Manifest
$cancel=Join-Path (Join-Path $bridge 'queue-requests') (([IO.Path]::GetFileNameWithoutExtension($Manifest))+'.cancel')
$lane=[Threading.Mutex]::new($false,'Local\ReflexCoreQueuedDesktop')
$held=$false
try {
    while(!$held){
        if(![IO.File]::Exists($claim) -or [IO.File]::Exists($cancel)){exit 2}
        try{$held=$lane.WaitOne(200)}catch [Threading.AbandonedMutexException]{$held=$true}
    }
    if(![IO.File]::Exists($claim) -or [IO.File]::Exists($cancel)){exit 2}
    $file=Get-Item -LiteralPath $claim
    if($file.Length -gt 256 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid queue claim'}
    $lines=[IO.File]::ReadAllLines($claim)
    if($lines.Count -ne 2 -or $lines[0] -cnotin 'RUN','REVIEW' -or $lines[1] -cnotmatch '^[a-zA-Z0-9_-]{1,70}\.ps1$'){throw 'Invalid queue manifest'}
    $script=Join-Path (Join-Path $root 'tasks') $lines[1]
    if((Get-Item -LiteralPath $script).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Invalid task link'}
    $env:REFLEXCORE_QUEUE_MANIFEST=$Manifest
    $global:LASTEXITCODE=0
    & $script
    if(!$?){exit 1}
    exit $LASTEXITCODE
}finally{
    if($held){$lane.ReleaseMutex()}
    $lane.Dispose()
}
