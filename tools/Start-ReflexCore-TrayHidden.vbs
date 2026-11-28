Option Explicit
Dim shell, files, launcher, ps, quote
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
quote = Chr(34)
launcher = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "ReflexCore-Tray.ps1")
ps = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
shell.Run quote & ps & quote & " -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & quote & launcher & quote, 0, False
