# pype for macOS

A menu bar port of [pype](../README.md) (see the [Windows
README](../windows/README.md) for the full project background — that's
where this project started). Same behavior as the Windows version: press
**Cmd+Shift+V** anywhere to type the clipboard's text content; text over 128
characters is truncated with a notice explaining why. Cmd (not Ctrl, despite
the Windows version using Ctrl+Shift+V) is deliberate: it's the Mac-native
equivalent of the same "paste as plain text" shortcut convention (e.g.
Google Docs uses Cmd+Shift+V on Mac for the same thing Ctrl+Shift+V does on
Windows).

This is a **separate implementation**, not a port of the C# codebase — none
of the Windows-specific mechanisms (WinForms, Win32 P/Invoke, Scheduled
Tasks, the registry) exist on macOS. Everything here is Swift/AppKit,
mapped to the closest macOS equivalent:

| Windows | macOS |
|---|---|
| `RegisterHotKey` | Carbon `RegisterEventHotKey` (still fully supported; deliberately *not* a CGEventTap/NSEvent global monitor — those need Input Monitoring permission just to detect a hotkey, this needs no permission at all) |
| `SendInput` / `KEYEVENTF_UNICODE` | `CGEvent` + `keyboardSetUnicodeString` |
| `Clipboard.GetText()` | `NSPasteboard.general` |
| System tray `NotifyIcon` | Menu bar `NSStatusItem` |
| Balloon tip | `UNUserNotificationCenter` |
| Scheduled Task autostart | `SMAppService.mainApp` (macOS 13+) |
| PowerShell installer / NSIS | `.pkg` via `pkgbuild`, silent-installable via `installer -pkg ... -target /` |

## Permissions (the one real platform difference)

macOS gates both hotkey detection and keystroke injection behind explicit,
one-time user consent — there's no way around this, unlike Windows:

