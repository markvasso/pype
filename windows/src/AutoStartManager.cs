// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

using Microsoft.Win32;
using System.Windows.Forms;

namespace Pype;

/// <summary>
/// Controls whether pype starts at login via the standard "Run" registry key
/// (HKCU\...\CurrentVersion\Run for per-user, HKLM\... for machine-wide). This
/// is deliberately NOT a Scheduled Task: Run-key entries are what Windows Task
/// Manager's "Startup apps" tab lists and lets the user enable/disable, so the
/// autostart is visible and manageable where users expect it. The installer
/// writes the same key, giving one visible source of truth. Registry reads are
/// fast and synchronous, so the tray checkmark reflects real state immediately
/// on menu open (no async round-trip like the old schtasks approach needed).
/// </summary>
internal static class AutoStartManager
{
    private const string RunSubKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string StartupApprovedSubKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    private const string ValueName = "pype";

    /// <summary>
    /// True if pype will start at login for the current user — a per-user
    /// (HKCU) or machine-wide (HKLM) Run entry exists and isn't disabled in
    /// Task Manager's Startup tab.
    /// </summary>
    public static bool IsEnabled()
    {
        return IsEnabledIn(Registry.CurrentUser) || IsEnabledIn(Registry.LocalMachine);
    }

    private static bool IsEnabledIn(RegistryKey root)
    {
        using var run = root.OpenSubKey(RunSubKey);
        if (run?.GetValue(ValueName) is null) return false;

        // Task Manager records its enable/disable state here; an absent entry
        // means enabled. When present, the leading byte's low bit set means the
        // user disabled the entry in the Startup tab, so honor that.
        using var approved = root.OpenSubKey(StartupApprovedSubKey);
        if (approved?.GetValue(ValueName) is byte[] flag && flag.Length > 0 && (flag[0] & 1) != 0)
        {
            return false;
        }
        return true;
    }

    /// <summary>
    /// Enables autostart for the current user (HKCU). Note: enabling/disabling
    /// from the tray always targets HKCU — a machine-wide (HKLM) entry written
    /// by an elevated/RMM install can't be changed by a standard user, which is
    /// the correct behavior for IT-managed autostart.
    /// </summary>
    public static bool TryEnable(out string error)
    {
        error = string.Empty;
        try
        {
            using (var run = Registry.CurrentUser.CreateSubKey(RunSubKey))
            {
                run.SetValue(ValueName, $"\"{Application.ExecutablePath}\"", RegistryValueKind.String);
            }

            // If the user previously disabled pype in Task Manager's Startup
            // tab, clearing that record lets enabling from the tray actually
            // take effect (otherwise the entry would exist but stay disabled).
            using var approved = Registry.CurrentUser.OpenSubKey(StartupApprovedSubKey, writable: true);
            approved?.DeleteValue(ValueName, throwOnMissingValue: false);
            return true;
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }
    }

    public static bool TryDisable(out string error)
    {
        error = string.Empty;
        try
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunSubKey, writable: true);
            run?.DeleteValue(ValueName, throwOnMissingValue: false);
            return true;
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }
    }
}
