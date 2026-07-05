// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import Carbon.HIToolbox
import AppKit

/// Registers Cmd+Shift+V as a global hotkey via Carbon's RegisterEventHotKey.
/// Cmd (not Ctrl) is deliberate: it's the Mac-native equivalent of the
/// Windows build's Ctrl+Shift+V, which was chosen there because Ctrl+Shift+V
/// is the widely recognized "paste as plain text" shortcut in many Windows
/// apps - the Mac apps that have an equivalent shortcut (e.g. Google Docs)
/// use Cmd+Shift+V for the same thing, so this keeps the same semantic
/// shortcut on each platform rather than a literal modifier-for-modifier copy.
///
/// This (still fully supported, not deprecated) API is used deliberately
/// instead of a CGEventTap or NSEvent global monitor: those require the
/// Input Monitoring privacy permission just to detect a hotkey combo, while
/// RegisterEventHotKey needs no special permission at all for detection —
/// only the keystroke *injection* in ClipboardTyper needs Accessibility.
/// This mirrors Windows' RegisterHotKey, which also needs no special
/// permission.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private static let signature: OSType = 0x70797065 // 'pype' as a four-char code
    private static let hotKeyID: UInt32 = 1

    var onHotkey: (() -> Void)?

    /// True if the hotkey was registered successfully. False most commonly
    /// means another app already claimed Cmd+Shift+V.
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
                guard status == noErr, receivedID.id == HotkeyManager.hotKeyID else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.onHotkey?()
                return noErr
            },
            1, &eventType,
            selfPtr,
            &eventHandler
        )
        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let modifiers = UInt32(cmdKey | shiftKey)
        let keyCode = UInt32(kVK_ANSI_V)

        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr else {
            // InstallEventHandler succeeded above but the hotkey itself
            // didn't (most commonly: another app already owns Cmd+Shift+V)
            // - these are two independent Carbon calls with no automatic
            // rollback, so without this the event handler installed above
            // would otherwise leak for the rest of the process's lifetime.
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
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
