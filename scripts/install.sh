#!/usr/bin/env bash
# Installs (or updates) the latest Vantage release into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/venkateswarisudalai/vantage/main/scripts/install.sh | bash
#   (run again to update)
#
# Installing this way skips the "Apple could not verify Vantage" prompt: the app is
# ad-hoc signed (not notarized), and files fetched by a script aren't quarantined.
set -euo pipefail

REPO="${VANTAGE_REPO:-venkateswarisudalai/vantage}"
APP=/Applications/Vantage.app

fail() { echo "✗ $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "Vantage is a macOS app."
[ "$(uname -m)" = arm64 ] || fail "Vantage needs an Apple silicon Mac (M1 or later)."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || fail "Vantage needs macOS 26 (Tahoe) or later; this Mac has $(sw_vers -productVersion)."

tmp="$(mktemp -d)"
cleanup() { hdiutil detach -quiet "$tmp/mnt" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

if [ -n "${VANTAGE_DMG:-}" ]; then
  # Testing a local build: VANTAGE_DMG=dist/Vantage.dmg scripts/install.sh
  cp "$VANTAGE_DMG" "$tmp/Vantage.dmg"
  [ -f "$VANTAGE_DMG.sha256" ] && cp "$VANTAGE_DMG.sha256" "$tmp/Vantage.dmg.sha256"
else
echo "▸ Downloading the latest Vantage"
if command -v gh >/dev/null && gh release download -R "$REPO" -p 'Vantage.dmg*' -D "$tmp" 2>/dev/null; then
  :
elif curl -fsSL -o "$tmp/Vantage.dmg" "https://github.com/$REPO/releases/latest/download/Vantage.dmg"; then
  curl -fsSL -o "$tmp/Vantage.dmg.sha256" "https://github.com/$REPO/releases/latest/download/Vantage.dmg.sha256" || true
else
  fail "Couldn't download Vantage from github.com/$REPO/releases. Check your connection and try again."
fi
fi

if [ -f "$tmp/Vantage.dmg.sha256" ]; then
  (cd "$tmp" && shasum -a 256 -c Vantage.dmg.sha256 >/dev/null) || fail "Download checksum didn't match. Try again."
  echo "▸ Checksum OK"
fi

echo "▸ Installing to $APP"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$tmp/mnt" "$tmp/Vantage.dmg"
if pgrep -xq Vantage; then
  osascript -e 'tell application "Vantage" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -xq Vantage || break; sleep 0.5; done
fi
if [ -d "$APP" ]; then mv "$APP" "$tmp/Vantage-previous.app"; fi
ditto "$tmp/mnt/Vantage.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --verify --strict "$APP" || fail "The installed app failed its signature check."

echo "✓ Installed $(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo Vantage)"
open "$APP" || echo "Open Vantage from your Applications folder."
cat <<'EOF'

Next:
  1. Press "Start listening" and allow the Microphone and Screen & System Audio Recording
     prompts (quit and reopen Vantage after granting Screen & System Audio Recording).
  2. For AI notes, open Vantage → Settings (⌘,) → AI and pick one: a free local model
     (Ollama / LM Studio), your own API key (OpenRouter, Groq, Gemini, OpenAI, …), or Claude.
EOF
