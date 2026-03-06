#!/usr/bin/env zsh
# run.sh — Build (debug), assemble .app bundle, and launch via `open`
# Usage: ./run.sh   (works from any directory)
#
# SwiftUI/AppKit apps MUST be launched as a .app bundle —
# running the raw binary directly causes NSApplication to hang.

set -euo pipefail

# Resolve script location even if called from another directory
SCRIPT_PATH="${0:A}"          # :A = realpath in zsh
PROJ_DIR="$(dirname "$SCRIPT_PATH")"

APP_NAME="PhotoSimilarFinder"
BUNDLE_ID="com.team.PhotoSimilarFinder"
MIN_OS="14.0"
VERSION="1.0.0-dev"

BIN_PATH="$PROJ_DIR/.build/debug/$APP_NAME"
APP_BUNDLE="$PROJ_DIR/.build/debug/${APP_NAME}.app"

echo "──────────────────────────────────────────"
echo "  PhotoSimilarFinder — Build & Run"
echo "──────────────────────────────────────────"

cd "$PROJ_DIR"
swift build -c debug

# ── Assemble .app bundle ──────────────────
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>       <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>             <string>Photo Similar Finder</string>
    <key>CFBundleDisplayName</key>      <string>Photo Similar Finder</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>          <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>   <string>${MIN_OS}</string>
    <key>NSPrincipalClass</key>         <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS allows the bundle to run
codesign --sign - --force "$APP_BUNDLE" --deep 2>/dev/null

echo ""
echo "✓ Launching ${APP_NAME}.app..."
echo ""

# `open -W` launches as a proper macOS app and waits; logs go to Console.app
open -W -a "$APP_BUNDLE"
