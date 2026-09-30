import { describe, expect, it } from 'vitest'
import { cleanTranscript, isEcho, isLikelyHallucination, isQuestion, joinFragments, lastQuestion, removeEchoSentences } from './text'
import { TranscriptAssembler } from './transcript'
import { formatTranscript, notesSystemPrompt, notesUserMessage, splitTitle, stripPromptTags, systemPrompt, timestamp, userMessage } from './prompts'
import { parseBlocks, parseInline } from './markdown'
import { authHeaders, endpoint, explainError, findProvider, ollamaContextWindow, PROVIDERS } from './providers'
import { parseAnthropicLine, parseOllamaLine, parseOpenAILine } from './stream'
import { BLOCK, encodeWav, Resampler, Segmenter, type Segment } from './segmenter'

describe('cleanTranscript (same cases as the Swift TranscriptCleaner)', () => {
  it.each([
    ['um so I I think we should uh ship it', 'So I think we should ship it'],
    ['we tried that , and it failed .', 'We tried that, and it failed.'],
    ['it worked uh.', 'It worked.'],
    ["i'm not sure. i think so", "I'm not sure. I think so"],
    ['The the cache was cold', 'The cache was cold'],
    ['Revenue grew 3.5 percent', 'Revenue grew 3.5 percent'],
    ['Very, very important', 'Very, very important'],
  ])('%s', (raw, expected) => expect(cleanTranscript(raw)).toBe(expected))

  it('is idempotent', () => {
    const once = cleanTranscript('um, so the the plan is uh fine , right')
    expect(cleanTranscript(once)).toBe(once)
  })

  it('joins fragments naturally', () => {
    expect(joinFragments('We moved the service', 'And then it broke.')).toBe('We moved the service and then it broke.')
    expect(joinFragments('It broke.', 'then we fixed it')).toBe('It broke. Then we fixed it')
    expect(joinFragments('talk to the', 'the platform team')).toBe('talk to the platform team')
    expect(joinFragments('We met', 'Priya yesterday')).toBe('We met Priya yesterday')
  })
})

describe('TranscriptAssembler', () => {
  const t0 = 1_000_000
  it('merges same-speaker fragments within the gap and splits on speaker change', () => {
    const a = new TranscriptAssembler()
    a.append('Tell me about', 'them', t0)
    a.append('a hard outage.', 'them', t0 + 1500)
    a.append('Sure.', 'you', t0 + 3000)
    expect(a.utterances.map((u) => u.text)).toEqual(['Tell me about a hard outage.', 'Sure.'])
  })
  it('keeps time order when a later-finishing segment started earlier', () => {
    const a = new TranscriptAssembler()
    a.append('Second.', 'you', t0 + 5000)
    a.append('First.', 'them', t0)
    expect(a.utterances.map((u) => u.speaker)).toEqual(['them', 'you'])
  })
  it('removes an echoed fragment', () => {
    const a = new TranscriptAssembler()
    const id = a.append('I think workspaces are fine.', 'you', t0)!
    a.append('great. next question.', 'you', t0 + 1000)
    expect(a.removeFragment('great. next question.', id)).toBe(true)
    expect(a.utterances[0].text).toBe('I think workspaces are fine.')
  })
  it('ignores empty fragments', () => {
    expect(new TranscriptAssembler().append('  um ', 'you', t0)).toBeNull()
  })
})

describe('question, echo, hallucination heuristics', () => {
  it('detects questions', () => {
    expect(isQuestion('What does your deploy pipeline look like?')).toBe(true)
    expect(isQuestion('So, walk me through the migration')).toBe(true)
    expect(isQuestion('We shipped it on Friday.')).toBe(false)
  })
  it('finds a question followed by more talk in a long chunk', () => {
    expect(lastQuestion('Sam, can you own the rollback plan? Sure, I will write it up. Perfect.')).toBe('Sam, can you own the rollback plan?')
    expect(lastQuestion('Anything else? We shipped. It went fine. Thanks all. See you.')).toBeNull() // too far back
    expect(lastQuestion('We launch Thursday.')).toBeNull()
  })
  it('flags echoes but keeps genuine replies', () => {
    const call = ['So how did you handle the database migration last year?']
    expect(isEcho('how did you handle the database migration', call)).toBe(true)
    expect(isEcho('we ran both schemas side by side for two weeks', call)).toBe(false)
  })
  it('removes only the echoed sentences from a long mic chunk', () => {
    const call = ["Okay, let's get started. So the main thing today is the checkout redesign launch. Priya, where are we?"]
    const r = removeEchoSentences('So the main thing today is the checkout redesign launch. Quick update from my side, the design review is finished.', call)
    expect(r.kept).toBe('Quick update from my side, the design review is finished.')
    expect(r.echoed).toHaveLength(1)
    expect(removeEchoSentences('Yes.', call).kept).toBe('Yes.') // short replies are never treated as echo
  })
  it('drops Whisper silence hallucinations only', () => {
    expect(isLikelyHallucination('Thank you.')).toBe(true)
    expect(isLikelyHallucination('Thank you for the update on payments.')).toBe(false)
  })
})

