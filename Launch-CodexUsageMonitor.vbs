Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
appScriptPath = fso.BuildPath(fso.BuildPath(scriptDir, "app"), "CodexUsageMonitor.ps1")
rootScriptPath = fso.BuildPath(scriptDir, "CodexUsageMonitor.ps1")

If fso.FileExists(appScriptPath) Then
    scriptPath = appScriptPath
Else
    scriptPath = rootScriptPath
End If

command = "powershell.exe -WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & scriptPath & Chr(34)

shell.Run command, 0, False
