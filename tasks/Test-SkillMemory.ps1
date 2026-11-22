$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/ReflexCore-SkillMemory.ps1')
$dir=Join-Path ([IO.Path]::GetTempPath()) ('ReflexCore-Memory-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$path=Join-Path $dir 'test.json'
try{
    if(Read-VerifiedSkill $path 'modern'){throw 'Missing memory treated as a hit'}
    Save-VerifiedSkill $path modern value $null
    $known=Read-VerifiedSkill $path modern
    if($known.successes -ne 1){throw 'First verification missing'}
    Save-VerifiedSkill $path modern value $known
    if((Read-VerifiedSkill $path modern).successes -ne 2){throw 'Verified count mismatch'}
    if(Read-VerifiedSkill $path classic){throw 'Wrong family accepted'}
    $valid=[IO.File]::ReadAllText($path)
    $bad=@('{',('x'*1030),$valid.Replace('ordinal_disk_readback','trust_model'),$valid.Replace('"value"','"command"'),$valid.Replace('"successes":2','"successes":true'),$valid.Replace('{','{"extra":"unknown",'))
    foreach($test in $bad){
        [IO.File]::WriteAllText($path,$test)
        if(Read-VerifiedSkill $path modern){throw 'Malformed memory accepted'}
    }
    Write-Host '[ReflexCore] Skill memory round-trip, replacement, family and malformed cases passed.'
}finally{
    if([IO.File]::Exists($path)){[IO.File]::Delete($path)}
    [IO.Directory]::Delete($dir,$false)
}
