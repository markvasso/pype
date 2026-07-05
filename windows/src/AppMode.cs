// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

using System.IO;
using System.Windows.Forms;

namespace Pype;

/// <summary>
/// Distinguishes the installed edition from the portable (standalone exe)
/// edition of the SAME pype.exe. The installer drops a marker file next to the
/// exe; a portable pype.exe downloaded on its own does not have it. In portable
/// mode pype hides the install-only features — Run at Login and the update
/// check — since those only make sense for a managed install.
/// </summary>
internal static class AppMode
{
    /// <summary>File the installer writes into the install directory.</summary>
    public const string InstalledMarkerName = "pype.installed";

    public static bool IsInstalled { get; } = ComputeIsInstalled();

    private static bool ComputeIsInstalled()
    {
        try
        {
            string? dir = Path.GetDirectoryName(Application.ExecutablePath);
            return dir is not null && File.Exists(Path.Combine(dir, InstalledMarkerName));
        }
        catch
        {
            return false;
        }
    }
}
