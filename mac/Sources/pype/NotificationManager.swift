// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import UserNotifications
import os.log

/// Non-blocking notices, the macOS equivalent of the Windows tray balloon
/// tips. Requires the user to grant notification permission on first launch
/// (a separate, one-time system prompt) — if that's declined, notices are
/// silently dropped rather than typing being blocked on it.
enum NotificationManager {
    private static let logger = Logger(subsystem: "pype", category: "notifications")

    // UNUserNotificationCenter requires the process to be a properly signed
    // app bundle (it reads bundleProxyForCurrentProcess internally) — calling
    // it from a bare executable (e.g. running `swift run`/.build/*/pype
    // directly, outside pype.app) crashes with an uncaught
    // NSInternalInconsistencyException. Bundle.main.bundleIdentifier is nil
    // in that case, so use it to detect and skip rather than crash.
    private static var isRunningFromBundle: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func requestAuthorization() {
        guard isRunningFromBundle else {
            logger.notice("Not running from an app bundle; skipping notification permission request.")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                logger.notice("Notification permission was declined; truncation/error notices will be silently dropped.")
            }
        }
    }

    static func show(title: String, body: String) {
        guard isRunningFromBundle else {
            logger.notice("Not running from an app bundle; printing notice instead of posting a notification: \(title, privacy: .public) - \(body, privacy: .public)")
            print("[pype] \(title): \(body)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
