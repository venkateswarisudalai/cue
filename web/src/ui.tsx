import { useEffect, useMemo, useRef, useState } from 'react'
import { parseBlocks, parseInline } from './core/markdown'
import { contextPlaceholder, formatTranscript, modeTitle, timestamp, type CueKind, type Mode } from './core/prompts'
import { speakerLabel, type Speaker, type Utterance } from './core/transcript'
import { getRecording, type Meeting } from './services/storage'
import type { Phase } from './App'

export interface Cue {
  id: string
  kind: CueKind
  title: string
  quote?: string
  auto: boolean
  text: string
  state: 'streaming' | 'done' | 'failed' | 'cancelled'
  error?: string
  at: number
}

export function Inline({ text }: { text: string }) {
  return (
    <>
      {parseInline(text).map((p, i) =>
        p.bold ? <strong key={i}>{p.text}</strong> : p.italic ? <em key={i}>{p.text}</em> : p.code ? <code key={i}>{p.text}</code> : <span key={i}>{p.text}</span>,
      )}
    </>
  )
}

export function Markdown({ text }: { text: string }) {
  const blocks = useMemo(() => parseBlocks(text), [text])
  return (
    <div className="md">
      {blocks.map((b, i) => {
        switch (b.kind) {
          case 'heading': return b.level <= 2 ? <h2 key={i}><Inline text={b.text} /></h2> : <h3 key={i}><Inline text={b.text} /></h3>
          case 'bullet': return <div key={i} className="li" style={{ marginLeft: b.depth * 20 }}><span className="dot">{b.depth ? '◦' : '•'}</span><span><Inline text={b.text} /></span></div>
          case 'numbered': return <div key={i} className="li" style={{ marginLeft: b.depth * 20 }}><span className="dot">{b.marker}</span><span><Inline text={b.text} /></span></div>
          case 'paragraph': return <p key={i}><Inline text={b.text} /></p>
          case 'divider': return <hr key={i} />
        }
      })}
    </div>
  )
}

// --- Sidebar

function groupMeetings(meetings: Meeting[]) {
  const day = (t: number) => new Date(t).toDateString()
  const today = day(Date.now())
  const yesterday = day(Date.now() - 86_400_000)
  const weekAgo = Date.now() - 7 * 86_400_000
  const groups: { title: string; items: Meeting[] }[] = []
  const add = (title: string, m: Meeting) => {
    const g = groups.find((x) => x.title === title)
    if (g) g.items.push(m); else groups.push({ title, items: [m] })
  }
  for (const m of meetings) {
    const d = day(m.createdAt)
    add(d === today ? 'Today' : d === yesterday ? 'Yesterday' : m.createdAt > weekAgo ? 'Previous 7 days' : 'Earlier', m)
  }
  return groups
}

export function Sidebar(props: {
  meetings: Meeting[]; currentId: string; locked: boolean; listening: boolean
  onNew(): void; onSelect(id: string): void; onDelete(id: string): void
  aiLabel: string; aiOk: boolean; onOpenSettings(): void
}) {
  return (
    <aside className="sidebar">
      <div className="brand"><span className="logo">◐</span> Vantage</div>
      <button className="new-note" onClick={props.onNew} disabled={props.locked}>✎ New note</button>
      <nav className="note-list">
        {groupMeetings(props.meetings).map((g) => (
          <section key={g.title}>
            <h4>{g.title}</h4>
            {g.items.map((m) => (
              <div key={m.id} className={`note-row ${m.id === props.currentId ? 'active' : ''}`}>
                <button className="note-open" onClick={() => props.onSelect(m.id)} disabled={props.locked && m.id !== props.currentId}>
                  <span className={`note-title ${m.title ? '' : 'muted'}`}>{m.title || 'New note'}</span>
                  <span className="note-time">{new Date(m.createdAt).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}</span>
                </button>
                {props.listening && m.id === props.currentId ? <span className="rec-dot" title="Listening" />
                  : <button className="note-delete" title="Delete note" disabled={props.locked && m.id === props.currentId}
                      onClick={() => { if (confirm(`Delete “${m.title || 'New note'}”?`)) props.onDelete(m.id) }}>🗑</button>}
              </div>
            ))}
          </section>
        ))}
      </nav>
      <button className={`ai-status ${props.aiOk ? '' : 'warn'}`} onClick={props.onOpenSettings} title="AI provider and API keys">
        <span>{props.aiOk ? '✨' : '⚠︎'}</span><span className="ai-label">{props.aiLabel}</span><span>⚙︎</span>
      </button>
    </aside>
  )
}

