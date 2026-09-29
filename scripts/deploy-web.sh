#!/usr/bin/env bash
# Tests and builds the web app, then publishes it to the gh-pages branch (GitHub Pages).
#   scripts/deploy-web.sh
# The site: https://venkateswarisudalai.github.io/vantage/
set -euo pipefail
cd "$(dirname "$0")/../web"

REMOTE="${VANTAGE_REMOTE:-$(git remote get-url origin)}"
SHA="$(git rev-parse --short HEAD)"

echo "▸ Installing"
npm ci --silent
echo "▸ Unit tests"
npm test --silent
echo "▸ Building"
npm run build --silent

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R dist/. "$STAGE/"
touch "$STAGE/.nojekyll"   # serve files as-is (no Jekyll processing)
cp "$STAGE/index.html" "$STAGE/404.html"

echo "▸ Publishing to gh-pages"
git -C "$STAGE" init -q
git -C "$STAGE" checkout -q -b gh-pages
git -C "$STAGE" add -A
git -C "$STAGE" -c user.name="$(git log -1 --format=%an)" -c user.email="$(git log -1 --format=%ae)" \
  commit -q -m "Deploy web app from $SHA"
# gh-pages holds only build output, so each deploy replaces it.
git -C "$STAGE" push -q -f "$REMOTE" gh-pages
echo "✓ Deployed $SHA — https://venkateswarisudalai.github.io/vantage/ (Pages can take a minute to update)"
