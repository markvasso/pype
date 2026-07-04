// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import ServiceManagement

/// Controls whether pype launches at login, via SMAppService (macOS 13+).
/// This is the modern replacement for LaunchAgent plists / SMLoginItemSetEnabled
/// — it only works for a properly signed .app bundle (Bundle.main must have a
/// real bundle identifier), not a bare command-line binary.
enum AutoStartManager {
    /// True once registration has succeeded, whether or not the user has
    /// additionally approved it yet — SMAppService has a third state,
    /// .requiresApproval, distinct from both "enabled" and "never
    /// registered": macOS itself may silently require the user to flip it on
    /// in System Settings > General > Login Items & Extensions before it
    /// actually runs at login, even though .register() returned success.
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func enable() throws {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return
        default:
            try SMAppService.mainApp.register()
        }
    }

    static func disable() throws {
        switch SMAppService.mainApp.status {
        case .notRegistered, .notFound:
            return
        default:
            try SMAppService.mainApp.unregister()
        }
    }
}
