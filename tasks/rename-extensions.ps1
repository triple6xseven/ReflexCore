$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$bridge=Join-Path $project 'data/bridge'
$manifest=$env:REFLEXCORE_QUEUE_MANIFEST
if($manifest -cnotmatch '\A[0-9]{17}-[0-9a-f]{32}\.job\z'){exit 1}
$id=[IO.Path]::GetFileNameWithoutExtension($manifest)
$claim=Join-Path $bridge ('running/'+$manifest)
$cancelPath=Join-Path $bridge ('queue-requests/'+$id+'.cancel')
$cancel=[Func[bool]]{ return (![IO.File]::Exists($claim) -or [IO.File]::Exists($cancelPath)) }
$count=0
$errorText=''
$outcome='failed'
$verification='not_confirmed'
$reason='precondition_failed'
try {
    $inputFile=Get-Item -LiteralPath (Join-Path $project "data/private/handoff/$id.json")
    if($inputFile.Length -gt 32768 -or ($inputFile.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid rename input'}
    $job=[IO.File]::ReadAllText($inputFile.FullName) | ConvertFrom-Json
    if($cancel.Invoke()){throw 'Cancelled'}
    Add-Type -Path (Join-Path $project 'tools/ReflexCore-ExtensionRename.cs') -ReferencedAssemblies System.Web.Extensions.dll
    $plan=[ReflexCore.Control.ExtensionRename]::Preview($job.folder,$job.source,$job.destination)
    if($plan.Entries.Count -eq 0 -or $plan.Fingerprint() -cne $job.fingerprint){throw 'Approval no longer matches'}
    if($job.guard){
        if($job.guard.folder -cne $job.folder -or $job.guard.checklist_sha256 -cnotmatch '\A[0-9a-fA-F]{64}\z'){throw 'Invalid verification guard'}
        $testReport=Join-Path $inputFile.DirectoryName ($id+"."+[guid]::NewGuid().ToString("N")+".guard.json")
        if(Test-Path -LiteralPath $testReport){throw 'Guard output already exists'}
        $createdGuardReport=$false
        try {
            Remove-Item Env:REFLEXCORE_QUEUE_MANIFEST
            $env:REFLEXCORE_GUARD_MANIFEST=$manifest
            $result=& (Join-Path $project 'target/release/reflexcore.exe') handoff $job.folder $job.guard.checklist $testReport --checklist-sha256 $job.guard.checklist_sha256
            $exit=$LASTEXITCODE
            $createdGuardReport=[IO.File]::Exists($testReport)
            if($exit -ne 0){throw 'Guard did not verify'}
            $guardReceipt=$result | ConvertFrom-Json
            if($guardReceipt.stage -cne 'handoff' -or $guardReceipt.outcome -cne 'verified' -or !$guardReceipt.handoff.ready){throw 'Required files no longer ready'}
        } finally {
            $env:REFLEXCORE_QUEUE_MANIFEST=$manifest
            Remove-Item Env:REFLEXCORE_GUARD_MANIFEST -ErrorAction SilentlyContinue
            if($createdGuardReport){[IO.File]::Delete($testReport)}
        }
    }
    $reason='infrastructure_error'
    if($plan.ApplyQueued([ReflexCore.Control.ExtensionRename]::JournalDirectory,$id,$cancel,[ref]$count,[ref]$errorText)){
        $outcome='verified';$verification='verified';$reason='rename_completed'
    }
} catch {
    # Keep paths and exception details out of shared receipts.
}
if($outcome -cne 'verified'){
    if($cancel.Invoke()){$outcome='cancelled';$reason='operator_cancelled'}
    elseif($count -gt 0){$outcome='partial';$reason='rename_partial'}
}
$receipt=@{schema='reflexcore.task.receipt.v1';task_id=$id;run_id=$id;stage='rename';outcome=$outcome;
           verification=$verification;reason=$reason;renamed=$count}
if([IO.File]::Exists($claim)){
    $dest=Join-Path $bridge "running/$id.receipt.json"
    $tempReceipt=$dest+'.tmp'
    [IO.File]::WriteAllText($tempReceipt,($receipt|ConvertTo-Json -Compress))
    [IO.File]::Move($tempReceipt,$dest)
}
if($outcome -ceq 'verified'){exit 0}
if($outcome -ceq 'cancelled'){exit 2}
exit 1
