// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

using System.Windows.Forms;

namespace Pype;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(initiallyOwned: true, AppInfo.MutexName, out bool createdNew);
        if (!createdNew)
        {
            MessageBox.Show(
                "pype is already running (check the system tray).",
                "pype",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        // Last-resort backstop so a stray unhandled exception on the UI thread
        // (e.g. one escaping an async void handler) surfaces as a dismissible
        // notice rather than the raw WinForms crash dialog or a silent exit.
        // Individual handlers still catch their own errors; this is only the
        // net beneath them for a background tray app with no main window.
        Application.ThreadException += (_, e) => ReportFatal(e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => ReportFatal(e.ExceptionObject as Exception);

        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        Application.Run(new TrayAppContext());

        GC.KeepAlive(mutex);
    }

    private static void ReportFatal(Exception? ex)
    {
        try
        {
            MessageBox.Show(
                $"pype hit an unexpected error and may need to be restarted.\n\n{ex?.Message}",
                "pype",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
        catch
        {
            // Nothing more we can safely do from a failing top-level handler.
        }
    }
}