// --- Meeting

type Page = 'notes' | 'mine' | 'transcript'

export function MeetingView(props: {
  meeting: Meeting; enhancing: boolean; listening: boolean; partial: Partial<Record<Speaker, string>>
  onChange(change: Partial<Meeting>): void; onMode(mode: Mode): void; onSuggestReply(u: Utterance): void
}) {
  const m = props.meeting
  const hasEnhanced = !!m.enhancedNotes || props.enhancing
  const hasTranscript = m.utterances.length > 0 || m.recordings.length > 0
  const [chosen, setChosen] = useState<Page | null>(null) // reset per note via key={id}
  useEffect(() => { if (props.enhancing) setChosen('notes') }, [props.enhancing])
  let page: Page = chosen ?? (hasEnhanced ? 'notes' : 'mine')
  if (page === 'notes' && !hasEnhanced) page = 'mine'
  if (page === 'transcript' && !hasTranscript) page = 'mine'
  const minutes = Math.max(1, Math.round(m.durationMs / 60_000))

  return (
    <div className="doc-scroll">
      <article className="doc">
        <input className="title" value={m.title} placeholder="New note" onChange={(e) => props.onChange({ title: e.target.value })} aria-label="Title" />
        <div className="chips">
          <span className="chip">📅 {new Date(m.createdAt).toLocaleString([], { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })}</span>
          <label className="chip select-chip">
            {m.mode === 'meeting' ? '👥' : '💼'}
            <select value={m.mode} disabled={props.listening} onChange={(e) => props.onMode(e.target.value as Mode)} aria-label="Mode">
              {(Object.keys(modeTitle) as Mode[]).map((k) => <option key={k} value={k}>{modeTitle[k]}</option>)}
            </select>
          </label>
          {m.durationMs > 0 && <span className="chip">⏱ {minutes >= 60 ? `${Math.floor(minutes / 60)}h ${minutes % 60}m` : `${minutes} min`}</span>}
          <span className="grow" />
          {(hasEnhanced || hasTranscript) && (
            <div className="segmented" role="tablist">
              {hasEnhanced && <button role="tab" aria-selected={page === 'notes'} onClick={() => setChosen('notes')}>✨ Notes</button>}
              <button role="tab" aria-selected={page === 'mine'} onClick={() => setChosen('mine')}>My notes</button>
              {hasTranscript && <button role="tab" aria-selected={page === 'transcript'} onClick={() => setChosen('transcript')}>Transcript</button>}
            </div>
          )}
        </div>
        {page === 'notes' && (
          <div className="enhanced">
            <Markdown text={m.enhancedNotes} />
            {props.enhancing && <p className="muted working">{m.enhancedNotes ? 'Writing…' : 'Writing notes from your meeting…'}</p>}
          </div>
        )}
        {page === 'mine' && (
          <textarea className="my-notes" value={m.userNotes} onChange={(e) => props.onChange({ userNotes: e.target.value })}
            placeholder={props.listening
              ? 'Jot down anything that matters — Vantage fills in the rest from the transcript.'
              : 'Write notes…\n\nPress Start listening when the meeting begins. When you stop, Vantage turns your notes and the transcript into clean meeting notes.'} />
        )}
        {page === 'transcript' && <TranscriptPage meeting={m} partial={props.partial} listening={props.listening} onSuggestReply={props.onSuggestReply} />}
      </article>
    </div>
  )
}

