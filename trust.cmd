@echo off
REM OPTIONAL. Signs the scripts with a personal certificate.
REM Windows will ask you once to confirm trusting the certificate.
REM Read the notes at the top of trust.ps1 before running this.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0trust.ps1"
pause
