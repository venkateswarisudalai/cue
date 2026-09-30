import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { cueTitle, notesSystemPrompt, notesUserMessage, splitTitle, stripPromptTags, systemPrompt, userMessage, type CueKind, type Mode } from './core/prompts'
import { newId, type Speaker, type Utterance } from './core/transcript'
import { backendFor, notReady, streamChat, type Backend } from './services/ai'
import { Session } from './services/session'
import { track } from './services/analytics'
import {
  deleteRecordings, isEmpty, loadKeys, loadMeetings, loadSettings, putRecording, saveKeys, saveMeetings, saveSettings,
  type Meeting, type Settings,
} from './services/storage'
import { BottomBar, MeetingView, Sidebar, SuggestionsPanel, TranscriptDrawer, type Cue } from './ui'
import { SettingsDialog } from './settings'
import './styles.css'

export type Phase = 'idle' | 'starting' | 'listening' | 'stopping'

const blankMeeting = (mode: Mode): Meeting => ({
  id: newId(), title: '', createdAt: Date.now(), mode, userNotes: '', enhancedNotes: '',
  utterances: [], durationMs: 0, recordings: [],
})

/** Distinct names and jargon from the user's notes, to help speech-to-text spell them. */
const vocabularyFrom = (text: string) =>
  [...new Set(text.match(/\b([A-Z][a-zA-Z0-9]+|[A-Z0-9]{2,}[a-z0-9]*)\b/g) ?? [])].slice(0, 60).join(', ')

