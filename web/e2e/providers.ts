// Which AI the end-to-end tests use. Default: local Whisper + Ollama (no keys).
// GEMINI_KEY=… runs the same tests against real Google Gemini for both speech and notes.
const GEMINI_KEY = process.env.GEMINI_KEY
const STT_URL = process.env.STT_URL ?? 'http://localhost:8178/v1'
const NOTES_MODEL = process.env.NOTES_MODEL ?? 'llama3.2'

export const usingGemini = !!GEMINI_KEY
export const aiLabel = usingGemini ? /AI: Google Gemini/ : /AI: Ollama/

/** Keeps test runs out of the site's visitor counts. */
export const blockAnalytics = (page: { route(url: string, handler: (r: { abort(): Promise<void> }) => unknown): Promise<unknown> }) =>
  page.route('https://gc.zgo.at/**', (r) => r.abort())

/** Settings + keys to put in localStorage before the app loads. */
export function seed(extra: Record<string, unknown>) {
  const base = usingGemini
    ? { notesProvider: 'gemini', speechProvider: 'gemini' }
    : { notesProvider: 'ollama', speechProvider: 'custom', customURL: STT_URL, models: { ollama: NOTES_MODEL } }
  return { settings: { ...base, ...extra }, keys: usingGemini ? { gemini: GEMINI_KEY } : {} }
}
