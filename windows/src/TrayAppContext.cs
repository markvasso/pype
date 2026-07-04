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
    private bool _runAtLoginKnownEnabled;

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
        // Apply state synchronously as the menu opens so it's visible on THIS
        // open, not the next one. The Run-at-Login checkmark comes from a
        // cached value because querying it fresh means shelling out to
        // schtasks.exe (tens to hundreds of ms) - too slow to block the menu
        // render on, and an `await` here would apply the checkmark only after
        // the menu is already on screen. So: show the last-known state
        // instantly, then refresh the cache in the background so it's correct
        // next open (and picks up any external change, e.g. the installer
        // re-running or Task Scheduler being edited by hand).
        menu.Opening += (_, _) =>
        {
            _exitItem.Enabled = !_isTyping;
            _runAtLoginItem.Checked = _runAtLoginKnownEnabled;
            _ = RefreshRunAtLoginCheckedAsync();
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

        // Prime the cached Run-at-Login state so the checkmark is correct on
        // the first menu open, not just from the second onward.
        _ = RefreshRunAtLoginCheckedAsync();
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
        catch (Exception ex)
        {
            // Core action - keep any unexpected failure in the typing path a
            // dismissible balloon rather than letting it escape this async void
            // handler onto the UI thread (Program.cs has a global backstop, but
            // a balloon is friendlier than its generic error dialog).
            _trayIcon.ShowBalloonTip(4000, "pype", $"Could not type the clipboard: {ex.Message}", ToolTipIcon.Error);
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
        try
        {
            _runAtLoginKnownEnabled = await AutoStartManager.IsEnabledAsync() == true;
            _runAtLoginItem.Checked = _runAtLoginKnownEnabled;
        }
        catch
        {
            // Best-effort status refresh (called fire-and-forget from the menu
            // Opening/constructor). If querying the task throws - e.g.
            // schtasks.exe can't be launched - just keep the last-known
            // checkmark rather than letting an unobserved Task exception drop
            // silently or, worse, surface elsewhere.
        }
    }

    private async Task ToggleRunAtLoginAsync()
    {
        bool enable = !_runAtLoginItem.Checked;
        bool ok;
        string error;
        try
        {
            (ok, error) = enable
                ? await AutoStartManager.TryEnableAsync()
                : await AutoStartManager.TryDisableAsync();
        }
        catch (Exception ex)
        {
            // TryEnable/TryDisable translate a non-zero schtasks exit into a
            // clean (false, error), but a thrown exception (e.g. schtasks.exe
            // unresolvable) would otherwise escape this async void click
            // handler onto the UI thread. Handle it here so the user gets the
            // same tidy balloon.
            ok = false;
            error = ex.Message;
        }

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
