# Uses the local vision model selected in Studio and the same independent disk verifier.
$ErrorActionPreference='Stop'
$tool=Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/ReflexCore-VisionLoop.ps1'
$result=& $tool -Action DemoNotepad -AllowInput -Route Visual
if(!$result.verified -or $result.schema -cne 'reflexcore.notepad.result.v1'){throw 'Notepad disk verification missing'}
& (Join-Path (Split-Path $tool -Parent) 'ReflexCore-NotepadReceipt.ps1')
