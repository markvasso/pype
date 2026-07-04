// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let singleInstanceLock = SingleInstanceLock()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard singleInstanceLock.acquire() else {
            let alert = NSAlert()
            alert.messageText = "pype is already running (check the menu bar)."
            alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Menu-bar-only app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        NotificationManager.requestAuthorization()
        statusBarController = StatusBarController()
    }
}
