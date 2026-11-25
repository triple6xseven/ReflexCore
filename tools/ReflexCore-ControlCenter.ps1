param([switch]$SelfTest,[switch]$UiSmoke,[ValidateSet('Agent','Models','Diagnostics')][string]$InitialTab='Agent')
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
if (Test-Path -LiteralPath (Join-Path $root "portable.flag")) {
    $env:REFLEXCORE_COMPANION_DIRECTORY = Join-Path $root "data/companion3d"
}
try {
    if (-not $SelfTest -and -not $UiSmoke) {
        try { & (Join-Path $root 'tools\Ensure-ReflexCore-Tray.ps1') }
        catch { Write-Warning 'Tray not started; main UI will still open.' }
    }
    # Combine existing native WinForms implementations into ONE in-process UI assembly.
    $parts=@('ReflexCore-ControlCenter.cs','ReflexCore-Diagnostics.cs','ReflexCore-ModelPanel.cs','ReflexCore-UnifiedShell.cs','ReflexCore-ThemePalettes.cs','ReflexCore-Queue.cs','ReflexCore-MenuStyle.cs','ReflexCore-HandoffDraft.cs','ReflexCore-ExtensionRename.cs','ReflexCore-FolderWorkflow.cs','ReflexCore-SharedControl.cs')
    $sources=@($parts|ForEach-Object{[IO.File]::ReadAllText((Join-Path $root ('tools\'+$_)))})
    $tail=$sources | Select-Object -Skip 1 | ForEach-Object { [regex]::Replace($_,'(?m)^using\s+[A-Za-z0-9_.]+;\s*\r?\n','') }
    $imports="using System.Net.Http;`nusing System.Collections.Generic;`nusing System.Linq;`nusing System.Threading.Tasks;`nusing System.Web.Script.Serialization;`n"
    $source=$imports+$sources[0]+"`n"+($tail -join "`n")
    $project=Join-Path $root 'ui\ReflexCore.Studio.csproj'
    $studio=Join-Path $root 'ui\bin\Release\net48\ReflexCore.Studio.dll'
    if(!(Test-Path -LiteralPath $studio)){
        & dotnet build $project -c Release --nologo
        if($LASTEXITCODE -ne 0){throw 'WPF Studio build failed'}
    }
    $refs=@('System.Windows.Forms.dll','System.Drawing.dll','System.Core.dll','System.Security.dll','System.Net.Http.dll','System.Web.Extensions.dll')
    foreach($name in 'WindowsBase','PresentationCore','PresentationFramework','System.Xaml','WindowsFormsIntegration'){
        $loaded=Add-Type -AssemblyName $name -PassThru
        $refs+=($loaded | Select-Object -First 1).Assembly.Location
    }
    [void][Reflection.Assembly]::LoadFrom($studio)
    $refs+=$studio
    Add-Type -TypeDefinition $source -ReferencedAssemblies $refs -ErrorAction Stop
    if($UiSmoke){
        [ReflexCore.Control.Center]::Smoke($root)
        exit 0
    }
    if($SelfTest){
        [ReflexCore.Control.Center]::SelfTest($root)
        [ReflexCore.Control.ShellModernizer]::SelfTest()
        [ReflexCore.Control.ModelPanel]::SelfTest($root)
        [ReflexCore.Diagnostics.Dashboard]::SelfTest($root)
        exit 0
    }
    [ReflexCore.Control.Center]::Run($root,$InitialTab)
} catch {
    $path=Join-Path $root 'data\bridge\control-center-error.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent)|Out-Null
    [IO.File]::WriteAllText($path,$_.Exception.ToString())
    Write-Error $_
    exit 1
}
