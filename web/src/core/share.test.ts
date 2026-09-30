import { describe, expect, it } from 'vitest'
import { decodeShare, encodeShare, isShareHash, mailtoLink, shareText } from './share'

const note = { title: 'Launch sync ✓', date: Date.UTC(2026, 8, 30, 17), notes: '### Decisions\n- Ship **Thursday** — “if Safari is fixed”\n' }

describe('share links', () => {
  it('round-trips a note through the link hash', async () => {
    const hash = await encodeShare(note)
    expect(isShareHash(hash)).toBe(true)
    expect(hash).toMatch(/^#note=[A-Za-z0-9_-]+$/)
    expect(await decodeShare(hash)).toEqual(note)
  })

  it('compresses long notes', async () => {
    const long = { ...note, notes: '- Discussed the rollout plan and owners\n'.repeat(200) }
    expect((await encodeShare(long)).length).toBeLessThan(long.notes.length / 5)
  })

  it('rejects damaged or foreign hashes', async () => {
    expect(await decodeShare('#note=not-a-real-note')).toBeNull()
    expect(await decodeShare('#toggle-goatcounter')).toBeNull()
    expect(isShareHash('#toggle-goatcounter')).toBe(false)
  })
})

describe('share text and email', () => {
  it('puts the title first, then the notes', () => {
    const text = shareText(note)
    expect(text.startsWith('# Launch sync ✓\n')).toBe(true)
    expect(text).toContain('- Ship **Thursday**')
    expect(shareText({ ...note, title: ' ', date: 0 })).toBe('# Meeting notes\n\n### Decisions\n- Ship **Thursday** — “if Safari is fixed”')
  })

  it('emails the notes, or just the link when they are too long for a mail URL', () => {
    const short = decodeURIComponent(mailtoLink(note, 'https://x.test/#note=abc'))
    expect(short).toContain('subject=Meeting notes: Launch sync ✓')
    expect(short).toContain('- Ship **Thursday**')
    const long = decodeURIComponent(mailtoLink({ ...note, notes: 'x'.repeat(5000) }, 'https://x.test/#note=abc'))
    expect(long).not.toContain('xxxxx')
    expect(long).toContain('https://x.test/#note=abc')
  })
})
