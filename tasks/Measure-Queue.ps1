[CmdletBinding()]
param([ValidateRange(5,100)][int]$Runs=20)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$tempBase=[IO.Path]::GetTempPath()
$fixture=Join-Path $tempBase ('ReflexCore-Submit-'+[Guid]::NewGuid().ToString('N'))
try {
    foreach($dir in 'tools','tasks'){[void][IO.Directory]::CreateDirectory((Join-Path $fixture $dir))}
    $script=Join-Path $fixture 'tools/Submit-ReflexJob.ps1'
    Copy-Item -LiteralPath (Join-Path $root 'tools/Submit-ReflexJob.ps1') -Destination $script
    [IO.File]::WriteAllText((Join-Path $fixture 'tasks/agent-demo.ps1'),'')
    Add-Type -Path (Join-Path $root 'tools/ReflexCore-Queue.cs') -ReferencedAssemblies System.Core.dll,System.Web.Extensions.dll
    $store=[ReflexCore.Bridge.QueueStore]::new($fixture)
    $samples=@{legacy=@();studio=@()}
    # Compilation has already happened when the real Studio UI accepts input.
    for($i=0;$i -le $Runs;$i++){
        $order=if($i%2){'studio','legacy'}else{'legacy','studio'}
        foreach($method in $order){
            $clock=[Diagnostics.Stopwatch]::StartNew()
            if($method -eq 'legacy'){
                & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -Task agent-demo -Run *> $null
                if($LASTEXITCODE){throw 'Legacy submission failed'}
            }else{[void]$store.Submit('agent-demo',$true)}
            $clock.Stop()
            $jobs=@([IO.Directory]::GetFiles((Join-Path $fixture 'data/bridge/pending'),'*.job'))
            if($jobs.Count -ne 1){throw 'Expected one committed manifest'}
            $lines=[IO.File]::ReadAllLines($jobs[0])
            if($lines.Length -ne 2 -or $lines[0] -cne 'RUN' -or $lines[1] -cne 'agent-demo.ps1'){throw 'Wrong manifest'}
            [IO.File]::Delete($jobs[0])
            if($i -gt 0){$samples[$method]+=$clock.Elapsed.TotalMilliseconds}
        }
    }
    foreach($method in 'legacy','studio'){
        $values=@($samples[$method]|Sort-Object)
        [pscustomobject]@{route=$method;verified=$values.Count;p50_ms=[math]::Round($values[[math]::Ceiling($Runs*.50)-1],2);p95_ms=[math]::Round($values[[math]::Ceiling($Runs*.95)-1],2)}
    }
}finally{
    $resolved=(Resolve-Path -LiteralPath $fixture).Path
    if([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ceq $tempBase.TrimEnd('\') -and [IO.Path]::GetFileName($resolved) -cmatch '^ReflexCore-Submit-[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
