#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MarkLens"
APP_BUNDLE="$ROOT/build/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP_BUNDLE" "$ROOT/build/AppIcon.iconset" "$ROOT/build/AppIcon.icns"
mkdir -p "$MACOS" "$RESOURCES"

cd "$ROOT"
python3 "$ROOT/Scripts/make_icon.py"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"

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
cp "$ROOT/build/AppIcon.icns" "$RESOURCES/AppIcon.icns"

codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "$APP_BUNDLE"
