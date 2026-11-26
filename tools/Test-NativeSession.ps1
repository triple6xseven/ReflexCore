# Interactive fault injection against a temporary copy of the owned fixture.
param([switch]$AllowVisibleUI,[ValidateSet('disposable','session')][string]$Worker='session')
$ErrorActionPreference='Stop'
if(!$AllowVisibleUI){throw 'This check needs -AllowVisibleUI and an unlocked Windows desktop.'}
$root=Split-Path $PSScriptRoot -Parent
$exe=(Resolve-Path (Join-Path $root 'target/release/reflexcore.exe')).Path
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('reflex-session-'+[Guid]::NewGuid().ToString('N'))
$job='20261125000000000-'+[Guid]::NewGuid().ToString('N')
$fixture=Join-Path $scratch 'tools/ReflexCore-Fixture.ps1'
$marker=Join-Path $scratch 'entered.txt'
$report=Join-Path $scratch 'data/flow_last_run.json'
$signal=Join-Path $scratch "data/bridge/queue-requests/$job.cancel"
$original=[IO.File]::ReadAllText((Join-Path $root 'tools/ReflexCore-Fixture.ps1'))
$anchor='[System.Windows.Forms.Application]::Run($form)'
if(!$original.Contains($anchor)){throw 'Fixture entry point changed'}
$pause=@'
$script:RcInputBox.Add_TextChanged({
    [IO.File]::AppendAllText('entered.txt','1')
    [Threading.Thread]::Sleep(60000)
})
'@
try {
    foreach($dir in @('tools','data/bridge/running','data/bridge/queue-requests')){
        [void][IO.Directory]::CreateDirectory((Join-Path $scratch $dir))
    }
    [IO.File]::WriteAllText((Join-Path $scratch "data/bridge/running/$job.job"),'')
    foreach($mode in @('cancel','crash','timeout','lost-target','recover')){
        [IO.File]::Delete($signal)
        [IO.File]::Delete($report)
        [IO.File]::Delete($marker)
        $source=if($mode -eq 'recover'){$original}else{$original.Replace($anchor,$pause+[Environment]::NewLine+$anchor)}
        [IO.File]::WriteAllText($fixture,$source)
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$exe
        $info.Arguments='flow demo --execute'
        $info.WorkingDirectory=$scratch
        $info.UseShellExecute=$false
        $info.CreateNoWindow=$true
        $info.EnvironmentVariables['REFLEXCORE_UIA_WORKER']=$Worker
        $info.EnvironmentVariables['REFLEXCORE_QUEUE_MANIFEST']="$job.job"
        $proc=[Diagnostics.Process]::Start($info)
        try {
            $elapsed=[Diagnostics.Stopwatch]::StartNew()
            if($mode -ne 'recover'){
                while(![IO.File]::Exists($marker)){
                    if($proc.HasExited -or $elapsed.Elapsed.TotalSeconds -gt 15){throw "Missing in-flight mutation for $mode"}
                    Start-Sleep -Milliseconds 10
                }
                if($mode -eq 'cancel'){[IO.File]::WriteAllText($signal,'')}
                if($mode -in @('crash','lost-target')){
                    $owned=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id)")
                    $child=if($mode -eq 'crash'){@($owned | Where-Object {$_.ExecutablePath -eq $exe -and $_.CommandLine -match 'uia-(session|act)-worker'})}
                        else{@($owned | Where-Object {$_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'ReflexCore-Fixture.ps1'})}
                    if(@($child).Count -ne 1){throw "Cannot identify the owned child for $mode"}
                    (Get-Process -Id $child.ProcessId -ErrorAction Stop).Kill()
                }
                $elapsed.Restart()
            }
            if(!$proc.WaitForExit(18000)){throw "Supervisor exceeded the test deadline for $mode"}
            $ms=$elapsed.Elapsed.TotalMilliseconds
            $result=[IO.File]::ReadAllText($report)|ConvertFrom-Json
            if($mode -eq 'recover'){
                if($proc.ExitCode -ne 0 -or $result.outcome -ne 'passed' -or $result.steps[-1].verification -ne 'verified'){throw 'Fresh session failed to verify output'}
            }else{
                if($proc.ExitCode -eq 0 -or $result.outcome -eq 'passed' -or $result.steps.Count -ne 1 -or $result.steps[0].attempts -ne 1 -or [IO.File]::ReadAllText($marker) -ne '1'){throw "Invalid failure evidence for $mode"}
                if($mode -eq 'cancel' -and $result.outcome -ne 'cancelled'){throw 'Missing cancellation classification'}
                if($mode -in @('crash','timeout') -and $result.outcome -ne 'completed_unverified'){throw 'Missing effect uncertainty'}
            }
            Write-Host ("{0} {1}: {2}, {3:N1} ms" -f $Worker,$mode,$result.outcome,$ms)
        }finally{
            if(!$proc.HasExited){& taskkill.exe /PID $proc.Id /T /F | Out-Null}
            $proc.Dispose()
        }
    }
}finally{
    if((Split-Path $scratch -Parent) -eq ([IO.Path]::GetTempPath()).TrimEnd('\') -and (Split-Path $scratch -Leaf) -match '^reflex-session-[a-f0-9]{32}$'){
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
