@echo off
REM SPDX-License-Identifier: GPL-3.0-or-later
REM Copyright (C) 2026 pype contributors
REM Thin wrapper around Uninstall-Pype.ps1 for double-click / scripted uninstalls.
REM Recognized leading switches (any order, any combination):
REM   /S, /SILENT, /VERYSILENT   silent uninstall, no prompts/output
REM   /ALLUSERS                  remove the system-wide (Machine-scope) install
REM   /CURRENTUSER               remove the per-user (User-scope) install
REM   (default, no scope switch) auto-detect whichever scope(s) are registered
REM Any further arguments are forwarded to Uninstall-Pype.ps1 as-is (quoting
REM preserved) via %*, e.g.:
REM   uninstall.cmd /S -KeepLogs
setlocal
set "SCRIPT_DIR=%~dp0"
set "SILENT_FLAG="
set "SCOPE_FLAG="

:parse
if /I "%~1"=="/S"           (set "SILENT_FLAG=-Silent" & shift & goto parse)
if /I "%~1"=="/SILENT"      (set "SILENT_FLAG=-Silent" & shift & goto parse)
if /I "%~1"=="/VERYSILENT"  (set "SILENT_FLAG=-Silent" & shift & goto parse)
if /I "%~1"=="/ALLUSERS"    (set "SCOPE_FLAG=-Scope Machine" & shift & goto parse)
if /I "%~1"=="/CURRENTUSER" (set "SCOPE_FLAG=-Scope User" & shift & goto parse)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Uninstall-Pype.ps1" %SILENT_FLAG% %SCOPE_FLAG% %*
exit /b %ERRORLEVEL%
