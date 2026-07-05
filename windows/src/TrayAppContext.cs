// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Pype;

internal sealed class TrayAppContext : ApplicationContext
{
    private readonly NotifyIcon _trayIcon;
    private readonly HotkeyWindow _hotkeyWindow;
    private readonly ToolStripMenuItem _exitItem;
    // Installed-edition-only items (null in portable mode).
    private readonly ToolStripMenuItem? _runAtLoginItem;
    private readonly ToolStripMenuItem? _updateCheckItem;
    private System.Drawing.Icon? _ownedIcon;
    private bool _isTyping;
    private CancellationTokenSource? _typeCts;

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

        // Typing is invoked only by the global hotkey, never from the menu - a
        // menu-invoked type couldn't reliably keep focus on the target app (the
        // tray menu steals it), which is why the menu just states the shortcut.
        // These lines are informational (disabled).
        var typeInfo = new ToolStripMenuItem("Ctrl + ` — Type clipboard") { Enabled = false };
        var stopInfo = new ToolStripMenuItem("Press the shortcut again to stop") { Enabled = false };
        _exitItem = new ToolStripMenuItem("Exit", null, (_, _) => ExitApp());

        var menu = new ContextMenuStrip();
        menu.Items.Add(typeInfo);
        menu.Items.Add(stopInfo);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("About pype", null, (_, _) => ShowAbout());