function TranscriptPage({ meeting, partial, listening, onSuggestReply }: {
  meeting: Meeting; partial: Partial<Record<Speaker, string>>; listening: boolean; onSuggestReply(u: Utterance): void
}) {
  const audio = useRef<HTMLAudioElement>(null)
  const [src, setSrc] = useState<{ id: string; url: string } | null>(null)
  const recording = meeting.recordings[meeting.recordings.length - 1]
  const recordingId = recording?.id
  useEffect(() => {
    let url: string | null = null
    let alive = true
    if (recordingId) void getRecording(recordingId).then((blob) => {
      if (!alive || !blob) return
      url = URL.createObjectURL(blob)
      setSrc({ id: recordingId, url })
    })
    return () => { alive = false; if (url) URL.revokeObjectURL(url); setSrc(null) }
  }, [recordingId])

  const origin = meeting.utterances[0]?.startedAt ?? meeting.createdAt
  const words = meeting.utterances.reduce((n, u) => n + u.text.split(/\s+/).length, 0)
  const playFrom = (u: Utterance) => {
    const r = meeting.recordings.find((x) => u.startedAt >= x.startedAt - 1000 && u.startedAt <= x.startedAt + x.durationMs)
    if (!r || !audio.current || src?.id !== r.id) return
    audio.current.currentTime = Math.max(0, (u.startedAt - r.startedAt) / 1000 - 0.5)
    void audio.current.play()
  }
  const copy = () => navigator.clipboard.writeText(formatTranscript(meeting.utterances))
  const download = () => {
    const a = document.createElement('a')
    a.href = URL.createObjectURL(new Blob([formatTranscript(meeting.utterances)], { type: 'text/plain' }))
    a.download = `${meeting.title || 'Meeting'} transcript.txt`
    a.click()
  }

  return (
    <div className="transcript-page">
      {src && recording && (
        <div className="player">
          <audio ref={audio} src={src.url} controls preload="metadata" />
          <a className="link" href={src.url} download={`${meeting.title || 'Meeting'}.${recording.mime.includes('mp4') ? 'm4a' : 'webm'}`}>Download audio</a>
        </div>
      )}
      <div className="transcript-tools">
        <span className="muted small">{meeting.utterances.length} lines · {words} words</span>
        <span className="grow" />
        <button className="link" onClick={copy} disabled={!meeting.utterances.length}>Copy</button>
        <button className="link" onClick={download} disabled={!meeting.utterances.length}>Export .txt</button>
      </div>
      {!meeting.utterances.length && <p className="muted">{listening ? 'Listening… lines appear as people pause.' : 'No transcript for this note.'}</p>}
      {meeting.utterances.map((u, i) => {
        const showSpeaker = i === 0 || meeting.utterances[i - 1].speaker !== u.speaker
        const stamp = timestamp((u.startedAt - origin) / 1000)
        const playable = !!src && meeting.recordings.some((r) => u.startedAt >= r.startedAt - 1000 && u.startedAt <= r.startedAt + r.durationMs)
        return (
          <div key={u.id} className="t-line">
            {showSpeaker && <div className={`t-speaker ${u.speaker}`}>{speakerLabel[u.speaker]}</div>}
            <div className="t-row">
              {playable ? <button className="t-stamp link" onClick={() => playFrom(u)} title="Play from here">▸ {stamp}</button>
                : <span className="t-stamp">{stamp}</span>}
              <span className="t-text">{u.text}</span>
              {u.speaker !== 'you' && <button className="t-suggest" onClick={() => onSuggestReply(u)} title="Suggest a reply">✨</button>}
            </div>
          </div>
        )
      })}
      {(Object.entries(partial) as [Speaker, string][]).filter(([, t]) => t).map(([s, t]) => (
        <div key={s} className="t-row partial"><span className="t-stamp" /><span className="t-text">{speakerLabel[s]}: {t}</span></div>
      ))}
    </div>
  )
}

// --- Transcript drawer (live)

