// Calls AI providers straight from the browser: chat streaming, model lists, speech-to-text.
import { authHeaders, endpoint, explainError, findProvider, ollamaContextWindow, type Provider } from '../core/providers'
import { lines, parseAnthropicLine, parseOllamaLine, parseOpenAILine } from '../core/stream'
import type { Settings } from './storage'

export interface Backend {
  provider: Provider
  baseURL: string
  model: string
  key?: string
}

export function backendFor(id: string, settings: Settings, keys: Record<string, string>): Backend {
  const provider = findProvider(id)
  return {
    provider,
    baseURL: provider.id === 'custom' ? settings.customURL : provider.baseURL,
    model: settings.models[provider.id]?.trim() || provider.defaultModel,
    key: keys[provider.id]?.trim() || undefined,
  }
}

/** Why a backend can't be used yet, or null if it's ready. Speech has its own model, so `forSpeech` skips that check. */
export function notReady(b: Backend, forSpeech = false): string | null {
  if (b.provider.needsKey && !b.key) return `Add your ${b.provider.name} API key in Settings.`
  if (!b.baseURL) return `Enter the server URL for ${b.provider.name} in Settings.`
  if (!forSpeech && !b.model) return `Choose a model for ${b.provider.name} in Settings.`
  return null
}

async function send(url: string, init: RequestInit, b: Backend): Promise<Response> {
  let res: Response
  try {
    res = await fetch(url, init)
  } catch (e) {
    if ((e as Error).name === 'AbortError') throw e
    if (b.provider.local) {
      throw new Error(
        `Couldn't reach ${b.provider.name} at ${b.baseURL}. Is it running, and does it allow this site? ` +
          (b.provider.id === 'ollama' ? `Start it with OLLAMA_ORIGINS=${location.origin} ollama serve` : 'Enable CORS in its server settings.'),
      )
    }
    throw new Error(`Couldn't reach ${b.provider.name} (network problem, or it blocked the request).`)
  }
  if (!res.ok) throw new Error(explainError(res.status, await res.text(), b.provider))
  return res
}

/** Errors worth one more try on a lighter model: overloaded, rate-limited, or retired. */
const retryable = (message: string) => /HTTP (429|503)|overloaded|rate-limiting|high demand|no longer available|does not exist/i.test(message)

/** Streams the reply text, falling back to the provider's lighter model if the first is unavailable. */
export async function* streamChat(b: Backend, system: string, user: string, signal?: AbortSignal): AsyncGenerator<string> {
  const fallback = b.provider.fallbackModel
  let started = false
  try {
    for await (const chunk of streamOnce(b, system, user, signal)) {
      started = true
      yield chunk
    }
  } catch (e) {
    if (started || !fallback || fallback === b.model || signal?.aborted || !retryable((e as Error).message)) throw e
    yield* streamOnce({ ...b, model: fallback }, system, user, signal)
  }
}

async function* streamOnce(b: Backend, system: string, user: string, signal?: AbortSignal): AsyncGenerator<string> {
  const p = b.provider
  const headers = authHeaders(p, b.key)
  let url: string | null
  let body: unknown
  let parse: typeof parseOpenAILine
  if (p.style === 'anthropic') {
    url = endpoint(b.baseURL, '/messages')
    body = { model: b.model, max_tokens: 8000, stream: true, system, messages: [{ role: 'user', content: user }] }
    parse = parseAnthropicLine
  } else if (p.style === 'ollama') {
    // Native API: the OpenAI-style one can't raise the context window, and long meetings get cut.
    url = b.baseURL.replace(/\/+$/, '').replace(/\/v1$/, '') + '/api/chat'
    body = {
      model: b.model, stream: true,
      messages: [{ role: 'system', content: system }, { role: 'user', content: user }],
      options: { temperature: 0.3, num_ctx: ollamaContextWindow(system.length + user.length) },
    }
    parse = parseOllamaLine
  } else {
    url = endpoint(b.baseURL, '/chat/completions')
    body = { model: b.model, stream: true, temperature: 0.3, messages: [{ role: 'system', content: system }, { role: 'user', content: user }] }
    parse = parseOpenAILine
  }
  if (!url) throw new Error(`Enter a valid server URL for ${p.name} in Settings.`)
  const res = await send(url, { method: 'POST', headers, body: JSON.stringify(body), signal }, b)
  if (!res.body) throw new Error('Empty response')
  for await (const line of lines(res.body)) {
    const e = parse(line)
    if (!e) continue
    if ('error' in e) throw new Error(e.error)
    if ('text' in e) yield e.text
  }
}

