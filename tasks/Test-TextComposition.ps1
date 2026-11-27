[CmdletBinding()]
param([switch]$AllowInput,[switch]$Chain)
$ErrorActionPreference='Stop'
if(!$AllowInput){throw 'Use -AllowInput on an unlocked Windows desktop.'}
$exe=Join-Path (Split-Path $PSScriptRoot -Parent) 'target/release/reflexcore.exe'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ComposeFocus {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
$grant=@('--create','--verify','--consume','--derive','--publish')
$dir=[IO.Directory]::CreateDirectory((Join-Path ([IO.Path]::GetTempPath()) ('ReflexCompose-'+[guid]::NewGuid().ToString('N'))))
$suffix=([string][char]13+[char]10+[char]0x03bb+[char]::ConvertFromUtf32(0x1F680))
foreach($app in 'winforms','winforms-background','notepad'){
    $dest=Join-Path $dir.FullName ($app+'.txt')
    $more=@()
    $extraArgs=''
    $stepCount=4
    if($Chain){
        $last=Join-Path $dir.FullName ($app+'-final.txt')
        $extraSuffix=[string][char]0x2603+[char]0x0308
        $more=@('--then',$last,$extraSuffix)
        $extraArgs=' --then "'+$last+'" "'+$extraSuffix+'"'
        $stepCount=6
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    if($app -eq 'winforms-background'){
        $before=[ComposeFocus]::GetForegroundWindow()
        if($before -eq [IntPtr]::Zero){throw 'Interactive foreground unavailable'}

        $params='agent compose-text winforms-background "'+$dest+'" "'+$suffix+'"'+$extraArgs+' '+($grant -join ' ')
        $start=[Diagnostics.ProcessStartInfo]::new($exe,$params)
        $start.UseShellExecute=$false
        $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true
        $proc=[Diagnostics.Process]::Start($start)
        $stdout=$proc.StandardOutput.ReadToEndAsync()
        try{
            do{
                if([ComposeFocus]::GetForegroundWindow() -ne $before){throw 'Foreground changed during background execution'}
            }while(!$proc.WaitForExit(30))
            if($proc.ExitCode -ne 0){throw 'Background producer failed'}
            $lines=@($stdout.GetAwaiter().GetResult().TrimEnd() -split "\r?\n")
        }finally{$proc.Dispose()}
    }else{$lines=@(& $exe agent compose-text $app $dest $suffix @more @grant)}
    if($LASTEXITCODE){throw ("Producer or transform failed for "+$app)}
    $receipt=$lines[-1]|ConvertFrom-Json
    if($receipt.schema -cne 'reflexcore.composed_goal.v1' -or $receipt.outcome -cne 'verified' -or $receipt.steps.Count -ne $stepCount){throw 'Invalid terminal receipt'}
    if($app -eq 'notepad'){
        $original=Join-Path $env:LOCALAPPDATA ("ReflexCore/runtime/fixtures/ReflexCore-VisionLoop-"+$receipt.run_id+'.txt')
        $expected='ReflexCore '+[char]0x0416+[char]0x03A9+[char]::ConvertFromUtf32(0x1f600)
    }else{
        $original=Join-Path ([IO.Path]::GetTempPath()) ("ReflexCore-save-"+$receipt.run_id+'/saved.txt')
        $expected='ReflexCore verified 010'
    }
    if([IO.File]::ReadAllText($original) -cne $expected -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($dest)) -cne [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($expected+$suffix))){throw 'Independent content check failed'}
    if($Chain -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($last)) -cne [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($expected+$suffix+$extraSuffix))){throw 'Independent chained content check failed'}
    Write-Output ("{0} verified, {1} ms" -f $app,$clock.ElapsedMilliseconds)
}
