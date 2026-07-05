// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

using System.Windows.Forms;

namespace Pype;

/// <summary>
/// A message-only native window (parent HWND_MESSAGE) used purely as a target
/// for WM_HOTKEY messages. It has no visible presence: no taskbar entry, no
/// Alt+Tab entry, not even a Form.
/// </summary>
internal sealed class HotkeyWindow : NativeWindow, IDisposable
{
    private const int HWND_MESSAGE = -3;
    private readonly List<int> _registeredIds = new();

    /// <summary>Raised with the hotkey's id when one of the registered combos fires.</summary>
    public event Action<int>? HotkeyPressed;

    public HotkeyWindow()
    {
        var cp = new CreateParams
        {
            Parent = new IntPtr(HWND_MESSAGE)
        };
        CreateHandle(cp);
    }

    public void RegisterHotkey(uint modifiers, uint vk, int id)
    {
        if (!NativeMethods.RegisterHotKey(Handle, id, modifiers, vk))
        {
            throw new InvalidOperationException(
                "Could not register a pype hotkey (Ctrl+` / Ctrl+Shift+`). It may already be in use by another application.");
        }
        _registeredIds.Add(id);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == NativeMethods.WM_HOTKEY)
        {
            HotkeyPressed?.Invoke(m.WParam.ToInt32());
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        foreach (int id in _registeredIds)
        {
            NativeMethods.UnregisterHotKey(Handle, id);
        }
        _registeredIds.Clear();
        DestroyHandle();
    }
}
