import { defineConfig } from '@playwright/test'
import { fileURLToPath } from 'node:url'

// End-to-end: the built app in Chromium, with e2e/fixtures/meeting.wav as the microphone.
// Needs a local Whisper server (STT_URL) and Ollama with OLLAMA_ORIGINS set — see e2e/README.md.
const audio = fileURLToPath(new URL('./e2e/fixtures/meeting.wav', import.meta.url))
const external = !!process.env.BASE_URL

export default defineConfig({
  testDir: 'e2e',
  timeout: 240_000,
  expect: { timeout: 30_000 },
  reporter: [['list']],
  use: {
    baseURL: process.env.BASE_URL ?? 'http://localhost:4173/cue/',
    // A public site calling Ollama/Whisper on localhost needs Chrome's local-network permission.
    permissions: external && process.env.BASE_URL!.startsWith('https') ? ['microphone', 'local-network-access'] : ['microphone'],
    launchOptions: {
      args: [
        '--use-fake-ui-for-media-stream',
        '--use-fake-device-for-media-stream',
        `--use-file-for-fake-audio-capture=${audio}`,
        '--autoplay-policy=no-user-gesture-required',
      ],
    },
  },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
  webServer: external ? undefined : {
    command: 'npm run build && npx vite preview --port 4173 --strictPort',
    url: 'http://localhost:4173/cue/',
    reuseExistingServer: true,
    timeout: 120_000,
  },
})
