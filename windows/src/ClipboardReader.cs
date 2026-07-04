// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Pype;

internal static class ClipboardReader
{
    /// <summary>
    /// Reads clipboard text, retrying briefly since the clipboard is a shared
    /// OS resource that other apps can be holding open for a moment. Uses
    /// Task.Delay (not Thread.Sleep) between attempts so it doesn't block the
    /// WinForms UI/message-pump thread it's normally called from.
    /// </summary>
    public static async Task<string> GetTextWithRetryAsync(int attempts = 8, int delayMs = 40)
    {
        for (int i = 0; i < attempts; i++)
        {
            try
            {
                return Clipboard.ContainsText() ? Clipboard.GetText() : string.Empty;
            }
            catch (ExternalException) when (i < attempts - 1)
            {
                await Task.Delay(delayMs);
            }
        }

        // Only reached if attempts <= 0; the loop above always either returns
        // or, on its final iteration, lets the ExternalException propagate.
        return string.Empty;
    }
}
