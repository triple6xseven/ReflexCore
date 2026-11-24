$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $root 'tools/ReflexCore-ExtensionRename.cs') -ReferencedAssemblies System.Web.Extensions.dll
function Require($condition,$message) { if (!$condition) { throw $message } }
$ru = 'Поменяй расширения всех файлов на .log'
[string]$source = ''; [string]$destination = ''
Require ([ReflexCore.Control.ExtensionRename]::TryParse($ru,[ref]$source,[ref]$destination)) 'Russian request rejected'
Require ($source -eq '' -and $destination -eq '.log') 'Wrong Russian extensions'
Require ([ReflexCore.Control.ExtensionRename]::TryParse('Change the extensions of all files from .txt to .log.',[ref]$source,[ref]$destination)) 'English request rejected'
Require ($source -eq '.txt' -and $destination -eq '.log') 'Wrong English extensions'
Require (![ReflexCore.Control.ExtensionRename]::TryParse('Change extensions to ../log',[ref]$source,[ref]$destination)) 'Unsafe extension accepted'

$temp = [IO.Path]::GetTempPath()
$fixture = Join-Path $temp ('ReflexRename-'+[guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'nested'))
    $history = Join-Path $fixture 'history'
    $unicode = ([char]0x96ea).ToString()
    [IO.File]::WriteAllText((Join-Path $fixture "$unicode.txt"),'unicode content')
    [IO.File]::WriteAllText((Join-Path $fixture 'nested/child.txt'),'nested')
    [IO.File]::WriteAllText((Join-Path $fixture 'README'),'extensionless')
    [IO.File]::WriteAllText((Join-Path $fixture 'notes.csv'),'csv content')
    [IO.File]::WriteAllText((Join-Path $fixture 'notes.log'),'existing')
    try {
        [void][ReflexCore.Control.ExtensionRename]::Preview($fixture,'','.log')
        throw 'Expected collision'
    } catch {
        if ($_.Exception.ToString() -notmatch 'destination name already exists') { throw }
    }

    $plan = [ReflexCore.Control.ExtensionRename]::Preview($fixture,'.txt','.log')
    Require ($plan.Entries.Count -eq 1 -and $plan.Entries[0].After -ceq "$unicode.log") 'Incorrect filtered preview'
    Require ([IO.File]::Exists((Join-Path $fixture "$unicode.txt"))) 'Preview modified source'
    [IO.File]::WriteAllText((Join-Path $fixture "$unicode.log"),'late arrival')
    [int]$count = -1; [string]$errorText = ''
    Require (!$plan.Apply($history,[ref]$count,[ref]$errorText) -and $count -eq 0) 'Stale plan applied'
    Require ([IO.File]::ReadAllText((Join-Path $fixture "$unicode.log")) -ceq 'late arrival') 'Existing file overwritten'
    [IO.File]::Delete((Join-Path $fixture "$unicode.log"))
    $blockedLog = Join-Path $fixture 'notes.log'
    Require (!$plan.Apply($blockedLog,[ref]$count,[ref]$errorText) -and $count -eq 0) 'Rename started with an unwritable history location'
    Require ([IO.File]::ReadAllText((Join-Path $fixture "$unicode.txt")) -ceq 'unicode content') 'Source changed without a journal'
    Require ($plan.Apply($history,[ref]$count,[ref]$errorText) -and $count -eq 1) 'Rename failed'
    Require (![IO.File]::Exists((Join-Path $fixture "$unicode.txt"))) 'Original name still present'
    Require ([IO.File]::ReadAllText((Join-Path $fixture "$unicode.log")) -ceq 'unicode content') 'File contents changed'
    [IO.File]::Delete((Join-Path $fixture 'notes.log'))
    $all = [ReflexCore.Control.ExtensionRename]::Preview($fixture,'','.bin')
    Require ($all.Apply($history,[ref]$count,[ref]$errorText) -and $count -eq 3) 'All-files rename failed'
    Require ([IO.File]::Exists((Join-Path $fixture 'README.bin'))) 'Extensionless file skipped'
    Require ([IO.File]::ReadAllText((Join-Path $fixture 'nested/child.txt')) -ceq 'nested') 'Nested file changed'
    $runLogs = @(Get-ChildItem -LiteralPath $history -Filter '*.jsonl')
    Require ($runLogs.Count -eq 3) 'Wrong number of run logs'
    $records = @(foreach ($runLog in $runLogs) {
        foreach ($line in [IO.File]::ReadLines($runLog.FullName)) { $line | ConvertFrom-Json }
    })
    Require (@($records | Where-Object action -eq 'stopped').Count -eq 1) 'Stale plan was not logged'
    Require (($records | Where-Object action -eq 'renamed').Count -eq 4) 'Missing completed renames'
    $moved = @($records | Where-Object { $_.action -eq 'renamed' -and $_.before -ceq "$unicode.txt" })
    Require ($moved.Count -eq 1 -and $moved[0].after -ceq "$unicode.log" -and $moved[0].utc) 'Unicode name or timestamp missing'
    $first = Join-Path $fixture 'aaa.txt'
    $locked = Join-Path $fixture 'zzz.txt'
    [IO.File]::WriteAllText($first,'first')
    [IO.File]::WriteAllText($locked,'locked')
    $partial = [ReflexCore.Control.ExtensionRename]::Preview($fixture,'.txt','.bak')
    $lock = [IO.File]::Open($locked,'Open','Read','Read')
    try {
        Require (!$partial.Apply($history,[ref]$count,[ref]$errorText) -and $count -eq 1) 'Partial rename result was wrong'
    } finally { $lock.Dispose() }
    Require ([IO.File]::ReadAllText((Join-Path $fixture 'aaa.bak')) -ceq 'first') 'Renamed content lost'
    Require ([IO.File]::ReadAllText($locked) -ceq 'locked') 'Locked content lost'
    Require (![IO.File]::Exists((Join-Path $fixture 'zzz.bak'))) 'Failed move produced a destination'
    'Extension rename passed English and Russian parsing, preview, collisions, Unicode, filtering, fail-closed journaling and partial failure with no data loss.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ceq $temp.TrimEnd('\') -and
        [IO.Path]::GetFileName($resolved) -cmatch '^ReflexRename-[a-f0-9]{32}$' -and [IO.Directory]::Exists($resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
