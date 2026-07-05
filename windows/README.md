# pype

Types the current clipboard's text content wherever your cursor is, triggered
by **Ctrl+Shift+V**. If the clipboard text is longer than 128 characters, pype
types only the first 128 and shows a tray notification explaining why it was
truncated.

This README covers the **Windows** version (this folder). There's also a
**macOS** menu bar version — same behavior, separate Swift/AppKit
implementation (none of the Windows-specific mechanisms below carry over) —
see [`../mac/README.md`](../mac/README.md).

## Why this isn't a literal Windows Service

A true Windows Service (the kind registered in `services.msc`) runs isolated
in Session 0 and, since Windows Vista, cannot register global hotkeys, read
the interactive user's clipboard reliably, inject keystrokes into foreground
apps, or show notifications — all of that requires running inside the user's
own desktop session. So pype is a small background app (tray icon, no main
window). Turn on **Run at Login** from its tray menu and it starts
automatically at logon (via the standard "Run" registry key, visible in Task
Manager's Startup tab) — functionally like a service, always running with
nothing to manually launch, just not registered with the Service Control
Manager.

## How it works

- `RegisterHotKey` (Win32) registers Ctrl+Shift+V against a hidden
  message-only window — no taskbar/Alt+Tab presence. The same typing action
  is also available as **"Type Clipboard"** (with a clipboard icon) in the tray
  right-click menu (it waits ~350ms for focus to return to your target window
  before typing).
- **"Type Clipboard — No Limit"** in the tray menu types the *entire* clipboard
  with no 128-character cap. It's deliberately menu-only and **never bound to
  the hotkey**, so injecting an unbounded amount of text is always an explicit,
  deliberate choice rather than something a keystroke could trigger.
- **Stopping a type in progress** can be done three ways: press **Ctrl+Shift+V
  again** (the hotkey toggles — it stops a running type instead of starting a
  new one), **left-click the tray icon**, or use **"Stop Typing"** in the menu.
  The first two exist because opening the menu mid-type is awkward — the
  injected keystrokes fight the menu for focus. Stopping cancels cleanly and
  leaves pype running; while a type is underway the type items and Exit are
  disabled. This matters most for the potentially long "No Limit" action.
- On trigger, it reads clipboard text (`Clipboard.GetText`, with retry since
  the clipboard is a shared OS resource other apps can transiently hold).
- Text is typed via `SendInput` using `KEYEVENTF_UNICODE`, which sends raw
  Unicode code points regardless of keyboard layout — correct for non-ASCII
  text. Characters are sent one at a time with a short (~10ms) delay between
  them, so typing is fast but *visibly* pype doing it rather than an
  instantaneous flash indistinguishable from a normal paste. Line endings
  (CRLF, lone CR, or lone LF) are each converted to a single Enter keystroke.
  If Windows blocks the injection (most commonly UIPI, when the target window
  is running elevated as Administrator), a tray notice explains that too.
- Text over 128 characters is truncated to the first 128 (without splitting
  a UTF-16 surrogate pair across the boundary) for the hotkey and the "Type
  Clipboard" item, and a non-blocking tray balloon notification explains the
  truncation while typing proceeds immediately. ("Type Clipboard — No Limit"
  skips this cap.)
- **Autostart** is controlled from the tray menu's **"Run at Login"** toggle
  (installed edition only), which writes the per-user `Run` registry key
  (`HKCU\...\Run`) — visible and toggleable in **Task Manager's Startup tab**.
  It's *not* a Scheduled Task, and the **installer does not enable it** (older
  installers did, which could leave two startup entries and launch pype
  twice). The tray shows a checkmark when it's active.
- **On launch** the installed edition checks the GitHub releases API once for
  a newer version and, if found, shows a popup linking to the downloads page.
  This is the only network request pype makes and sends no data beyond a
  normal API call; it fails silently offline. It can be turned off via the
  tray menu's **"Check for updates on startup"** toggle.
- **About** (tray menu) links to the project's GitHub page.
- **Portable vs installed**: the same `pype.exe` runs either way. Run on its
  own it's *portable* — just the hotkey, "Type Clipboard", "Type Clipboard —
  No Limit", "Stop Typing", About, and Exit. Placed by the installer (which
  drops a marker file next to it), it's the
  *installed* edition and additionally shows Run at Login and the update
  check. Portable pype never touches autostart or the network.

## SmartScreen / antivirus warnings

`pype.exe` and `PypeSetup.exe` are **not code-signed** (that needs a paid
certificate). Two consequences to expect:

