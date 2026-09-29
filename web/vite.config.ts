import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'

// Served from GitHub Pages at https://venkateswarisudalai.github.io/cue/
export default defineConfig({
  base: process.env.VANTAGE_BASE ?? '/cue/',
  plugins: [react()],
  test: { include: ['src/**/*.test.ts'] },
})
