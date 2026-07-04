// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

using System.Threading.Tasks;
using System.Windows.Forms;

namespace Pype;

internal sealed class TrayAppContext : ApplicationContext
{
    private readonly NotifyIcon _trayIcon;
    private readonly HotkeyWindow _hotkeyWindow;
    private readonly ToolStripMenuItem _runAtLoginItem;
    private readonly ToolStripMenuItem _exitItem;
    private System.Drawing.Icon? _ownedIcon;
    private bool _isTyping;

    public TrayAppContext()
    {
        // Construct the hotkey window (native window creation, however
        // unlikely to fail, can throw) before the tray icon becomes visible,
        // so a failure here can't leave an orphaned icon behind with nothing
        // left alive to clean it up.
        _hotkeyWindow = new HotkeyWindow();
        _hotkeyWindow.HotkeyPressed += OnHotkeyPressed;

        _trayIcon = new NotifyIcon
        {
            Icon = LoadAppIcon(),
            Text = AppInfo.DisplayName,
            Visible = true
        };

        _runAtLoginItem = new ToolStripMenuItem("Run at Login", null, async (_, _) => await ToggleRunAtLoginAsync());
        _exitItem = new ToolStripMenuItem("Exit", null, (_, _) => ExitApp());

        var menu = new ContextMenuStrip();
        menu.Items.Add("About pype", null, (_, _) => ShowAbout());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_runAtLoginItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_exitItem);
        // Re-check each time the menu opens rather than caching Checked, since
        // the underlying Scheduled Task can also be changed by the installer
        // or by re-running it, outside of this process. Async so opening the
        // menu doesn't stall the UI/message-pump thread on a schtasks.exe call.
        // Also re-applies _exitItem's disabled-while-typing state, in case the
        // menu is opened after typing already started.
        menu.Opening += async (_, _) =>
        {
            _exitItem.Enabled = !_isTyping;
            await RefreshRunAtLoginCheckedAsync();
        };
        _trayIcon.ContextMenuStrip = menu;

