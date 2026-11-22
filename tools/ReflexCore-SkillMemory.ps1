# One bounded document per editor family, serialized by the VisionLoop mutex.
# The descriptor identifies a built-in operation. Stored data never supplies executable input.
function Read-VerifiedSkill([string]$path,[string]$family) {
    if($family -notin 'modern','classic' -or ![IO.File]::Exists($path)){return $null}
    try {
        if(([IO.FileInfo]$path).Length -gt 1024){return $null}
        $s=[IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        if(@($s.PSObject.Properties).Count -ne 7){return $null}
        if($s.schema -cne 'reflexcore.skill.v1' -or $s.family -cne $family -or
           $s.permission -cne 'explicit_foreground_owned_notepad' -or $s.effect -cne 'save_new_file' -or
           $s.verifier -cne 'ordinal_disk_readback' -or $s.method -cnotin 'value','native' -or
           ($s.successes -isnot [int] -and $s.successes -isnot [long]) -or [long]$s.successes -lt 1 -or [long]$s.successes -gt 1000000){return $null}
        return $s
    } catch {return $null}
}
function Save-VerifiedSkill([string]$path,[string]$family,[string]$method,$previous) {
    if($family -cnotin 'modern','classic'){return}
    if($method -cnotin 'value','native'){throw 'Invalid built-in method'}
    $count=1
    if($previous -and $previous.method -ceq $method){$count=[Math]::Min(1000000,[long]$previous.successes+1)}
    $s=[ordered]@{schema='reflexcore.skill.v1';family=$family;permission='explicit_foreground_owned_notepad';method=$method;effect='save_new_file';verifier='ordinal_disk_readback';successes=$count}
    $tmp=$path+'.reflex-tmp-'+[guid]::NewGuid().ToString('N')
    $backup=$tmp+'.old'
    try {
        [IO.File]::WriteAllText($tmp,($s | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,$backup)}
        else{[IO.File]::Move($tmp,$path)}
    } finally {
        foreach($f in @($tmp,$backup)){if([IO.File]::Exists($f)){[IO.File]::Delete($f)}}
    }
}
