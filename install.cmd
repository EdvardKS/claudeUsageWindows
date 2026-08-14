@echo off
REM Run this once on each PC. No administrator rights needed, no prompts.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Install
timeout /t 6 /nobreak >nul
