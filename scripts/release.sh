#!/usr/bin/env bash
# Builds Vantage.dmg and publishes it as a GitHub release, with a checksum and the installer.
#   scripts/release.sh 1.0.0            publish v1.0.0 from main
#   DRAFT=1 scripts/release.sh 1.0.0    create it as a draft to review first
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>, e.g. 1.0.0}"
REPO="${VANTAGE_REPO:-venkateswarisudalai/vantage}"
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

**Needs:** an Apple silicon Mac on macOS 26 (Tahoe) or later. For AI notes, use any of:
a free local model (Ollama, LM Studio), your own key for OpenRouter, Groq, Gemini, OpenAI,
Mistral, DeepSeek or Together, any OpenAI-compatible server, or Claude.

**Windows, Linux, ChromeOS:** use the web app at https://venkateswarisudalai.github.io/vantage/ (Chrome or Edge).

## What's new
- Notes are organized by topic: decisions and tasks, with owners and dates, sit in the topic they belong to. No more empty "None recorded" sections
- Groq works again: it now uses \`openai/gpt-oss-120b\`, since Groq retired the old Llama model. A retired model you saved falls back automatically
- Gemini uses Google's current models (\`gemini-flash-latest\`, \`gemini-flash-lite-latest\`) and retries on the lighter one when busy
- Local models are much faster for suggestions: Ollama "thinking" is turned off (\`qwen3:14b\`: about 7 s instead of about 50 s)
- Fixed: prompt text like \`<context_notes>\` could show up at the end of notes
EOF

echo "▸ Publishing $TAG"
gh release create "$TAG" dist/Vantage.dmg dist/Vantage.dmg.sha256 scripts/install.sh \
  -R "$REPO" --target main --title "Vantage $VERSION" --notes-file "$NOTES" ${DRAFT:+--draft}
echo "✓ Released $TAG"
