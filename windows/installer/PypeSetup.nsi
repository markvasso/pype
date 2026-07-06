; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 pype contributors
;
; NSIS installer script for pype's GUI wizard installer.
;
; This is a THIN WRAPPER, same philosophy as the CLI installer: it stages
; pype.exe + Install-Pype.ps1 + Uninstall-Pype.ps1 and hands off to
; Install-Pype.ps1 to do the actual work (registry Uninstall key, Start Menu
; shortcuts, scope detection, installed marker). One implementation of the
; install logic, not two kept in sync by hand. Autostart is NOT set up by the
; installer - it's a per-user choice in pype's tray menu.
;
; Build with NSIS 3.x (https://nsis.sourceforge.io/), e.g. via Homebrew on
; macOS/Linux (`brew install makensis`) or the official Windows installer:
;   makensis PypeSetup.nsi
; Requires a freshly published pype.exe sitting next to this script (see
; ../README.md).
;
; Silent install is a native NSIS feature, no extra scripting needed:
;   PypeSetup.exe /S                    fully silent
;   PypeSetup.exe /S /AllUsers          silent + force machine-wide scope
;   PypeSetup.exe /S /CurrentUser       silent + force per-user scope

Unicode true

; NSIS's !getdllversion can't read the version resource from pype.exe once
; it's published as a self-contained single-file exe (confirmed: it errors
; cleanly in isolation on this file, and silently corrupts later macro
; expansion into a crash if left to fail inline) - so there's no working way
; to pull this from the exe at NSIS compile time. Bump this by hand
; alongside <Version> in ../src/Pype.csproj when you cut a new release.
!define PRODUCT_NAME "pype"
!define PRODUCT_VERSION "1.3.2"
!define PRODUCT_PUBLISHER "pype"

; --- MultiUser: gives the wizard an "Install for all users" / "Install for
;     me only" page (or /AllUsers, /CurrentUser command-line switches),
;     mirroring Install-Pype.ps1's own -Scope Machine/User/Auto. Whichever
;     mode is chosen determines whether this process ends up elevated, and
;     Install-Pype.ps1's own -Scope Auto then does the right thing based on
;     that. These defines must come before MultiUser.nsh is included - it
;     reads them while processing, not at macro-insertion time.
!define MULTIUSER_EXECUTIONLEVEL Highest
!define MULTIUSER_MUI
!define MULTIUSER_INSTALLMODE_COMMANDLINE
!define MULTIUSER_INSTALLMODE_INSTDIR "pype"
!define MULTIUSER_INSTALLMODE_INSTDIR_REGISTRY_KEY "Software\pype"
!define MULTIUSER_INSTALLMODE_INSTDIR_REGISTRY_VALUENAME "InstallDir"

; --- MUI2 wizard appearance ---
!define MUI_ABORTWARNING
!define MUI_ICON "..\src\pype.ico"

!include "MultiUser.nsh"
!include "MUI2.nsh"
!include "LogicLib.nsh"

Name "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "..\dist\PypeSetup.exe"
ShowInstDetails show

!insertmacro MUI_PAGE_WELCOME
!insertmacro MULTIUSER_PAGE_INSTALLMODE
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\pype.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch pype now"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_LANGUAGE "English"

Function .onInit
  !insertmacro MULTIUSER_INIT
FunctionEnd

Section "pype (required)" SEC_CORE
  SectionIn RO
  ; Staged to $PLUGINSDIR (a per-run temp dir NSIS provides), NOT $INSTDIR:
  ; Install-Pype.ps1 copies pype.exe from its own script directory to
  ; -InstallDir itself, so extracting directly into $INSTDIR first would
  ; make that copy step try to copy pype.exe onto itself and fail.
  SetOutPath "$PLUGINSDIR"
  File "pype.exe"
  File "Install-Pype.ps1"
  File "Uninstall-Pype.ps1"

  ; Autostart is intentionally NOT offered here - it's controlled from pype's
  ; tray menu ("Run at Login") after install. Older installers had a "start at
  ; login" option that could produce a duplicate startup entry.
  DetailPrint "Configuring pype..."
  nsExec::ExecToLog '"$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\Install-Pype.ps1" -InstallDir "$INSTDIR" -Silent -NoStartNow'
  Pop $1
  ${If} $1 != 0
    MessageBox MB_OK|MB_ICONSTOP "pype setup could not finish configuring the app (exit code $1). See %TEMP%\pype-install.log for details."
    Abort
  ${EndIf}
SectionEnd
