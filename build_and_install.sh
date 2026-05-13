#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-Release}"
APP_NAME="ISSApp.app"
BUILD_DIR="./build"
SRC="$BUILD_DIR/Build/Products/$CONFIG/$APP_NAME"
DST="/Applications/$APP_NAME"

# Regenerate xcodeproj if project.yml has been edited since.
if [ -f generate_xcodeproj.sh ] && [ project.yml -nt iss.xcodeproj ]; then
  ./generate_xcodeproj.sh
fi

xcodebuild \
  -project iss.xcodeproj \
  -scheme ISSApp \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR" \
  build

if [ ! -d "$SRC" ]; then
  echo "Build product not found at $SRC" >&2
  exit 1
fi

# Stop any running instance so we can replace the bundle in place.
osascript -e 'tell application "ISSApp" to quit' >/dev/null 2>&1 || true

[ -d "$DST" ] && rm -rf "$DST"
cp -R "$SRC" "$DST"

echo "Installed $DST"