export default function App() {
  const [settings, setSettings] = useState<Settings>(loadSettings)
  const [keys, setKeys] = useState<Record<string, string>>(loadKeys)
  const [meetings, setMeetings] = useState<Meeting[]>(() => {
    const saved = loadMeetings()
    return saved.length && isEmpty(saved[0]) ? saved : [blankMeeting(loadSettings().mode), ...saved]
  })
  const [currentId, setCurrentId] = useState(() => meetings[0].id)
  const current = meetings.find((m) => m.id === currentId) ?? meetings[0]

  const [phase, setPhase] = useState<Phase>('idle')
  const [partial, setPartial] = useState<Partial<Record<Speaker, string>>>({})
  const [levels, setLevels] = useState({ mic: 0, call: 0 })
  const [callAudio, setCallAudio] = useState(false)
  const [sessionStart, setSessionStart] = useState<number | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [enhancing, setEnhancing] = useState(false)
  const [cues, setCues] = useState<Cue[]>([])
  const [drawer, setDrawer] = useState(false)
  const [settingsOpen, setSettingsOpen] = useState(false)
  const session = useRef<Session | null>(null)
  const notesAbort = useRef<AbortController | null>(null)
  const cueAborts = useRef(new Map<string, AbortController>())

  useEffect(() => { saveSettings(settings) }, [settings])
  useEffect(() => { saveKeys(keys) }, [keys])
  useEffect(() => { saveMeetings(meetings) }, [meetings])
  useEffect(() => () => session.current?.cancel(), [])

  const update = useCallback((id: string, change: (m: Meeting) => Partial<Meeting>) => {
    setMeetings((ms) => ms.map((m) => (m.id === id ? { ...m, ...change(m) } : m)))
  }, [])
  const updateCurrent = (change: Partial<Meeting>) => update(current.id, () => change)

  const notesBackend: Backend = useMemo(() => backendFor(settings.notesProvider, settings, keys), [settings, keys])
  const aiProblem = notReady(notesBackend)

  // --- Meetings

  const newMeeting = () => {
    if (phase !== 'idle') return
    if (isEmpty(current)) return
    const m = blankMeeting(settings.mode)
    setMeetings((ms) => [m, ...ms])
    select(m.id)
  }

  const select = (id: string) => {
    if (phase !== 'idle' || id === current.id) return
    notesAbort.current?.abort()
    setEnhancing(false)
    cueAborts.current.forEach((a) => a.abort())
    setCues([])
    setError(null)
    setDrawer(false)
    setMeetings((ms) => ms.filter((m) => m.id === id || m.id !== current.id || !isEmpty(m)))
    setCurrentId(id)
  }

  const deleteMeeting = (id: string) => {
    if (phase !== 'idle' && id === current.id) return
    const m = meetings.find((x) => x.id === id)
    if (m) void deleteRecordings(m.recordings.map((r) => r.id))
    const rest = meetings.filter((x) => x.id !== id)
    const next = rest.length ? rest : [blankMeeting(settings.mode)]
    setMeetings(next)
    if (id === current.id) setCurrentId(next[0].id)
  }

  // --- AI

  const generateNotes = useCallback(async (m: Meeting = current) => {
    if (notReady(notesBackend)) { setError(notReady(notesBackend)); setSettingsOpen(true); return }
    if (!m.utterances.length && !m.userNotes.trim()) return
    notesAbort.current?.abort()
    const abort = new AbortController()
    notesAbort.current = abort
    setEnhancing(true)
    setError(null)
    const previous = m.enhancedNotes
    let text = ''
    try {
      update(m.id, () => ({ enhancedNotes: '' }))
      for await (const chunk of streamChat(notesBackend, notesSystemPrompt(m.mode, settings.context[m.mode]),
        notesUserMessage(m.title, m.userNotes, m.utterances), abort.signal)) {
        text += chunk
        update(m.id, () => ({ enhancedNotes: stripPromptTags(text) }))
      }
      track('notes-written', `Notes written (${notesBackend.provider.name})`)
      const [title, body] = splitTitle(stripPromptTags(text))
      update(m.id, (x) => ({ enhancedNotes: body, title: x.title.trim() ? x.title : title ?? x.title }))
    } catch (e) {
      if ((e as Error).name !== 'AbortError') setError(`Couldn't write notes: ${(e as Error).message}`)
      if (!text) update(m.id, () => ({ enhancedNotes: previous }))
    } finally {
      if (notesAbort.current === abort) setEnhancing(false)
    }
  }, [current, notesBackend, settings.context, update])

  const requestCue = useCallback(async (kind: CueKind, focus?: Utterance, question?: string, auto = false) => {
    if (notReady(notesBackend)) { setError(notReady(notesBackend)); setSettingsOpen(true); return }
    const m = current
    const target = kind === 'respond' ? focus ?? [...m.utterances].reverse().find((u) => u.speaker !== 'you') : focus
    const cue: Cue = { id: newId(), kind, title: cueTitle[kind], quote: kind === 'custom' ? question : target?.text, auto, text: '', state: 'streaming', at: Date.now() }
    if (auto) setCues((cs) => { cs.filter((c) => c.auto && c.state === 'streaming').forEach((c) => cueAborts.current.get(c.id)?.abort()); return cs })
    setCues((cs) => [cue, ...cs])
    const abort = new AbortController()
    cueAborts.current.set(cue.id, abort)
    const set = (patch: Partial<Cue>) => setCues((cs) => cs.map((c) => (c.id === cue.id ? { ...c, ...patch } : c)))
    let text = ''
    try {
      for await (const chunk of streamChat(notesBackend, systemPrompt(m.mode, settings.context[m.mode]),
        userMessage(kind, m.utterances, target, question), abort.signal)) {
        text += chunk
        set({ text: stripPromptTags(text) })
      }
      set({ state: 'done' })
    } catch (e) {
      set((e as Error).name === 'AbortError' ? { state: 'cancelled' } : { state: 'failed', error: (e as Error).message })
    } finally {
      cueAborts.current.delete(cue.id)
    }
  }, [current, notesBackend, settings.context])

  const cancelCue = (id: string) => cueAborts.current.get(id)?.abort()
  const dismissCue = (id: string) => { cancelCue(id); setCues((cs) => cs.filter((c) => c.id !== id)) }

  // --- Listening

  const autoCue = useRef({ suggestions: settings.suggestions, autoSuggest: settings.autoSuggest, requestCue })
  useEffect(() => { autoCue.current = { suggestions: settings.suggestions, autoSuggest: settings.autoSuggest, requestCue } })

  const start = async () => {
    if (phase !== 'idle') return
    const speech = settings.speechProvider === 'browser' ? 'browser' as const : backendFor(settings.speechProvider, settings, keys)
    if (speech !== 'browser' && notReady(speech, true)) { setError(notReady(speech, true)); setSettingsOpen(true); return }
    setError(null)
    setPhase('starting')
    const meetingId = current.id
    const s = new Session(current.utterances, {
      speech,
      shareCallAudio: settings.shareCallAudio,
      record: settings.record,
      vocabulary: vocabularyFrom(`${settings.context[current.mode]}\n${current.userNotes}`),
    }, {
      onTranscript: (utterances) => update(meetingId, () => ({ utterances })),
      onPartial: (speaker, text) => setPartial((p) => ({ ...p, [speaker]: text ?? undefined })),
      onLevel: (source, level) => setLevels((l) => (Math.abs(l[source] - level) > 0.05 ? { ...l, [source]: level } : l)),
      onQuestion: (text) => {
        const a = autoCue.current
        if (a.suggestions && a.autoSuggest) void a.requestCue('respond', { id: newId(), speaker: 'them', text, startedAt: Date.now(), updatedAt: Date.now() }, undefined, true)
      },
      onError: (message) => setError(message),
      onCallAudioEnded: () => { setCallAudio(false); setError('Call audio sharing ended — still transcribing your mic.') },
    })
    try {
      await s.start()
      track('started-listening', `Started listening (${speech === 'browser' ? 'browser speech' : speech.provider.name}${s.hasCallAudio ? ', with call audio' : ', mic only'})`)
      session.current = s
      setCallAudio(s.hasCallAudio)
      setSessionStart(Date.now())
      setPhase('listening')
    } catch (e) {
      const name = (e as Error).name
      setError(name === 'NotAllowedError'
        ? 'Microphone access was blocked. Allow it in your browser’s site settings (the icon left of the address bar), then press Start again.'
        : `Couldn't start listening: ${(e as Error).message}`)
      await s.stop().catch(() => {})
      setPhase('idle')
    }
  }

  const stop = async () => {
    const s = session.current
    if (!s || phase !== 'listening') return
    setPhase('stopping')
    const meetingId = current.id
    const { utterances, recording } = await s.stop()
    session.current = null
    const elapsed = sessionStart ? Date.now() - sessionStart : 0
    let recordingRef: Meeting['recordings'][number] | undefined
    if (recording) {
      recordingRef = { id: newId(), startedAt: recording.startedAt, durationMs: recording.durationMs, mime: recording.blob.type }
      try { await putRecording(recordingRef.id, recording.blob) } catch { setError('Couldn’t save the recording in this browser.'); recordingRef = undefined }
    }
    const withSession = (m: Meeting): Meeting => ({
      ...m, utterances, durationMs: m.durationMs + elapsed, recordings: recordingRef ? [...m.recordings, recordingRef] : m.recordings,
    })
    // Built from the render-time copy: a state updater runs later, too late for the notes call below.
    const finished = withSession(meetings.find((m) => m.id === meetingId) ?? current)
    setMeetings((ms) => ms.map((m) => (m.id === meetingId ? withSession(m) : m)))
    setPartial({})
    setLevels({ mic: 0, call: 0 })
    setCallAudio(false)
    setSessionStart(null)
    setPhase('idle')
    if (settings.autoNotes && utterances.length && !notReady(notesBackend)) void generateNotes(finished)
  }

  const toggle = () => (phase === 'idle' ? void start() : phase === 'listening' ? void stop() : undefined)

  // Keyboard shortcuts, matching the Mac app where the browser allows.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey
      if (!mod) return
      const k = e.key.toLowerCase()
      if (k === 'e' && !e.shiftKey) { e.preventDefault(); void generateNotes() }
      else if (k === 'j') { e.preventDefault(); setDrawer((d) => !d) }
      else if (k === ',') { e.preventDefault(); setSettingsOpen(true) }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [generateNotes])

  // Warn before closing the tab mid-session.
  useEffect(() => {
    if (phase === 'idle') return
    const warn = (e: BeforeUnloadEvent) => { e.preventDefault() }
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [phase])

  const setSetting = <K extends keyof Settings>(key: K, value: Settings[K]) => setSettings((s) => ({ ...s, [key]: value }))

  return (
    <div className={`app ${settings.suggestions ? 'with-panel' : ''}`}>
      <Sidebar
        meetings={meetings} currentId={current.id} locked={phase !== 'idle'} listening={phase === 'listening'}
        onNew={newMeeting} onSelect={select} onDelete={deleteMeeting}
        aiLabel={aiProblem ? 'Set up AI — add a free key' : `AI: ${notesBackend.provider.name} · ${notesBackend.model}`}
        aiOk={!aiProblem} onOpenSettings={() => setSettingsOpen(true)}
      />
      <main className="main">
        <header className="topbar">
          <span className="grow" />
          <button className={`chip-button ${settings.suggestions ? 'on' : ''}`} onClick={() => setSetting('suggestions', !settings.suggestions)}
            title="Live suggestions while you talk">✨ Suggestions</button>
          <button className="icon-button" onClick={() => setSettingsOpen(true)} title="Settings, AI and keys (Ctrl/⌘ ,)">⚙︎</button>
        </header>
        {error && <div className="banner" role="alert"><span>{error}</span><button onClick={() => setError(null)} aria-label="Dismiss">✕</button></div>}
        <MeetingView
          key={current.id}
          meeting={current} enhancing={enhancing} listening={phase === 'listening'} partial={partial}
          onChange={updateCurrent} onMode={(mode) => { updateCurrent({ mode }); setSetting('mode', mode) }}
          onSuggestReply={(u) => { setSetting('suggestions', true); void requestCue('respond', u) }}
        />
        <div className="dock">
          {drawer && <TranscriptDrawer meeting={current} partial={partial} listening={phase === 'listening'} onClose={() => setDrawer(false)} />}
          <BottomBar
            phase={phase} sessionStart={sessionStart} levels={levels} callAudio={callAudio} recordOn={settings.record}
            shareCallAudio={settings.shareCallAudio} hasTranscript={current.utterances.length > 0}
            enhancing={enhancing} hasEnhanced={!!current.enhancedNotes} canGenerate={current.utterances.length > 0 || !!current.userNotes.trim()}
            onToggle={toggle} onToggleRecord={() => setSetting('record', !settings.record)}
            onToggleShare={() => setSetting('shareCallAudio', !settings.shareCallAudio)}
            onToggleDrawer={() => setDrawer((d) => !d)} drawerOpen={drawer}
            onAsk={(q) => { setSetting('suggestions', true); void requestCue('custom', undefined, q) }}
            onGenerate={() => void generateNotes()} onStopNotes={() => { notesAbort.current?.abort(); setEnhancing(false) }}
          />
        </div>
      </main>
      {settings.suggestions && (
        <SuggestionsPanel
          cues={cues} hasTranscript={current.utterances.length > 0} autoSuggest={settings.autoSuggest}
          onAutoSuggest={(v) => setSetting('autoSuggest', v)} onRequest={(k) => void requestCue(k)}
          onCancel={cancelCue} onDismiss={dismissCue} mode={current.mode}
          context={settings.context[current.mode]}
          onContext={(text) => setSettings((s) => ({ ...s, context: { ...s.context, [current.mode]: text } }))}
          onClose={() => setSetting('suggestions', false)}
        />
      )}
      {settingsOpen && (
        <SettingsDialog settings={settings} keys={keys} onSettings={setSettings} onKeys={setKeys} onClose={() => setSettingsOpen(false)} />
      )}
    </div>
  )
}
