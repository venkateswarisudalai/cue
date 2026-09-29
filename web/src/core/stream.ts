// Streaming response parsers: OpenAI-style SSE, Anthropic SSE, and Ollama NDJSON.

export type StreamEvent = { text: string } | { stop: string | null } | { error: string }

const json = (s: string): any => {
  try { return JSON.parse(s) } catch { return null }
}

/** One `data: {...}` line from an OpenAI-style /chat/completions stream. */
export function parseOpenAILine(line: string): StreamEvent | null {
  if (!line.startsWith('data:')) return null
  const payload = line.slice(5).trim()
  if (payload === '[DONE]') return { stop: null }
  const obj = json(payload)
  if (!obj) return null
  if (obj.error) return { error: obj.error.message ?? 'Stream error' }
  const choice = obj.choices?.[0]
  if (!choice) return null
  // Reasoning models' `reasoning` / `reasoning_content` never reaches the user.
  const text = choice.delta?.content
  if (typeof text === 'string' && text) return { text }
  if (choice.finish_reason) return { stop: choice.finish_reason }
  return null
}

/** One `data: {...}` line from Anthropic's Messages stream. */
export function parseAnthropicLine(line: string): StreamEvent | null {
  if (!line.startsWith('data:')) return null
  const e = json(line.slice(5).trim())
  if (!e) return null
  if (e.type === 'content_block_delta' && e.delta?.type === 'text_delta') return { text: e.delta.text }
  if (e.type === 'message_delta' && e.delta?.stop_reason) return { stop: e.delta.stop_reason }
  if (e.type === 'error') return { error: e.error?.message ?? 'Stream error' }
  return null
}

/** One NDJSON line from Ollama's /api/chat. */
export function parseOllamaLine(line: string): StreamEvent | null {
  const obj = json(line)
  if (!obj) return null
  if (typeof obj.error === 'string') return { error: obj.error }
  const text = obj.message?.content
  if (typeof text === 'string' && text) return { text }
  if (obj.done === true) return { stop: obj.done_reason ?? null }
  return null
}

/** Splits a byte stream into lines, across chunk boundaries. */
export async function* lines(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  for (;;) {
    const { value, done } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })
    let nl: number
    while ((nl = buffer.indexOf('\n')) >= 0) {
      yield buffer.slice(0, nl).replace(/\r$/, '')
      buffer = buffer.slice(nl + 1)
    }
  }
  buffer += decoder.decode()
  if (buffer) yield buffer
}