- **SmartScreen**: first run shows "Windows protected your PC / unknown
  publisher." Click **More info → Run anyway**. It'll flag it until the
  binary earns reputation (which unsigned apps effectively never do).
- **Antivirus**: an app whose entire purpose is synthesizing keystrokes from
  the clipboard looks, to a heuristic scanner, a lot like the input-injection
  step of malware. False-positive flags are plausible. The full source is in
  this repo — build it yourself (see [Building](#building)) if you'd rather
  not trust a prebuilt binary, and add an AV exclusion for the install path
  if your scanner quarantines it.

Signing + reputation is the only real fix; it's a deliberate cost tradeoff
for a free tool.

## Requirements

- Windows 10/11, x64.
- Nothing else — the published exe is self-contained (bundles the .NET
  runtime), so no separate .NET install is required on the target machine.

## Building

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
(can be built from Windows, macOS, or Linux — the output only *runs* on
Windows).

```powershell
# from the repo root
dotnet publish src/Pype.csproj -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -o publish

Copy-Item publish/pype.exe installer/ -Force
```

Or just run `scripts/Publish-Pype.ps1`, which does both of the above steps.

**Neither `pype.exe` nor the compiled `PypeSetup.exe` is checked into this
repo** — the self-contained exe is ~150MB and the NSIS installer ~63MB, both
over GitHub's 100MB hard per-file push limit (the exe alone would make
`git push` fail outright). Build them locally first; `installer/pype.exe` is
gitignored specifically so this doesn't silently regress. The icon (tray,
taskbar, Explorer, shortcuts) comes from [`src/pype.ico`](src/pype.ico),
embedded into the exe automatically via `<ApplicationIcon>` in the
`.csproj` — that one small file *is* checked in, since it's a static asset,
not a build output.

Release builds intentionally produce no `.pdb` (`<DebugType>none</DebugType>`,
scoped to `Configuration=Release` in `Pype.csproj`). By default the compiler
embeds the absolute local build path — `/Users/<you>/...` or
`C:\Users\<you>\...` — both as a reference inside the exe and as source-file
paths inside the `.pdb` itself, which would leak your OS username and folder
layout into a binary anyone else might receive from you. If you need real
debug symbols for local troubleshooting, use a `Debug` build instead of
`Release` — that config isn't affected.

## Installing

