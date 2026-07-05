#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 pype contributors
#
# Builds pype.app (via build-app.sh) and packages it into a portable
# pype-macos-portable.zip - a no-installer, no-admin download. Unzip it and
# run pype.app from anywhere (e.g. ~/Applications).
#
# ditto (not `zip`) is used deliberately: it preserves the code signature,
# extended attributes, and resource forks of the .app bundle. A plain `zip`
# can mangle the signature so the extracted app won't launch. --keepParent
# wraps the archive so it expands to `pype.app`, not loose Contents/.
#
# Like the .pkg, this build is only ad-hoc signed (no Developer ID), so the
# first launch on another Mac needs a right-click > Open to clear Gatekeeper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$MAC_DIR/dist"
APP_DIR="$DIST_DIR/pype.app"
ZIP_PATH="$DIST_DIR/pype-macos-portable.zip"

"$SCRIPT_DIR/build-app.sh"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MAC_DIR/Info.plist")

echo "Building pype-macos-portable.zip (version $VERSION)..."
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo ""
echo "Built $ZIP_PATH"
echo ""
echo "Use it: unzip, then run pype.app (right-click > Open the first time to"
echo "clear Gatekeeper on another Mac)."
