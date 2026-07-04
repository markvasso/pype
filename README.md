# pype

Types the current clipboard's text content wherever your cursor is, triggered
by a hotkey — **Ctrl+Shift+V** on Windows, **Cmd+Shift+V** on macOS (each
platform's native equivalent of the same "paste as plain text" convention).
If the clipboard text is longer than 128 characters, pype types only the
first 128 and shows a notification explaining why it was truncated. Typing
is deliberately paced rather than instantaneous, so it's visibly pype (not
a native paste) doing it.

## Use case

pype simulates real keystrokes instead of firing a paste event, so it works
in places where clipboard paste is disabled or simply doesn't reach:

- Remote consoles, KVM/IP-KVM switches, hypervisor/BIOS consoles, and VMs
  without clipboard passthrough — anywhere you need to get a password,
  license key, or command into a session your clipboard can't reach.
- Fields and apps that explicitly block paste (some secure input fields,
  some kiosk/locked-down environments).
- Anywhere you want plain text typed, stripped of clipboard formatting,
  without hunting for that app's own "paste as plain text" shortcut.

It's a small, single-purpose utility, not a text expander or clipboard
manager — one hotkey, one job.

## Features

- Global hotkey types the clipboard's text content into whatever has focus.
- 128-character cap with a notification explaining the truncation, so a
  huge or unexpected clipboard contents never silently dumps somewhere.
- Typing is paced (fast, but visible), not an instant flash — a clear signal
  it's pype doing the typing.
- Tray icon (Windows) / menu bar item (macOS) with About (links to GitHub),
  a Run at Login toggle, and Exit/Quit. macOS additionally shows live
  Accessibility-permission status and a one-click way to open the setting.
- Run at Login that's visible where users expect it — Task Manager's Startup
  tab on Windows (a `Run` key entry), Login Items on macOS (`SMAppService`).
- Checks GitHub on launch for a newer release and points you to the download
  if there is one. This is the only network call pype makes.
- Installers with silent switches for unattended/scripted deployment:
  PowerShell + NSIS GUI installer on Windows, `.pkg` on macOS. Re-running an
  installer cleans the prior version first and keeps your autostart choice.
- Windows: registers in the standard Programs-and-Features registry
  location with a real version number, so RMM/patch-management tooling can
  see and manage it like any other installed app.

## Patching

- **Windows**: the installer writes `DisplayVersion` from the published
  exe's own file version metadata — there's no separate version to track by
  hand. To ship an update, republish, then re-run the installer (interactive
  or `/S` silent) the same way you did the original install; it's
  idempotent and updates the registry entry in place. Full detail —
  including the RMM/registry integration — is in
  [`windows/README.md`](windows/README.md#patching--rmm-management).
- **macOS**: no registry equivalent (there's no macOS analogue of
  Programs-and-Features) — rebuild and reinstall the `.pkg` to update. See
  [`mac/README.md`](mac/README.md).

## The two implementations

Two independent implementations, one per OS — see the platform's own README
for build, install, and usage instructions:

- **[Windows](windows/README.md)** — C#/.NET WinForms tray app. PowerShell
  and GUI (NSIS) installers, `Run`-key autostart (visible in Task Manager),
  registry integration for RMM/patch-management tools.
- **[macOS](mac/README.md)** — Swift/AppKit menu bar app. `.pkg` installer,
  `SMAppService` autostart.

Neither is a port of the other — none of the Windows-specific mechanisms
(WinForms, Win32 P/Invoke, the registry) exist on macOS, and vice versa. Each
platform's README explains its own architecture in full.

## License

GNU General Public License v3.0 or later — see [LICENSE](LICENSE). Source
files carry an `SPDX-License-Identifier: GPL-3.0-or-later` header.
