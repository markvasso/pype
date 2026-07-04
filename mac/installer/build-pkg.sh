#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 pype contributors
#
# Builds pype.app (via build-app.sh) and packages it into PypeInstaller.pkg,
# a standard macOS installer package. pkgbuild's --component mode installs
# the whole app bundle to /Applications; postinstall relaunches it after
# an upgrade.
#
# The resulting .pkg is unsigned (no Developer ID certificate available
# here) - macOS will show an "unidentified developer" Gatekeeper warning
# when double-clicked from Finder on another machine. It still installs
# fine via the command line (see below), and right-click > Open in Finder
# bypasses the warning too. For real distribution, sign with
# `productsign --sign "Developer ID Installer: ..."` and notarize.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$MAC_DIR/dist"
APP_DIR="$DIST_DIR/pype.app"

"$SCRIPT_DIR/build-app.sh"

chmod +x "$SCRIPT_DIR/scripts/postinstall"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MAC_DIR/Info.plist")
IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$MAC_DIR/Info.plist")

echo "Building PypeInstaller.pkg (version $VERSION)..."
pkgbuild \
    --component "$APP_DIR" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location /Applications \
    --scripts "$SCRIPT_DIR/scripts" \
    "$DIST_DIR/PypeInstaller.pkg"

echo ""
echo "Built $DIST_DIR/PypeInstaller.pkg"
echo ""
echo "Install interactively: double-click the .pkg, or:"
echo "  open \"$DIST_DIR/PypeInstaller.pkg\""
echo ""
echo "Install silently (the macOS equivalent of the Windows /S switch):"
echo "  sudo installer -pkg \"$DIST_DIR/PypeInstaller.pkg\" -target /"
