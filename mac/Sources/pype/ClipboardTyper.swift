// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import CoreGraphics
import Carbon.HIToolbox

/// Simulates keystrokes for arbitrary Unicode text via CGEvent, so pype
/// works regardless of the active keyboard layout. Requires Accessibility
/// permission (System Settings > Privacy & Security > Accessibility) —
/// posting synthetic input into other apps is gated behind it on macOS.
enum ClipboardTyper {
    /// - Returns: true if typing was attempted (Accessibility was granted).
    ///   CGEvent posting has no synchronous success/failure signal the way
    ///   Windows' SendInput does, so this reports whether the OS would even
    ///   let us try, not whether every keystroke landed.
    @discardableResult
    static func type(_ text: String) async -> Bool {
        guard !text.isEmpty else { return true }
        guard AXIsProcessTrusted() else { return false }

        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        // Normalize all line-ending styles (CRLF, lone CR, lone LF) to a
        // single Return keystroke each.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let characters = Array(normalized)
        for (index, character) in characters.enumerated() {
            if character == "\n" {
                postKey(keyCode: CGKeyCode(kVK_Return), source: source)
            } else {
                postUnicode(character: character, source: source)
            }

            // Paced rather than one instantaneous burst - see
            // AppInfo.typingIntervalNanoseconds for why. Skip the trailing
            // delay after the last character.
            if index < characters.count - 1 {
                try? await Task.sleep(nanoseconds: AppInfo.typingIntervalNanoseconds)
            }
        }
        return true
    }

    private static func postUnicode(character: Character, source: CGEventSource) {
        let utf16 = Array(String(character).utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return
        }
        // Clear modifier flags explicitly: the trigger is Cmd+Shift+V, and
        // the hotkey can fire while those keys are still physically held.
        // CGEventSource can otherwise merge current physical modifier state
        // into freshly created events, which would make the injected text
        // look like it's being typed with Cmd/Shift held — some apps would
        // then treat it as a shortcut and swallow it instead of inserting text.
        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private static func postKey(keyCode: CGKeyCode, source: CGEventSource) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = []
        up.flags = []
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
