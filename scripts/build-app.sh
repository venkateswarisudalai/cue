#!/usr/bin/env bash
# Builds dist/Vantage.app (and optionally installs it / makes a DMG).
#   scripts/build-app.sh            build dist/Vantage.app
#   scripts/build-app.sh --install  also copy to /Applications
#   scripts/build-app.sh --dmg      also create dist/Vantage.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▸ Compiling (release)"
swift build -c release --product Vantage
BIN="$(swift build -c release --show-bin-path)/Vantage"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Generating icon"
  swift scripts/make-icon.swift Resources
fi

# Assemble and sign outside the project: ~/Documents is often synced by iCloud
# (File Provider), whose extended attributes stop codesign from sealing resources.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Vantage.app"

echo "▸ Assembling Vantage.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vantage"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "▸ Signing (ad-hoc)"
xattr -cr "$APP"
codesign --force --sign - --identifier com.venka.vantage --timestamp=none "$APP"
codesign --verify --strict "$APP"

mkdir -p dist
rm -rf dist/Vantage.app
ditto "$APP" dist/Vantage.app

for arg in "$@"; do
  case "$arg" in
    --install)
      echo "▸ Installing to /Applications"
      rm -rf /Applications/Vantage.app
      ditto "$APP" /Applications/Vantage.app
      codesign --verify --strict /Applications/Vantage.app
      ;;
    --dmg)
      echo "▸ Creating dist/Vantage.dmg"
      DMG_SRC="$STAGE/dmg"
      mkdir -p "$DMG_SRC"
      ditto "$APP" "$DMG_SRC/Vantage.app"
      ln -s /Applications "$DMG_SRC/Applications"
      rm -f dist/Vantage.dmg
      hdiutil create -volname Vantage -srcfolder "$DMG_SRC" -ov -format UDZO dist/Vantage.dmg >/dev/null
      ;;
  esac
done

echo "✓ Done: dist/Vantage.app"
