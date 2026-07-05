// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Pype;

internal sealed class TrayAppContext : ApplicationContext
{
    // When the user triggers typing from the tray menu (rather than the
    // hotkey), give focus a moment to return to the target window after the
    // menu closes before injecting keystrokes - otherwise the first few could
    // land in the wrong place. The hotkey path needs no delay (the target
    // already has focus).
    private const int MenuTypeFocusDelayMs = 350;

    private readonly NotifyIcon _trayIcon;
    private readonly HotkeyWindow _hotkeyWindow;
    private readonly ToolStripMenuItem _typeItem;
    private readonly ToolStripMenuItem _typeUnlimitedItem;
    private readonly ToolStripMenuItem _stopItem;
    private readonly ToolStripMenuItem _exitItem;
    // Installed-edition-only items (null in portable mode).
    private readonly ToolStripMenuItem? _runAtLoginItem;
    private readonly ToolStripMenuItem? _updateCheckItem;
    private readonly System.Drawing.Image? _clipboardImage;
    private readonly System.Drawing.Image? _clipboardUnlimitedImage;
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

        _clipboardImage = LoadMenuIcon("pype.clipboard.png");
        _clipboardUnlimitedImage = LoadMenuIcon("pype.clipboard-unlimited.png");

        // Type actions (both menu-triggered). The unlimited one is deliberately
        // NOT bound to the hotkey - typing an unbounded clipboard should be a
        // deliberate, explicit action, not something a keystroke can trigger.
        _typeItem = new ToolStripMenuItem("Type Clipboard", _clipboardImage,
            async (_, _) => await TypeClipboardAsync(fromMenu: true, unlimited: false));
        _typeUnlimitedItem = new ToolStripMenuItem("Type Clipboard — No Limit", _clipboardUnlimitedImage,
            async (_, _) => await TypeClipboardAsync(fromMenu: true, unlimited: true));
        _stopItem = new ToolStripMenuItem("Stop Typing", null, (_, _) => StopTyping());
        _exitItem = new ToolStripMenuItem("Exit", null, (_, _) => ExitApp());

        var menu = new ContextMenuStrip();
        menu.Items.Add(_typeItem);
        menu.Items.Add(_typeUnlimitedItem);
        menu.Items.Add(_stopItem);
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

        // Apply state synchronously as the menu opens so it's correct on the
        // first (and every) open. While a type is in progress the only enabled
        // action is Stop Typing - everything else is disabled so a long
        // "no limit" type can't be interrupted halfway by another action.
        menu.Opening += (_, _) =>
        {
            bool typing = _isTyping;
            _typeItem.Enabled = !typing;
            _typeUnlimitedItem.Enabled = !typing;
            _stopItem.Enabled = typing;
            _exitItem.Enabled = !typing;
            if (_runAtLoginItem is not null)
            {
                _runAtLoginItem.Enabled = !typing;
                _runAtLoginItem.Checked = AutoStartManager.IsEnabled();
            }
            if (_updateCheckItem is not null)
            {
                _updateCheckItem.Enabled = !typing;
                _updateCheckItem.Checked = Settings.CheckForUpdatesOnStartup;
            }
        };
        _trayIcon.ContextMenuStrip = menu;

        // A left-click on the tray icon while a type is running stops it - the
        // low-friction stop the user can hit without opening the menu (opening
        // it mid-type is awkward because the injected keystrokes fight the menu
        // for focus). Right-click still opens the menu, which also has Stop.
        _trayIcon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left && _isTyping)
            {
                StopTyping();
            }
        };

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

    // The hotkey is a toggle: while a type is running it STOPS it, otherwise
    // it types the bounded (128-char) version. Stopping via the same key the
    // user already knows is the low-friction way out of a long "No Limit" run -
    // opening the menu mid-type is awkward, since the injected keystrokes fight
    // for focus with the menu itself.
    private async void OnHotkeyPressed()
    {
        if (_isTyping)
        {
            StopTyping();
            return;
        }
        await TypeClipboardAsync(fromMenu: false, unlimited: false);
    }

    private async Task TypeClipboardAsync(bool fromMenu, bool unlimited)
    {
        // One type at a time - overlapping runs would interleave keystrokes.
        if (_isTyping) return;
        _isTyping = true;

        _typeCts?.Dispose();
        _typeCts = new CancellationTokenSource();
        var token = _typeCts.Token;

        try
        {
            // Triggered from the menu: let focus return to the target window
            // after the menu closes before we start injecting keystrokes.
            if (fromMenu)
            {
                await Task.Delay(MenuTypeFocusDelayMs, token);
            }

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

            bool willTruncate = !unlimited && text.Length > AppInfo.MaxTypeLength;
            string toType = willTruncate ? TruncateWithoutSplittingSurrogatePair(text, AppInfo.MaxTypeLength) : text;

            // Fire the truncation notice first (non-blocking), then start typing
            // right away. Typing is deliberately paced, not instantaneous - fast,
            // but visibly "typing" rather than an indistinguishable-from-paste
            // flash. The "No Limit" action skips truncation entirely.
            if (willTruncate)
            {
                _trayIcon.ShowBalloonTip(
                    4000,
                    "pype - text truncated",
                    $"Clipboard held {text.Length} characters; only the first {toType.Length} were typed. Use \"Type Clipboard — No Limit\" for all of it.",
                    ToolTipIcon.Warning);
            }

            bool ok = await ClipboardTyper.TypeAsync(toType, token);
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
            // Stopped via "Stop Typing" during the focus delay - nothing to report.
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

    // Loads an embedded menu icon by its manifest resource name, returning a
    // copy independent of the (disposed) stream. Returns null on any failure so
    // a missing/renamed resource just means "no icon", not a crash.
    private static System.Drawing.Image? LoadMenuIcon(string logicalName)
    {
        try
        {
            using var stream = typeof(TrayAppContext).Assembly.GetManifestResourceStream(logicalName);
            if (stream is null) return null;
            using var loaded = new System.Drawing.Bitmap(stream);
            return new System.Drawing.Bitmap(loaded);
        }
        catch
        {
            return null;
        }
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
            body: "Press Ctrl+Shift+V anywhere (or use \"Type Clipboard\" in this menu) to\n" +
                  $"type the clipboard's text content. Text over {AppInfo.MaxTypeLength} characters is\n" +
                  "truncated; \"Type Clipboard — No Limit\" types all of it.\n\n" +
                  "To stop a type in progress: press Ctrl+Shift+V again, left-click the\n" +
                  "tray icon, or use \"Stop Typing\".",
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
        _clipboardImage?.Dispose();
        _clipboardUnlimitedImage?.Dispose();
        _typeCts?.Dispose();
        ExitThread();
    }
}