The installer auto-detects **scope** from whether the session is elevated —
this is what makes it work both for a normal user double-clicking it and for
an RMM tool pushing it as `SYSTEM` (see [Patching / RMM management](#patching--rmm-management)
below):

| Scope | When | Install location | Registry | Admin required |
|---|---|---|---|---|
| `Machine` | session is elevated (incl. `SYSTEM`) | `%ProgramFiles%\pype` | `HKLM\...\Uninstall\pype` | Yes |
| `User` | session is not elevated | `%LOCALAPPDATA%\pype` | `HKCU\...\Uninstall\pype` | No |

```powershell
cd installer
.\Install-Pype.ps1          # interactive, scope auto-detected
.\Install-Pype.ps1 -Silent  # silent, no prompts/output
```

Or the `.cmd` wrapper, which is more convenient for scripted/silent deploys.
It recognizes the conventional `/S`, `/SILENT`, `/VERYSILENT`, `/ALLUSERS`,
and `/CURRENTUSER` switches, in any order/combination, as leading arguments:

```cmd
installer\install.cmd
installer\install.cmd /S
installer\install.cmd /S /ALLUSERS
```

This first cleans up any prior install (including the machine-side autostart
and the legacy Scheduled Task older versions used) for a clean environment,
then copies `pype.exe` (and a copy of `Uninstall-Pype.ps1`, so the registered
uninstall command keeps working even if the original install source is later
deleted), drops the `pype.installed` marker (so the app knows it's the
installed edition), creates Start Menu shortcuts (`pype` to launch it,
`Uninstall pype` to remove it — in `%ProgramData%\...\Start Menu` or
`%APPDATA%\...\Start Menu` depending on scope), writes the registry Uninstall
key described below, and starts pype immediately. **The installer no longer
enables autostart** — turn on Run at Login from pype's tray menu if you want
it. Useful extra switches (pass to the `.ps1` directly, or as extra
passthrough args to the `.cmd`, after any silent/scope switch):

| Switch | Effect |
|---|---|
| `-SystemWide` | Install for all users instead of just you — `%ProgramFiles%\pype`, `HKLM` registration. Requires an elevated session. Shorthand for `-Scope Machine`; the `.cmd` wrapper's `/ALLUSERS` maps to this. |
| `-Scope Machine\|User\|Auto` | Force a scope instead of auto-detecting |
| `-InstallDir <path>` | Install somewhere other than the scope's default. For a **machine-wide** install this must be an admin-only location (under `%ProgramFiles%` or `%WINDIR%`) — the installer refuses a user-writable path, since a shared all-users exe there could be swapped by a standard user for code that other users then run. Per-user installs have no such restriction. |
| `-NoStartNow` | Don't launch pype immediately after installing |
| `-NoStartMenuShortcut` | Don't create the Start Menu shortcuts |

Install activity is logged to `%TEMP%\pype-install.log`.

## Uninstalling

`-Scope Auto` (the default) detects which scope(s) are actually registered by
checking the registry, so you don't need to remember which one was used at
install time:

```powershell
cd installer
.\Uninstall-Pype.ps1          # interactive
.\Uninstall-Pype.ps1 -Silent  # silent
```

```cmd
installer\uninstall.cmd
installer\uninstall.cmd /S
installer\uninstall.cmd /S /ALLUSERS
```

`uninstall.cmd` recognizes the same `/S`, `/SILENT`, `/VERYSILENT`,
`/ALLUSERS`, `/CURRENTUSER` switches as `install.cmd`, to explicitly target
one scope instead of relying on auto-detection.

Stops the running process, removes autostart (the `Run` key entry, plus the
legacy Scheduled Task from older versions), deletes the install directory
(only if it actually contains `pype.exe` — a safety check against a mistyped
`-InstallDir` wiping the wrong folder), removes the registry key, and deletes
the log files (unless `-KeepLogs` is passed). Removing a
`Machine`-scope install requires an elevated session.

## GUI installer (PypeSetup.exe)

For a normal wizard-style install experience — Welcome, install-mode choice,
destination folder, component checkboxes, progress, Finish page —
[`installer/PypeSetup.nsi`](installer/PypeSetup.nsi) is an
[NSIS](https://nsis.sourceforge.io/) script (using MUI2 + MultiUser.nsh for
the wizard UI and the all-users/current-user dual-mode support). It's a thin
wrapper, same philosophy as everything else here: it stages `pype.exe` and
both `.ps1` scripts into a temp directory and hands off to `Install-Pype.ps1`
to actually do the work, so there's one implementation of the install logic,
not two kept in sync by hand. The wizard adds:

- An "Install for me only" / "Install for all users" page (or `/CurrentUser`,
  `/AllUsers` on the command line) — whichever is chosen determines whether
  the process ends up elevated, and `Install-Pype.ps1`'s own `-Scope Auto`
  detection then does the right thing based on that, same composition as the
  CLI installer.
- A "Launch pype now" option on the Finish page.

(There's no "start at login" option — autostart is turned on from pype's tray
menu after install, not by the installer.)

It deliberately does **not** register its own Add/Remove Programs entry (no
`WriteUninstaller` call in the script — NSIS warns about this at compile
time, which is expected) — `Install-Pype.ps1` already writes a complete one
(see below), and a second entry would just be a confusing duplicate.
Uninstalling a GUI-installed copy works the same way as any other install:
via that registry entry (Control Panel / Settings > Apps) or the "Uninstall
pype" Start Menu shortcut.

**This one actually got compiled and verified**, unlike a typical
cross-platform-authored installer script: NSIS's compiler (`makensis`) runs
natively on macOS/Linux (`brew install makensis`), so it was built and
checked in this repo, not just written and hoped-for. Two real bugs were
caught this way before they could ship: `pype.exe` was originally staged
directly into the final `$INSTDIR` before invoking `Install-Pype.ps1`,
which would have made that script's own copy step try to copy `pype.exe`
onto itself and fail (fixed by staging to a temp dir instead, the same class
of bug the CLI installer's Inno Setup precursor had); and a components-page
checkbox was referenced before NSIS considered it declared, which is a hard
compile error, not a runtime one.

**Building it**: install NSIS 3.x, make sure `installer/pype.exe` is up to
date, then:

```
makensis installer/PypeSetup.nsi
```

This produces `dist/PypeSetup.exe` (not checked into the repo - see the
note on build outputs above). Silent install is a native NSIS feature, no
extra scripting needed:

```
PypeSetup.exe /S
PypeSetup.exe /S /AllUsers
PypeSetup.exe /S /CurrentUser
```

**Version note**: NSIS's `!getdllversion` can't read the version resource
from `pype.exe` once it's a self-contained single-file publish (confirmed —
it errors on this specific file, and silently corrupts later macro expansion
into a compiler crash if left unhandled). Unlike the rest of this project's
"the exe's own metadata is the single source of truth" approach,
`PRODUCT_VERSION` in `PypeSetup.nsi` is a hardcoded string — bump it by hand
alongside `<Version>` in `src/Pype.csproj` when cutting a release.

## Patching / RMM management

Install registers a standard "Programs and Features" Uninstall entry —
`DisplayName`, `DisplayVersion`, `Publisher`, `InstallLocation`,
`UninstallString`/`QuietUninstallString`, `EstimatedSize`, `InstallDate` —
under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\pype` (or
`HKCU\...` for a `User`-scope install). This is the same convention every
RMM/patch-management tool's software-inventory scan reads, so pype shows up
there with a real version number instead of needing special-casing.

**Version source of truth**: `DisplayVersion` is read from the *published
exe's own file version metadata* at install time (`FileVersionInfo`), not
hardcoded in the install script. To ship a patch:

1. Bump `<Version>` in [`src/Pype.csproj`](src/Pype.csproj).
2. Republish (`scripts/Publish-Pype.ps1`), and copy the new `pype.exe` into
   `installer/`.
3. Push `installer\install.cmd /S` (or `Install-Pype.ps1 -Silent`) through
   your RMM the same way you did the original install — it cleans the prior
   install, overwrites the exe, and updates `DisplayVersion` to match. The
   install is idempotent, so re-running it is the patch mechanism; there's no
   separate "update" script. (The app also self-notifies about new releases on
   launch, but that's a user-facing nudge, not a substitute for pushing the
   update.)

RMM agents almost universally execute deployment scripts as `SYSTEM`, which
`Test-IsAdmin` in the installer resolves to `Machine` scope automatically —
no special flags needed for a typical RMM push. Note that autostart is no
longer part of the install (it's a per-user tray choice), so a machine-wide
push installs and registers pype for all users but leaves "Run at Login" for
each user to enable — if you need every user's pype to autostart, set the
`HKLM\...\Run\pype` value yourself as part of your deployment.

## Usage

Copy any text to the clipboard, place your cursor wherever you want it typed,
then press **Ctrl+Shift+V** — or right-click the tray icon and choose **Type
Clipboard**. To type more than 128 characters, use **Type Clipboard — No
Limit** (menu only, never the hotkey). The tray menu also has About, "Run at
Login" (see [How it works](#how-it-works)), and Exit.

**Stopping a type in progress** (useful mainly for a long "No Limit" run) can be
done three ways — opening the menu to click "Stop Typing" mid-type is awkward,
since the keystrokes being injected fight the menu for focus, so there are two
faster options:

- **Press Ctrl+Shift+V again** — the hotkey is a toggle: it stops a running
  type instead of starting a new one.
- **Left-click the tray icon** — a single left-click stops a running type.
  (Right-click still opens the menu, which also has Stop Typing.)
- **Stop Typing** in the menu still works too.

## Known limitations

- **Elevated target windows**: Windows' UIPI blocks a normal-integrity
  process from injecting input into an elevated (Run as Administrator)
  window. To type into an elevated app, pype itself would need to run
  elevated too — not set up by default, since that would also require
  elevating the install.
- **Plain text only**: reads whatever `Clipboard.GetText()` returns; rich
  text, images, or files on the clipboard are ignored (nothing is typed, with
  a tray notice if there's no text at all).
- **One hotkey**: Ctrl+Shift+V is fixed, not currently configurable. If
  another app has already claimed that combination, pype shows a tray error
  on startup instead of silently failing.
- **Switching scopes**: installing `Machine`-scope on a machine that already
  has a `User`-scope install (or vice versa) leaves both registered rather
  than migrating one into the other. Harmless in practice — the single-
  instance check means only one copy actually runs per login session — but
  uninstall whichever one you no longer want explicitly (`-Scope Machine` or
  `-Scope User`) rather than relying on `-Scope Auto` to reconcile it.

## License

GNU General Public License v3.0 or later — see [LICENSE](LICENSE) (the
unmodified license text) and the `SPDX-License-Identifier: GPL-3.0-or-later`
+ copyright header at the top of each source/script file. In short: you're
free to use, modify, and redistribute pype, including commercially, but any
distributed modified version must also be licensed under the GPL and come
with source. The per-file copyright lines read "pype contributors" as a
placeholder — replace them with your name if you'd rather it be attributed
to you personally.
