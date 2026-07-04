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

    public const int HotkeyId = 0xB001;
}
