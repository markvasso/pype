# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 pype contributors
#Requires -Version 5.1
<#
.SYNOPSIS
    Installs pype and registers it in the Windows "Programs and Features"
    registry (with a version number) so RMM/patch-management tools can
    inventory and re-push it.

.DESCRIPTION
    Copies pype.exe (and a copy of Uninstall-Pype.ps1, so the registered
    uninstall command keeps working later) into an install directory,
    registers a Scheduled Task that starts pype hidden at logon, and writes
    a standard Uninstall registry key (DisplayName/DisplayVersion/
    UninstallString/etc.) under either HKLM or HKCU.

    Re-running this script (e.g. to push a newer pype.exe) is idempotent: it
    overwrites the exe, re-registers the task, and updates the registry
    DisplayVersion to match whatever version is actually on disk.

.PARAMETER Silent
    Suppresses console output (still writes to the log file) and never prompts.

.PARAMETER Scope
    'Machine'  - installs to Program Files, registers under HKLM (all users),
                 starts pype for whichever user logs on. Requires an elevated
                 session. This is what an RMM tool running as SYSTEM will get.
    'User'     - installs to %LOCALAPPDATA%, registers under HKCU, starts
                 pype only for the current user. No admin rights needed.
    'Auto'     - (default) picks Machine if the current session is elevated,
                 User otherwise.

.PARAMETER SystemWide
    Shorthand for -Scope Machine - installs to %ProgramFiles%\pype for all
    users instead of just the current one. Requires an elevated session, same
    as -Scope Machine. Conflicts with -Scope User.

.PARAMETER InstallDir
    Where to copy pype.exe. Defaults to "$env:ProgramFiles\pype" (Machine
    scope) or "$env:LOCALAPPDATA\pype" (User scope).

.PARAMETER NoAutoStart
    Skips registering the logon Scheduled Task.

.PARAMETER NoStartNow
    Skips launching pype immediately after install.

.PARAMETER NoStartMenuShortcut
    Skips creating the Start Menu shortcut.

.EXAMPLE
    .\Install-Pype.ps1
    Interactive install; scope auto-detected from whether the session is elevated.

.EXAMPLE
    .\Install-Pype.ps1 -Silent
    Fully silent install, suitable for RMM/scripted deployment (RMM agents
    typically already run as SYSTEM, so this lands as a Machine-scope install).
