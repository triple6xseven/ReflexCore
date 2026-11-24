#requires -Version 5.1
[CmdletBinding()]
param([switch]$AutoStart,[switch]$Match,[switch]$SelfTest,[ValidatePattern('^de_[a-z0-9_]{1,29}$')][string]$Map)

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $PSScriptRoot 'ReflexCore-CS16Practice.cs') -ReferencedAssemblies @(
    'System.Windows.Forms.dll','System.Drawing.dll','System.Core.dll','System.Web.Extensions.dll'
)
if($SelfTest){
    [ReflexCore.Practice.PracticePanel]::SelfTest()
    exit 0
}
if($Map -and $Match){throw '-Map is for the automatic plant drill'}
[ReflexCore.Practice.PracticePanel]::Run($root,[bool]$AutoStart,[bool]$Match,$Map)
