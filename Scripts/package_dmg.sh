#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MarkLens"
VERSION="0.1.1"
APP_BUNDLE="$ROOT/.build/$APP_NAME.app"
STAGE="$ROOT/.build/dmg-stage"
DMG="$ROOT/dist/$APP_NAME-$VERSION-arm64.dmg"

"$ROOT/Scripts/build.sh" >/dev/null

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE" "$ROOT/dist"
ditto "$APP_BUNDLE" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

codesign --force --sign - "$DMG"
echo "$DMG"
