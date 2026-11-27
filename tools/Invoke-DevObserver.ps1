#Requires -Version 5.1
param([ValidateSet('Install','Run')][string]$Action='Run',[string[]]$ObserverArgs)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $root
try {
    $private=& git rev-parse --absolute-git-dir
    if($LASTEXITCODE){throw 'Worktree unavailable'}
    $dir=Join-Path $private 'reflex-observer'
    $pointer=Join-Path $dir 'active-v2'
    if($Action -eq 'Install'){
        & cargo build --locked --release --bin reflex-observer
        if($LASTEXITCODE){throw 'Observer build failed'}
        $source=Join-Path $root 'target/release/reflex-observer.exe'
        $hash=(Get-FileHash $source).Hash
        [void][IO.Directory]::CreateDirectory($dir)
        $dest=Join-Path $dir ($hash+'.exe')
        if(!(Test-Path -LiteralPath $dest)){[IO.File]::Copy($source,$dest,$false)}
    } else {
        if(!(Test-Path -LiteralPath $pointer)){throw 'Observer not installed'}
        $hash=[IO.File]::ReadAllText($pointer)
        if($hash -cnotmatch '^[A-F0-9]{64}$'){throw 'Observer pointer invalid'}
        $dest=Join-Path $dir ($hash+'.exe')
    }
    $pin=[IO.File]::Open($dest,'Open','Read','Read')
    try {
        if((Get-FileHash $dest).Hash -cne $hash){throw 'Observer hash mismatch'}
        if($Action -eq 'Install'){
            if((& $dest protocol) -cne 'reflex.observer.2' -or $LASTEXITCODE){throw 'Incompatible observer'}
            $tmp=$pointer+'.'+[guid]::NewGuid().ToString('N')
            [IO.File]::WriteAllText($tmp,$hash)
            if([IO.File]::Exists($pointer)){[IO.File]::Replace($tmp,$pointer,($pointer+'.previous'))}
            else{[IO.File]::Move($tmp,$pointer)}
        } else {
            & $dest @ObserverArgs
            if($LASTEXITCODE){throw 'Recovery observer unavailable'}
        }
    } finally {$pin.Dispose()}
} finally {Pop-Location}
