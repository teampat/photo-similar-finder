#!/usr/bin/env zsh
# package_dmg.sh — Build, bundle into .app, and create a distributable DMG
# Usage: ./package_dmg.sh [version]   (default: 1.0.0)
#
# Output: dist/PhotoSimilarFinder-<version>.dmg
#
# Requirements:
#   - Swift Command Line Tools (swift, codesign, hdiutil — all built into macOS)
#   - No Xcode required, no third-party tools required

set -euo pipefail

# ─────────────────────────────────────────
# Config
# ─────────────────────────────────────────
APP_NAME="Photo Similar Finder"
BINARY_NAME="PhotoSimilarFinder"
BUNDLE_ID="com.team.PhotoSimilarFinder"
VERSION="${1:-1.0.0}"
MIN_OS="14.0"

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJ_DIR/.build/release"
DIST_DIR="$PROJ_DIR/dist"
STAGING_DIR="$DIST_DIR/staging"
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
DMG_OUT="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
DMG_TMP="$DIST_DIR/${APP_NAME}-tmp.dmg"
DMG_VOLUME="$APP_NAME $VERSION"

echo "════════════════════════════════════════════"
echo "  $APP_NAME — Package DMG"
echo "  Version : $VERSION"
echo "  Output  : $DMG_OUT"
echo "════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────
# Step 1: Release build
# ─────────────────────────────────────────
echo "▶ [1/5] Building release binary..."
cd "$PROJ_DIR"
swift build -c release
echo "  ✓ Build complete"
echo ""

# ─────────────────────────────────────────
# Step 2: Assemble .app bundle
# ─────────────────────────────────────────
echo "▶ [2/5] Assembling .app bundle..."

# Clean previous staging
rm -rf "$STAGING_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Write a fully-expanded Info.plist (no Xcode variables)
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Photo Similar Finder</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_OS}</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026. All rights reserved.</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

# Write PkgInfo
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "  ✓ .app bundle ready: $APP_BUNDLE"
echo ""

# ─────────────────────────────────────────
# Step 3: Ad-hoc code sign
# ─────────────────────────────────────────
echo "▶ [3/5] Code signing (ad-hoc)..."

# Sign the binary first, then the bundle
codesign \
  --sign - \
  --force \
  --timestamp \
  --options runtime \
  "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

codesign \
  --sign - \
  --force \
  --timestamp \
  --options runtime \
  "$APP_BUNDLE"

echo "  ✓ Signed (ad-hoc)"
codesign --verify --verbose=1 "$APP_BUNDLE" 2>&1 | head -3 | sed 's/^/  /'
echo ""

# ─────────────────────────────────────────
# Step 4: Create writable DMG from staging folder
# ─────────────────────────────────────────
echo "▶ [4/5] Creating DMG..."

# Clean old outputs
rm -f "$DMG_OUT" "$DMG_TMP"
mkdir -p "$DIST_DIR"

# Create a writable DMG with enough space
DMG_SIZE="$(($(du -sm "$APP_BUNDLE" | awk '{print $1}') + 20))m"

hdiutil create \
  -srcfolder "$STAGING_DIR" \
  -volname "$DMG_VOLUME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,b=16" \
  -format UDRW \
  -size "$DMG_SIZE" \
  "$DMG_TMP" \
  -ov -quiet

# Mount the writable DMG
MOUNT_POINT="$(mktemp -d /tmp/dmg-mount-XXXXXX)"
hdiutil attach "$DMG_TMP" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

# Add a symlink to /Applications for drag-and-drop install
ln -sf /Applications "$MOUNT_POINT/Applications"

# Set icon positions and background via AppleScript (optional window cosmetics)
osascript << APPLESCRIPT 2>/dev/null || true
tell application "Finder"
  tell disk "$DMG_VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 100, 900, 400}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 100
    set position of item "${APP_NAME}.app" of container window to {130, 150}
    set position of item "Applications" of container window to {370, 150}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

# Unmount
hdiutil detach "$MOUNT_POINT" -quiet
rm -rf "$MOUNT_POINT"

# ─────────────────────────────────────────
# Step 5: Convert to compressed, read-only DMG
# ─────────────────────────────────────────
echo "▶ [5/5] Compressing DMG..."

hdiutil convert "$DMG_TMP" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_OUT" \
  -ov -quiet

rm -f "$DMG_TMP"

# Final info
DMG_SIZE_HUMAN="$(du -sh "$DMG_OUT" | awk '{print $1}')"

echo ""
echo "════════════════════════════════════════════"
echo "  ✓ DMG ready!"
echo "  File : $DMG_OUT"
echo "  Size : $DMG_SIZE_HUMAN"
echo "════════════════════════════════════════════"
echo ""
echo "  Install: drag ${APP_NAME}.app to Applications"
echo ""

# Open dist folder in Finder
open "$DIST_DIR"
