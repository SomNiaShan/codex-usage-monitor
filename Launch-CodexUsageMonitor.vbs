Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(scriptDir, "CodexUsageMonitor.ps1")
command = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & scriptPath & Chr(34)

shell.Run command, 1, False
