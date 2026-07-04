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
window) that's registered to start automatically at logon via a Scheduled
Task. Functionally it behaves like a service — always running, nothing to
manually launch — it's just not registered with the Service Control Manager.

## How it works

- `RegisterHotKey` (Win32) registers Ctrl+Shift+V against a hidden
  message-only window — no taskbar/Alt+Tab presence.
- On trigger, it reads clipboard text (`Clipboard.GetText`, with retry since
  the clipboard is a shared OS resource other apps can transiently hold).
- Text is typed via `SendInput` using `KEYEVENTF_UNICODE`, which sends raw
  Unicode code points regardless of keyboard layout — fast (one batched
  native call) and correct for non-ASCII text. Line endings (CRLF, lone CR,
  or lone LF) are each converted to a single Enter keystroke. If Windows
  blocks the injection (most commonly UIPI, when the target window is
  running elevated as Administrator), a tray notice explains that too.
- Text over 128 characters is truncated to the first 128 (without splitting
  a UTF-16 surrogate pair across the boundary), and a non-blocking tray
  balloon notification explains the truncation while typing proceeds
  immediately.
- "Run at Login" (right-click the tray icon) doesn't introduce a second
  autostart mechanism — it enables/disables the *same* Scheduled Task the
  installer creates (via `schtasks.exe`), so there's exactly one source of
  truth regardless of whether autostart was set up by the installer or
  toggled from the tray. If pype was run standalone without ever being
  installed, turning it on creates a simple per-user task on the fly. If
  pype was pushed machine-wide by an RMM tool, a standard (non-admin) user
  won't be able to turn it off from the tray — `schtasks.exe` denies the
  modification, which is arguably the correct behavior for IT-managed
  software.

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

This copies `pype.exe` (and a copy of `Uninstall-Pype.ps1`, so the registered
uninstall command keeps working even if the original install source is later
deleted), registers a Scheduled Task (`pype-clipboard-typer`) that starts pype
hidden at logon, creates Start Menu shortcuts (`pype` to launch it, `Uninstall
pype` to remove it — in `%ProgramData%\...\Start Menu` or `%APPDATA%\...\Start
Menu` depending on scope), writes the registry Uninstall key described below,
and starts pype immediately. Useful extra switches (pass to the `.ps1`
directly, or as extra passthrough args to the `.cmd`, after any silent/scope
switch):

| Switch | Effect |
|---|---|
| `-SystemWide` | Install for all users instead of just you — `%ProgramFiles%\pype`, `HKLM`, starts for whichever user logs on. Requires an elevated session. Shorthand for `-Scope Machine`; the `.cmd` wrapper's `/ALLUSERS` maps to this. |
| `-Scope Machine\|User\|Auto` | Force a scope instead of auto-detecting |
| `-InstallDir <path>` | Install somewhere other than the scope's default |
| `-NoAutoStart` | Don't register the logon Scheduled Task |
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

Stops the running process, removes the Scheduled Task, deletes the install
directory (only if it actually contains `pype.exe` — a safety check against a
mistyped `-InstallDir` wiping the wrong folder), removes the registry key,
and deletes the log files (unless `-KeepLogs` is passed). Removing a
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
- A components checkbox: "Start pype at login" (checked by default, maps to
  `-NoAutoStart` when unchecked). Start Menu shortcuts are always created by
  `Install-Pype.ps1` regardless.
- A "Launch pype now" option on the Finish page.

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
   your RMM the same way you did the original install — it overwrites the
   exe, re-registers the Scheduled Task, and updates `DisplayVersion` to
   match. The install is idempotent, so re-running it is the patch mechanism;
   there's no separate "update" script.

RMM agents almost universally execute deployment scripts as `SYSTEM`, which
`Test-IsAdmin` in the installer resolves to `Machine` scope automatically —
no special flags needed for a typical RMM push. One thing to note: because a
`Machine`-scope install's Scheduled Task is registered for "any user" (not a
specific account — necessary since `SYSTEM` never logs on interactively
itself), it starts pype for whichever user is actually using the machine.

## Usage

Copy any text to the clipboard, place your cursor wherever you want it typed,
then press **Ctrl+Shift+V**. Right-click the tray icon for About, "Run at
Login" (see [How it works](#how-it-works)), and Exit.

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
