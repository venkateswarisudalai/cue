import { defineConfig } from '@playwright/test'
import { fileURLToPath } from 'node:url'

// End-to-end: the built app in Chromium, with a spoken clip as the microphone.
// Needs a local Whisper server (STT_URL) and Ollama with OLLAMA_ORIGINS set — see e2e/README.md.
const fixture = (name: string) => fileURLToPath(new URL(`./e2e/fixtures/${name}`, import.meta.url))
const external = !!process.env.BASE_URL
const micArgs = (clip: string) => [
  '--use-fake-ui-for-media-stream',
  '--use-fake-device-for-media-stream',
  `--use-file-for-fake-audio-capture=${fixture(clip)}`,
  '--autoplay-policy=no-user-gesture-required',
]

export default defineConfig({
  testDir: 'e2e',
  timeout: 300_000,
  expect: { timeout: 30_000 },
  reporter: [['list']],
  use: {
    baseURL: process.env.BASE_URL ?? 'http://localhost:4173/vantage/',
    // A public site calling Ollama/Whisper on localhost needs Chrome's local-network permission.
    permissions: external && process.env.BASE_URL!.startsWith('https') ? ['microphone', 'local-network-access'] : ['microphone'],
  },
  projects: [
    // The whole meeting through the mic (in-person / "Room").
    { name: 'mic', testIgnore: /call-audio/, use: { browserName: 'chromium', launchOptions: { args: micArgs('meeting.wav') } } },
    // The other side via shared audio ("Them"), your own voice on the mic ("You").
    { name: 'call', testMatch: /call-audio/, use: { browserName: 'chromium', launchOptions: { args: micArgs('you.wav') } } },
  ],
  webServer: external ? undefined : {
    command: 'npm run build && npx vite preview --port 4173 --strictPort',
    url: 'http://localhost:4173/vantage/',
    reuseExistingServer: true,
    timeout: 120_000,
  },
})
