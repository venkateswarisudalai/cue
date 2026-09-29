import { expect, test } from '@playwright/test'

// Real pipeline, no API keys: speech goes to a local Whisper server ("Custom" provider) and notes
// to local Ollama. Override with STT_URL / NOTES_MODEL when running elsewhere (e.g. Linux in Docker).
const STT_URL = process.env.STT_URL ?? 'http://localhost:8178/v1'
const NOTES_MODEL = process.env.NOTES_MODEL ?? 'llama3.2'

test.beforeEach(async ({ page }) => {
  await page.addInitScript(({ stt, model }) => {
    if (sessionStorage.getItem('seeded')) return
    sessionStorage.setItem('seeded', '1')
    localStorage.clear()
    localStorage.setItem('vantage.settings', JSON.stringify({
      notesProvider: 'ollama', speechProvider: 'custom', customURL: stt,
      models: { ollama: model, custom: 'whisper-1' },
      shareCallAudio: false, record: true, autoNotes: true, suggestions: false,
    }))
  }, { stt: STT_URL, model: NOTES_MODEL })
})

test('a new visitor is told to set up AI', async ({ browser }) => {
  const page = await browser.newPage()
  await page.goto('./')
  await expect(page.getByRole('button', { name: /Set up AI/ })).toBeVisible()
  await page.getByRole('button', { name: /Set up AI/ }).click()
  await expect(page.getByRole('dialog', { name: 'Settings' })).toBeVisible()
  await expect(page.getByText('Best free choice', { exact: false }).first()).toBeVisible()
  await page.close()
})

test('keys can be saved, shown, hidden, and removed', async ({ page }) => {
  await page.goto('./')
  await page.getByTitle(/Settings, AI and keys/).click()
  await page.getByLabel('Notes provider').selectOption('groq')
  const key = 'gsk_test1234567890abcdWXYZ'
  await page.getByLabel('Groq API key').fill(key)
  await page.getByRole('button', { name: 'Save', exact: true }).first().click()
  const dialog = page.getByRole('dialog', { name: 'Settings' })
  await expect(dialog.getByText('gsk_••••••••WXYZ')).toBeVisible()
  await dialog.getByRole('button', { name: 'Show' }).first().click()
  await expect(dialog.getByText(key)).toBeVisible()
  await dialog.getByRole('button', { name: 'Hide' }).first().click()
  await expect(dialog.getByText(key)).toBeHidden()
  await expect(dialog.locator('section', { has: page.getByRole('heading', { name: 'Saved keys' }) }).locator('p')).toHaveText('Groq')
  await dialog.getByRole('button', { name: 'Remove' }).first().click()
  await expect(dialog.getByText('gsk_••••••••WXYZ')).toBeHidden()
})

test('listen → transcript → AI notes → transcript page → suggestion → reload', async ({ page }) => {
  page.on('console', (m) => { if (m.type() === 'error') console.log('[browser]', m.text()) })
  await page.goto('./')
  await expect(page.getByRole('button', { name: /AI: Ollama/ })).toBeVisible()

  // Settings → Test connection checks both the notes model and speech-to-text.
  await page.getByTitle(/Settings, AI and keys/).click()
  await page.getByRole('button', { name: 'Test connection' }).click()
  const out = page.locator('.test-output')
  await expect(out).toContainText('✓ Notes', { timeout: 90_000 })
  await expect(out).toContainText('✓ Speech')
  await page.getByRole('button', { name: 'Close settings' }).click()

  await page.getByLabel('Title').fill('')
  await page.locator('.my-notes').fill('launch date?\nwho owns rollback')

  await page.getByRole('button', { name: /Start listening/ }).click()
  await expect(page.locator('.live-pill')).toBeVisible()
  await page.getByTitle(/Transcript \(Ctrl/).click()
  // Whisper lines arrive as the speaker pauses.
  await expect(page.locator('.drawer .bubble').first()).toBeVisible({ timeout: 60_000 })
  await page.waitForTimeout(40_000) // let the ~44 s clip play through once
  await page.locator('.live-pill').click()

  // Notes are written automatically when listening stops.
  await expect(page.locator('.enhanced .md')).toContainText(/Thursday/i, { timeout: 180_000 })
  await expect(page.locator('.enhanced .working')).toBeHidden({ timeout: 180_000 })
  await expect(page.getByLabel('Title')).not.toHaveValue('')
  const notes = await page.locator('.enhanced').innerText()
  console.log('\n--- NOTES ---\n' + notes)

  // Full transcript, with the recording's player.
  await page.getByRole('tab', { name: 'Transcript' }).click()
  const transcript = await page.locator('.transcript-page').innerText()
  console.log('\n--- TRANSCRIPT ---\n' + transcript.slice(0, 1500))
  expect(transcript).toMatch(/checkout|payment|Safari/i)
  await expect(page.locator('.player audio')).toBeAttached()
  await expect(page.locator('button.t-stamp').first()).toBeVisible()

  // Suggestions panel: Recap.
  await page.getByRole('button', { name: /Suggestions/ }).first().click()
  await page.getByRole('button', { name: /Recap/ }).click()
  await expect(page.locator('.card').first()).toContainText(/Summary|Decisions|Next steps/i, { timeout: 120_000 })
  await expect(page.locator('.card .spinner')).toHaveCount(0, { timeout: 120_000 })

  // Everything survives a reload.
  const title = await page.getByLabel('Title').inputValue()
  await page.reload()
  await expect(page.locator('.note-title', { hasText: title })).toBeVisible()
})
