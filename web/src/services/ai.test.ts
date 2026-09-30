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
