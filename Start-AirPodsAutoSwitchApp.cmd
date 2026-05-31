@echo off
set "SCRIPT_DIR=%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT_DIR%AirPodsAutoSwitchApp.ps1"
