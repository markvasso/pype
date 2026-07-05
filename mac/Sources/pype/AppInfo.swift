// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import Foundation

/// Shared constants for the app.
enum AppInfo {
    static let displayName = "pype - Clipboard Typer"

    /// Nanoseconds between injected keystrokes. Deliberately not 0: typing
    /// the clipboard in one instantaneous burst looks identical to a native
    /// paste, giving the user no visible cue that pype (rather than the user,
    /// or something else) is the one entering the text. Fast enough not to
    /// feel sluggish, slow enough to visibly read as "typing."
    static let typingIntervalNanoseconds: UInt64 = 10_000_000 // 10ms

    /// Project home, shown/linked in the About dialog.
    static let repoUrl = "https://github.com/markvasso/pype"

    /// Where the launch-time update check sends users to download a newer version.
    static let releasesUrl = "https://github.com/markvasso/pype/releases"

    /// GitHub API endpoint the update check reads the latest release tag from.
    static let latestReleaseApiUrl = "https://api.github.com/repos/markvasso/pype/releases/latest"

    /// The running app's short version (e.g. "1.0.2"), read from the bundle.
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
