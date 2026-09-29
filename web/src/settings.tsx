import { useEffect, useState } from 'react'
import { findProvider, PROVIDERS, SPEECH_PROVIDERS } from './core/providers'
import { backendFor, listModels, notReady, speechModel, streamChat, transcribe } from './services/ai'
import { browserSpeechAvailable } from './services/session'
import type { Settings } from './services/storage'
import { encodeWav } from './core/segmenter'

const mask = (k: string) => (k.length > 8 ? `${k.slice(0, 4)}••••••••${k.slice(-4)}` : '•'.repeat(k.length))

/** A key with the saved value masked, Show/Hide, Copy, Remove, and a paste field with an eye toggle. */
function KeyInput({ label, value, onChange }: { label: string; value: string; onChange(v: string): void }) {
  const [draft, setDraft] = useState('')
  const [showSaved, setShowSaved] = useState(false)
  const [showDraft, setShowDraft] = useState(false)
  const save = () => { if (draft.trim()) { onChange(draft.trim()); setDraft(''); setShowDraft(false) } }
  return (
    <div className="field">
      <span className="field-label">{label}</span>
      {value && (
        <div className="saved-key">
          <code>{showSaved ? value : mask(value)}</code>
          <button className="link" onClick={() => setShowSaved((s) => !s)}>{showSaved ? 'Hide' : 'Show'}</button>
          <button className="link" onClick={() => navigator.clipboard.writeText(value)}>Copy</button>
          <button className="link danger" onClick={() => onChange('')}>Remove</button>
        </div>
      )}
      <div className="row">
        <input type={showDraft ? 'text' : 'password'} value={draft} placeholder={value ? 'Replace key' : 'Paste your key'}
          onChange={(e) => setDraft(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && save()} autoComplete="off" spellCheck={false} aria-label={label} />
        <button className="icon-button" onClick={() => setShowDraft((s) => !s)} title={showDraft ? 'Hide' : 'Show'}>{showDraft ? '🙈' : '👁'}</button>
        <button onClick={save} disabled={!draft.trim()}>Save</button>
      </div>
    </div>
  )
}

export function SettingsDialog({ settings, keys, onSettings, onKeys, onClose }: {
  settings: Settings; keys: Record<string, string>
  onSettings(s: Settings | ((s: Settings) => Settings)): void; onKeys(k: Record<string, string>): void; onClose(): void
}) {
  const set = <K extends keyof Settings>(k: K, v: Settings[K]) => onSettings((s) => ({ ...s, [k]: v }))
  const notes = findProvider(settings.notesProvider)
  const [models, setModels] = useState<string[]>([])
  const [modelsMsg, setModelsMsg] = useState('')
  const [test, setTest] = useState('')
  const [testing, setTesting] = useState(false)
  useEffect(() => { setModels([]); setModelsMsg('') }, [settings.notesProvider])
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const setKey = (id: string, v: string) => {
    const next = { ...keys }
    if (v) next[id] = v; else delete next[id]
    onKeys(next)
  }
  const notesBackend = backendFor(settings.notesProvider, settings, keys)
  const speechIsBrowser = settings.speechProvider === 'browser'
  const speechProvider = speechIsBrowser ? null : findProvider(settings.speechProvider)
  const savedNames = PROVIDERS.filter((p) => keys[p.id]).map((p) => p.name)

  const loadModelList = async () => {
    setModelsMsg('Loading…')
    try {
      const list = await listModels(notesBackend)
      setModels(list)
      setModelsMsg(list.length ? `${list.length} models` : 'The server listed no models.')
    } catch (e) {
      setModelsMsg((e as Error).message)
    }
  }

  const runTest = async () => {
    setTesting(true)
    const lines: string[] = []
    const problem = notReady(notesBackend)
    if (problem) lines.push(`✗ Notes: ${problem}`)
    else {
      try {
        let reply = ''
        for await (const c of streamChat(notesBackend, 'Reply in five words or fewer.', 'Say hello to Vantage.')) reply += c
        lines.push(`✓ Notes (${notesBackend.provider.name} · ${notesBackend.model}): ${reply.trim()}`)
      } catch (e) { lines.push(`✗ Notes: ${(e as Error).message}`) }
    }
    if (speechIsBrowser) lines.push(browserSpeechAvailable() ? '✓ Speech: browser built-in (mic only)' : '✗ Speech: this browser has no built-in recognition — use Chrome or Edge')
    else {
      const sb = backendFor(settings.speechProvider, settings, keys)
      const sp = notReady(sb, true)
      if (sp) lines.push(`✗ Speech: ${sp}`)
      else {
        try {
          // One second of silence: checks the key and endpoint without sending any real audio.
          await transcribe(sb, encodeWav(new Float32Array(16_000)))
          lines.push(`✓ Speech (${sb.provider.name} · ${speechModel(sb)}) accepted a test clip`)
        } catch (e) { lines.push(`✗ Speech: ${(e as Error).message}`) }
      }
    }
    setTest(lines.join('\n'))
    setTesting(false)
  }

  const quickSetup = (id: 'gemini' | 'groq') => onSettings((s) => ({ ...s, notesProvider: id, speechProvider: id }))

  return (
    <div className="modal-backdrop" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal" role="dialog" aria-label="Settings">
        <div className="modal-head"><h2>Settings</h2><button className="icon-button" onClick={onClose} aria-label="Close settings">✕</button></div>

        <section>
          <h3>Quick start — free</h3>
          <p className="muted small">One free key covers speech and notes. Keys are saved only in this browser and sent only to the provider you pick.</p>
          <div className="quick">
            <button className={settings.notesProvider === 'gemini' && settings.speechProvider === 'gemini' ? 'on' : ''} onClick={() => quickSetup('gemini')}>
              <strong>Google Gemini</strong><span>Best free choice · handles long meetings</span>
            </button>
            <button className={settings.notesProvider === 'groq' && settings.speechProvider === 'groq' ? 'on' : ''} onClick={() => quickSetup('groq')}>
              <strong>Groq</strong><span>Fastest · free Whisper speech</span>
            </button>
          </div>
        </section>

        <section>
          <h3>Notes & suggestions</h3>
          <div className="field">
            <span className="field-label">Provider</span>
            <select value={settings.notesProvider} onChange={(e) => set('notesProvider', e.target.value)} aria-label="Notes provider">
              {PROVIDERS.map((p) => <option key={p.id} value={p.id}>{p.name}{p.free ? ' — free' : ''}</option>)}
            </select>
          </div>
          <p className="muted small">{notes.note} {notes.keyURL && <a href={notes.keyURL} target="_blank" rel="noreferrer">{notes.needsKey ? `Get a ${notes.name} key ↗` : `Get ${notes.name.split(' (')[0]} ↗`}</a>}</p>
          {notes.id === 'custom' && (
            <div className="field"><span className="field-label">Server URL</span>
              <input value={settings.customURL} placeholder="http://localhost:8000/v1" onChange={(e) => set('customURL', e.target.value)} aria-label="Server URL" /></div>
          )}
          {(notes.needsKey || notes.id === 'custom') && (
            <KeyInput label={`${notes.name} API key`} value={keys[notes.id] ?? ''} onChange={(v) => setKey(notes.id, v)} />
          )}
          <div className="field">
            <span className="field-label">Model</span>
            <div className="row">
              <input list="model-list" value={settings.models[notes.id] ?? ''} placeholder={notes.defaultModel || 'model id'} aria-label="Model"
                onChange={(e) => onSettings((s) => ({ ...s, models: { ...s.models, [notes.id]: e.target.value } }))} />
              <datalist id="model-list">{models.map((m) => <option key={m} value={m} />)}</datalist>
              <button onClick={loadModelList}>Load models</button>
            </div>
            {modelsMsg && <span className="muted small">{modelsMsg}</span>}
          </div>
        </section>

        <section>
          <h3>Speech to text</h3>
          <div className="field">
            <span className="field-label">Transcribe with</span>
            <select value={settings.speechProvider} onChange={(e) => set('speechProvider', e.target.value)} aria-label="Speech provider">
              {SPEECH_PROVIDERS.map((p) => <option key={p.id} value={p.id}>{p.name}{p.free ? ' — free' : ''}</option>)}
              <option value="browser">Browser built-in (Chrome/Edge, mic only, no key)</option>
            </select>
          </div>
          <p className="muted small">
            {speechIsBrowser
              ? 'No key needed, but it only hears your microphone, and Chrome sends the audio to Google to transcribe.'
              : speechProvider?.id === 'gemini'
                ? 'Sends audio in ~15–45 s chunks at pauses (to stay inside the free daily limit), so the transcript updates in bursts.'
                : speechProvider?.id === 'groq'
                  ? 'Whisper large-v3 turbo: sends each phrase at a pause, so the transcript is close to live.'
                  : speechProvider?.id === 'custom'
                    ? 'Uses the Custom server’s /audio/transcriptions (e.g. a local Whisper server).'
                    : 'Whisper, sent at each pause.'}
          </p>
          {speechProvider && speechProvider.id !== notes.id && (speechProvider.needsKey || speechProvider.id === 'custom') && (
            <KeyInput label={`${speechProvider.name} API key`} value={keys[speechProvider.id] ?? ''} onChange={(v) => setKey(speechProvider.id, v)} />
          )}
        </section>

        <section>
          <h3>Saved keys</h3>
          <p className="muted small">{savedNames.length ? savedNames.join(', ') : 'None yet'}</p>
          <div className="row">
            <button onClick={runTest} disabled={testing}>{testing ? 'Testing…' : 'Test connection'}</button>
          </div>
          {test && <pre className="test-output">{test}</pre>}
        </section>

        <section>
          <h3>Listening</h3>
          <label className="check"><input type="checkbox" checked={settings.shareCallAudio} onChange={(e) => set('shareCallAudio', e.target.checked)} /> Also transcribe the other side (asks to share a tab or screen with audio)</label>
          <label className="check"><input type="checkbox" checked={settings.record} onChange={(e) => set('record', e.target.checked)} /> Record audio (saved in this browser; tell people before you record)</label>
          <label className="check"><input type="checkbox" checked={settings.autoNotes} onChange={(e) => set('autoNotes', e.target.checked)} /> Write notes automatically when listening stops</label>
        </section>

        <section>
          <h3>Help</h3>
          <ul className="help">
            <li><strong>Hear the other side:</strong> in Chrome or Edge, when asked to share, pick the tab with your call (Meet, Teams, Zoom web) and tick <em>Share tab audio</em>. On Windows you can share the entire screen with <em>Share system audio</em> to capture desktop apps like Zoom. Firefox and Safari can only share your mic.</li>
            <li><strong>Use headphones</strong> so your mic doesn’t pick up the other side.</li>
            <li><strong>Ollama:</strong> start it with <code>OLLAMA_ORIGINS={location.origin} ollama serve</code> so this page may talk to it.</li>
            <li><strong>Privacy:</strong> your notes, transcripts, and keys stay in this browser. Audio and text go only to the providers you choose.</li>
          </ul>
        </section>
      </div>
    </div>
  )
}
