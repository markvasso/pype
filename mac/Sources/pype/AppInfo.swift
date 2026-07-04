// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import Foundation

/// Shared constants for the app.
enum AppInfo {
    static let displayName = "pype - Clipboard Typer"

    /// Longest clipboard text that will be typed; longer text is truncated.
    static let maxTypeLength = 128

    /// Nanoseconds between injected keystrokes. Deliberately not 0: typing
    /// all 128 characters in one instantaneous burst looks identical to a
    /// native paste, giving the user no visible cue that pype (rather than
    /// the user, or something else) is the one entering the text. Fast
    /// enough not to feel sluggish, slow enough to visibly read as "typing."
    static let typingIntervalNanoseconds: UInt64 = 10_000_000 // 10ms
}
