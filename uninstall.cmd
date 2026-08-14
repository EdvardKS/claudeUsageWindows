@echo off
REM Stops the app and removes the autostart entry. Leaves the files in place.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Uninstall
pause
