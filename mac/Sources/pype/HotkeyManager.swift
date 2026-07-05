// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import Carbon.HIToolbox
import AppKit

/// Registers two global hotkeys via Carbon's RegisterEventHotKey: Cmd+`
/// (type the clipboard, bounded) and Cmd+Shift+` (type all of it). Cmd (not
/// Ctrl) mirrors the Windows build's Ctrl+` / Ctrl+Shift+`; backtick was chosen
/// because it rarely collides with app shortcuts. Note macOS assigns Cmd+` /
/// Cmd+Shift+` to "move focus to next/previous window" system-wide, so if those
/// system shortcuts are enabled this registration may not win — see the README.
///
/// This (still fully supported, not deprecated) API is used deliberately
/// instead of a CGEventTap or NSEvent global monitor: those require the
/// Input Monitoring privacy permission just to detect a hotkey combo, while
/// RegisterEventHotKey needs no special permission at all for detection —
/// only the keystroke *injection* in ClipboardTyper needs Accessibility.
/// This mirrors Windows' RegisterHotKey, which also needs no special
/// permission.
final class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private var boundedRef: EventHotKeyRef?
    private var unlimitedRef: EventHotKeyRef?

    private static let signature: OSType = 0x70797065 // 'pype' as a four-char code
    private static let boundedID: UInt32 = 1
    private static let unlimitedID: UInt32 = 2

    /// Called when a hotkey fires; `unlimited` is true for Cmd+Shift+`.
    var onHotkey: ((_ unlimited: Bool) -> Void)?

    /// Registers both hotkeys. Returns true only if both registered; on partial
    /// or total failure it rolls everything back (so the installed event handler
    /// can't leak) and returns false. False most commonly means another app or
    /// the system already owns one of the combos.
    @discardableResult
    func register() -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
                var receivedID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &receivedID
                )
                guard status == noErr, receivedID.signature == HotkeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                switch receivedID.id {
                case HotkeyManager.boundedID: manager.onHotkey?(false)
                case HotkeyManager.unlimitedID: manager.onHotkey?(true)
                default: return OSStatus(eventNotHandledErr)
                }
                return noErr
            },
            1, &eventType,
            selfPtr,
            &eventHandler
        )
        guard installStatus == noErr else { return false }

        let key = UInt32(kVK_ANSI_Grave)
        // The two Carbon calls and InstallEventHandler above have no automatic
        // rollback, so if either RegisterEventHotKey fails, unregister() tears
        // down whatever did succeed rather than leaking it for the process's life.
        guard registerOne(id: Self.boundedID, modifiers: UInt32(cmdKey), keyCode: key, into: &boundedRef),
              registerOne(id: Self.unlimitedID, modifiers: UInt32(cmdKey | shiftKey), keyCode: key, into: &unlimitedRef)
        else {
            unregister()
            return false
        }
        return true
    }

    private func registerOne(id: UInt32, modifiers: UInt32, keyCode: UInt32, into ref: inout EventHotKeyRef?) -> Bool {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        return RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func unregister() {
        if let boundedRef {
            UnregisterEventHotKey(boundedRef)
            self.boundedRef = nil
        }
        if let unlimitedRef {
            UnregisterEventHotKey(unlimitedRef)
            self.unlimitedRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        unregister()
    }
}
