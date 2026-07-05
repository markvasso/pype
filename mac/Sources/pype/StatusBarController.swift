// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import AppKit
import ApplicationServices

/// Menu bar item + menu — the macOS equivalent of the Windows tray icon.
///
/// Unlike the Windows build, macOS has NO global hotkey and does NOT prompt
/// for Accessibility. That's a deliberate platform difference: because these
/// builds aren't Developer ID signed, the Accessibility grant doesn't survive
/// updates, so a proactive prompt would mislead more than help. Typing is
/// invoked purely from this menu; the user grants Accessibility themselves in
/// System Settings if/when they want it to work.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let typeItem = NSMenuItem()
    private let typeUnlimitedItem = NSMenuItem()
    private let stopItem = NSMenuItem()
    private let runAtLoginItem = NSMenuItem()
    private let updateCheckItem = NSMenuItem()
    private let quitItem = NSMenuItem()
    private var isTyping = false
    private var typingTask: Task<Void, Never>?
    // Shows the "needs Accessibility" notice at most once per not-granted
    // episode instead of on every attempt; reset once trust is observed.
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

        // Primary action: type the clipboard (bounded to 128 characters).
        typeItem.title = "Type Clipboard"
        typeItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Type clipboard")
        typeItem.action = #selector(typeClipboard(_:))
        typeItem.target = self
        menu.addItem(typeItem)

        // Types the ENTIRE clipboard, no 128-char cap. Deliberately menu-only
        // (never a hotkey) so injecting an unbounded clipboard is always an
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

        statusItem.menu = menu
    }

    // Refreshes item state each time the menu opens. While a type is in
    // progress the only enabled action is Stop Typing, so a long "no limit"
    // type can't be interrupted halfway by another action.
    func menuWillOpen(_ menu: NSMenu) {
        typeItem.isEnabled = !isTyping
        typeUnlimitedItem.isEnabled = !isTyping
        stopItem.isEnabled = isTyping
        quitItem.isEnabled = !isTyping
        runAtLoginItem.isEnabled = !isTyping
        updateCheckItem.isEnabled = !isTyping
        runAtLoginItem.state = AutoStartManager.isEnabled ? .on : .off
        updateCheckItem.state = Settings.checkForUpdatesOnStartup ? .on : .off
    }

    @objc private func typeClipboard(_ sender: Any?) {
        startTyping(unlimited: false)
    }

    @objc private func typeClipboardUnlimited(_ sender: Any?) {
        startTyping(unlimited: true)
    }

    private func startTyping(unlimited: Bool) {
        // Set isTyping synchronously here, on the main actor, BEFORE launching
        // the task - not inside performTyping. If it were only set inside the
        // (asynchronously-scheduled) task, two rapid triggers could both pass
        // the guard and overwrite `typingTask`, leaving Stop Typing pointed at
        // the wrong task. Setting it here makes the check-and-set atomic.
        guard !isTyping else { return }
        isTyping = true
        typingTask = Task { await performTyping(unlimited: unlimited) }
    }

    @objc private func stopTyping() {
        typingTask?.cancel()
    }

    @objc private func toggleUpdateCheck() {
        Settings.checkForUpdatesOnStartup.toggle()
        updateCheckItem.state = Settings.checkForUpdatesOnStartup ? .on : .off
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
            Use "Type Clipboard" in this menu to type the clipboard's text content.
            Text over \(AppInfo.maxTypeLength) characters is truncated; "Type Clipboard — No Limit" types all of it.
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

        // Check Accessibility up front. macOS gates keystroke injection behind
        // it; without it CGEvents are silently dropped. We don't prompt (see
        // the type note above) - just inform, once, so a user isn't left
        // wondering why nothing typed.
        guard AXIsProcessTrusted() else {
            if !hasWarnedNoAccessibility {
                hasWarnedNoAccessibility = true
                NotificationManager.show(
                    title: "pype",
                    body: "pype needs Accessibility permission to type. Add pype under System Settings > Privacy & Security > Accessibility, then try again."
                )
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

        // Let focus return to the target window after the menu closes before
        // injecting keystrokes, so the first characters don't land on the menu.
        do {
            try await Task.sleep(nanoseconds: AppInfo.menuTypeFocusDelayNanoseconds)
        } catch {
            return // cancelled during the focus delay
        }

        await ClipboardTyper.type(toType)
    }
}