#>
[CmdletBinding()]
param(
    [switch]$Silent,
    [ValidateSet('Auto', 'Machine', 'User')]
    [string]$Scope = 'Auto',
    [switch]$SystemWide,
    [string]$InstallDir,
    [switch]$NoAutoStart,
    [switch]$NoStartNow,
    [switch]$NoStartMenuShortcut
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceExe = Join-Path $scriptDir 'pype.exe'
$sourceUninstallScript = Join-Path $scriptDir 'Uninstall-Pype.ps1'
$taskName  = 'pype-clipboard-typer'
$logFile   = Join-Path $env:TEMP 'pype-install.log'

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

function Get-StartMenuProgramsDir {
    param([string]$ScopeName)
    if ($ScopeName -eq 'Machine') {
        Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    } else {
        Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    }
}

function Set-UninstallRegistryKey {
    param(
        [string]$RegPath,
        [string]$InstallDir,
        [string]$DestExe,
        [string]$DisplayVersion,
        [string]$UninstallCmd,
        [string]$QuietUninstallCmd
    )

    New-Item -Path $RegPath -Force | Out-Null

    $estimatedSizeKb = [int][math]::Ceiling((Get-Item -LiteralPath $DestExe).Length / 1KB)

    $values = @{
        DisplayName           = 'pype - Clipboard Typer'
        DisplayVersion        = $DisplayVersion
        Publisher             = 'pype'
        InstallLocation       = $InstallDir
        DisplayIcon           = "$DestExe,0"
        UninstallString       = $UninstallCmd
        QuietUninstallString  = $QuietUninstallCmd
        InstallDate           = (Get-Date -Format 'yyyyMMdd')
        EstimatedSize         = $estimatedSizeKb
        NoModify              = 1
        NoRepair              = 1
    }

    foreach ($name in $values.Keys) {
        $value = $values[$name]
        $propType = if ($value -is [int]) { 'DWord' } else { 'String' }
        New-ItemProperty -Path $RegPath -Name $name -Value $value -PropertyType $propType -Force | Out-Null
    }
}

try {
    if ($SystemWide) {
        if ($Scope -eq 'User') {
            Fail '-SystemWide conflicts with -Scope User; use one or the other.'
        }
        $Scope = 'Machine'
    }

    $isAdmin = Test-IsAdmin

    $resolvedScope = switch ($Scope) {
        'Machine' {
            if (-not $isAdmin) {
                Fail 'Machine-wide install (-Scope Machine) requires an elevated (Administrator) session.'
            }
            'Machine'
        }
        'User' { 'User' }
        default { if ($isAdmin) { 'Machine' } else { 'User' } }
    }

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        $InstallDir = if ($resolvedScope -eq 'Machine') {
            Join-Path $env:ProgramFiles 'pype'
        } else {
            Join-Path $env:LOCALAPPDATA 'pype'
        }
    }

    $regPath = if ($resolvedScope -eq 'Machine') {
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\pype'
    } else {
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\pype'
    }

    Write-PypeLog "Installing pype (scope: $resolvedScope) to $InstallDir"

    if (-not (Test-Path -LiteralPath $sourceExe)) {
        Fail "Could not find pype.exe next to this script ($scriptDir). Publish it first (see README.md) and place pype.exe alongside Install-Pype.ps1."
    }
    if (-not (Test-Path -LiteralPath $sourceUninstallScript)) {
        Fail "Could not find Uninstall-Pype.ps1 next to this script ($scriptDir). It must ship alongside Install-Pype.ps1 - it gets copied into the install directory so the registered uninstall command keeps working later."
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

    # Stop a currently running instance so the exe isn't locked for the copy below.
    Get-Process -Name 'pype' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300

    $destExe = Join-Path $InstallDir 'pype.exe'
    $destUninstallScript = Join-Path $InstallDir 'Uninstall-Pype.ps1'
    Copy-Item -LiteralPath $sourceExe -Destination $destExe -Force
    # Copied so the UninstallString registered below still resolves even if the
    # original install source (e.g. an RMM staging folder) is later cleaned up.
    Copy-Item -LiteralPath $sourceUninstallScript -Destination $destUninstallScript -Force
    Write-PypeLog "Copied pype.exe and Uninstall-Pype.ps1 to $InstallDir"

    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($destExe)
    $displayVersion = if ($versionInfo.ProductVersion) { $versionInfo.ProductVersion.Trim() }
                       elseif ($versionInfo.FileVersion) { $versionInfo.FileVersion.Trim() }
                       else { '0.0.0.0' }
    Write-PypeLog "Detected pype.exe version: $displayVersion"

    if (-not $NoAutoStart) {
        $action = New-ScheduledTaskAction -Execute $destExe
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

        if ($resolvedScope -eq 'Machine') {
            # No -User: fires for whichever user logs on, not a specific account
            # (RMM installs run as SYSTEM, which never logs on interactively itself).
            $trigger = New-ScheduledTaskTrigger -AtLogOn
            $principal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Limited
        } else {
            $currentUser = "$env:USERDOMAIN\$env:USERNAME"
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
            $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
        }

        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        # -Force so a re-run is truly idempotent even if the Unregister call
        # above silently no-op'd (e.g. a permission quirk) and the task still
        # exists; without it Register-ScheduledTask can throw/prompt instead
        # of overwriting, which would break -Silent's no-prompts guarantee.
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force `
            -Description 'Runs pype (clipboard-to-keystrokes typer, Ctrl+Shift+V) hidden in the background at logon.' `
            | Out-Null

        Write-PypeLog "Registered scheduled task '$taskName' to start pype at logon (scope: $resolvedScope)."
    }
    else {
        Write-PypeLog 'Skipped auto-start registration (-NoAutoStart).'
    }

    if (-not $NoStartMenuShortcut) {
        $wsh = $null
        try {
            $startMenuDir = Get-StartMenuProgramsDir -ScopeName $resolvedScope
            New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null

            $wsh = New-Object -ComObject WScript.Shell

            $launchShortcut = $wsh.CreateShortcut((Join-Path $startMenuDir 'pype.lnk'))
            $launchShortcut.TargetPath = $destExe
            $launchShortcut.WorkingDirectory = $InstallDir
            $launchShortcut.IconLocation = "$destExe,0"
            $launchShortcut.Description = 'pype - types clipboard text via Ctrl+Shift+V'
            $launchShortcut.Save()

            $uninstallShortcut = $wsh.CreateShortcut((Join-Path $startMenuDir 'Uninstall pype.lnk'))
            $uninstallShortcut.TargetPath = 'powershell.exe'
            $uninstallShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$destUninstallScript`" -Scope $resolvedScope"
            $uninstallShortcut.WorkingDirectory = $InstallDir
            $uninstallShortcut.IconLocation = "$destExe,0"
            $uninstallShortcut.Description = 'Uninstall pype'
            $uninstallShortcut.Save()

            Write-PypeLog "Created Start Menu shortcuts in $startMenuDir"
        }
        catch {
            # Non-fatal: missing shortcuts don't break pype itself.
            Write-PypeLog "WARNING: could not create Start Menu shortcuts: $($_.Exception.Message)"
        }
        finally {
            # Release even if a CreateShortcut/.Save() call above threw partway through.
            if ($null -ne $wsh) {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)
            }
        }
    }
    else {
        Write-PypeLog 'Skipped Start Menu shortcuts (-NoStartMenuShortcut).'
    }

    $uninstallCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$destUninstallScript`" -Scope $resolvedScope"
    $quietUninstallCmd = "$uninstallCmd -Silent"
    Set-UninstallRegistryKey -RegPath $regPath -InstallDir $InstallDir -DestExe $destExe `
        -DisplayVersion $displayVersion -UninstallCmd $uninstallCmd -QuietUninstallCmd $quietUninstallCmd
    Write-PypeLog "Registered $regPath (DisplayVersion $displayVersion)."

    if (-not $NoStartNow) {
        Start-Process -FilePath $destExe
        Write-PypeLog 'Started pype.'
    }

    Write-PypeLog 'Install complete.'
    if (-not $Silent) {
        Write-Host "`npype $displayVersion installed ($resolvedScope scope). Press Ctrl+Shift+V anywhere to type clipboard text." -ForegroundColor Green
    }
    exit 0
}
catch {
    Fail $_.Exception.Message
}
