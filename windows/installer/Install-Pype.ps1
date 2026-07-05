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
    uninstall command keeps working later) into an install directory, and
    writes a standard Uninstall registry key (DisplayName/DisplayVersion/
    UninstallString/etc.) under either HKLM or HKCU.

    Autostart is NOT set up by the installer - it's controlled from pype's tray
    menu ("Run at Login"). Older versions enabled autostart from the installer,
    which could leave two startup entries (a machine HKLM entry plus the user's
    tray HKCU entry) and launch pype twice; installing over such a version
    removes the machine-side autostart and the legacy Scheduled Task, leaving
    only the user's own per-user choice.

    Re-running this script (e.g. to push a newer pype.exe) cleans up any prior
    install for a fresh environment and updates the registry DisplayVersion to
    match whatever version is actually on disk.

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

function Get-RunKeyPath {
    param([string]$ScopeName)
    $root = if ($ScopeName -eq 'Machine') { 'HKLM:' } else { 'HKCU:' }
    "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
}

function Get-StartupApprovedPath {
    param([string]$ScopeName)
    $root = if ($ScopeName -eq 'Machine') { 'HKLM:' } else { 'HKCU:' }
    "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
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
    elseif ($resolvedScope -eq 'Machine') {
        # Security check for machine-wide installs: the logon task runs
        # pype.exe for EVERY interactive user, so if the exe sits somewhere a
        # standard (non-admin) user can write, that user could replace it and
        # get their code run in other users' sessions. The default
        # %ProgramFiles%\pype is admin-only and safe; a custom -InstallDir
        # under a user-writable location (e.g. a profile folder) is not.
        # Block the obvious footguns rather than silently creating a
        # privilege-escalation primitive. Matching is on a path-component
        # boundary (equal, or prefix + '\') so "C:\Program Files Evil" doesn't
        # sneak past a naive "starts with C:\Program Files" check.
        $normalized = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
        $protectedRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:WINDIR) |
            Where-Object { $_ } |
            ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') } |
            Select-Object -Unique
        $isProtected = $false
        foreach ($root in $protectedRoots) {
            if ($normalized -eq $root -or
                $normalized.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $isProtected = $true
                break
            }
        }
        if (-not $isProtected) {
            Fail "For a machine-wide install, -InstallDir must be under a protected, admin-only location (e.g. `"$env:ProgramFiles\pype`"). Installing to a user-writable path would let a standard user replace pype.exe and run code in other users' logon sessions. Use -Scope User for a per-user install to a custom location instead."
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

    # --- Clean any prior install so the new one lands in a fresh environment.
    # Remove the legacy Scheduled Task older versions used for autostart.
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    # Remove the MACHINE (HKLM) autostart entry. The installer no longer sets up
    # autostart at all (it's controlled from pype's tray menu now); older
    # versions wrote an HKLM Run entry for machine installs, which combined with
    # a user's own tray (HKCU) entry could start pype twice at logon. Clearing
    # HKLM leaves only the user's per-user choice. HKCU is deliberately left
    # alone so a reinstall preserves the user's own "Run at Login" preference.
    foreach ($p in @((Get-RunKeyPath -ScopeName 'Machine'), (Get-StartupApprovedPath -ScopeName 'Machine'))) {
        if (Test-Path -LiteralPath $p) {
            Remove-ItemProperty -LiteralPath $p -Name 'pype' -Force -ErrorAction SilentlyContinue
        }
    }

    # If a prior install (either scope) registered a DIFFERENT location, remove
    # its pype files so a stale copy isn't left behind. Only touch it if
    # pype.exe is actually there, to avoid deleting from a mis-recorded location.
    foreach ($priorScope in @('Machine', 'User')) {
        $priorReg = if ($priorScope -eq 'Machine') {
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\pype'
        } else {
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\pype'
        }
        $priorLocation = (Get-ItemProperty -LiteralPath $priorReg -Name 'InstallLocation' -ErrorAction SilentlyContinue).InstallLocation
        if ($priorLocation -and ($priorLocation.TrimEnd('\') -ne $InstallDir.TrimEnd('\'))) {
            $priorExe = Join-Path $priorLocation 'pype.exe'
            if (Test-Path -LiteralPath $priorExe) {
                Remove-Item -LiteralPath $priorExe -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath (Join-Path $priorLocation 'Uninstall-Pype.ps1') -Force -ErrorAction SilentlyContinue
                Write-PypeLog "Removed prior pype install at $priorLocation"
            }
        }
    }

    $destExe = Join-Path $InstallDir 'pype.exe'
    $destUninstallScript = Join-Path $InstallDir 'Uninstall-Pype.ps1'
    Copy-Item -LiteralPath $sourceExe -Destination $destExe -Force
    # Copied so the UninstallString registered below still resolves even if the
    # original install source (e.g. an RMM staging folder) is later cleaned up.
    Copy-Item -LiteralPath $sourceUninstallScript -Destination $destUninstallScript -Force
    # Marker that tells the running pype.exe it's the installed edition (vs a
    # standalone portable exe), so it shows the install-only menu items.
    Set-Content -LiteralPath (Join-Path $InstallDir 'pype.installed') -Value '' -Force
    Write-PypeLog "Copied pype.exe and Uninstall-Pype.ps1 to $InstallDir"

    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($destExe)
    $displayVersion = if ($versionInfo.ProductVersion) { $versionInfo.ProductVersion.Trim() }
                       elseif ($versionInfo.FileVersion) { $versionInfo.FileVersion.Trim() }
                       else { '0.0.0.0' }
    # Strip any SemVer build-metadata suffix (e.g. "1.3.0+abcdef") so Control
    # Panel shows a clean version. The exe is built with
    # IncludeSourceRevisionInProductVersion=false, but this keeps an older or
    # differently-built exe from registering the ugly suffix either.
    $displayVersion = ($displayVersion -split '\+')[0]
    Write-PypeLog "Detected pype.exe version: $displayVersion"

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
        Write-Host "`npype $displayVersion installed ($resolvedScope scope). Press Ctrl+`` anywhere to type clipboard text." -ForegroundColor Green
    }
    exit 0
}
catch {
    Fail $_.Exception.Message
}
