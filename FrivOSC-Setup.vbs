Option Explicit

' Double-click entry point for FrivOSC Setup.
'
' The window is hidden, so PowerShell's own output is redirected to a log.
' Without that, anything that stops the script before its own error handler
' is installed — a parse error, a missing file, a blocked execution policy —
' produces no window, no message, and nothing to look at. That is exactly
' the failure this file is most likely to be blamed for.
Dim shell, fileSystem, folder, setupScript, logPath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
folder = fileSystem.GetParentFolderName(WScript.ScriptFullName)
setupScript = folder & "\FrivOSC-Setup.ps1"
logPath = shell.ExpandEnvironmentStrings("%TEMP%") & "\FrivOSC-Setup-launch.log"

If Not fileSystem.FileExists(setupScript) Then
    MsgBox "FrivOSC-Setup.ps1 was not found next to this file." & vbCrLf & vbCrLf & _
           setupScript, vbCritical, "FrivOSC Setup"
    WScript.Quit 1
End If

command = "cmd.exe /c powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File """ & _
          setupScript & """ > """ & logPath & """ 2>&1"
shell.Run command, 0, False
