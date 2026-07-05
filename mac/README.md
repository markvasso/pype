# pype for macOS

A menu bar port of [pype](../README.md) (see the [Windows
README](../windows/README.md) for the full project background — that's
where this project started). Same behavior as the Windows version: press
**Cmd+Shift+V** anywhere to type the clipboard's text content, or use the
menu bar icon (**Type Clipboard**). Text over 128 characters is truncated with
a notice; **Type Clipboard — No Limit** types all of it. Cmd (not Ctrl, despite
the Windows version using Ctrl+Shift+V) is deliberate: it's the Mac-native
equivalent of the same "paste as plain text" shortcut convention (e.g. Google
Docs uses Cmd+Shift+V on Mac for what Ctrl+Shift+V does on Windows).

The one real platform difference is Accessibility permission — keystroke
injection needs it, and on these unsigned builds the grant doesn't survive
updates. pype gives you a live status item and step-by-step guidance (including
the post-update fix) rather than leaving you guessing; see
[Permissions](#permissions-the-one-real-platform-difference) below.

This is a **separate implementation**, not a port of the C# codebase — none
of the Windows-specific mechanisms (WinForms, Win32 P/Invoke, the registry)
exist on macOS. Everything here is Swift/AppKit, mapped to the closest macOS
equivalent:

| Windows | macOS |
|---|---|
| `RegisterHotKey` | Carbon `RegisterEventHotKey` (still fully supported; deliberately *not* a CGEventTap/NSEvent global monitor — those need Input Monitoring permission just to detect a hotkey, this needs none) |
| `SendInput` / `KEYEVENTF_UNICODE` | `CGEvent` + `keyboardSetUnicodeString` |
| `Clipboard.GetText()` | `NSPasteboard.general` |
| System tray `NotifyIcon` | Menu bar `NSStatusItem` |
| Balloon tip | `UNUserNotificationCenter` |
| `Run`-key autostart | `SMAppService.mainApp` (macOS 13+) |
| PowerShell installer / NSIS | `.pkg` via `pkgbuild`, silent-installable via `installer -pkg ... -target /` |

## Permissions (the one real platform difference)

- **Accessibility** (System Settings > Privacy & Security > Accessibility):
  required for `ClipboardTyper` to inject keystrokes. The menu bar item shows
  live status ("Accessibility Access: Granted" or "Grant Accessibility
  Access…"); the latter opens a guide with the exact steps — including how to
  fix the common post-update case where pype is already listed but still can't
  type (remove the stale entry with `−` and re-add this copy with `+`), and a
  button that opens the Accessibility pane directly. If you trigger a type
  without the permission, pype shows that same guidance **once** (not on every
  keypress) and does nothing else. Hotkey *detection* itself
  (`RegisterEventHotKey`) needs no permission — same as Windows for that part.
- **Notifications**: requested on first launch for the truncation/error
  notices. If declined, those notices are silently dropped (logged via
  `os.log` instead) rather than blocking typing.

### Accessibility and code signing (affects updates)

These builds are **ad-hoc signed, not Developer ID signed or notarized**
(that needs a paid Apple Developer account). macOS ties an Accessibility grant
to the app's code identity, and an ad-hoc build's identity **changes every
time the binary changes**. Two real consequences:

- **On first grant** you may find that enabling pype under Privacy & Security
  > Accessibility doesn't take effect until you quit and reopen pype.
- **On every update**, because the new build has a different identity, the old
  grant no longer applies: pype shows up already-checked in the Accessibility
  list but still can't type. You have to **remove pype from the list (`–`) and
  re-add it (`+`) / re-toggle it**, then relaunch.

This is a limitation of unsigned/ad-hoc apps and TCC (macOS's permission
system), not a pype bug, and it can't be fixed in code. The one real fix is a
**Developer ID signed + notarized build** (see [Signing](#building)); the app's
identity would then be stable across versions and the grant would persist.
Until pype has a certificate, expect to re-grant Accessibility after each
update — whether you use the `.pkg` or the portable `.zip`.

## Building

Requires Xcode (or at least the Xcode Command Line Tools) and macOS 13+.

```bash
cd mac
./installer/build-app.sh        # produces dist/pype.app
# or, to also produce the installer:
./installer/build-pkg.sh        # produces dist/pype.app AND dist/PypeInstaller.pkg
# or, for the no-installer portable download:
./installer/build-portable.sh   # produces dist/pype.app AND dist/pype-macos-portable.zip
```

A pre-built `dist/PypeInstaller.pkg` is already included in this repo (ad-hoc
signed, tiny — Swift dynamically links the system frameworks rather than
bundling a runtime, so there's no equivalent of the Windows
self-contained-publish size). The loose `.app` is a build artifact and isn't
committed; `build-app.sh`/`build-pkg.sh` regenerate it.

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

Two downloads, pick one:

**Installer (`.pkg`)** — installs to `/Applications/pype.app`:

```bash
open dist/PypeInstaller.pkg              # interactive
sudo installer -pkg dist/PypeInstaller.pkg -target /   # silent
```

A `preinstall` script removes any prior copy for a clean install; the
`postinstall` script stops any already-running pype and relaunches the new one
as the logged-in console user (the scripts run as root under `sudo installer`).

**Portable (`.zip`)** — no installer, no admin rights:

```bash
unzip pype-macos-portable.zip            # yields pype.app
```

Drop `pype.app` wherever you like (e.g. `~/Applications`) and double-click to
run. Nothing is written outside the bundle except the standard per-app
`UserDefaults` and the `SMAppService` login-item registration (only if you
enable Run at Login). Because it's unsigned, the first launch needs a
right-click > Open to get past Gatekeeper (see [Signing](#building)). Note the
[Accessibility-on-update caveat](#accessibility-and-code-signing-affects-updates)
applies to both downloads equally — nothing about the portable build makes it
worse than the `.pkg` on that front.

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
**Cmd+Shift+V** — or use the menu bar menu:

- **Type Clipboard** — types the clipboard's text, truncated to
  128 characters (with a notice) if longer. Same as the hotkey, but from the
  menu it waits a moment for focus to return to your target window after the
  menu closes.
- **Type Clipboard — No Limit** — types the *entire* clipboard, no cap.
  Deliberately menu-only and **never bound to the hotkey**, so injecting an
  unbounded blob of text is always an explicit, deliberate action.
- **Stop Typing** — cancels an in-progress type cleanly (pype keeps running).

**Stopping a type in progress** (useful mainly for a long "No Limit" run) can be
done three ways — trying to open the menu and click "Stop Typing" mid-type is
awkward, because the keystrokes being injected fight the menu for focus, so
there are two faster options:

- **Press Cmd+Shift+V again** — the hotkey is a toggle: it stops a running type
  instead of starting a new one.
- **Click the menu bar icon** — a single click stops a running type (it opens
  the menu as usual when nothing is being typed).
- **Stop Typing** in the menu still works too.

The menu also has About (which links to the GitHub page), the Accessibility
status / "Grant Accessibility Access…" item, a "Run at Login" toggle (checkmark
when active), a "Check for updates on startup" toggle, and Quit.

## Update check

On launch pype checks the GitHub releases API once for a newer version and, if
found, shows a notice with a button to open the downloads page. This is the
only network request pype makes — it sends no data beyond a standard API call
and fails silently offline.

## Testing notes

This was built and smoke-tested in a real macOS environment (not just
compiled): `swift build` succeeds, the `.app` bundle launches without
crashing, registers correctly as a background-only (`LSUIElement`) process
with no Dock icon, the single-instance lock was verified to actually block a
second launch (confirmed a second process starts, detects the lock, and
exits on its own within ~2 seconds while the first keeps running), and the
`.pkg` was inspected (`pkgutil --expand`) to confirm it's well-formed. It
also went through an adversarial code review pass, which caught and fixed:
a TOCTOU race in the original `NSRunningApplication`-based single-instance
check (replaced with the `flock()`-based lock above), `SMAppService`'s
`.requiresApproval` state not being distinguished from either "enabled" or
"never registered" (Run at Login can succeed but still need a manual approval
in System Settings), and a `postinstall` edge case where installing at the
login screen (`/dev/console` reporting `loginwindow`, not a real user) would
have tried to launch the app as that system account.

What wasn't tested end-to-end: actually pressing **Cmd+Shift+V** (or choosing
**Type Clipboard**) after granting Accessibility permission and confirming text
types into a real target app — that needs an interactive permission grant this
environment didn't have a way to click through (screen-recording/computer-use
access was offered and declined). Worth a real test before relying on it.

## Known limitations

- **One hotkey**: Cmd+Shift+V is fixed, not configurable (Windows' equivalent
  is Ctrl+Shift+V — see the intro for why they differ). "Type Clipboard — No
  Limit" is menu-only by design and intentionally has no shortcut.
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
  [Accessibility + code signing](#accessibility-and-code-signing-affects-updates)
  section above. This is the single biggest caveat for real-world use.
