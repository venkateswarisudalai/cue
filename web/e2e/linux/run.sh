#!/usr/bin/env bash
# Runs the end-to-end suite in Linux (Ubuntu 24.04 + Playwright's Linux Chromium) inside Docker,
# against the app, Whisper server, and Ollama running on the host.
#   host:  npx vite preview --host 0.0.0.0 --port 4173   (after npm run build)
#          whisper-server ... --host 0.0.0.0 --port 8178 --inference-path /v1/audio/transcriptions
#          OLLAMA_ORIGINS='*' OLLAMA_HOST=0.0.0.0 ollama serve
#   then:  e2e/linux/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION="$(node -p "require('@playwright/test/package.json').version")"

docker run --rm --add-host=host.docker.internal:host-gateway \
  -v "$PWD/e2e:/work/e2e:ro" -v "$PWD/playwright.config.ts:/work/playwright.config.ts:ro" \
  -w /work "mcr.microsoft.com/playwright:v${VERSION}-noble" bash -c "
    set -e
    cat /etc/os-release | grep PRETTY_NAME
    npm init -y >/dev/null && npm pkg set type=module && npm i -s @playwright/test@${VERSION} >/dev/null
    # Make the host's services appear on localhost, so the page is a secure context (mic access)
    # and the Ollama preset's localhost URL works unchanged.
    node e2e/linux/forward.mjs 4173 8178 11434 &
    sleep 1
    BASE_URL=http://localhost:4173/cue/ npx playwright test --output /tmp/results
  "
