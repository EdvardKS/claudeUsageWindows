' Launches tray.ps1 with no console window at all.
' Started by the HKCU Run entry that install.cmd creates.
Option Explicit

Dim shell, fso, here, script
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "tray.ps1")

If Not fso.FileExists(script) Then
    WScript.Quit 1
End If

' 0 = hidden window, False = do not wait for it to finish.
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & script & """", 0, False