export function TranscriptDrawer({ meeting, partial, listening, onClose }: {
  meeting: Meeting; partial: Partial<Record<Speaker, string>>; listening: boolean; onClose(): void
}) {
  const end = useRef<HTMLDivElement>(null)
  const last = meeting.utterances[meeting.utterances.length - 1]
  // Braces matter: newer Chrome returns a Promise from scrollIntoView, and React would call it as a cleanup.
  useEffect(() => { void end.current?.scrollIntoView({ block: 'end' }) }, [last?.text, partial])
  return (
    <div className="drawer" role="region" aria-label="Transcript">
      <div className="drawer-head">
        <strong>Transcript</strong>{listening && <span className="live">Live</span>}
        <span className="grow" />
        <button className="link" onClick={() => navigator.clipboard.writeText(formatTranscript(meeting.utterances))}>Copy</button>
        <button className="icon-button" onClick={onClose} aria-label="Close transcript">✕</button>
      </div>
      <div className="drawer-body">
        {!meeting.utterances.length && !Object.values(partial).some(Boolean) && (
          <p className="muted center">{listening ? 'Listening… lines appear as people pause.' : 'No transcript yet. Your mic is “You”; a shared tab or screen is “Them”. Use headphones so your mic doesn’t pick up the other side.'}</p>
        )}
        {meeting.utterances.map((u, i) => (
          <div key={u.id} className={`bubble-wrap ${u.speaker === 'you' ? 'mine' : ''}`}>
            {(i === 0 || meeting.utterances[i - 1].speaker !== u.speaker) && <div className="bubble-speaker">{speakerLabel[u.speaker]}</div>}
            <div className="bubble">{u.text}</div>
          </div>
        ))}
        {(Object.entries(partial) as [Speaker, string][]).filter(([, t]) => t).map(([s, t]) => (
          <div key={s} className={`bubble-wrap ${s === 'you' ? 'mine' : ''}`}><div className="bubble partial">{t}</div></div>
        ))}
        <div ref={end} />
      </div>
    </div>
  )
}

// --- Bottom bar

function Clock({ since }: { since: number }) {
  const [, tick] = useState(0)
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 1000); return () => clearInterval(t) }, [])
  return <span className="mono">{timestamp((Date.now() - since) / 1000)}</span>
}

export function BottomBar(p: {
  phase: Phase; sessionStart: number | null; levels: { mic: number; call: number }; callAudio: boolean
  recordOn: boolean; shareCallAudio: boolean; hasTranscript: boolean; enhancing: boolean; hasEnhanced: boolean; canGenerate: boolean
  drawerOpen: boolean
  onToggle(): void; onToggleRecord(): void; onToggleShare(): void; onToggleDrawer(): void
  onAsk(q: string): void; onGenerate(): void; onStopNotes(): void
}) {
  const [ask, setAsk] = useState('')
  const level = Math.max(p.levels.mic, p.levels.call)
  const idle = p.phase === 'idle'
  return (
    <div className="bar">
      {idle && <button className="primary pill" onClick={p.onToggle}>〰 {p.hasTranscript ? 'Resume' : 'Start listening'}</button>}
      {(p.phase === 'starting' || p.phase === 'stopping') && <span className="muted pad">{p.phase === 'starting' ? 'Starting… choose a tab to share' : 'Finishing transcription…'}</span>}
      {p.phase === 'listening' && (
        <button className="live-pill pill" onClick={p.onToggle} title={`${p.callAudio ? 'Mic + call audio' : 'Mic only'}${p.recordOn ? ', recording' : ''} — click to stop`}>
          {p.recordOn && <span className="rec-dot white" />}
          <span className="wave">{[0, 1, 2, 3].map((i) => <i key={i} style={{ height: 4 + level * (8 + i * 2) }} />)}</span>
          {p.sessionStart && <Clock since={p.sessionStart} />} ■
        </button>
      )}
      {idle && (
        <>
          <button className={`toggle ${p.shareCallAudio ? 'on' : ''}`} onClick={p.onToggleShare}
            title={p.shareCallAudio ? 'Will ask to share a tab or screen so the other side is transcribed. Click to use mic only.' : 'Mic only. Click to also transcribe a shared tab or screen (the other side of the call).'}>
            🖥 {p.shareCallAudio ? 'Call audio' : 'Mic only'}
          </button>
          <button className={`toggle ${p.recordOn ? 'rec' : ''}`} onClick={p.onToggleRecord}
            title={p.recordOn ? 'Audio will be recorded — let everyone know. Click to turn off.' : 'Also record audio (off)'}>
            ⏺{p.recordOn ? ' Rec' : ''}
          </button>
        </>
      )}
      <button className={`icon-button ${p.drawerOpen ? 'on' : ''}`} onClick={p.onToggleDrawer} title="Transcript (Ctrl/⌘ J)">💬</button>
      <span className="divider" />
      <form className="ask" onSubmit={(e) => { e.preventDefault(); if (ask.trim()) { p.onAsk(ask.trim()); setAsk('') } }}>
        <input value={ask} onChange={(e) => setAsk(e.target.value)} placeholder="Ask anything about this meeting…" aria-label="Ask anything" />
      </form>
      {p.enhancing
        ? <button className="pill" onClick={p.onStopNotes}>■ Stop</button>
        : <button className="pill" onClick={p.onGenerate} disabled={p.phase !== 'idle' || !p.canGenerate} title="Turn your notes and the transcript into meeting notes (Ctrl/⌘ E)">
            ✨ {p.hasEnhanced ? 'Regenerate' : 'Generate notes'}
          </button>}
    </div>
  )
}

