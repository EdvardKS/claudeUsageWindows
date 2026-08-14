@echo off
REM Run this once on each PC. No administrator rights needed.
REM
REM   install.cmd              full wizard, follows your Windows language
REM   install.cmd /silent      no questions, no pauses (unattended)
REM   install.cmd /repair      re-check and rewire without copying anything
REM   install.cmd /inplace     run from this folder instead of copying it
REM   install.cmd /en          force English      /es  force Spanish
REM
REM Flags can be combined, e.g.  install.cmd /silent /en

setlocal enabledelayedexpansion
set ARGS=-Install
set LANG=

:parse
if "%~1"=="" goto run
if /i "%~1"=="/silent"  set ARGS=%ARGS% -Silent
if /i "%~1"=="/quiet"   set ARGS=%ARGS% -Silent
if /i "%~1"=="/inplace" set ARGS=%ARGS% -InPlace
if /i "%~1"=="/repair"  set ARGS=-Repair
if /i "%~1"=="/en"      set LANG=-Language en
if /i "%~1"=="/es"      set LANG=-Language es
shift
goto parse

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %ARGS% %LANG%
if not "%ARGS%"=="%ARGS: -Silent=%" goto end
pause
:end
endlocal
