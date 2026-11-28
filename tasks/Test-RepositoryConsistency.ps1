#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    $files=@(& git ls-files)
    if($LASTEXITCODE){throw 'Tracked file inventory unavailable'}
    foreach($file in $files | Where-Object {$_ -like '*.md'}){
        $body=[IO.File]::ReadAllText((Join-Path $root $file))
        foreach($match in [regex]::Matches($body,'\[[^\]\r\n]*\]\(([^\s)]+)\)')){
            $uri=$match.Groups[1].Value
            if($uri -match '^([a-z]+:|//|#)'){continue}
            $path=[Uri]::UnescapeDataString(($uri -split '#',2)[0])
            $parent=[IO.Path]::GetDirectoryName((Join-Path $root $file))
            if(!(Test-Path -LiteralPath (Join-Path $parent $path))){throw "Broken local link in ${file}: $path"}
        }
    }
    $manifest=Get-Content -Raw plugins/reflexcore/.codex-plugin/plugin.json|ConvertFrom-Json
    if($manifest.version -cnotmatch '^\d+\.\d+\.\d+$' -or $manifest.skills -cne './skills/'){throw 'Invalid local plugin manifest'}
    foreach($skill in 'reflex-resume','reflex-continue','reflex-validate','release-check','offline-lab-evidence'){
        $file="plugins/reflexcore/skills/$skill/SKILL.md"
        if($files -cnotcontains $file -or (Get-Content -Raw -LiteralPath $file) -cnotmatch "(?m)^name: $skill\r?$"){throw "Invalid skill file: $skill"}
    }
    if($files -match '^(data|target|backups)/|(^|/)\.env($|\.)'){throw 'Unexpected tracked local runtime data'}
    $directory=Get-Content -Raw docs/engineering-knowledge.json|ConvertFrom-Json
    if($directory.schema -ne 2){throw 'Expected the versioned knowledge directory'}
    foreach($group in $directory.routes|Group-Object shard){
        $path='docs/knowledge/'+$group.Name+'.json'
        if($group.Name -cnotmatch '^[a-z0-9-]+$' -or $files -cnotcontains $path){throw 'Unknown engineering knowledge shard'}
        $catalog=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json
        if($catalog.schema -ne 1){throw 'Unknown knowledge shard version'}
        $seen=@{}
        foreach($record in $catalog.records){
            $scope=$record.component+'/'+$record.topic
            if($seen.ContainsKey($record.id) -or ($record.supersedes -and $seen[$record.supersedes] -cne $scope)){throw "Invalid supersession in $path"}
            if(!($group.Group | Where-Object {($_.component+'/'+$_.topic) -ceq $scope})){throw "Missing route in $path"}
            $seen[$record.id]=$scope
        }
        foreach($route in $group.Group){
            if($seen.Values -cnotcontains ($route.component+'/'+$route.topic)){throw "Route has no record in $path"}
        }
    }
    'PASS: local documentation targets, plugin skills, private data exclusions and knowledge routes.'
}finally{Pop-Location}
