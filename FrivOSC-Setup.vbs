Option Explicit

' Silent, double-click entry point for FrivOSC Setup.  This small PowerShell
' bootstrap asks Windows to elevate the native FrivOSC host; starting an
' administrator-only EXE directly from WScript can otherwise fail silently.
Dim shell, fileSystem, folder, setupScript, arguments
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
folder = fileSystem.GetParentFolderName(WScript.ScriptFullName)
setupScript = folder & "\FrivOSC-Setup.ps1"
arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & setupScript & """"
shell.Run "powershell.exe " & arguments, 0, False
