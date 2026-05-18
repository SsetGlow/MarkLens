#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MarkLens"
BUILD_DIR="$ROOT/.build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP_BUNDLE" "$BUILD_DIR/dmg-stage" "$BUILD_DIR/AppIcon.iconset" "$BUILD_DIR/AppIcon.icns"
rm -rf "$ROOT/build/$APP_NAME.app"
mkdir -p "$MACOS" "$RESOURCES"
touch "$BUILD_DIR/.metadata_never_index"

cd "$ROOT"
python3 "$ROOT/Scripts/make_icon.py"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"

swiftc \
  -O \
  -whole-module-optimization \
  -parse-as-library \
  -target arm64-apple-macos14.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  "$ROOT/Sources/MarkLens/main.swift" \
  -o "$MACOS/$APP_NAME"

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$BUILD_DIR/AppIcon.icns" "$RESOURCES/AppIcon.icns"

codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "$APP_BUNDLE"
