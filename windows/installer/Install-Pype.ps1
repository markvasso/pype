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
    enables autostart via the standard "Run" registry key (visible and
    toggleable in Task Manager's Startup tab), and writes a standard Uninstall
    registry key (DisplayName/DisplayVersion/UninstallString/etc.) under either
    HKLM or HKCU.

    Re-running this script (e.g. to push a newer pype.exe) first cleans up any
    prior install - including the Scheduled Task older versions used for
    autostart - for a fresh environment, while preserving the user's autostart
    on/off preference. It then updates the registry DisplayVersion to match
    whatever version is actually on disk.

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
    Skips enabling autostart (the Run registry key). On a reinstall this
    always wins; otherwise a reinstall preserves the prior autostart choice.

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

function Test-AutoStartEnabled {
    # Mirrors the app's AutoStartManager.IsEnabled for one scope: the Run value
    # must exist AND not be marked disabled in Task Manager's Startup tab
    # (StartupApproved, leading byte's low bit set = disabled).
    param([string]$ScopeName)
    $runVal = (Get-ItemProperty -LiteralPath (Get-RunKeyPath -ScopeName $ScopeName) -Name 'pype' -ErrorAction SilentlyContinue).pype
    if (-not $runVal) { return $false }
    $approved = (Get-ItemProperty -LiteralPath (Get-StartupApprovedPath -ScopeName $ScopeName) -Name 'pype' -ErrorAction SilentlyContinue).pype
    if ($approved -is [byte[]] -and $approved.Length -gt 0 -and ($approved[0] -band 1) -ne 0) {
        return $false
    }
    return $true
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
    $runKeyPath = Get-RunKeyPath -ScopeName $resolvedScope

    # Capture the prior autostart preference BEFORE cleaning anything, so a
    # reinstall preserves the user's on/off choice ("user preferences can
    # stay"). Autostart is pype's only persistent preference. Both scopes are
    # checked (not just the one being installed now) so changing scope on a
    # reinstall still inherits the prior choice rather than defaulting to on.
    $priorInstall = (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\pype') -or
                    (Test-Path -LiteralPath 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\pype')
    # Test-AutoStartEnabled honors Task Manager's disable record, so a user who
    # turned pype off in the Startup tab is correctly seen as "autostart off"
    # and a reinstall won't silently re-enable it.
    $priorAutoStart = (Test-AutoStartEnabled -ScopeName 'User') -or (Test-AutoStartEnabled -ScopeName 'Machine')
    # Older pype versions used a Scheduled Task for autostart; treat an
    # existing, non-disabled one as "autostart was on" so upgrading from those
    # versions doesn't silently turn it off.
    $legacyTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($legacyTask -and $legacyTask.State -ne 'Disabled') { $priorAutoStart = $true }

    # Fresh install defaults to autostart on; a reinstall preserves the prior
    # choice; -NoAutoStart always wins.
    $enableAutoStart = if ($NoAutoStart) { $false }
                       elseif ($priorInstall) { $priorAutoStart }
                       else { $true }

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
    #     The autostart preference captured above is re-applied below.
    # Remove the legacy Scheduled Task older versions used for autostart.
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

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

    # Remove the OTHER scope's autostart Run entry so a scope-changing reinstall
    # doesn't leave a redundant/stale one behind (best-effort; removing HKLM
    # needs elevation, which a User-scope reinstall may lack).
    $otherScope = if ($resolvedScope -eq 'Machine') { 'User' } else { 'Machine' }
    foreach ($p in @((Get-RunKeyPath -ScopeName $otherScope), (Get-StartupApprovedPath -ScopeName $otherScope))) {
        if (Test-Path -LiteralPath $p) {
            Remove-ItemProperty -LiteralPath $p -Name 'pype' -Force -ErrorAction SilentlyContinue
        }
    }

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

    # Autostart via the standard "Run" registry key rather than a Scheduled
    # Task, so it shows up in - and can be toggled from - Task Manager's
    # Startup tab. HKLM (machine scope) runs pype for every user at logon;
    # HKCU (user scope) for the current user only.
    $approvedPath = Get-StartupApprovedPath -ScopeName $resolvedScope
    if ($enableAutoStart) {
        New-Item -Path $runKeyPath -Force | Out-Null
        New-ItemProperty -Path $runKeyPath -Name 'pype' -Value "`"$destExe`"" -PropertyType String -Force | Out-Null
        # If pype was previously disabled in Task Manager's Startup tab, clear
        # that record so this install's autostart actually takes effect.
        if (Test-Path -LiteralPath $approvedPath) {
            Remove-ItemProperty -LiteralPath $approvedPath -Name 'pype' -Force -ErrorAction SilentlyContinue
        }
        Write-PypeLog "Enabled autostart via $runKeyPath (visible in Task Manager > Startup)."
    }
    else {
        # Not enabling: make sure no stale Run entry lingers from a prior install.
        if (Test-Path -LiteralPath $runKeyPath) {
            Remove-ItemProperty -LiteralPath $runKeyPath -Name 'pype' -Force -ErrorAction SilentlyContinue
        }
        Write-PypeLog 'Autostart not enabled.'
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
