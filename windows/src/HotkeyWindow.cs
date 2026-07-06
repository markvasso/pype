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
    private int? _registeredId;

    public event Action? HotkeyPressed;

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
                "Could not register the Ctrl+' hotkey. It may already be in use by another application.");
        }
        _registeredId = id;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == NativeMethods.WM_HOTKEY)
        {
            HotkeyPressed?.Invoke();
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        if (_registeredId is int id)
        {
            NativeMethods.UnregisterHotKey(Handle, id);
        }
        DestroyHandle();
    }
}
