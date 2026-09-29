import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'

// Served from GitHub Pages at https://venkateswarisudalai.github.io/vantage/
export default defineConfig({
  base: process.env.VANTAGE_BASE ?? '/vantage/',
  plugins: [react()],
  test: { include: ['src/**/*.test.ts'] },
})
