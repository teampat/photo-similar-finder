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
DMG_FILENAME="photo-similar-finder-${VERSION}.dmg"
DMG_OUT="$DIST_DIR/${DMG_FILENAME}"
DMG_TMP="$DIST_DIR/photo-similar-finder-tmp.dmg"
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

# Write PkgInfo
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Generate AppIcon.icns from app-icon.png (if source exists)
ICON_PNG="$PROJ_DIR/app-icon.png"
ICON_SRC="$PROJ_DIR/PhotoSimilarFinder/AppIcon.icns"
if [[ -f "$ICON_PNG" ]]; then
    ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET_TMP"
    sips -z 16 16     "$ICON_PNG" --out "$ICONSET_TMP/icon_16x16.png"     &>/dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICONSET_TMP/icon_16x16@2x.png"  &>/dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICONSET_TMP/icon_32x32.png"      &>/dev/null
    sips -z 64 64     "$ICON_PNG" --out "$ICONSET_TMP/icon_32x32@2x.png"  &>/dev/null
    sips -z 128 128   "$ICON_PNG" --out "$ICONSET_TMP/icon_128x128.png"   &>/dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICONSET_TMP/icon_128x128@2x.png" &>/dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICONSET_TMP/icon_256x256.png"   &>/dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICONSET_TMP/icon_256x256@2x.png" &>/dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICONSET_TMP/icon_512x512.png"   &>/dev/null
    cp "$ICON_PNG"                    "$ICONSET_TMP/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET_TMP" -o "$ICON_SRC"
    rm -rf "$(dirname "$ICONSET_TMP")"
    echo "  ✓ App icon generated from app-icon.png"
elif [[ -f "$ICON_SRC" ]]; then
    echo "  ✓ App icon found (pre-built)"
else
    echo "  ⚠ No app-icon.png or AppIcon.icns found — skipping icon"
fi

# Copy icon into bundle
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

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
  --entitlements "$PROJ_DIR/PhotoSimilarFinder/PhotoSimilarFinder.entitlements" \
  "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

codesign \
  --sign - \
  --force \
  --timestamp \
  --options runtime \
  --entitlements "$PROJ_DIR/PhotoSimilarFinder/PhotoSimilarFinder.entitlements" \
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

# Generate dark gradient background image (540×380) using Python stdlib — no deps needed
python3 << 'PYEOF'
import struct, zlib
W, H = 540, 380
def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)
rows = []
for y in range(H):
    t = y / (H - 1)
    r = int(0x1a + t * (0x28 - 0x1a))
    g = int(0x1a + t * (0x28 - 0x1a))
    b = int(0x2a + t * (0x3c - 0x2a))
    rows.append(b'\x00' + bytes([r, g, b] * W))
png  = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(b''.join(rows), 9))
png += chunk(b'IEND', b'')
with open('/tmp/dmg_bg.png', 'wb') as f:
    f.write(png)
PYEOF
mkdir -p "$MOUNT_POINT/.background"
cp /tmp/dmg_bg.png "$MOUNT_POINT/.background/background.png"
rm -f /tmp/dmg_bg.png

# Set icon layout and background via AppleScript
osascript << APPLESCRIPT 2>/dev/null || true
tell application "Finder"
  tell disk "$DMG_VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 150, 740, 530}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 12
    set background picture of viewOptions to POSIX file "$MOUNT_POINT/.background/background.png"
    set position of item "${APP_NAME}.app" of container window to {155, 190}
    set position of item "Applications" of container window to {385, 190}
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

# Cleanup: remove staging folder and old-named DMG files
rm -rf "$STAGING_DIR"
rm -f "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