export async function listModels(b: Backend): Promise<string[]> {
  const url = endpoint(b.baseURL, '/models')
  if (!url) throw new Error('Enter a valid server URL first.')
  const headers = authHeaders(b.provider, b.key)
  delete headers['content-type'] // a GET needs no body type; keeps the CORS preflight minimal
  const res = await send(url, { headers }, b)
  const j = await res.json()
  const ids: string[] = (j.data ?? j.models ?? []).map((m: any) => m.id ?? m.name).filter(Boolean)
  // Gemini lists "models/gemini-…"; its chat endpoint wants the bare id.
  return ids.map((id) => id.replace(/^models\//, '')).sort()
}

const toBase64 = (buf: ArrayBuffer) => {
  const bytes = new Uint8Array(buf)
  let s = ''
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}

/** Speech-to-text for one WAV segment. `vocabulary` biases spelling of names and jargon. */
export async function transcribe(b: Backend, wav: ArrayBuffer, vocabulary = '', signal?: AbortSignal): Promise<string> {
  const speech = b.provider.speech
  if (!speech) throw new Error(`${b.provider.name} doesn't do speech-to-text. Pick Gemini, Groq, or OpenAI for speech.`)
  if (speech.style === 'gemini') {
    const model = speechModel(b)
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`
    const prompt =
      'Transcribe this audio verbatim in its original language. Output only the spoken words, with punctuation. ' +
      'If there is no speech, output nothing.' + (vocabulary ? ` Names and terms that may appear: ${vocabulary}` : '')
    const res = await send(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...(b.key ? { 'x-goog-api-key': b.key } : {}) },
      body: JSON.stringify({
        contents: [{ parts: [{ inline_data: { mime_type: 'audio/wav', data: toBase64(wav) } }, { text: prompt }] }],
        generationConfig: { temperature: 0 },
      }),
      signal,
    }, b)
    const j = await res.json()
    return (j.candidates?.[0]?.content?.parts ?? []).map((p: any) => p.text ?? '').join('').trim()
  }
  const url = endpoint(b.baseURL, '/audio/transcriptions')
  if (!url) throw new Error(`Enter a valid server URL for ${b.provider.name} in Settings.`)
  const form = new FormData()
  form.append('file', new Blob([wav], { type: 'audio/wav' }), 'segment.wav')
  form.append('model', speechModel(b))
  form.append('response_format', 'json')
  form.append('temperature', '0')
  if (vocabulary) form.append('prompt', vocabulary.slice(0, 800))
  const res = await send(url, { method: 'POST', headers: b.key ? { authorization: `Bearer ${b.key}` } : {}, body: form, signal }, b)
  const j = await res.json()
  return String(j.text ?? '').trim()
}

/** Gemini transcribes with its flash-lite model: accurate, and much higher free-tier request limits. */
export function speechModel(b: Backend): string {
  if (b.provider.speech?.style === 'gemini') return b.provider.speech.model
  return b.provider.speech?.model ?? 'whisper-1'
}

/**
 * How audio is chunked for each speech service. Shorter chunks feel live; free tiers limit
 * requests (Gemini per day, Groq per minute), so those get longer ones.
 */
export function segmentPolicy(b: Backend) {
  if (b.provider.speech?.style === 'gemini') return { minSegmentMs: 15_000, maxSegmentMs: 45_000, silenceToCutMs: 900 }
  if (b.provider.id === 'groq') return { minSegmentMs: 4_000, maxSegmentMs: 12_000, silenceToCutMs: 500 }
  return { minSegmentMs: 1_500, maxSegmentMs: 12_000, silenceToCutMs: 500 }
}

/** Free tiers answer 429 when busy; wait and retry a couple of times instead of dropping audio. */
export async function withRateLimitRetry<T>(run: () => Promise<T>, signal?: AbortSignal, waits = [8_000, 20_000]): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await run()
    } catch (e) {
      const limited = /rate-limiting|HTTP (429|503)|overloaded/.test((e as Error).message)
      if (!limited || attempt >= waits.length || signal?.aborted) throw e
      await new Promise((r) => setTimeout(r, waits[attempt]))
    }
  }
}
