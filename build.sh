#!/usr/bin/env zsh
# build.sh — Build PhotoSimilarFinder
# Usage: ./build.sh [debug|release]   (default: debug)

set -euo pipefail

CONFIG="${1:-debug}"
PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJ_DIR/.build"

if [[ "$CONFIG" == "release" ]]; then
  BIN_PATH="$BUILD_DIR/release/PhotoSimilarFinder"
else
  BIN_PATH="$BUILD_DIR/debug/PhotoSimilarFinder"
fi

echo "──────────────────────────────────────────"
echo "  PhotoSimilarFinder — Build ($CONFIG)"
echo "──────────────────────────────────────────"

cd "$PROJ_DIR"
swift build -c "$CONFIG"

echo ""
echo "✓ Build succeeded"
echo "  Binary: $BIN_PATH"
