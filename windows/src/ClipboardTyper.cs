// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Pype;

/// <summary>
/// Simulates keystrokes for arbitrary Unicode text via SendInput, so pype
/// works regardless of the active keyboard layout.
/// </summary>
internal static class ClipboardTyper
{
    private static readonly ushort[] ModifierVksToRelease =
    {
        0x10, // VK_SHIFT
        0x11, // VK_CONTROL
        0xA0, // VK_LSHIFT
        0xA1, // VK_RSHIFT
        0xA2, // VK_LCONTROL
        0xA3, // VK_RCONTROL
    };

    /// <param name="cancellationToken">
    /// Cancels an in-progress type (e.g. the tray "Stop Typing" item). On
    /// cancellation the loop stops cleanly between characters — matters most
    /// for the unbounded "Type Clipboard — No Limit" action, which can run for
    /// a long time.
    /// </param>
    /// <returns>
    /// True if every input event was accepted by SendInput. False on a partial
    /// or total failure (most commonly UIPI blocking injection into a
    /// higher-integrity foreground window, e.g. one running elevated).
    /// </returns>
    public static async Task<bool> TypeAsync(string text, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(text)) return true;

        // The trigger can be Ctrl+Shift+V, which RegisterHotKey can fire while
        // those keys are still physically held. Some apps read modifier state
        // (not just the WM_CHAR stream) and would swallow the injected text as
        // a shortcut, so force the modifiers up before typing anything.
        ReleaseModifierKeys();

        // Normalize all line-ending styles (CRLF, lone CR, lone LF) to a single
        // Enter keystroke each — clipboard text from browsers/terminals/WSL
        // commonly uses LF-only endings.
        string normalized = text.Replace("\r\n", "\n").Replace('\r', '\n');
        if (normalized.Length == 0) return true;

        bool allSucceeded = true;

        for (int i = 0; i < normalized.Length; i++)
        {
            if (cancellationToken.IsCancellationRequested) break;

            char c = normalized[i];
            var inputs = new List<NativeMethods.INPUT>(2);

            if (c == '\n')
            {
                AddVirtualKey(inputs, 0x0D); // VK_RETURN
            }
            else
            {
                AddUnicodeChar(inputs, c);
            }

            allSucceeded &= SendAll(inputs);

            // Paced rather than a single instantaneous batch - see
            // AppInfo.TypingIntervalMs for why. Skip the trailing delay
            // after the last character.
            if (i < normalized.Length - 1)
            {
                try
                {
                    await Task.Delay(AppInfo.TypingIntervalMs, cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }

        return allSucceeded;
    }

    private static void ReleaseModifierKeys()
    {
        var inputs = new List<NativeMethods.INPUT>(ModifierVksToRelease.Length);
        foreach (ushort vk in ModifierVksToRelease)
        {
            inputs.Add(MakeKeyInput(vk, wScan: 0, unicode: false, keyUp: true));
        }
        // Unlike TypeAsync's SendAll call, this result is discarded on
        // purpose: releasing modifiers is a best-effort precaution, not the
        // actual typing - if it fails, typing still proceeds rather than
        // aborting over a step that's just a defensive extra.
        SendAll(inputs);
    }

    private static void AddUnicodeChar(List<NativeMethods.INPUT> inputs, char c)
    {
        inputs.Add(MakeKeyInput(0, wScan: c, unicode: true, keyUp: false));
        inputs.Add(MakeKeyInput(0, wScan: c, unicode: true, keyUp: true));
    }

    private static void AddVirtualKey(List<NativeMethods.INPUT> inputs, ushort vk)
    {
        inputs.Add(MakeKeyInput(vk, wScan: 0, unicode: false, keyUp: false));
        inputs.Add(MakeKeyInput(vk, wScan: 0, unicode: false, keyUp: true));
    }

    private static NativeMethods.INPUT MakeKeyInput(ushort vk, ushort wScan, bool unicode, bool keyUp)
    {
        uint flags = 0;
        if (unicode) flags |= NativeMethods.KEYEVENTF_UNICODE;
        if (keyUp) flags |= NativeMethods.KEYEVENTF_KEYUP;

        return new NativeMethods.INPUT
        {
            type = NativeMethods.INPUT_KEYBOARD,
            U = new NativeMethods.InputUnion
            {
                ki = new NativeMethods.KEYBDINPUT
                {
                    wVk = vk,
                    wScan = wScan,
                    dwFlags = flags,
                    time = 0,
                    dwExtraInfo = IntPtr.Zero
                }
            }
        };
    }

    private static bool SendAll(List<NativeMethods.INPUT> inputs)
    {
        if (inputs.Count == 0) return true;
        var array = inputs.ToArray();
        uint sent = NativeMethods.SendInput((uint)array.Length, array, Marshal.SizeOf<NativeMethods.INPUT>());
        return sent == array.Length;
    }
}
