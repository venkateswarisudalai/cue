// Port of Sources/VantageCore/Prompts.swift. Keep the wording in sync with the Mac app.
import { type Utterance, isOtherParty, speakerLabel } from './transcript'

export type Mode = 'meeting' | 'sales'
export type CueKind = 'respond' | 'ask' | 'recap' | 'custom'

export const modeTitle: Record<Mode, string> = { meeting: 'Meeting', sales: 'Customer call' }

export const contextPlaceholder: Record<Mode, string> = {
  meeting: 'Paste the agenda, your goals, open decisions, and who’s attending.',
  sales: 'Paste the account notes, product details, pricing guardrails, and known objections.',
}

const roleBrief: Record<Mode, string> = {
  meeting: `The user is a participant in a work meeting. "Them" is everyone else on the call.
Help the user contribute clearly, keep the meeting on track, surface risks, and pin down owners, decisions, and dates.`,
  sales: `The user is on a customer or sales call. "Them" is the customer.
Help the user understand the customer's real need, handle objections honestly, and move toward a clear next step. Never suggest misleading claims.`,
}

export const cueTitle: Record<CueKind, string> = {
  respond: 'Suggested answer',
  ask: 'Questions to ask',
  recap: 'Recap',
  custom: 'Your question',
}

const MAX_TRANSCRIPT_CHARACTERS = 400_000

export function timestamp(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds))
  const two = (n: number) => String(n).padStart(2, '0')
  return s >= 3600 ? `${Math.floor(s / 3600)}:${two(Math.floor((s % 3600) / 60))}:${two(s % 60)}` : `${Math.floor(s / 60)}:${two(s % 60)}`
}

export function formatTranscript(utterances: Utterance[]): string {
  if (utterances.length === 0) return ''
  const origin = utterances[0].startedAt
  const lines = utterances.map((u) => `[${timestamp((u.startedAt - origin) / 1000)}] ${speakerLabel[u.speaker]}: ${u.text}`)
  let total = lines.reduce((n, l) => n + l.length + 1, 0)
  let dropped = false
  while (total > MAX_TRANSCRIPT_CHARACTERS && lines.length > 1) {
    total -= lines.shift()!.length + 1
    dropped = true
  }
  if (dropped) lines.unshift('[earlier conversation omitted for length]')
  return lines.join('\n')
}

const context = (notes: string) => {
  const n = notes.trim()
  return `<context_notes>\n${n || '(none provided)'}\n</context_notes>`
}

export function systemPrompt(mode: Mode, contextNotes: string): string {
  return `You are Vantage, a real-time assistant running beside a live conversation. The user glances at your output while talking, so every word must earn its place.

${roleBrief[mode]}

The transcript comes from automatic speech recognition: expect missing punctuation, misheard words, and cut-off sentences. Infer intent sensibly; don't comment on transcription errors.
"You" is the user's microphone. "Them" is the other side of the call. "Room" is a single microphone picking up everyone in the room.

Rules:
- Lead with the thing the user can say or do right now. No preamble, no restating the question.
- Short lines and bullets. Bold only the few words that matter most.
- Use only facts from the context notes and transcript. Never invent employers, numbers, projects, or credentials. Where a specific example is needed and none is known, write a bracketed placeholder like [your example] instead of making one up.
- Measured, natural tone. No superlatives or hype.

${context(contextNotes)}`
}

export function userMessage(kind: CueKind, utterances: Utterance[], focus?: Utterance, customQuestion?: string): string {
  const transcript = formatTranscript(utterances)
  let task: string
  switch (kind) {
    case 'respond': {
      const target = focus?.text ?? [...utterances].reverse().find((u) => isOtherParty(u.speaker))?.text
      const quoted = target ? `\n\nRespond to this, the latest from the other side:\n"${target}"` : ''
      task = `Draft what the user should say next.${quoted}

Format:
**Say:** 2–4 sentences in first person, spoken style, ready to read aloud
**Points:** 2–3 short bullets to expand on if there's time
If this isn't really a question for the user, reply with one line saying what's happening and whether they need to respond.`
      break
    }
    case 'ask':
      task = `Suggest the 3 best questions the user could ask at this moment, most valuable first. Build on what was just said; avoid anything already answered.
Format: numbered, each a single question, then " — " and a few words on why it helps.`
      break
    case 'recap':
      task = `Recap the conversation so far.
Format:
**Summary:** 2–3 bullets
**Decisions / commitments:** bullets, or "none yet"
**Open questions:** bullets, or "none"
**Next steps:** bullets with owners where known`
      break
    case 'custom':
      task = (customQuestion ?? '').trim()
  }
  return `<transcript>\n${transcript || '(nothing has been said yet)'}\n</transcript>\n\n${task}`
}

export function notesSystemPrompt(mode: Mode, contextNotes: string): string {
  return `You write meeting notes. You get the user's own rough notes and a transcript from automatic speech recognition (expect misheard words and missing punctuation; infer intent, never comment on transcription quality). "You" is the user; "Them" is everyone else on the call; "Room" is a single microphone picking up everyone in the room.

${roleBrief[mode]}

Rules:
- The user's notes show what they care about. Keep every point they wrote, in their order, expanded with the relevant detail from the transcript. Add other important points after.
- Only facts from the transcript, the user's notes, and the context notes. Never invent names, numbers, dates, or commitments. If something is unclear, say so briefly.
- Scannable: short bullets, nested where it helps. Bold only key names, numbers, and decisions.
- Measured, factual tone. No filler, no hype, no preamble.

Output Markdown only, in this shape:
# <short title for the meeting, 3–7 words>
### <topic heading>
- bullets (as many topic sections as the conversation needs)
### Decisions
- bullets, or "None recorded"
### Action items
- **Owner** — task (due date if said), or "None recorded"

${context(contextNotes)}`
}

export function notesUserMessage(title: string, userNotes: string, utterances: Utterance[]): string {
  const transcript = formatTranscript(utterances)
  const named = title.trim()
  return `${named ? `The user titled this meeting: ${named}\n\n` : ''}<my_notes>
${userNotes.trim() || '(the user took no notes)'}
</my_notes>

<transcript>
${transcript || '(no transcript)'}
</transcript>

Write the meeting notes.`
}

/** A title Claude wrote as the first `# heading`; returns [title, notes without it]. */
export function splitTitle(notes: string): [string | null, string] {
  const body = notes.trim()
  const firstLine = body.split('\n').find((l) => l.trim() !== '')?.trim() ?? ''
  if (!firstLine.startsWith('# ')) return [null, body]
  const title = firstLine.slice(2).trim()
  const rest = body.slice(body.indexOf(firstLine) + firstLine.length).trim()
  return [title || null, rest]
}