// --- Suggestions

export function SuggestionsPanel(p: {
  cues: Cue[]; hasTranscript: boolean; autoSuggest: boolean; mode: Mode; context: string
  onAutoSuggest(v: boolean): void; onRequest(k: CueKind): void; onCancel(id: string): void; onDismiss(id: string): void
  onContext(text: string): void; onClose(): void
}) {
  const [tab, setTab] = useState<'suggestions' | 'context'>('suggestions')
  return (
    <aside className="panel">
      <div className="panel-head">
        <div className="segmented">
          <button aria-selected={tab === 'suggestions'} onClick={() => setTab('suggestions')}>Suggestions</button>
          <button aria-selected={tab === 'context'} onClick={() => setTab('context')}>Context</button>
        </div>
        <span className="grow" />
        <button className="icon-button" onClick={p.onClose} aria-label="Hide suggestions">✕</button>
      </div>
      {tab === 'suggestions' ? (
        <>
          <div className="panel-actions">
            <button onClick={() => p.onRequest('respond')} disabled={!p.hasTranscript}>💬 Answer</button>
            <button onClick={() => p.onRequest('ask')} disabled={!p.hasTranscript}>❓ Ask</button>
            <button onClick={() => p.onRequest('recap')} disabled={!p.hasTranscript}>📋 Recap</button>
          </div>
          <label className="check"><input type="checkbox" checked={p.autoSuggest} onChange={(e) => p.onAutoSuggest(e.target.checked)} /> Suggest automatically when someone asks a question</label>
          <div className="cards">
            {!p.cues.length && <p className="muted center">{p.hasTranscript ? 'Tap Answer, Ask, or Recap — or ask anything from the bottom bar.' : 'While you listen, suggestions appear here. Add context so they use real details.'}</p>}
            {p.cues.map((c) => (
              <div key={c.id} className="card">
                <div className="card-head">
                  <strong>{c.title}</strong>{c.auto && <span className="badge">AUTO</span>}
                  {c.state === 'streaming' && <span className="spinner" />}
                  <span className="grow" />
                  <span className="muted small">{new Date(c.at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}</span>
                  {c.state === 'streaming'
                    ? <button className="icon-button" onClick={() => p.onCancel(c.id)} title="Stop">■</button>
                    : <button className="icon-button" onClick={() => navigator.clipboard.writeText(c.text)} title="Copy">⧉</button>}
                  <button className="icon-button" onClick={() => p.onDismiss(c.id)} title="Dismiss">✕</button>
                </div>
                {c.quote && <p className="quote">“{c.quote}”</p>}
                {c.text ? <Markdown text={c.text} /> : c.state === 'streaming' && <p className="muted">Thinking…</p>}
                {c.state === 'failed' && <p className="error">{c.error}</p>}
                {c.state === 'cancelled' && <p className="muted small">Stopped</p>}
              </div>
            ))}
          </div>
        </>
      ) : (
        <div className="context">
          <p className="muted small">Context for {modeTitle[p.mode].toLowerCase()} mode — sent with suggestions and notes so they use real details. Saved in this browser.</p>
          <textarea value={p.context} onChange={(e) => p.onContext(e.target.value)} placeholder={contextPlaceholder[p.mode]} />
        </div>
      )}
    </aside>
  )
}