        // Run at Login and the update-check toggle are install-only: a portable
        // pype.exe doesn't manage autostart or check for updates.
        if (AppMode.IsInstalled)
        {
            _runAtLoginItem = new ToolStripMenuItem("Run at Login", null, (_, _) => ToggleRunAtLogin());
            _updateCheckItem = new ToolStripMenuItem("Check for updates on startup", null, (_, _) => ToggleUpdateCheck());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(_runAtLoginItem);
            menu.Items.Add(_updateCheckItem);
        }

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_exitItem);

        // Refresh the toggles' checkmarks each time the menu opens (Run at Login
        // can also be changed outside pype, e.g. in Task Manager's Startup tab).
        menu.Opening += (_, _) =>
        {
            if (_runAtLoginItem is not null) _runAtLoginItem.Checked = AutoStartManager.IsEnabled();
            if (_updateCheckItem is not null) _updateCheckItem.Checked = Settings.CheckForUpdatesOnStartup;
        };
        _trayIcon.ContextMenuStrip = menu;

        try
        {
            // MOD_NOREPEAT stops WM_HOTKEY from re-firing on OS-level key repeat
            // while Ctrl+` is held - without it, holding it down would spam
            // OnHotkeyPressed before _isTyping's re-entrancy guard comes into play.
            _hotkeyWindow.RegisterHotkey(
                NativeMethods.MOD_CONTROL | NativeMethods.MOD_NOREPEAT,
                NativeMethods.VK_OEM_3,
                AppInfo.HotkeyId);
        }
        catch (Exception ex)
        {
            _trayIcon.ShowBalloonTip(5000, "pype", ex.Message, ToolTipIcon.Error);
        }

        // Update check: installed edition only, and only if the user hasn't
        // turned it off. Run once the message loop is actually up - starting
        // the async work in the constructor would run before Application.Run
        // installs the WinForms SynchronizationContext, so the continuation
        // (which shows UI) could resume off the UI thread. Application.Idle
        // first fires once the loop is running.
        if (AppMode.IsInstalled && Settings.CheckForUpdatesOnStartup)
        {
            Application.Idle += OnFirstIdle;
        }
    }

    private void OnFirstIdle(object? sender, EventArgs e)
    {
        Application.Idle -= OnFirstIdle;
        _ = CheckForUpdatesAsync();
    }

    // Ctrl+` is a toggle: while a type is running it STOPS it; otherwise it
    // types the whole clipboard. The target window keeps focus (the hotkey
    // doesn't steal it the way opening the tray menu would), so no focus
    // juggling is needed.
    private async void OnHotkeyPressed()
    {
        if (_isTyping)
        {
            StopTyping();
            return;
        }
        await TypeClipboardAsync();
    }

    private async Task TypeClipboardAsync()
    {
        // One type at a time - overlapping runs would interleave keystrokes.
        if (_isTyping) return;
        _isTyping = true;

        _typeCts?.Dispose();
        _typeCts = new CancellationTokenSource();
        var token = _typeCts.Token;

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

            // Typing is deliberately paced, not instantaneous - fast, but
            // visibly "typing" rather than an indistinguishable-from-paste flash.
            bool ok = await ClipboardTyper.TypeAsync(text, token);
            if (!ok && !token.IsCancellationRequested)
            {
                _trayIcon.ShowBalloonTip(
                    4000,
                    "pype",
                    "Typing was blocked by Windows — the target window may be running elevated (as Administrator).",
                    ToolTipIcon.Warning);
            }
        }
        catch (OperationCanceledException)
        {
            // Stopped via the hotkey - nothing to report.
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
        }
    }

    private void StopTyping() => _typeCts?.Cancel();

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

    private void ToggleRunAtLogin()
    {
        bool enable = !AutoStartManager.IsEnabled();
        bool ok = enable
            ? AutoStartManager.TryEnable(out string error)
            : AutoStartManager.TryDisable(out error);

        if (!ok)
        {
            _trayIcon.ShowBalloonTip(
                4000,
                "pype",
                $"Could not {(enable ? "enable" : "disable")} Run at Login: {error}",
                ToolTipIcon.Error);
        }
        else if (!enable && AutoStartManager.IsEnabled())
        {
            // The tray toggle only manages the per-user (HKCU) entry. If
            // autostart is still on after a "disable", it's held by a
            // machine-wide (HKLM) entry an admin/RMM set - a standard user
            // can't remove it. Explain rather than appear to do nothing.
            _trayIcon.ShowBalloonTip(
                5000,
                "pype",
                "Run at Login is managed for all users (set by an administrator) and can't be turned off here.",
                ToolTipIcon.Info);
        }

        // Reflect what actually happened rather than assuming.
        if (_runAtLoginItem is not null) _runAtLoginItem.Checked = AutoStartManager.IsEnabled();
    }

    private void ToggleUpdateCheck()
    {
        try
        {
            Settings.CheckForUpdatesOnStartup = !Settings.CheckForUpdatesOnStartup;
        }
        catch (Exception ex)
        {
            // Persisting the setting writes to HKCU; on a locked-down profile
            // that could throw. Degrade to a balloon like the Run-at-Login
            // toggle rather than escaping to the global crash dialog.
            _trayIcon.ShowBalloonTip(4000, "pype", $"Could not save the update-check setting: {ex.Message}", ToolTipIcon.Error);
        }
        if (_updateCheckItem is not null) _updateCheckItem.Checked = Settings.CheckForUpdatesOnStartup;
    }

    private void ShowAbout()
    {
        ShowInfoWithLink(
            caption: "About pype",
            heading: $"{AppInfo.DisplayName} {UpdateChecker.LocalVersionString}",
            body: "Press Ctrl+` anywhere to type the clipboard's text content\n" +
                  "wherever your cursor is. Press the same shortcut again to stop\n" +
                  "a type in progress.",
            url: AppInfo.RepoUrl);
    }

    private async Task CheckForUpdatesAsync()
    {
        string? newer = await UpdateChecker.GetNewerVersionAsync();
        if (newer is null) return; // up to date, offline, or check failed - stay quiet

        ShowInfoWithLink(
            caption: "pype update available",
            heading: $"pype {newer} is available",
            body: $"You're running {UpdateChecker.LocalVersionString}. A newer version can be downloaded from the releases page.",
            url: AppInfo.ReleasesUrl);
    }

    // Shows an info dialog whose text includes a clickable link. Uses the modern
    // TaskDialog (which renders <a> links); if that's unavailable for any reason
    // it falls back to a plain MessageBox that still shows the URL as text.
    private static void ShowInfoWithLink(string caption, string heading, string body, string url)
    {
        try
        {
            var page = new TaskDialogPage
            {
                Caption = caption,
                Heading = heading,
                Text = $"{body}\n\n<a href=\"{url}\">{url}</a>",
                Icon = TaskDialogIcon.Information,
                EnableLinks = true,
            };
            page.LinkClicked += (_, e) => OpenUrl(string.IsNullOrEmpty(e.LinkHref) ? url : e.LinkHref);
            TaskDialog.ShowDialog(page);
        }
        catch
        {
            MessageBox.Show(
                $"{heading}\n\n{body}\n\n{url}",
                caption,
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
    }

    private static void OpenUrl(string url)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch
        {
            // Opening a browser is best-effort; nothing useful to do on failure.
        }
    }

    private void ExitApp()
    {
        _typeCts?.Cancel();
        _trayIcon.Visible = false;
        _hotkeyWindow.HotkeyPressed -= OnHotkeyPressed;
        _hotkeyWindow.Dispose();
        _trayIcon.Dispose();
        _ownedIcon?.Dispose();
        _typeCts?.Dispose();
        ExitThread();
    }
}
