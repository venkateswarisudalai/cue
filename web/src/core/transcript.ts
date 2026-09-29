import { cleanTranscript, joinFragments } from './text'

export type Speaker = 'you' | 'them' | 'room'

export const speakerLabel: Record<Speaker, string> = { you: 'You', them: 'Them', room: 'Room' }

export const isOtherParty = (s: Speaker) => s !== 'you'

export interface Utterance {
  id: string
  speaker: Speaker
  text: string
  /** ms since epoch when the first words were spoken */
  startedAt: number
  updatedAt: number
}

export const newId = () =>
  typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : Math.random().toString(36).slice(2) + Date.now().toString(36)

/**
 * Folds finalized speech fragments into speaker turns: fragments from the same speaker merge
 * unless they paused longer than `turnGapMs`, someone else spoke, or the turn got long.
 */
export class TranscriptAssembler {
  utterances: Utterance[]
  private turnGapMs: number
  private maxTurnCharacters: number

  constructor(existing: Utterance[] = [], turnGapMs = 4000, maxTurnCharacters = 600) {
    this.utterances = [...existing]
    this.turnGapMs = turnGapMs
    this.maxTurnCharacters = maxTurnCharacters
  }

  /** Returns the id of the utterance the fragment landed in, or null if it was empty. */
  append(fragment: string, speaker: Speaker, at: number, endedAt = at): string | null {
    const text = cleanTranscript(fragment)
    if (!text) return null
    const last = this.utterances[this.utterances.length - 1]
    if (last && last.speaker === speaker && at - last.updatedAt <= this.turnGapMs && last.text.length < this.maxTurnCharacters) {
      const merged = { ...last, text: joinFragments(last.text, text), updatedAt: endedAt }
      this.utterances = [...this.utterances.slice(0, -1), merged]
      return last.id
    }
    const u: Utterance = { id: newId(), speaker, text, startedAt: at, updatedAt: endedAt }
    // Segments from two sources can finish out of order; keep the transcript in time order.
    const i = this.utterances.findIndex((x) => x.startedAt > at)
    this.utterances = i < 0 ? [...this.utterances, u] : [...this.utterances.slice(0, i), u, ...this.utterances.slice(i)]
    return u.id
  }

  /** Removes one fragment from an utterance, dropping the utterance if nothing is left. */
  removeFragment(fragment: string, id: string): boolean {
    const i = this.utterances.findIndex((u) => u.id === id)
    if (i < 0) return false
    const target = cleanTranscript(fragment).toLowerCase()
    const current = this.utterances[i].text
    const at = current.toLowerCase().lastIndexOf(target)
    if (!target || at < 0) return false
    const text = (current.slice(0, at) + current.slice(at + target.length)).split(/\s+/).filter(Boolean).join(' ')
    this.utterances = text
      ? this.utterances.map((u, j) => (j === i ? { ...u, text } : u))
      : this.utterances.filter((_, j) => j !== i)
    return true
  }
}
