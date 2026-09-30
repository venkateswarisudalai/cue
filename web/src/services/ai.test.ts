import { afterEach, describe, expect, it, vi } from 'vitest'
import { backendFor, speechModel, streamChat } from './ai'
import { DEFAULT_SETTINGS } from './storage'

const sse = (texts: string[]) =>
  new Response(texts.map((t) => `data: ${JSON.stringify({ choices: [{ delta: { content: t } }] })}\n\n`).join('') + 'data: [DONE]\n\n', { status: 200 })
const gemini = () => backendFor('gemini', DEFAULT_SETTINGS, { gemini: 'test-key' })
const collect = async (it: AsyncGenerator<string>) => { let s = ''; for await (const c of it) s += c; return s }

afterEach(() => vi.unstubAllGlobals())

describe('Gemini models', () => {
  it('uses the -latest aliases (numbered models get retired for new keys)', () => {
    expect(gemini().model).toBe('gemini-flash-latest')
    expect(speechModel(gemini())).toBe('gemini-flash-lite-latest')
  })

  it('falls back to flash-lite when the main model is overloaded', async () => {
    const models: string[] = []
    vi.stubGlobal('fetch', vi.fn(async (_url: string, init: RequestInit) => {
      const model = JSON.parse(String(init.body)).model
      models.push(model)
      return model === 'gemini-flash-latest'
        ? new Response('[{"error":{"code":503,"message":"This model is currently experiencing high demand."}}]', { status: 503 })
        : sse(['Hello, ', 'Vantage'])
    }))
    expect(await collect(streamChat(gemini(), 'sys', 'user'))).toBe('Hello, Vantage')
    expect(models).toEqual(['gemini-flash-latest', 'gemini-flash-lite-latest'])
  })

  it('does not retry a rejected key', async () => {
    const fetch = vi.fn(async () => new Response('{"error":{"message":"API key not valid"}}', { status: 400 }))
    vi.stubGlobal('fetch', fetch)
    await expect(collect(streamChat(gemini(), 'sys', 'user'))).rejects.toThrow(/API key not valid/)
    expect(fetch).toHaveBeenCalledTimes(1)
  })
})

describe('request timeouts', () => {
  it('gives up on a provider that never answers, then falls back to the lighter Gemini model', async () => {
    const { responseTimeout } = await import('./ai')
    const saved = responseTimeout.hostedMs
    responseTimeout.hostedMs = 50
    const models: string[] = []
    vi.stubGlobal('fetch', vi.fn((_url: string, init: RequestInit) => {
      const model = JSON.parse(String(init.body)).model
      models.push(model)
      if (model === 'gemini-flash-latest') {
        // Never answers until aborted.
        return new Promise<Response>((_, reject) => init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError'))))
      }
      return Promise.resolve(sse(['Recovered']))
    }))
    try {
      expect(await collect(streamChat(gemini(), 'sys', 'user'))).toBe('Recovered')
      expect(models).toEqual(['gemini-flash-latest', 'gemini-flash-lite-latest'])
    } finally {
      responseTimeout.hostedMs = saved
    }
  })

  it('still lets the user cancel', async () => {
    vi.stubGlobal('fetch', vi.fn((_url: string, init: RequestInit) =>
      new Promise<Response>((_, reject) => init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError'))))))
    const cancel = new AbortController()
    const run = collect(streamChat(gemini(), 'sys', 'user', cancel.signal))
    cancel.abort()
    await expect(run).rejects.toThrow(/aborted/)
  })
})
