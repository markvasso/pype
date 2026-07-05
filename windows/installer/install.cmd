@echo off
REM SPDX-License-Identifier: GPL-3.0-or-later
REM Copyright (C) 2026 pype contributors
REM Thin wrapper around Install-Pype.ps1 for double-click / scripted installs.
REM Recognized leading switches (any order, any combination):
REM   /S, /SILENT, /VERYSILENT   silent install, no prompts/output
REM   /ALLUSERS                  system-wide install (Program Files, all users;
REM                              same as Install-Pype.ps1's -SystemWide, requires
REM                              an elevated session)
REM   /CURRENTUSER               per-user install (%LOCALAPPDATA%, no admin needed)
REM Any further arguments are forwarded to Install-Pype.ps1 as-is (quoting
REM preserved) via %*, e.g.:
REM   install.cmd /S /ALLUSERS -NoStartMenuShortcut
setlocal
set "SCRIPT_DIR=%~dp0"
set "SILENT_FLAG="
set "SCOPE_FLAG="

:parse
if /I "%~1"=="/S"           (set "SILENT_FLAG=-Silent" & shift & goto parse)
if /I "%~1"=="/SILENT"      (set "SILENT_FLAG=-Silent" & shift & goto parse)
if /I "%~1"=="/VERYSILENT"  (set "SILENT_FLAG=-Silent" & shift & goto parse)
if /I "%~1"=="/ALLUSERS"    (set "SCOPE_FLAG=-SystemWide" & shift & goto parse)
if /I "%~1"=="/CURRENTUSER" (set "SCOPE_FLAG=-Scope User" & shift & goto parse)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Install-Pype.ps1" %SILENT_FLAG% %SCOPE_FLAG% %*
exit /b %ERRORLEVEL%
