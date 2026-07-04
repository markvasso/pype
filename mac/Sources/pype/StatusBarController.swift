// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import AppKit
import ApplicationServices

/// Menu bar item + menu — the macOS equivalent of the Windows tray icon.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let hotkeyManager = HotkeyManager()
    private let runAtLoginItem = NSMenuItem()
    private let accessibilityItem = NSMenuItem()
    private let quitItem = NSMenuItem()
    private var isTyping = false
    // Guards the "needs Accessibility" notification so it fires at most once
    // per not-granted episode instead of on every hotkey press. Reset to
    // false whenever trust is observed as granted, so a later loss of the
    // permission re-notifies.
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

        let menu = NSMenu()
        menu.delegate = self

        let aboutItem = NSMenuItem(title: "About pype", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Accessibility status/affordance. Its title and action are set live
        // in menuWillOpen (AXIsProcessTrusted is a fast local call, safe to
        // query synchronously as the menu opens - unlike the schtasks-backed
        // Run-at-Login state). Gives the user a persistent, non-spammy way to
        // see whether pype can actually type and to jump straight to the
        // setting, instead of relying on a per-keypress notification.
        accessibilityItem.target = self
        accessibilityItem.action = #selector(fixAccessibility)
        menu.addItem(accessibilityItem)

        runAtLoginItem.title = "Run at Login"
        runAtLoginItem.action = #selector(toggleRunAtLogin)
        runAtLoginItem.target = self
        menu.addItem(runAtLoginItem)

        menu.addItem(.separator())

        quitItem.title = "Quit"
        quitItem.action = #selector(quit)
        quitItem.keyEquivalent = "q"
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // HotkeyManager's callback fires from a synchronous Carbon C
        // callback, which can't itself be async - wrap in an unstructured
        // Task so handleHotkey can use Task.sleep for the paced typing
        // effect without blocking that callback or the run loop.
        hotkeyManager.onHotkey = { [weak self] in
            Task { await self?.handleHotkey() }
        }
        if !hotkeyManager.register() {
            NotificationManager.show(
                title: "pype",
                body: "Could not register the Cmd+Shift+V hotkey. It may already be in use by another app."
            )
        }
    }

    // Refreshes the checkmark each time the menu opens rather than caching
    // it, since Run at Login can also be changed outside this process (e.g.
    // System Settings > General > Login Items). Also re-applies quitItem's
    // disabled-while-typing state, in case the menu is opened after typing
    // already started, and reflects live Accessibility status.
    func menuWillOpen(_ menu: NSMenu) {
        runAtLoginItem.state = AutoStartManager.isEnabled ? .on : .off
        quitItem.isEnabled = !isTyping

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

    @objc private func fixAccessibility() {
        promptForAccessibility()
    }

    // Opens the system Accessibility prompt and pre-populates pype in the
    // Privacy & Security > Accessibility list (unchecked, ready to toggle on).
    // AXIsProcessTrustedWithOptions with the prompt option is the documented
    // way to do this; without the option it's a silent status check.
    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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
            Press Cmd+Shift+V anywhere to type the clipboard's text content.
            Text over \(AppInfo.maxTypeLength) characters is truncated.
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
        NSApp.terminate(nil)
    }

    private func handleHotkey() async {
        // Typing is paced over real time (see AppInfo.typingIntervalNanoseconds)
        // - up to ~1.3s for the full 128 characters - instead of one
        // instantaneous burst, so there's a real window for the hotkey to
        // fire again before the previous run finishes. Without this guard,
        // two overlapping ClipboardTyper.type calls would interleave their
        // keystrokes into garbled output. StatusBarController is @MainActor,
        // and this method (like the Task{} that calls it) always runs on
        // that actor, so this check-then-set is race-free.
        guard !isTyping else { return }
        isTyping = true
        // Also disable Quit for that same window: without this, choosing
        // Quit mid-type calls NSApp.terminate while ClipboardTyper.type's
        // paced loop is still mid-Task.sleep, silently abandoning the rest
        // of the characters - not a crash, just unnoticed truncated output.
        // A single instantaneous burst never had a large enough window for
        // this to matter; the paced version does.
        quitItem.isEnabled = false
        defer {
            isTyping = false
            quitItem.isEnabled = true
        }

        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NotificationManager.show(title: "pype", body: "Clipboard has no text to type.")
            return
        }

        // Check Accessibility BEFORE the truncation notice: otherwise an
        // ungranted user sees "only the first 128 were typed" (past tense,
        // implying success) followed by "permission required" - contradictory,
        // and nothing was actually typed. AXIsProcessTrusted() is a fast local
        // call, so gating on it up front costs nothing.
        guard AXIsProcessTrusted() else {
            // Notify at most once per not-granted episode - firing on every
            // keypress is exactly the "constant" barrage we want to avoid.
            // Also open the system prompt (once) so the fix is one click away;
            // the menu's "Grant Accessibility Access…" item is the persistent
            // path. hasWarnedNoAccessibility resets once trust is regained
            // (below and in menuWillOpen), so a later loss re-notifies.
            if !hasWarnedNoAccessibility {
                hasWarnedNoAccessibility = true
                promptForAccessibility()
                NotificationManager.show(
                    title: "pype",
                    body: "Accessibility permission is required to type. Enable pype under System Settings > Privacy & Security > Accessibility (opened for you). If it's already enabled, quit and reopen pype."
                )
            }
            return
        }
        hasWarnedNoAccessibility = false

        let truncated = text.count > AppInfo.maxTypeLength
        // Character-based truncation (Swift's default String semantics) never
        // splits an extended grapheme cluster, unlike a raw UTF-16 code-unit
        // cut would — no separate surrogate-pair-safety check needed here.
        let toType = truncated ? String(text.prefix(AppInfo.maxTypeLength)) : text

        // Fire the notice first (it's non-blocking), then start typing right
        // away so it isn't held up waiting on it. Typing itself is
        // deliberately paced (see AppInfo.typingIntervalNanoseconds), not
        // instantaneous - fast, but visibly "typing" rather than an
        // indistinguishable-from-paste flash.
        if truncated {
            NotificationManager.show(
                title: "pype - text truncated",
                body: "Clipboard held \(text.count) characters; only the first \(toType.count) were typed."
            )
        }

        await ClipboardTyper.type(toType)
    }
}
