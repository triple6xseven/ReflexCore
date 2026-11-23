#requires -Version 5.1
[CmdletBinding()]
param([switch]$AutoStart,[switch]$SelfTest)

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $PSScriptRoot 'ReflexCore-CS16Practice.cs') -ReferencedAssemblies @(
    'System.Windows.Forms.dll','System.Drawing.dll','System.Core.dll','System.Web.Extensions.dll'
)
if($SelfTest){
    [ReflexCore.Practice.PracticePanel]::SelfTest()
    exit 0
}
[ReflexCore.Practice.PracticePanel]::Run($root,[bool]$AutoStart)
