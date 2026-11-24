# Called only after the Notepad adapter verifies the owned file via disk readback.
$ErrorActionPreference='Stop'
$claim=$env:REFLEXCORE_QUEUE_MANIFEST
if(!$claim){return}
if($claim -cnotmatch '^[0-9]{17}-[0-9a-f]{32}\.job$'){throw 'Invalid queue task ID'}
$id=[IO.Path]::GetFileNameWithoutExtension($claim)
$run=[guid]::NewGuid().ToString('N')
$running=Join-Path (Split-Path $PSScriptRoot -Parent) 'data/bridge/running'
if(![IO.File]::Exists((Join-Path $running $claim))){throw 'Queue claim interrupted'}
$record=[ordered]@{schema='reflexcore.task.receipt.v1';task_id=$id;run_id=$run
    stage='notepad';outcome='verified';verification='verified';reason='disk_readback'}
$staging=Join-Path $running "$id.$run.tmp"
try{
    [IO.File]::WriteAllText($staging,($record | ConvertTo-Json -Compress))
    [IO.File]::Move($staging,(Join-Path $running "$id.receipt.json"))
}finally{[IO.File]::Delete($staging)}
