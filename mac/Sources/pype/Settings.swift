// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import Foundation

/// Small persisted settings, stored in UserDefaults.
enum Settings {
    private static let checkForUpdatesKey = "CheckForUpdatesOnStartup"

    /// Whether pype checks GitHub for a newer version at launch. Defaults to on
    /// (the key is absent until the user first toggles it off).
    static var checkForUpdatesOnStartup: Bool {
        get {
            if UserDefaults.standard.object(forKey: checkForUpdatesKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: checkForUpdatesKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: checkForUpdatesKey)
        }
    }
}