        try
        {
            // MOD_NOREPEAT stops WM_HOTKEY from re-firing on OS-level key
            // repeat while Ctrl+Shift+V is held - without it, holding the
            // combo down would spam OnHotkeyPressed on its own, before
            // _isTyping's re-entrancy guard even comes into play.
            _hotkeyWindow.RegisterHotkey(
                NativeMethods.MOD_CONTROL | NativeMethods.MOD_SHIFT | NativeMethods.MOD_NOREPEAT,
                NativeMethods.VK_V,
                AppInfo.HotkeyId);
        }
        catch (Exception ex)
        {
            _trayIcon.ShowBalloonTip(5000, "pype", ex.Message, ToolTipIcon.Error);
        }
    }

    private async void OnHotkeyPressed()
    {
        // Typing is now paced over real time (see AppInfo.TypingIntervalMs) -
        // up to ~1.3s for the full 128 characters - instead of one
        // instantaneous batch, so there's a real window for the hotkey to
        // fire again before the previous run finishes. Without this guard,
        // two overlapping TypeAsync calls would interleave their keystrokes
        // into garbled output.
        if (_isTyping) return;
        _isTyping = true;
        // Also disable Exit for that same window: without this, choosing Exit
        // mid-type disposes _hotkeyWindow/_trayIcon and stops the message
        // pump, silently abandoning the rest of TypeAsync's paced loop (its
        // queued continuation never gets to run) - not a crash, just
        // unnoticed truncated output. A single instantaneous SendInput batch
        // never had a large enough window for this to matter; the paced
        // version does.
        _exitItem.Enabled = false;

        try
        {
            string text;
            try
            {
                text = await ClipboardReader.GetTextWithRetryAsync();
            }
            catch (Exception ex)
            {
                _trayIcon.ShowBalloonTip(3000, "pype", $"Could not read the clipboard: {ex.Message}", ToolTipIcon.Error);
                return;
            }

            if (string.IsNullOrEmpty(text))
            {
                _trayIcon.ShowBalloonTip(3000, "pype", "Clipboard has no text to type.", ToolTipIcon.Warning);
                return;
            }

            bool truncated = text.Length > AppInfo.MaxTypeLength;
            string toType = truncated ? TruncateWithoutSplittingSurrogatePair(text, AppInfo.MaxTypeLength) : text;

            // Fire the notice first (it's non-blocking), then start typing right
            // away so it isn't held up waiting on the notification. Typing itself
            // is deliberately paced, not instantaneous - fast, but visibly
            // "typing" rather than an indistinguishable-from-paste flash.
            if (truncated)
            {
                _trayIcon.ShowBalloonTip(
                    4000,
                    "pype - text truncated",
                    $"Clipboard held {text.Length} characters; only the first {toType.Length} were typed.",
                    ToolTipIcon.Warning);
            }

            if (!await ClipboardTyper.TypeAsync(toType))
            {
                _trayIcon.ShowBalloonTip(
                    4000,
                    "pype",
                    "Typing was blocked by Windows — the target window may be running elevated (as Administrator).",
                    ToolTipIcon.Warning);
            }
        }
        finally
        {
            _isTyping = false;
            _exitItem.Enabled = true;
        }
    }

    private System.Drawing.Icon LoadAppIcon()
    {
        // Pulls pype's own embedded icon resource (set via <ApplicationIcon> in
        // Pype.csproj) straight from the running exe, so the tray icon always
        // matches whatever's shown for pype.exe in Explorer/Start Menu/taskbar
        // without needing a separately-managed resource stream. The extracted
        // Icon owns a native handle, unlike the SystemIcons.Application
        // fallback (a shared icon Windows Forms owns) — track it separately so
        // ExitApp can dispose only the one pype actually allocated.
        try
        {
            var extracted = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            if (extracted is not null)
            {
                _ownedIcon = extracted;
                return extracted;
            }
        }
        catch
        {
            // fall through to the shared system icon
        }

        return System.Drawing.SystemIcons.Application;
    }

    private static string TruncateWithoutSplittingSurrogatePair(string text, int maxLength)
    {
        int length = maxLength;
        if (length > 0 && length < text.Length && char.IsHighSurrogate(text[length - 1]))
        {
            length--;
        }
        return text[..length];
    }

    private async Task RefreshRunAtLoginCheckedAsync()
    {
        _runAtLoginItem.Checked = await AutoStartManager.IsEnabledAsync() == true;
    }

    private async Task ToggleRunAtLoginAsync()
    {
        bool enable = !_runAtLoginItem.Checked;
        (bool ok, string error) = enable
            ? await AutoStartManager.TryEnableAsync()
            : await AutoStartManager.TryDisableAsync();

        if (!ok)
        {
            _trayIcon.ShowBalloonTip(
                4000,
                "pype",
                $"Could not {(enable ? "enable" : "disable")} Run at Login: {error}",
                ToolTipIcon.Error);
        }

        // Re-query rather than assume: a Machine-scope task installed by an
        // admin/RMM commonly can't be modified by a standard user, so this
        // reflects what actually happened rather than the attempted state.
        await RefreshRunAtLoginCheckedAsync();
    }

    private void ShowAbout()
    {
        MessageBox.Show(
            $"{AppInfo.DisplayName}\n\nPress Ctrl+Shift+V anywhere to type the clipboard's text content.\n" +
            $"Text over {AppInfo.MaxTypeLength} characters is truncated, with a notice explaining why.",
            "About pype",
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }

    private void ExitApp()
    {
        _trayIcon.Visible = false;
        _hotkeyWindow.HotkeyPressed -= OnHotkeyPressed;
        _hotkeyWindow.Dispose();
        _trayIcon.Dispose();
        _ownedIcon?.Dispose();
        ExitThread();
    }
}