- **Accessibility** (System Settings > Privacy & Security > Accessibility):
  required for `ClipboardTyper` to inject keystrokes. The menu bar item shows
  live status ("Accessibility Access: Granted" or "Grant Accessibility
  Access…" which opens the setting directly). If it's not granted when you
  press Cmd+Shift+V, pype opens the prompt and notifies you **once** (not on
  every keypress).
- **Notifications**: requested on first launch for the truncation/error
  notices. If declined, those notices are silently dropped (logged via
  `os.log` instead) rather than blocking typing.
- Hotkey *detection* itself (Carbon `RegisterEventHotKey`) needs neither
  permission — same low-friction behavior as Windows for that specific part.

### ⚠️ Accessibility + code signing (read this if typing does nothing)

These builds are **ad-hoc signed, not Developer ID signed or notarized**
(that needs a paid Apple Developer account). On recent macOS, that has a real
consequence: **you can enable pype under Privacy & Security > Accessibility,
the toggle turns on, but `AXIsProcessTrusted()` still returns false and pype
still can't type** — even after moving it to `/Applications` and relaunching.
This is a known limitation of unsigned/ad-hoc apps and TCC (macOS's
permission system), not a pype bug, and it can't be fully fixed in code.

If you hit this, in rough order of effort:

1. Make sure pype is in `/Applications` (not run from the download folder —
   that triggers a separate translocation issue) and fully quit + reopen it
   after enabling the toggle.
2. Try removing and re-adding pype in the Accessibility list (the `–`/`+`
   buttons), then relaunch.
3. If it still won't stick, the reliable fix is a **signed + notarized
   build** — see [Signing](#building) below. That's the only thing that makes
   TCC trust the app persistently.

The definitive fix is on the roadmap only if pype gets a Developer ID
certificate; until then this is the honest state of unsigned distribution.

## Building

Requires Xcode (or at least the Xcode Command Line Tools) and macOS 13+.

```bash
cd mac
./installer/build-app.sh   # produces dist/pype.app
# or, to also produce the installer:
./installer/build-pkg.sh   # produces dist/pype.app AND dist/PypeInstaller.pkg
```

A pre-built `dist/pype.app` and `dist/PypeInstaller.pkg` are already included
in this repo (ad-hoc signed, tiny — Swift dynamically links the system
frameworks rather than bundling a runtime, so there's no equivalent of the
Windows self-contained-publish size).

Release builds pass `-Xswiftc -gnone` to the compiler deliberately: by
default Swift embeds the absolute local build path in the binary's DWARF
debug info, which would leak whoever built it's OS username and folder
layout into a binary checked into a public repo — the same class of issue
the Windows build had with its `.pdb`, fixed the same way (no debug info in
what's shipped).

**Signing**: `build-app.sh` ad-hoc signs (`codesign --sign -`), which is
enough to run locally but will show Gatekeeper's "unidentified developer"
warning if the `.app`/`.pkg` is copied to another Mac (right-click > Open
bypasses it once). For real distribution, get a Developer ID certificate and
notarize — see [Apple's notarization
docs](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
`CFBundleIdentifier` in `Info.plist` is currently the placeholder
`com.pype.app`; change it to your own reverse-DNS namespace if you have one.

## Installing

```bash
open dist/PypeInstaller.pkg              # interactive
sudo installer -pkg dist/PypeInstaller.pkg -target /   # silent
```

Installs to `/Applications/pype.app`. The `postinstall` script stops any
already-running pype (so a re-run/upgrade doesn't leave a stale instance
running) and relaunches the new one as the logged-in console user (the
script itself runs as root under `sudo installer`).

Or just drag `pype.app` to `/Applications` yourself — the `.pkg` is a
convenience, not a requirement.

## Uninstalling

```bash
pkill -f /Applications/pype.app/Contents/MacOS/pype
rm -rf /Applications/pype.app
```

If Run at Login was enabled, toggle it off from the menu bar first (or it'll
still try to launch at next login even after the app itself is deleted,
since `SMAppService`'s registration is separate from the file on disk).
There's no separate uninstaller script — the app is a single self-contained
bundle with nothing else written to disk (no registry-equivalent, no
LaunchAgent plist file — `SMAppService.mainApp` manages that internally).

## Usage

Copy any text to the clipboard, click wherever you want it typed, then press
**Cmd+Shift+V**. Click the menu bar icon for About, the Accessibility status
/ "Grant Accessibility Access…" item, a "Run at Login" toggle (checkmark when
active), and Quit.

## Testing notes

This was built and smoke-tested in a real macOS environment (not just
compiled): `swift build` succeeds, the `.app` bundle launches without
crashing, registers correctly as a background-only (`LSUIElement`) process
with no Dock icon, the single-instance lock was verified to actually block a
second launch (confirmed a second process starts, detects the lock, and
exits on its own within ~2 seconds while the first keeps running), and the
`.pkg` was inspected (`pkgutil --expand`) to confirm it's well-formed. It
also went through an adversarial code review pass, which caught and fixed:
an event-handler leak when `RegisterEventHotKey` fails after
`InstallEventHandler` succeeds (most likely when another app already owns
Cmd+Shift+V), a TOCTOU race in the original `NSRunningApplication`-based
single-instance check (replaced with the `flock()`-based lock above),
`SMAppService`'s `.requiresApproval` state not being distinguished from
either "enabled" or "never registered" (Run at Login can succeed but still
need a manual approval in System Settings), and a `postinstall` edge case
where installing at the login screen (`/dev/console` reporting
`loginwindow`, not a real user) would have tried to launch the app as that
system account.

What wasn't tested end-to-end: actually pressing Cmd+Shift+V after granting
Accessibility permission and confirming text types into a real target app —
that needs an interactive permission grant this environment didn't have a
way to click through (screen-recording/computer-use access was offered and
declined). Worth a real test before relying on it.

## Known limitations

- **One hotkey**: Cmd+Shift+V is fixed, not configurable (Windows' equivalent
  is Ctrl+Shift+V — see the intro above for why they differ).
- **Plain text only**: reads whatever `NSPasteboard.general.string(forType:
  .string)` returns.
- **macOS 13+ only**: `SMAppService` (Run at Login) requires Ventura or
  later. No LaunchAgent-plist fallback for older macOS is implemented.
- **No update mechanism**: unlike the Windows side (registry
  `DisplayVersion`, RMM-friendly), there's no equivalent "patch" story here
  yet — re-running `build-pkg.sh` and reinstalling is the only path.
- **Accessibility may not persist on unsigned builds**: because these builds
  aren't Developer ID signed + notarized, macOS may refuse to actually trust
  pype for Accessibility even after you enable it — see the
  [Accessibility + code signing](#️-accessibility--code-signing-read-this-if-typing-does-nothing)
  section above. This is the single biggest caveat for real-world use.
