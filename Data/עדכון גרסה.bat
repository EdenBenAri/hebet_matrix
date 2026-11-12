@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hebet-update.ps1" -Source "%~1"
pause
