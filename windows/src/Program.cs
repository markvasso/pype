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

        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        Application.Run(new TrayAppContext());

        GC.KeepAlive(mutex);
    }
}
