@echo off
set "SCRIPT_DIR=%~dp0"
start "" powershell.exe -WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%CodexUsageMonitor.ps1"
