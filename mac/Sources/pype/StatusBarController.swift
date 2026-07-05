// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import AppKit
import ApplicationServices

/// Menu bar item + menu — the macOS equivalent of the Windows tray icon.
///
/// Typing is invoked only by the two global hotkeys: Cmd+` types the clipboard
/// (bounded) and Cmd+Shift+` types all of it; pressing either again stops a
/// type in progress. The menu itself just states the shortcuts (a menu-invoked
/// type couldn't reliably keep focus on the target app). Only the keystroke
/// *injection* in ClipboardTyper needs Accessibility permission — hotkey
/// *detection* (Carbon RegisterEventHotKey) needs none.
///
/// Because these builds aren't Developer ID signed, the Accessibility grant
/// doesn't survive an update (the new build has a different code identity), so
/// the menu keeps a live "Grant Accessibility Access…" affordance and the
/// guidance spells out how to remove the stale entry and re-add this copy.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let hotkeyManager = HotkeyManager()
    private let accessibilityItem = NSMenuItem()
    private let runAtLoginItem = NSMenuItem()
    private let updateCheckItem = NSMenuItem()
    private var isTyping = false
    private var typingTask: Task<Void, Never>?
    // Shows the "needs Accessibility" notice at most once per not-granted
    // episode instead of on every hotkey press; reset once trust is observed.
    private var hasWarnedNoAccessibility = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            if let image = NSImage(named: "MenuBarIcon") {
                image.isTemplate = true
                button.image = image
            } else {
                // Fallback so the item is still visible/clickable if the
                // bundled icon resource is missing for some reason.
                button.title = "pype"
            }
        }

        menu.delegate = self
        // We manage enabled state ourselves (the info lines below stay disabled;
        // the accessibility item is toggled live in menuWillOpen).
        menu.autoenablesItems = false

        // Informational lines stating the shortcuts. Typing is hotkey-only, so
        // these aren't actions - just a reminder of the two combos.
        menu.addItem(infoItem("⌘` — Type clipboard"))
        menu.addItem(infoItem("⌘⇧` — Type all (no limit)"))
        menu.addItem(infoItem("Press the shortcut again to stop"))

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About pype", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Accessibility status/affordance. Its title and enabled state are set
        // live in menuWillOpen (AXIsProcessTrusted is a fast local call, safe
        // to query synchronously as the menu opens). Gives the user a
        // persistent way to see whether pype can actually type and to jump
        // straight to the setup + troubleshooting guidance.
        accessibilityItem.action = #selector(grantAccessibility)
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        runAtLoginItem.title = "Run at Login"
        runAtLoginItem.action = #selector(toggleRunAtLogin)
        runAtLoginItem.target = self
        menu.addItem(runAtLoginItem)

        updateCheckItem.title = "Check for updates on startup"
        updateCheckItem.action = #selector(toggleUpdateCheck)
        updateCheckItem.target = self
        menu.addItem(updateCheckItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // HotkeyManager's callback fires from a synchronous Carbon C callback,
        // which can't itself be async - hop to the main actor. Both hotkeys are
        // toggles: while a type runs either STOPS it; otherwise Cmd+` types the
        // bounded clipboard and Cmd+Shift+` types all of it. The target window
        // keeps focus (unlike opening the menu), so no focus juggling is needed.
        hotkeyManager.onHotkey = { [weak self] unlimited in
            Task { @MainActor in
                guard let self else { return }
                if self.isTyping {
                    self.stopTyping()
                } else {
                    self.startTyping(unlimited: unlimited)
                }
            }
        }
        if !hotkeyManager.register() {
            NotificationManager.show(
                title: "pype",
                body: "Could not register the Cmd+` / Cmd+Shift+` hotkeys. They may already be in use by another app or by the macOS \"move focus to next/previous window\" shortcuts."
            )
        }
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // Refreshes the toggle checkmarks and the live Accessibility status each
    // time the menu opens (Run at Login can also be changed outside pype, e.g.
    // in System Settings > Login Items).
    func menuWillOpen(_ menu: NSMenu) {
        runAtLoginItem.state = AutoStartManager.isEnabled ? .on : .off
        updateCheckItem.state = Settings.checkForUpdatesOnStartup ? .on : .off

        if AXIsProcessTrusted() {
            accessibilityItem.title = "Accessibility Access: Granted"
            accessibilityItem.state = .on
            accessibilityItem.isEnabled = false
            hasWarnedNoAccessibility = false
        } else {
            accessibilityItem.title = "Grant Accessibility Access…"
            accessibilityItem.state = .off
            accessibilityItem.isEnabled = true
        }
    }

    private func startTyping(unlimited: Bool) {
        // Set isTyping synchronously here, on the main actor, BEFORE launching
        // the task - not inside performTyping. If it were only set inside the
        // (asynchronously-scheduled) task, two rapid triggers could both pass
        // the guard and overwrite `typingTask`, leaving the stop pointed at the
        // wrong task. Setting it here makes the check-and-set atomic.
        guard !isTyping else { return }
        isTyping = true
        typingTask = Task { await performTyping(unlimited: unlimited) }
    }

    private func stopTyping() {
        typingTask?.cancel()
    }

    @objc private func toggleUpdateCheck() {
        Settings.checkForUpdatesOnStartup.toggle()
        updateCheckItem.state = Settings.checkForUpdatesOnStartup ? .on : .off
    }

    @objc private func grantAccessibility() {
        showAccessibilityHelp()
    }

    // Opens the Accessibility settings pane directly.
    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The Accessibility "prompt": a modal that explains how to grant the
    /// permission AND — crucially for these unsigned builds — how to fix the
    /// common post-update case where pype is already listed but still can't
    /// type. Shown from the menu item and from a failed type (once per
    /// not-granted episode).
    private func showAccessibilityHelp() {
        let alert = NSAlert()
        alert.messageText = "Allow pype to type"
        alert.informativeText = """
            pype needs Accessibility permission to type into other apps. Open \
            System Settings ▸ Privacy & Security ▸ Accessibility, then:

            • If pype isn't listed, click +, choose this copy of pype.app, and \
            turn it on.

            • If pype IS listed but still can't type — this normally happens \
            right after updating pype, because the new version has a different \
            identity than the one macOS remembers — select the existing pype \
            entry, click − to remove it, then click + and add this copy of \
            pype.app again, and turn it on.

            Quit and reopen pype after granting access.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    @objc private func toggleRunAtLogin() {
        do {
            if AutoStartManager.isEnabled {
                try AutoStartManager.disable()
            } else {
                try AutoStartManager.enable()
                if AutoStartManager.requiresApproval {
                    NotificationManager.show(
                        title: "pype",
                        body: "Run at Login needs approval: open System Settings > General > Login Items & Extensions and enable pype there."
                    )
                }
            }
        } catch {
            NotificationManager.show(
                title: "pype",
                body: "Could not change Run at Login: \(error.localizedDescription)"
            )
        }
        runAtLoginItem.state = AutoStartManager.isEnabled ? .on : .off
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "\(AppInfo.displayName) \(AppInfo.version)"
        alert.informativeText = """
            Press Cmd+` anywhere to type the clipboard's text content. Text over \(AppInfo.maxTypeLength) characters is truncated; press Cmd+Shift+` to type all of it.

            Press the same shortcut again to stop a type in progress.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "View on GitHub")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            openURL(AppInfo.repoUrl)
        }
    }

    /// Shows a modal notice that a newer release exists, with a button that
    /// opens the releases page. Called once at launch (see AppDelegate).
    func notifyUpdateAvailable(_ newerVersion: String) {
        let alert = NSAlert()
        alert.messageText = "pype \(newerVersion) is available"
        alert.informativeText = "You're running \(AppInfo.version). A newer version can be downloaded from the releases page."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openURL(AppInfo.releasesUrl)
        }
    }

    private func openURL(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        typingTask?.cancel()
        NSApp.terminate(nil)
    }

    private func performTyping(unlimited: Bool) async {
        // isTyping was set by startTyping (synchronously, on the main actor)
        // before this task was launched, so the single-run guarantee holds;
        // this just clears it when the run finishes, however it exits.
        defer { isTyping = false }

        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NotificationManager.show(title: "pype", body: "Clipboard has no text to type.")
            return
        }

        // Check Accessibility up front — macOS gates keystroke injection behind
        // it and silently drops CGEvents without it. Show the full setup +
        // troubleshooting guidance once per not-granted episode (firing on
        // every hotkey press would be a barrage). hasWarnedNoAccessibility
        // resets once trust is regained (below and in menuWillOpen), so a later
        // loss of the grant — e.g. after an update — re-notifies.
        guard AXIsProcessTrusted() else {
            if !hasWarnedNoAccessibility {
                hasWarnedNoAccessibility = true
                showAccessibilityHelp()
            }
            return
        }
        hasWarnedNoAccessibility = false

        let willTruncate = !unlimited && text.count > AppInfo.maxTypeLength
        // Character-based truncation (Swift's default String semantics) never
        // splits an extended grapheme cluster, unlike a raw UTF-16 code-unit
        // cut would — no separate surrogate-pair-safety check needed here.
        let toType = willTruncate ? String(text.prefix(AppInfo.maxTypeLength)) : text

        // Fire the truncation notice first (non-blocking). Cmd+Shift+` skips
        // truncation entirely.
        if willTruncate {
            NotificationManager.show(
                title: "pype - text truncated",
                body: "Clipboard held \(text.count) characters; only the first \(toType.count) were typed. Press Cmd+Shift+` for all of it."
            )
        }

        await ClipboardTyper.type(toType)
    }
}
