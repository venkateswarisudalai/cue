// AI providers the web app can call straight from the browser (all send CORS headers).
// Mirrors Sources/VantageCore/Providers.swift, plus speech-to-text where the provider offers it.

export type ApiStyle = 'openai' | 'anthropic' | 'ollama'

export interface Provider {
  id: string
  name: string
  /** Up to and including the version path. */
  baseURL: string
  defaultModel: string
  needsKey: boolean
  keyURL: string
  note: string
  style: ApiStyle
  free: boolean
  local?: boolean
  /** Speech-to-text this provider offers with the same key. */
  speech?: { model: string; style: 'openai' | 'gemini' }
}

export const PROVIDERS: Provider[] = [
  {
    id: 'gemini', name: 'Google Gemini', baseURL: 'https://generativelanguage.googleapis.com/v1beta/openai',
    defaultModel: 'gemini-2.5-flash', needsKey: true, keyURL: 'https://aistudio.google.com/apikey', style: 'openai', free: true,
    speech: { model: 'gemini-2.5-flash', style: 'gemini' },
    note: 'Best free choice: one free key (no card) does speech and notes, and handles hour-long meetings. Google may use free-tier data to improve its products.',
  },
  {
    id: 'groq', name: 'Groq', baseURL: 'https://api.groq.com/openai/v1',
    defaultModel: 'llama-3.3-70b-versatile', needsKey: true, keyURL: 'https://console.groq.com/keys', style: 'openai', free: true,
    speech: { model: 'whisper-large-v3-turbo', style: 'openai' },
    note: 'Free key, no card, very fast. Whisper speech-to-text included. The free tier caps tokens per minute, so notes for long meetings can hit the limit.',
  },
  {
    id: 'openrouter', name: 'OpenRouter', baseURL: 'https://openrouter.ai/api/v1',
    defaultModel: 'meta-llama/llama-3.3-70b-instruct:free', needsKey: true, keyURL: 'https://openrouter.ai/keys', style: 'openai', free: true,
    note: 'One key for hundreds of models. Models ending in :free cost nothing but allow a limited number of requests per day. Notes only — pick another service for speech.',
  },
  {
    id: 'mistral', name: 'Mistral', baseURL: 'https://api.mistral.ai/v1',
    defaultModel: 'mistral-small-latest', needsKey: true, keyURL: 'https://console.mistral.ai/api-keys', style: 'openai', free: true,
    note: 'Free "Experiment" plan (phone verification) with rate limits. Notes only.',
  },
  {
    id: 'ollama', name: 'Ollama (on your computer)', baseURL: 'http://localhost:11434/v1',
    defaultModel: 'llama3.2', needsKey: false, keyURL: 'https://ollama.com/download', style: 'ollama', free: true, local: true,
    note: 'Free and private — notes never leave your computer. Install Ollama, run `ollama pull llama3.2`, and start it with OLLAMA_ORIGINS set to this site (see Help). Notes only.',
  },
  {
    id: 'lmstudio', name: 'LM Studio (on your computer)', baseURL: 'http://localhost:1234/v1',
    defaultModel: '', needsKey: false, keyURL: 'https://lmstudio.ai', style: 'openai', free: true, local: true,
    note: 'Free and private. Load a model, start the local server with CORS enabled, then press Load models. Notes only.',
  },
  {
    id: 'openai', name: 'OpenAI', baseURL: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4.1-mini', needsKey: true, keyURL: 'https://platform.openai.com/api-keys', style: 'openai', free: false,
    speech: { model: 'whisper-1', style: 'openai' },
    note: 'Paid. GPT models plus Whisper speech-to-text with one key.',
  },
  {
    id: 'anthropic', name: 'Anthropic Claude', baseURL: 'https://api.anthropic.com/v1',
    defaultModel: 'claude-sonnet-5-5', needsKey: true, keyURL: 'https://console.anthropic.com/settings/keys', style: 'anthropic', free: false,
    note: 'Paid. Claude writes the most careful notes. Notes only.',
  },
  {
    id: 'deepseek', name: 'DeepSeek', baseURL: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat', needsKey: true, keyURL: 'https://platform.deepseek.com/api_keys', style: 'openai', free: false,
    note: 'Paid, low-cost. Notes only.',
  },
  {
    id: 'together', name: 'Together AI', baseURL: 'https://api.together.xyz/v1',
    defaultModel: 'meta-llama/Llama-3.3-70B-Instruct-Turbo', needsKey: true, keyURL: 'https://api.together.ai/settings/api-keys', style: 'openai', free: false,
    note: 'Paid, hosted open models. Notes only.',
  },
  {
    id: 'custom', name: 'Custom (OpenAI-compatible)', baseURL: '', defaultModel: '', needsKey: false, keyURL: '', style: 'openai', free: true,
    speech: { model: 'whisper-1', style: 'openai' },
    note: 'Any server with OpenAI-style /chat/completions (and optionally /audio/transcriptions): vLLM, llama.cpp, LiteLLM, a local Whisper server, a company gateway. It must allow this site (CORS).',
  },
]

export const findProvider = (id: string) => PROVIDERS.find((p) => p.id === id) ?? PROVIDERS[0]

/** Speech options: providers with speech, plus the browser's own (Chrome/Edge, mic only). */
export const SPEECH_PROVIDERS = PROVIDERS.filter((p) => p.speech)

/** `base` + `path`, tolerating a trailing slash or a pasted full endpoint URL. */
export function endpoint(base: string, path: string): string | null {
  let b = base.trim()
  for (const suffix of ['/chat/completions', '/audio/transcriptions', '/models', '/']) {
    if (b.endsWith(suffix)) b = b.slice(0, -suffix.length)
  }
  if (!/^https?:\/\/[^/]+/.test(b)) return null
  return b + path
}

/** Only the headers each API needs: Google rejects unknown ones in CORS preflight. */
export function authHeaders(p: Provider, key: string | undefined): Record<string, string> {
  const h: Record<string, string> = { 'content-type': 'application/json' }
  if (p.style === 'anthropic') {
    if (key) h['x-api-key'] = key
    h['anthropic-version'] = '2023-06-01'
    h['anthropic-dangerous-direct-browser-access'] = 'true'
  } else if (key) {
    h['authorization'] = `Bearer ${key}`
  }
  return h
}

/** Room for the whole prompt plus a long answer (Ollama defaults to a few thousand tokens). */
export function ollamaContextWindow(promptCharacters: number): number {
  const needed = Math.floor(promptCharacters / 3) + 4096
  return [8192, 16384, 32768, 65536, 131072].find((s) => needed <= s) ?? 131072
}

/** Turns free-tier HTTP errors into something a person can act on. */
export function explainError(status: number, body: string, p: Provider): string {
  let detail = `HTTP ${status}`
  try {
    const j = JSON.parse(body)
    const err = Array.isArray(j) ? j[0]?.error : j.error
    const msg = typeof err === 'string' ? err : err?.message
    if (msg) detail += `: ${msg}`
  } catch {
    if (body) detail += `: ${body.slice(0, 200)}`
  }
  if (status === 429) return `${p.name} is rate-limiting this key (free tiers allow only so many requests per minute or day). Wait a minute and try again. (${detail})`
  if (status === 413) return `This meeting is too long for ${p.name}'s limits on this key. Try Gemini or a paid tier. (${detail})`
  if (status === 401 || status === 403) return `${p.name} rejected the API key — check it in Settings. (${detail})`
  return detail
}
