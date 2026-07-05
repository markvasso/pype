// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

namespace Pype;

/// <summary>Shared constants for the app.</summary>
internal static class AppInfo
{
    public const string AppName = "pype";
    public const string DisplayName = "pype - Clipboard Typer";

    /// <summary>Longest clipboard text that will be typed; longer text is truncated.</summary>
    public const int MaxTypeLength = 128;

    /// <summary>
    /// Delay between injected keystrokes. Deliberately not 0: typing all 128
    /// characters in one instantaneous batch looks identical to a native
    /// paste, giving the user no visible cue that pype (rather than the
    /// user, or something else) is the one entering the text. Fast enough
    /// not to feel sluggish, slow enough to visibly read as "typing."
    /// </summary>
    public const int TypingIntervalMs = 10;

    /// <summary>Named mutex used to prevent a second instance from registering the hotkey twice.</summary>
    public const string MutexName = "Local\\Pype.SingleInstance.Mutex";

    // Two global hotkeys: Ctrl+` types the clipboard (bounded to MaxTypeLength),
    // Ctrl+Shift+` types all of it. Distinct ids so WM_HOTKEY can tell them apart.
    public const int HotkeyIdBounded = 0xB001;
    public const int HotkeyIdUnlimited = 0xB002;

    /// <summary>Project home, shown/linked in the About dialog.</summary>
    public const string RepoUrl = "https://github.com/markvasso/pype";

    /// <summary>Where the launch-time update check sends users to download a newer version.</summary>
    public const string ReleasesUrl = "https://github.com/markvasso/pype/releases";

    /// <summary>GitHub API endpoint the update check reads the latest release tag from.</summary>
    public const string LatestReleaseApiUrl = "https://api.github.com/repos/markvasso/pype/releases/latest";
}