describe('prompts', () => {
  const us = [
    { id: '1', speaker: 'them' as const, text: 'Why this role?', startedAt: 0, updatedAt: 0 },
    { id: '2', speaker: 'you' as const, text: 'Because platform work.', startedAt: 75_000, updatedAt: 75_000 },
  ]
  it('formats timestamps and transcripts like the Mac app', () => {
    expect(timestamp(3725)).toBe('1:02:05')
    expect(formatTranscript(us)).toBe('[0:00] Them: Why this role?\n[1:15] You: Because platform work.')
  })
  it('quotes the latest other-party line when answering', () => {
    const m = userMessage('respond', us)
    expect(m).toContain('"Why this role?"')
    expect(m).toContain('**Say:**')
    expect(systemPrompt('meeting', 'Agenda: Q3')).toContain('Agenda: Q3')
  })
  it('builds the notes request and splits the title', () => {
    expect(notesUserMessage('', 'rollback?', us)).toContain('rollback?')
    expect(splitTitle('# Payments cutover\n### A\n- b')).toEqual(['Payments cutover', '### A\n- b'])
    expect(splitTitle('### A\n- b')[0]).toBeNull()
  })
})

describe('markdown', () => {
  it('parses blocks and inline styles', () => {
    expect(parseBlocks('### Decisions\n- Ship **Tuesday**\n  - Porter\n1. First\nPlain\nmore\n\n---')).toEqual([
      { kind: 'heading', level: 3, text: 'Decisions' },
      { kind: 'bullet', depth: 0, text: 'Ship **Tuesday**' },
      { kind: 'bullet', depth: 1, text: 'Porter' },
      { kind: 'numbered', depth: 0, marker: '1.', text: 'First' },
      { kind: 'paragraph', text: 'Plain more' },
      { kind: 'divider' },
    ])
    expect(parseInline('Ship **Tuesday** or `later`')).toEqual([
      { text: 'Ship ' }, { text: 'Tuesday', bold: true }, { text: ' or ' }, { text: 'later', code: true },
    ])
  })
})

describe('providers', () => {
  it('lists free options first and gives speech to Gemini, Groq, OpenAI', () => {
    expect(PROVIDERS.slice(0, 2).map((p) => p.id)).toEqual(['gemini', 'groq'])
    expect(PROVIDERS.filter((p) => p.speech && p.id !== 'custom').map((p) => p.id)).toEqual(['gemini', 'groq', 'openai'])
    expect(findProvider('openrouter').defaultModel.endsWith(':free')).toBe(true)
  })
  it('builds endpoints from whatever was pasted', () => {
    for (const b of ['http://localhost:11434/v1', 'http://localhost:11434/v1/', 'http://localhost:11434/v1/chat/completions'])
      expect(endpoint(b, '/chat/completions')).toBe('http://localhost:11434/v1/chat/completions')
    expect(endpoint('', '/models')).toBeNull()
  })
  it('sends only the headers each API allows', () => {
    expect(Object.keys(authHeaders(findProvider('gemini'), 'k')).sort()).toEqual(['authorization', 'content-type'])
    expect(authHeaders(findProvider('anthropic'), 'k')['anthropic-dangerous-direct-browser-access']).toBe('true')
    expect(authHeaders(findProvider('ollama'), undefined)).toEqual({ 'content-type': 'application/json' })
  })
  it('explains free-tier errors', () => {
    expect(explainError(429, '{"error":{"message":"slow down"}}', findProvider('groq'))).toMatch(/rate-limiting.*slow down/)
    expect(explainError(400, '[{"error":{"message":"bad"}}]', findProvider('gemini'))).toBe('HTTP 400: bad')
    expect(ollamaContextWindow(60_000)).toBe(32768)
  })
})

