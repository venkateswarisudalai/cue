// Everything lives in this browser: settings and keys in localStorage, recordings in IndexedDB.
import type { Mode } from '../core/prompts'
import type { Utterance } from '../core/transcript'

export interface RecordingRef {
  id: string
  startedAt: number
  durationMs: number
  mime: string
}

export interface Meeting {
  id: string
  title: string
  createdAt: number
  mode: Mode
  userNotes: string
  enhancedNotes: string
  utterances: Utterance[]
  durationMs: number
  recordings: RecordingRef[]
}

export interface Settings {
  /** Provider id that writes notes and suggestions. */
  notesProvider: string
  /** Provider id for speech-to-text, or 'browser' (Chrome/Edge built-in, mic only). */
  speechProvider: string
  models: Record<string, string>
  customURL: string
  mode: Mode
  context: Record<Mode, string>
  suggestions: boolean
  autoSuggest: boolean
  record: boolean
  autoNotes: boolean
  shareCallAudio: boolean
}

export const DEFAULT_SETTINGS: Settings = {
  notesProvider: 'gemini',
  speechProvider: 'gemini',
  models: {},
  customURL: '',
  mode: 'meeting',
  context: { meeting: '', sales: '' },
  suggestions: false,
  autoSuggest: true,
  record: false,
  autoNotes: true,
  shareCallAudio: true,
}

const K = { settings: 'vantage.settings', keys: 'vantage.keys', meetings: 'vantage.meetings' }

function read<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key)
    return raw ? (JSON.parse(raw) as T) : fallback
  } catch {
    return fallback
  }
}

function write(key: string, value: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(value))
  } catch (e) {
    console.warn('Vantage: could not save', key, e)
  }
}

export const loadSettings = (): Settings => {
  const s = read<Partial<Settings>>(K.settings, {})
  return { ...DEFAULT_SETTINGS, ...s, context: { ...DEFAULT_SETTINGS.context, ...(s.context ?? {}) } }
}
export const saveSettings = (s: Settings) => write(K.settings, s)

/** API keys, by provider id. Stored only in this browser's localStorage. */
export const loadKeys = (): Record<string, string> => read(K.keys, {})
export const saveKeys = (k: Record<string, string>) => write(K.keys, k)

export const loadMeetings = (): Meeting[] =>
  read<Meeting[]>(K.meetings, []).map((m) => ({ ...m, recordings: m.recordings ?? [], durationMs: m.durationMs ?? 0 })).sort((a, b) => b.createdAt - a.createdAt)
export const saveMeetings = (ms: Meeting[]) => write(K.meetings, ms.filter((m) => !isEmpty(m)))

export const isEmpty = (m: Meeting) =>
  !m.title.trim() && !m.userNotes.trim() && !m.enhancedNotes && m.utterances.length === 0

// Recordings: IndexedDB, since audio is too big for localStorage.
const DB = 'vantage'
const STORE = 'recordings'

function db(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1)
    req.onupgradeneeded = () => req.result.createObjectStore(STORE)
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
}

export async function putRecording(id: string, blob: Blob) {
  const d = await db()
  await new Promise<void>((resolve, reject) => {
    const tx = d.transaction(STORE, 'readwrite')
    tx.objectStore(STORE).put(blob, id)
    tx.oncomplete = () => resolve()
    tx.onerror = () => reject(tx.error)
  })
}

export async function getRecording(id: string): Promise<Blob | undefined> {
  const d = await db()
  return new Promise((resolve, reject) => {
    const req = d.transaction(STORE).objectStore(STORE).get(id)
    req.onsuccess = () => resolve(req.result as Blob | undefined)
    req.onerror = () => reject(req.error)
  })
}

export async function deleteRecordings(ids: string[]) {
  if (!ids.length) return
  const d = await db()
  const tx = d.transaction(STORE, 'readwrite')
  for (const id of ids) tx.objectStore(STORE).delete(id)
}
