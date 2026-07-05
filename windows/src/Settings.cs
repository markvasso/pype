// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

using Microsoft.Win32;

namespace Pype;

/// <summary>
/// Small per-user settings store under HKCU\Software\pype. Only the installed
/// edition uses these (portable mode has no update check to toggle).
/// </summary>
internal static class Settings
{
    private const string KeyPath = @"Software\pype";
    private const string CheckUpdatesValue = "CheckForUpdatesOnStartup";

    /// <summary>Whether pype checks GitHub for a newer version at launch. Default on.</summary>
    public static bool CheckForUpdatesOnStartup
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
            return key?.GetValue(CheckUpdatesValue) is int i ? i != 0 : true;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(KeyPath);
            key.SetValue(CheckUpdatesValue, value ? 1 : 0, RegistryValueKind.DWord);
        }
    }
}
