#!/usr/bin/env bash
# Builds Vantage.dmg and publishes it as a GitHub release, with a checksum and the installer.
#   scripts/release.sh 1.0.0            publish v1.0.0 from main
#   DRAFT=1 scripts/release.sh 1.0.0    create it as a draft to review first
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>, e.g. 1.0.0}"
REPO="${VANTAGE_REPO:-venkateswarisudalai/cue}"
TAG="v$VERSION"

[ -z "$(git status --porcelain)" ] || { echo "✗ Commit or stash your changes first." >&2; exit 1; }

echo "▸ Testing"
swift test >/dev/null

VERSION="$VERSION" scripts/build-app.sh --dmg
(cd dist && shasum -a 256 Vantage.dmg > Vantage.dmg.sha256)

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
cat > "$NOTES" <<EOF
## Install

**One command** (installs to /Applications and opens it — no security prompt):

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash
\`\`\`

**Or by hand:** download **Vantage.dmg** below, open it, and drag Vantage into Applications.
The app isn't notarized yet, so the first time you open it macOS says it can't verify the
developer: click **Done**, then go to **System Settings → Privacy & Security**, scroll down,
and click **Open Anyway**.

**Needs:** an Apple silicon Mac on macOS 26 (Tahoe) or later, plus either Claude Code
(logged in) or an Anthropic API key for AI notes and suggestions.

## What's new
- Granola-style meeting notepad: your notes + Claude-written notes after the call
- Offers to start listening when a Zoom / Teams / Meet / FaceTime / Slack call begins
- Cleaner on-device transcripts, viewable any time; optional audio recording
- Live suggestions are optional; modes are Meeting and Customer call
EOF

echo "▸ Publishing $TAG"
gh release create "$TAG" dist/Vantage.dmg dist/Vantage.dmg.sha256 scripts/install.sh \
  -R "$REPO" --target main --title "Vantage $VERSION" --notes-file "$NOTES" ${DRAFT:+--draft}
echo "✓ Released $TAG"
