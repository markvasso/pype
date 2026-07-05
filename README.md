# pype

Types the current clipboard's text content wherever your cursor is, triggered
by a hotkey — **Ctrl+Shift+V** on Windows, **Cmd+Shift+V** on macOS (each
platform's native equivalent of the same "paste as plain text" convention) —
or from the tray / menu-bar menu. If the clipboard text is longer than 128
characters, pype types only the first 128 and shows a notification explaining
why it was truncated — or use **Type Clipboard — No Limit** to type all of it.
Typing is deliberately paced rather than instantaneous, so it's visibly pype
(not a native paste) doing it.

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

- **Type Clipboard** — types the clipboard's text content into whatever has
  focus, via the hotkey (**Ctrl+Shift+V** on Windows, **Cmd+Shift+V** on macOS)
  or the tray/menu-bar menu.
- **Type Clipboard — No Limit** types the entire clipboard past the 128-char
  cap. It's menu-only and never bound to a shortcut, so dumping a large blob of
  text is always an explicit, deliberate action.
- **Stop a type in progress** three ways (it matters most for the unbounded
  "No Limit" action): press the hotkey again (it toggles), click the tray /
  menu-bar icon, or use **Stop Typing** in the menu — leaving pype running. The
  first two exist because opening the menu mid-type is awkward while keystrokes
  are being injected.
- 128-character cap (on the hotkey / "Type Clipboard") with a notification
  explaining the truncation, so huge or unexpected clipboard contents never
  silently dumps somewhere.
- Typing is paced (fast, but visible), not an instant flash — a clear signal
  it's pype doing the typing.
- Tray icon (Windows) / menu bar item (macOS) with About (links to GitHub) and
  Exit/Quit. The installed edition also has a **Run at Login** toggle and a
  **Check for updates on startup** toggle; macOS additionally shows live
  Accessibility-permission status and one-click guidance to grant it (including
  the fix for the permission being dropped after an update).
- Run at Login (when you enable it) is visible where users expect it — Task
  Manager's Startup tab on Windows (a `Run` key entry), Login Items on macOS
  (`SMAppService`). Installers don't force it on.
- The installed edition checks GitHub on launch for a newer release and points
  you to the download if there is one (toggleable). This is the only network
  call pype makes. The portable Windows exe never does this.
- Installers with silent switches for unattended/scripted deployment:
  PowerShell + NSIS GUI installer on Windows, `.pkg` on macOS. Re-running an
  installer cleans the prior version first.
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
  Programs-and-Features) — reinstall the `.pkg`, or replace the `pype.app` from
  the portable `.zip`, to update. See [`mac/README.md`](mac/README.md).

## The two implementations

Two independent implementations, one per OS — see the platform's own README
for build, install, and usage instructions:

- **[Windows](windows/README.md)** — C#/.NET WinForms tray app. PowerShell
  and GUI (NSIS) installers, `Run`-key autostart (visible in Task Manager),
  registry integration for RMM/patch-management tools.
- **[macOS](mac/README.md)** — Swift/AppKit menu bar app. `.pkg` installer or
  portable `.zip`, `SMAppService` autostart, Cmd+Shift+V via Carbon
  `RegisterEventHotKey`. Keystroke injection needs Accessibility permission,
  and because these builds aren't Developer ID signed that grant doesn't
  survive updates — so the menu carries a live status item and step-by-step
  guidance, including the fix (remove the stale entry, re-add this copy) for
  when pype is listed but still can't type after an update.

Neither is a port of the other — none of the Windows-specific mechanisms
(WinForms, Win32 P/Invoke, the registry) exist on macOS, and vice versa. Each
platform's README explains its own architecture in full.

## License

GNU General Public License v3.0 or later — see [LICENSE](LICENSE). Source
files carry an `SPDX-License-Identifier: GPL-3.0-or-later` header.
