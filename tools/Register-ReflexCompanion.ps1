#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Godot,
    [string]$Avatar,
    [string]$BareLegsAvatar
)
$ErrorActionPreference='Stop'
$runtime=(Resolve-Path -LiteralPath $Godot).ProviderPath
if([IO.Path]::GetFileName($runtime) -notmatch '^Godot.*\.exe$' -or
   !(Test-Path -LiteralPath $runtime -PathType Leaf)){
    throw 'Choose the Godot 4 Windows executable.'
}
$folder=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ReflexCore\companion3d'
[void][IO.Directory]::CreateDirectory($folder)
function Install-Avatar([string]$Source,[string]$Name){
    if(!$Source){return}
    $model=Get-Item -LiteralPath (Resolve-Path -LiteralPath $Source).ProviderPath
    if($model.Extension -notin '.vrm','.glb' -or $model.Length -le 20 -or $model.Length -gt 100MB){
        throw 'Choose a local rigged VRM or GLB of up to 100 MiB.'
    }
    $target=Join-Path $folder ($Name+$model.Extension.ToLowerInvariant())
    if([IO.File]::Exists($target)){
        if((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $model.FullName).Hash){
            throw 'The default avatar already exists. Choose the new avatar from Studio to keep both.'
        }
    }else{[IO.File]::Copy($model.FullName,$target,$false)}
}
Install-Avatar $Avatar 'avatar'
Install-Avatar $BareLegsAvatar 'avatar-bare-legs'
$registration=Join-Path $folder 'runtime-exe.txt'
$temporary=$registration+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
[IO.File]::WriteAllText($temporary,$runtime,[Text.UTF8Encoding]::new($false))
if([IO.File]::Exists($registration)){[IO.File]::Replace($temporary,$registration,[NullString]::Value)}
else{[IO.File]::Move($temporary,$registration)}
Write-Output 'ReflexCompanion is registered. Open Companion & Widgets in ReflexCore Studio.'
