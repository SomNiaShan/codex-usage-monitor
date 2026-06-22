param(
    [string]$ShortcutName = "Codex Usage Monitor",
    [switch]$Remove
)

$ErrorActionPreference = "Stop"

$scriptDirectory = if ($PSScriptRoot) {
    $PSScriptRoot
}
else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

$launcherPath = Join-Path $scriptDirectory "Launch-CodexUsageMonitor.vbs"
$iconPath = Join-Path $scriptDirectory "assets\codex-usage-monitor.ico"
$desktopPath = [Environment]::GetFolderPath("Desktop")
$shortcutPath = Join-Path $desktopPath ($ShortcutName + ".lnk")

if ($Remove) {
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Host "Removed shortcut: $shortcutPath"
    }
    else {
        Write-Host "Shortcut not found: $shortcutPath"
    }
    return
}

if (-not (Test-Path -LiteralPath $launcherPath)) {
    throw "Launcher not found: $launcherPath"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "$env:WINDIR\System32\wscript.exe"
$shortcut.Arguments = "`"$launcherPath`""
$shortcut.WorkingDirectory = $scriptDirectory
$shortcut.IconLocation = if (Test-Path -LiteralPath $iconPath) {
    $iconPath
}
else {
    "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe,0"
}
$shortcut.Description = "Floating Codex usage quota monitor"
$shortcut.Save()

Write-Host "Created shortcut: $shortcutPath"
