@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Data\hebet-update.ps1" -Source "%~dp0." -PickTarget
pause
