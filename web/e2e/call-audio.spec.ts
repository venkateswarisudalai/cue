import { expect, test } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { seed } from './providers'

// A two-sided call: the other side arrives as shared audio ("Them") and your voice on the mic
// ("You", from fixtures/you.wav). One mic sentence repeats the call, like speakers leaking into the
// mic, and should be dropped from "You".
//
// Chromium's fake-device mode can only return a beep for screen/tab sharing, so the test hands the
// app a real audio stream instead: getDisplayMedia returns an <audio> element's captureStream()
// playing the meeting clip. Everything after the browser's share picker is the real app code.
const callClip = readFileSync(fileURLToPath(new URL('./fixtures/meeting.wav', import.meta.url)))

test('two-sided call: Them + You, echo removed, auto-suggestion, notes', async ({ page }) => {
  page.on('pageerror', (e) => console.log('[pageerror]', e.message))
  await page.route('**/__test/call.wav', (r) => r.fulfill({ body: callClip, contentType: 'audio/wav' }))
  await page.addInitScript((data) => {
    localStorage.setItem('vantage.settings', JSON.stringify(data.settings))
    localStorage.setItem('vantage.keys', JSON.stringify(data.keys))
    navigator.mediaDevices.getDisplayMedia = async () => {
      const audio = new Audio(new URL('__test/call.wav', location.href).href)
      audio.crossOrigin = 'anonymous'
      await audio.play()
      const stream = (audio as HTMLAudioElement & { captureStream(): MediaStream }).captureStream()
      // Real shares include video; the app must discard it.
      const canvas = document.createElement('canvas')
      stream.addTrack(canvas.captureStream(1).getVideoTracks()[0])
      return stream
    }
  }, seed({ shareCallAudio: true, record: false, autoNotes: true, suggestions: true, autoSuggest: true }))

  await page.goto('./')
  await page.getByRole('button', { name: /Start listening/ }).click()
  await expect(page.locator('.live-pill')).toBeVisible()
  const started = Date.now()
  await expect(page.locator('.banner')).toBeHidden() // call audio was accepted

  // Stop before Chromium's fake mic loops back to the start of you.wav (~44 s).
  await page.waitForTimeout(Math.max(0, 41_000 - (Date.now() - started)))
  await page.locator('.live-pill').click()
  // Them asked questions ("…can you own the rollback plan?") → an automatic suggested answer.
  // Long speech chunks (Gemini) can deliver it just after stopping, so check afterwards.
  await expect(page.locator('.card', { has: page.locator('.badge', { hasText: 'AUTO' }) }).first()).toBeVisible({ timeout: 120_000 })

  await expect(page.locator('.enhanced .md')).toContainText(/Thursday/i, { timeout: 180_000 })
  await expect(page.locator('.enhanced .working')).toBeHidden({ timeout: 180_000 })

  const utterances: { speaker: string; text: string }[] = await page.evaluate(
    () => JSON.parse(localStorage.getItem('vantage.meetings') ?? '[]')[0]?.utterances ?? [])
  console.log('\n--- TRANSCRIPT ---\n' + utterances.map((u) => `${u.speaker}: ${u.text}`).join('\n'))
  const them = utterances.filter((u) => u.speaker === 'them').map((u) => u.text).join(' ')
  const you = utterances.filter((u) => u.speaker === 'you').map((u) => u.text).join(' ')
  expect(them).toMatch(/checkout|payment|Safari/i)
  expect(you).toMatch(/design review|analytics dashboard|marketing know/i) // your own lines are kept as You
  expect(you).not.toMatch(/main thing today is the checkout/i) // the echoed line is not
  expect(utterances.some((u) => u.speaker === 'room')).toBe(false)

  const autoCue = await page.locator('.card', { has: page.locator('.badge', { hasText: 'AUTO' }) }).first().innerText()
  console.log('\n--- AUTO SUGGESTION ---\n' + autoCue.slice(0, 500))
})
