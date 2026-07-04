# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 pype contributors
#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls pype: stops the running process, removes the logon Scheduled
    Task, deletes the install directory, and removes the registry Uninstall
    key registered by Install-Pype.ps1.

.PARAMETER Silent
    Suppresses console output (still writes to the log file) and never prompts.

.PARAMETER Scope
    'Machine' - removes the HKLM registration and Program Files install.
                Requires an elevated session.
    'User'    - removes the HKCU registration and %LOCALAPPDATA% install.
    'Auto'    - (default) removes whichever scope(s) are actually registered,
                detected by checking for the HKLM/HKCU registry keys. If
                neither key is present (e.g. it predates this registry
                feature), falls back to checking both conventional install
                directories directly.

.PARAMETER InstallDir
    Overrides where to look for the install directory. Only meaningful when
    exactly one scope is being removed; ignored (conventional per-scope
    defaults are used instead) when both scopes are being cleaned up.

.PARAMETER KeepLogs
    Keeps the install/uninstall log files in %TEMP% instead of deleting them.

.EXAMPLE
    .\Uninstall-Pype.ps1 -Silent
#>
[CmdletBinding()]
param(
    [switch]$Silent,
    [ValidateSet('Auto', 'Machine', 'User')]
    [string]$Scope = 'Auto',
    [string]$InstallDir,
    [switch]$KeepLogs
)

$ErrorActionPreference = 'Stop'
$taskName = 'pype-clipboard-typer'
$logFile  = Join-Path $env:TEMP 'pype-uninstall.log'
$hklmRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\pype'
$hkcuRegPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\pype'

function Write-PypeLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    if (-not $Silent) { Write-Host $Message }
}

function Fail {
    param([string]$Message)
    Write-PypeLog "ERROR: $Message"
    if (-not $Silent) { Write-Error $Message }
    exit 1
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DefaultInstallDir {
    param([string]$ScopeName)
    if ($ScopeName -eq 'Machine') { Join-Path $env:ProgramFiles 'pype' } else { Join-Path $env:LOCALAPPDATA 'pype' }
}

function Get-StartMenuProgramsDir {
    param([string]$ScopeName)
    if ($ScopeName -eq 'Machine') {
        Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    } else {
        Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    }
}

function Remove-PypeScope {
    param(
        [string]$ScopeName,
        [string]$OverrideInstallDir
    )

    $dir = if ($OverrideInstallDir) { $OverrideInstallDir } else { Get-DefaultInstallDir -ScopeName $ScopeName }
    $regPath = if ($ScopeName -eq 'Machine') { $hklmRegPath } else { $hkcuRegPath }

    if (Test-Path -LiteralPath $regPath) {
        Remove-Item -LiteralPath $regPath -Recurse -Force
        Write-PypeLog "Removed registry key $regPath"
    }
    else {
        Write-PypeLog "$regPath did not exist; nothing to remove there."
    }

    if (Test-Path -LiteralPath $dir) {
        # Sanity check before a recursive forced delete: only proceed if this
        # actually looks like a pype install (contains pype.exe). Guards
        # against a mistaken/mistyped -InstallDir silently wiping an unrelated
        # directory tree.
        $markerExe = Join-Path $dir 'pype.exe'
        if (Test-Path -LiteralPath $markerExe) {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-PypeLog "Removed $dir"
        }
        else {
            Write-PypeLog "WARNING: $dir exists but does not contain pype.exe; skipping delete as a safety check. Pass the correct -InstallDir if this really is the install folder."
        }
    }
    else {
        Write-PypeLog "$dir did not exist; nothing to remove there."
    }

    $startMenuDir = Get-StartMenuProgramsDir -ScopeName $ScopeName
    foreach ($shortcutName in @('pype.lnk', 'Uninstall pype.lnk')) {
        $shortcutPath = Join-Path $startMenuDir $shortcutName
        if (Test-Path -LiteralPath $shortcutPath) {
            Remove-Item -LiteralPath $shortcutPath -Force
            Write-PypeLog "Removed Start Menu shortcut $shortcutPath"
        }
    }
}

try {
    $isAdmin = Test-IsAdmin

    $scopesToRemove = if ($Scope -ne 'Auto') {
        @($Scope)
    }
    else {
        $detected = @()
        if (Test-Path -LiteralPath $hklmRegPath) { $detected += 'Machine' }
        if (Test-Path -LiteralPath $hkcuRegPath) { $detected += 'User' }
        if ($detected.Count -gt 0) { $detected } else { @('Machine', 'User') }
    }

    Write-PypeLog "Uninstalling pype (scope(s): $($scopesToRemove -join ', '))"

    Get-Process -Name 'pype' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-PypeLog "Removed scheduled task '$taskName' (if present)."

    foreach ($sc in $scopesToRemove) {
        if ($sc -eq 'Machine' -and -not $isAdmin) {
            if ($Scope -eq 'Machine') {
                Fail 'Machine-wide uninstall (-Scope Machine) requires an elevated (Administrator) session.'
            }
            Write-PypeLog 'Skipping machine-wide (HKLM) cleanup: not running elevated. Re-run this script as Administrator to fully remove it.'
            continue
        }
        Remove-PypeScope -ScopeName $sc -OverrideInstallDir $InstallDir
    }

    Write-PypeLog 'Uninstall complete.'
    if (-not $Silent) {
        Write-Host "`npype has been uninstalled." -ForegroundColor Green
    }

    if (-not $KeepLogs) {
        Remove-Item -LiteralPath (Join-Path $env:TEMP 'pype-install.log') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
    }

    exit 0
}
catch {
    Fail $_.Exception.Message
}
