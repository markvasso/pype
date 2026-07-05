// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import AppKit
import ApplicationServices

/// Menu bar item + menu — the macOS equivalent of the Windows tray icon.
///
/// Typing can be triggered either by the global Cmd+Shift+V hotkey (the
/// Mac-native counterpart of the Windows build's Ctrl+Shift+V) or from this
/// menu. Only the keystroke *injection* in ClipboardTyper needs Accessibility
/// permission — hotkey *detection* (Carbon RegisterEventHotKey) needs none.
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
    private let typeItem = NSMenuItem()
    private let typeUnlimitedItem = NSMenuItem()
    private let stopItem = NSMenuItem()
    private let accessibilityItem = NSMenuItem()
    private let runAtLoginItem = NSMenuItem()
    private let updateCheckItem = NSMenuItem()
    private let quitItem = NSMenuItem()
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
            // Handle clicks ourselves instead of assigning statusItem.menu
            // permanently: while a type runs a click must STOP it (not open the
            // menu), and otherwise it should open the menu. statusItemClicked
            // decides which, and pops the menu with NSMenu.popUp when needed.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu.delegate = self

        // Primary action: type the clipboard (bounded to 128 characters),
        // same as the Cmd+Shift+V hotkey.
        typeItem.title = "Type Clipboard"
        typeItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Type clipboard")
        typeItem.action = #selector(typeClipboard(_:))
        typeItem.target = self
        menu.addItem(typeItem)

        // Types the ENTIRE clipboard, no 128-char cap. Deliberately menu-only
        // (never the hotkey) so injecting an unbounded clipboard is always an
        // explicit, deliberate action.
        typeUnlimitedItem.title = "Type Clipboard — No Limit"
        typeUnlimitedItem.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Type entire clipboard")
        typeUnlimitedItem.action = #selector(typeClipboardUnlimited(_:))
        typeUnlimitedItem.target = self
        menu.addItem(typeUnlimitedItem)

        stopItem.title = "Stop Typing"
        stopItem.action = #selector(stopTyping)
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About pype", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Accessibility status/affordance. Its title and enabled state are set
        // live in menuWillOpen (AXIsProcessTrusted is a fast local call, safe
        // to query synchronously as the menu opens). Gives the user a
        // persistent, non-spammy way to see whether pype can actually type and
        // to jump straight to the setup + troubleshooting guidance.
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

        quitItem.title = "Quit"
        quitItem.action = #selector(quit)
        quitItem.keyEquivalent = "q"
        quitItem.target = self
        menu.addItem(quitItem)

        // HotkeyManager's callback fires from a synchronous Carbon C callback,
        // which can't itself be async - hop to the main actor. The hotkey is a
        // toggle: while a type runs it STOPS it (the low-friction way out of a
        // long "No Limit" run — reaching the menu mid-type is awkward), and
        // otherwise it starts a bounded, non-menu type. It never triggers the
        // unbounded "No Limit" variant.
        hotkeyManager.onHotkey = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.isTyping {
                    self.stopTyping()
                } else {
                    self.startTyping(unlimited: false, fromMenu: false)
                }
            }
        }
        if !hotkeyManager.register() {
            NotificationManager.show(
                title: "pype",
                body: "Could not register the Cmd+Shift+V hotkey. It may already be in use by another app. You can still type from the menu bar icon."
            )
        }
    }

    // A click on the menu bar icon. While a type is running it STOPS it - the
    // easy-to-hit stop that doesn't require opening the menu (opening it
    // mid-type is awkward, since the injected keystrokes fight the menu for
    // focus). Otherwise it opens the menu.
    //
    // We show the menu with popUp(...) rather than assigning statusItem.menu:
    // a permanent statusItem.menu would auto-open on every click, defeating the
    // click-to-stop behavior, and the assign-then-performClick workaround risks
    // re-entering this handler. popUp is deterministic and can't recurse. The
    // manual highlight gives the button the usual "pressed" look while open.
    @objc private func statusItemClicked() {
        if isTyping {
            stopTyping()
            return
        }
        guard let button = statusItem.button else { return }
        button.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        button.highlight(false)
    }

    // Refreshes item state each time the menu opens. While a type is in
    // progress the only enabled action is Stop Typing, so a long "no limit"
    // type can't be interrupted halfway by another action. Also reflects live
    // Accessibility status.
    func menuWillOpen(_ menu: NSMenu) {
        typeItem.isEnabled = !isTyping
        typeUnlimitedItem.isEnabled = !isTyping
        stopItem.isEnabled = isTyping
        quitItem.isEnabled = !isTyping
        runAtLoginItem.isEnabled = !isTyping
        updateCheckItem.isEnabled = !isTyping
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
            accessibilityItem.isEnabled = !isTyping
        }
    }

    @objc private func typeClipboard(_ sender: Any?) {
        startTyping(unlimited: false, fromMenu: true)
    }

    @objc private func typeClipboardUnlimited(_ sender: Any?) {
        startTyping(unlimited: true, fromMenu: true)
    }

    private func startTyping(unlimited: Bool, fromMenu: Bool) {
        // Set isTyping synchronously here, on the main actor, BEFORE launching
        // the task - not inside performTyping. If it were only set inside the
        // (asynchronously-scheduled) task, two rapid triggers could both pass
        // the guard and overwrite `typingTask`, leaving Stop Typing pointed at
        // the wrong task. Setting it here makes the check-and-set atomic.
        guard !isTyping else { return }
        isTyping = true
        typingTask = Task { await performTyping(unlimited: unlimited, fromMenu: fromMenu) }
    }

    @objc private func stopTyping() {
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
            Press Cmd+Shift+V anywhere (or use "Type Clipboard" in this menu) to type the clipboard's text content.
            Text over \(AppInfo.maxTypeLength) characters is truncated; "Type Clipboard — No Limit" types all of it.

            To stop a type in progress: press Cmd+Shift+V again, click the menu bar icon, or use "Stop Typing".
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

    private func performTyping(unlimited: Bool, fromMenu: Bool) async {
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

        // Fire the truncation notice first (non-blocking). The "No Limit"
        // action skips truncation entirely.
        if willTruncate {
            NotificationManager.show(
                title: "pype - text truncated",
                body: "Clipboard held \(text.count) characters; only the first \(toType.count) were typed. Use \"Type Clipboard — No Limit\" for all of it."
            )
        }

        // Triggered from the menu: let focus return to the target window after
        // the menu closes before injecting keystrokes, so the first characters
        // don't land on the menu. The hotkey path needs no delay — the target
        // already has focus.
        if fromMenu {
            do {
                try await Task.sleep(nanoseconds: AppInfo.menuTypeFocusDelayNanoseconds)
            } catch {
                return // cancelled during the focus delay
            }
        }

        await ClipboardTyper.type(toType)
    }
}
