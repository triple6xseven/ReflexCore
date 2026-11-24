#requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$Godot,
    [Parameter(Mandatory)][string]$AvatarDirectory,
    [Parameter(Mandatory)][string]$Net48,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=[IO.Directory]::CreateDirectory($OutputDirectory).FullName
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('ReflexCore-package-'+[guid]::NewGuid().ToString('N'))
$payload=Join-Path $scratch 'ReflexCore'
$signature=Get-AuthenticodeSignature -LiteralPath $Net48
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Microsoft Corporation*'){
    throw 'The .NET Framework redistributable needs a valid Microsoft signature.'
}
[void][IO.Directory]::CreateDirectory($payload)
function Put([string]$Source,[string]$Relative){
    $target=Join-Path $scratch $Relative
    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    Copy-Item -LiteralPath $Source -Destination $target
}
function Assert-Exit([string]$Step){
    if($LASTEXITCODE -ne 0){throw "$Step failed with code $LASTEXITCODE"}
}
Push-Location $root
try {
    cargo build --release --locked
    Assert-Exit 'Rust build'
    dotnet build ui/ReflexCore.Studio.csproj -c Release --nologo
    Assert-Exit 'Studio build'
    $files=git ls-files
    Assert-Exit 'Source inventory'
    foreach($name in $files){
        if($name -match '^(tools|companion3d|examples|tasks|docs|games|assets|src|ui|packaging|sandbox)/' -or $name -in @('LICENSE','README.md','CHANGELOG.md','Cargo.toml','Cargo.lock')){
            Put (Join-Path $root $name) "ReflexCore/$name"
        }
    }
    $dependencies=cargo metadata --format-version 1 --locked --offline | ConvertFrom-Json
    Assert-Exit 'Rust dependency inventory'
    foreach($crate in $dependencies.packages){
        if(!$crate.source){continue}
        $sourceFolder=Split-Path $crate.manifest_path -Parent
        foreach($license in (Get-ChildItem -LiteralPath $sourceFolder -File | Where-Object Name -match '^(LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE|UNLICENSE)')){
            Put $license.FullName "ReflexCore/runtime/licenses/$($crate.name)-$($crate.version)/$($license.Name)"
        }
    }
    Put 'target/release/reflexcore.exe' 'ReflexCore/target/release/reflexcore.exe'
    Put 'ui/bin/Release/net48/ReflexCore.Studio.dll' 'ReflexCore/ui/bin/Release/net48/ReflexCore.Studio.dll'
    Put $Godot 'ReflexCore/runtime/Godot.exe'
    Put $Net48 'Prerequisites/net48.exe'
    foreach($name in @('avatar.vrm','avatar-bare-legs.vrm','avatar-zxc.vrm','avatar-zxc-stockings.vrm')){
        Put (Join-Path $AvatarDirectory $name) "ReflexCore/data/companion3d/$name"
    }
    $defaults='{"edition":"zxc","zoom":1.0,"mode":"roam","midnight_stockings":true,"legwear_den":40,"legwear_color":"white","top":true,"fullscreen_overlay":true,"bubble":true,"bubble_style":"glass","app_start":true}'
    [IO.File]::WriteAllText((Join-Path $payload 'data/companion3d/settings.json'),$defaults)
    [IO.File]::WriteAllText((Join-Path $payload 'portable.flag'),'ReflexCore')
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/godotengine/godot/4.7.2-stable/COPYRIGHT.txt' -OutFile (Join-Path $payload 'runtime/THIRD-PARTY.txt')
    Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/godotengine/godot/4.7.2-stable/LICENSE.txt' -OutFile (Join-Path $payload 'runtime/LICENSE-GODOT.txt')
    $compiler=Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    $launcher=Join-Path $payload 'ReflexCore.exe'
    $icon=Join-Path $root 'assets/reflexcore.ico'
    & $compiler /nologo /target:winexe /reference:System.Windows.Forms.dll "/win32icon:$icon" "/out:$launcher" (Join-Path $root 'tools\ReflexCore-Launcher.cs')
    Assert-Exit 'Launcher build'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=Join-Path $out 'ReflexCore-Portable-win-x64.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($scratch,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
    $setup=Join-Path $out 'ReflexCore-Setup-win-x64.exe'
    & $compiler /nologo /target:winexe /reference:System.Windows.Forms.dll /reference:Microsoft.CSharp.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll "/win32icon:$icon" "/out:$setup" "/resource:$zip,ReflexCore.Payload.zip" (Join-Path $root 'packaging\ReflexCore-Setup.cs')
    Assert-Exit 'Setup build'
    Get-FileHash $zip,$setup | ForEach-Object {"$($_.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($_.Path))"} |
        Set-Content -Encoding ascii (Join-Path $out 'SHA256SUMS.txt')
    Write-Output "Staged payload: $scratch"
} finally {
    Pop-Location
}
