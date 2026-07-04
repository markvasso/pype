#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 pype contributors
#
# Builds pype.app: compiles the Swift package in Release, assembles a proper
# .app bundle (Info.plist, icon, executable), and ad-hoc code-signs it.
#
# Ad-hoc signing (`codesign --sign -`) lets the app run locally without a
# paid Apple Developer account, but Gatekeeper will still show an "unverified
# developer" warning on any *other* Mac it's copied to (right-click > Open
# bypasses that once). For real distribution, replace the ad-hoc sign below
# with a Developer ID certificate and notarize the app - see
# https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$MAC_DIR/.build/release"
DIST_DIR="$MAC_DIR/dist"
APP_DIR="$DIST_DIR/pype.app"

# -gnone disables debug-info generation. By default swift build embeds the
# absolute local build path (e.g. /Users/<you>/git/pype/mac/...) into the
# binary's DWARF debug info (both the object-file paths and the source
# directory) - since this repo ships a pre-built pype.app, that would
# otherwise leak whoever built it's OS username and folder layout into a
# public binary, the same issue the Windows build had with its .pdb.
echo "Building pype (release)..."
(cd "$MAC_DIR" && swift build -c release -Xswiftc -gnone)

echo "Assembling pype.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/pype" "$APP_DIR/Contents/MacOS/pype"
cp "$MAC_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$MAC_DIR/icons/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$MAC_DIR/icons/MenuBarIcon.png" "$APP_DIR/Contents/Resources/MenuBarIcon.png"
cp "$MAC_DIR/icons/MenuBarIcon@2x.png" "$APP_DIR/Contents/Resources/MenuBarIcon@2x.png"
cp "$MAC_DIR/icons/MenuBarIcon@3x.png" "$APP_DIR/Contents/Resources/MenuBarIcon@3x.png"

echo "Ad-hoc code-signing..."
codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
codesign --verify --verbose "$APP_DIR"
