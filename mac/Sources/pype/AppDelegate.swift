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
        checkForUpdates()
    }

    // One-shot, best-effort update check at launch, unless the user turned it
    // off in the menu. Failures are silent (see UpdateChecker); only a strictly
    // newer release surfaces a notice. The Task is @MainActor so the UI call
    // after the await stays on the main actor (the network work still runs off
    // it - newerVersion isn't isolated).
    private func checkForUpdates() {
        guard Settings.checkForUpdatesOnStartup else { return }
        Task { @MainActor [weak self] in
            guard let newer = await UpdateChecker.newerVersion() else { return }
            self?.statusBarController?.notifyUpdateAvailable(newer)
        }
    }
}
