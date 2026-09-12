#!/usr/bin/env bash
# Builds dist/Cue.app (and optionally installs it / makes a DMG).
#   scripts/build-app.sh            build dist/Cue.app
#   scripts/build-app.sh --install  also copy to /Applications
#   scripts/build-app.sh --dmg      also create dist/Cue.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▸ Compiling (release)"
swift build -c release --product Cue
BIN="$(swift build -c release --show-bin-path)/Cue"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Generating icon"
  swift scripts/make-icon.swift Resources
fi

# Assemble and sign outside the project: ~/Documents is often synced by iCloud
# (File Provider), whose extended attributes stop codesign from sealing resources.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Cue.app"

echo "▸ Assembling Cue.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cue"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "▸ Signing (ad-hoc)"
xattr -cr "$APP"
codesign --force --sign - --identifier com.venka.cue --timestamp=none "$APP"
codesign --verify --strict "$APP"

mkdir -p dist
rm -rf dist/Cue.app
ditto "$APP" dist/Cue.app

for arg in "$@"; do
  case "$arg" in
    --install)
      echo "▸ Installing to /Applications"
      rm -rf /Applications/Cue.app
      ditto "$APP" /Applications/Cue.app
      codesign --verify --strict /Applications/Cue.app
      ;;
    --dmg)
      echo "▸ Creating dist/Cue.dmg"
      DMG_SRC="$STAGE/dmg"
      mkdir -p "$DMG_SRC"
      ditto "$APP" "$DMG_SRC/Cue.app"
      ln -s /Applications "$DMG_SRC/Applications"
      rm -f dist/Cue.dmg
      hdiutil create -volname Cue -srcfolder "$DMG_SRC" -ov -format UDZO dist/Cue.dmg >/dev/null
      ;;
  esac
done

echo "✓ Done: dist/Cue.app"