describe('stream parsers', () => {
  it('parses OpenAI-style SSE and skips reasoning', () => {
    expect(parseOpenAILine('data: {"choices":[{"delta":{"content":"Hi"}}]}')).toEqual({ text: 'Hi' })
    expect(parseOpenAILine('data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}')).toBeNull()
    expect(parseOpenAILine('data: [DONE]')).toEqual({ stop: null })
    expect(parseOpenAILine('data: {"error":{"message":"nope"}}')).toEqual({ error: 'nope' })
  })
  it('parses Anthropic and Ollama streams', () => {
    expect(parseAnthropicLine('data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Yo"}}')).toEqual({ text: 'Yo' })
    expect(parseOllamaLine('{"message":{"content":"Hey"},"done":false}')).toEqual({ text: 'Hey' })
    expect(parseOllamaLine('{"done":true,"done_reason":"stop","message":{"content":""}}')).toEqual({ stop: 'stop' })
  })
})

describe('audio segmenting', () => {
  const tone = (amp: number) => Float32Array.from({ length: BLOCK }, (_, i) => amp * Math.sin(i / 3))
  const silence = () => new Float32Array(BLOCK)

  it('cuts one segment per utterance at the pause, with pre-roll', () => {
    const s = new Segmenter()
    const out: Segment[] = []
    let t = 0
    const feed = (b: Float32Array, n: number) => { for (let i = 0; i < n; i++) { out.push(...s.push(b, t)); t += 100 } }
    feed(silence(), 10)
    feed(tone(0.3), 20) // 2 s of speech from t=1000
    feed(silence(), 10)
    feed(tone(0.3), 15)
    feed(silence(), 10)
    expect(out).toHaveLength(2)
    expect(out[0].startedAt).toBe(1000 - 300)
    expect(out[0].durationMs).toBeGreaterThanOrEqual(2000)
    expect(out[0].durationMs).toBeLessThan(3000)
  })

  it('ignores clicks and caps very long speech', () => {
    const s = new Segmenter({ maxSegmentMs: 5000 })
    const out: Segment[] = []
    for (let i = 0; i < 5; i++) out.push(...s.push(silence(), i * 100))
    out.push(...s.push(tone(0.5), 500)) // a click
    for (let i = 0; i < 10; i++) out.push(...s.push(silence(), 600 + i * 100))
    expect(out).toHaveLength(0)
    for (let i = 0; i < 80; i++) out.push(...s.push(tone(0.3), 2000 + i * 100))
    expect(out.length).toBe(1)
    expect(out[0].durationMs).toBe(5000)
    expect(s.flush()).toHaveLength(1)
  })

  it('resamples 48 kHz to 16 kHz and writes a valid WAV header', () => {
    const r = new Resampler(48_000)
    const total = [r.process(new Float32Array(4800).fill(0.5)), r.process(new Float32Array(4800).fill(0.5))]
    expect(total.reduce((n, a) => n + a.length, 0)).toBe(3200)
    expect(total[1][10]).toBeCloseTo(0.5)
    const wav = new DataView(encodeWav(new Float32Array(1600)))
    expect(String.fromCharCode(wav.getUint8(0), wav.getUint8(1), wav.getUint8(2), wav.getUint8(3))).toBe('RIFF')
    expect(wav.getUint32(24, true)).toBe(16_000)
    expect(wav.byteLength).toBe(44 + 3200)
  })
})

describe('prompt tags', () => {
  it('leaves an empty context block out of the notes prompt', () => {
    expect(notesSystemPrompt('meeting', '  ')).not.toMatch(/context_notes|none provided/)
    expect(notesSystemPrompt('meeting', 'Agenda: launch')).toMatch(/<context_notes>\nAgenda: launch\n<\/context_notes>/)
  })

  it('ends the notes prompt with the output shape, not the context', () => {
    expect(notesSystemPrompt('meeting', 'Agenda: launch').trimEnd()).toMatch(/None recorded"$/)
  })

  it('strips echoed prompt blocks and tags from replies', () => {
    const echoed = '### Decisions\n- None recorded\n<context_notes>\n(none provided)\n</context_notes>'
    expect(stripPromptTags(echoed)).toBe('### Decisions\n- None recorded')
    expect(stripPromptTags('- Ship it\n<contextnotes> (none provided) </contextnotes>')).toBe('- Ship it')
    expect(stripPromptTags('Use <transcript> tags')).toBe('Use  tags')
    expect(stripPromptTags('a < b and c > d')).toBe('a < b and c > d')
  })
})
