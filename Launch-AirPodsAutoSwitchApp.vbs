Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
shell.CurrentDirectory = scriptDir

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File " & Chr(34) & scriptDir & "\AirPodsAutoSwitchApp.ps1" & Chr(34)
shell.Run command, 0, True
