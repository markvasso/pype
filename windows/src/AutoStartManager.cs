// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Xml.Linq;

namespace Pype;

/// <summary>
/// Controls the SAME Scheduled Task the installer registers (see
/// installer/Install-Pype.ps1), so there's exactly one autostart mechanism
/// whether it was set up by the installer or toggled from the tray menu.
/// Shells out to schtasks.exe rather than using the Task Scheduler COM API
/// directly, to avoid a COM interop dependency for a single small feature.
/// Everything here is async so it doesn't stall the WinForms message pump —
/// this is called from the tray context menu's Opening/Click handlers, which
/// run on the UI thread.
/// </summary>
internal static class AutoStartManager
{
    private const string TaskName = "pype-clipboard-typer";

    /// <returns>
    /// True/false if the task exists, or null if it doesn't exist at all
    /// (e.g. pype was run standalone without ever being installed).
    /// </returns>
    public static async Task<bool?> IsEnabledAsync()
    {
        // /XML dumps the task's definition in Task Scheduler's fixed XML
        // schema, not the human-readable /FO LIST report — the latter is
        // localized (e.g. "Scheduled Task State:" is translated on non-English
        // Windows), which would silently break a string match against it.
        var (exitCode, output) = await RunSchtasksAsync($"/Query /TN \"{TaskName}\" /XML");
        if (exitCode != 0) return null;

        try
        {
            var doc = XDocument.Parse(output);
            var enabledElement = doc.Descendants().FirstOrDefault(e => e.Name.LocalName == "Enabled");
            return enabledElement is not null && bool.Parse(enabledElement.Value);
        }
        catch
        {
            return null;
        }
    }

    public static async Task<(bool Success, string Error)> TryEnableAsync()
    {
        if (await IsEnabledAsync() is null)
        {
            // No task registered yet (standalone run, or -NoAutoStart was used
            // at install time) — create a simple current-user one on demand.
            // No admin rights needed: it only runs for whoever enables it.
            string exePath = Application.ExecutablePath;
            var (createCode, createOutput) = await RunSchtasksAsync(
                $"/Create /TN \"{TaskName}\" /TR \"\\\"{exePath}\\\"\" /SC ONLOGON /RL LIMITED /F");
            return createCode == 0 ? (true, string.Empty) : (false, createOutput);
        }

        var (exitCode, output) = await RunSchtasksAsync($"/Change /TN \"{TaskName}\" /ENABLE");
        return exitCode == 0 ? (true, string.Empty) : (false, output);
    }

    public static async Task<(bool Success, string Error)> TryDisableAsync()
    {
        var (exitCode, output) = await RunSchtasksAsync($"/Change /TN \"{TaskName}\" /DISABLE");
        return exitCode == 0 ? (true, string.Empty) : (false, output);
    }

    private static async Task<(int ExitCode, string Output)> RunSchtasksAsync(string arguments)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "schtasks.exe",
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        using var process = Process.Start(psi);
        if (process is null) return (-1, "Could not start schtasks.exe.");

        Task<string> stdoutTask = process.StandardOutput.ReadToEndAsync();
        Task<string> stderrTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        string stdout = await stdoutTask;
        string stderr = await stderrTask;

        string output = string.IsNullOrWhiteSpace(stdout) ? stderr : stdout;
        return (process.ExitCode, output.Trim());
    }
}
