// Ports of the Mac app's VantageCore text logic (TranscriptCleaner, QuestionDetector, EchoFilter).
// Keep behavior in sync with Sources/VantageCore.

const FILLERS = new Set(['um', 'umm', 'uh', 'uhh', 'uhm', 'erm', 'er', 'ah', 'hmm', 'mm', 'mhm'])

/** Words that are never names, so lowering them mid-sentence is safe. */
const COMMON_WORDS = new Set([
  'and', 'but', 'so', 'or', 'because', 'then', 'that', 'which', 'the', 'a', 'an', 'to', 'of',
  'in', 'on', 'for', 'with', 'we', 'you', 'they', 'it', 'is', 'was', 'if', 'when', 'like', 'just',
])

const sentencesOf = (text: string) => text.match(/[^.!?]+[.!?]*/g)?.map((s) => s.trim()).filter(Boolean) ?? []

const core = (token: string) => token.toLowerCase().replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, '')

function capitalizeSentences(text: string): string {
  let out = ''
  let capitalizeNext = true
  for (const ch of text) {
    if (capitalizeNext && /\p{L}/u.test(ch)) {
      out += ch.toUpperCase()
      capitalizeNext = false
    } else {
      out += ch
      if ('.?!'.includes(ch)) capitalizeNext = true
      else if (!/\s/.test(ch)) capitalizeNext = false
    }
  }
  return out
}

/**
 * Tidies a raw speech-recognition fragment: drops fillers, collapses stutters, fixes spacing
 * around punctuation, capitalizes sentence starts. Deterministic and idempotent.
 */
export function cleanTranscript(raw: string): string {
  const words: string[] = []
  for (const token of raw.split(/\s+/).filter(Boolean)) {
    const bare = core(token)
    if (FILLERS.has(bare)) {
      // Keep sentence punctuation the filler carried ("uh." ends the sentence before it).
      const p = token[token.length - 1]
      if ('.?!'.includes(p) && words.length > 0) {
        const last = words.pop()!
        words.push(core(last) === '' ? last : last.replace(/,$/, '') + p)
      }
      continue
    }
    const last = words[words.length - 1]
    if (last !== undefined && bare !== '' && core(last) === bare && token.toLowerCase() === bare && last.toLowerCase() === bare) {
      continue // "I I I think" → "I think"
    }
    words.push(token)
  }
  let text = words.join(' ')
  text = text.replace(/\s+([,.?!;:])/g, '$1')
  text = text.replace(/,+/g, ',')
  text = text.replace(/^[,;:]\s*/, '')
  text = text.replace(/\bi\b/g, 'I').replace(/\bi'/g, "I'")
  return capitalizeSentences(text).trim()
}

/** Joins a new fragment onto a turn, dropping a word repeated across the boundary. */
export function joinFragments(existing: string, fragment: string): string {
  if (!existing) return fragment
  if (!fragment) return existing
  let next = fragment
  const lastWord = existing.split(' ').pop() ?? ''
  const firstWord = next.split(' ')[0] ?? ''
  if (lastWord.toLowerCase() === core(lastWord) && core(lastWord) === core(firstWord) && core(firstWord) !== '') {
    next = next.slice(firstWord.length).trim()
    if (!next) return existing
  }
  const end = existing[existing.length - 1]
  if ('.?!'.includes(end)) {
    next = next.charAt(0).toUpperCase() + next.slice(1)
  } else {
    const first = next.split(' ')[0] ?? ''
    if (first !== 'I' && /^\p{Lu}\p{Ll}*$/u.test(first) && COMMON_WORDS.has(first.toLowerCase())) {
      // The recognizer capitalizes each segment; mid-sentence "And so" → "and so".
      next = next.charAt(0).toLowerCase() + next.slice(1)
    }
  }
  return existing + ' ' + next
}

const OPENERS = [
  'what', 'how', 'why', 'when', 'where', 'who', 'which',
  'can you', 'could you', 'would you', 'will you', 'do you', 'did you',
  'have you', 'are you', 'were you', 'is there', 'is it', 'should we',
  'tell me', 'walk me through', 'talk me through', 'describe', 'explain',
  'give me an example', 'share an example', 'talk about', 'take me through',
]
const LEAD_FILLERS = ['so ', 'okay ', 'ok ', 'alright ', 'and ', 'um ', 'uh ', 'great ', 'cool ', 'right ', 'now ']

function stripLeadFiller(sentence: string): string {
  let s = sentence.replace(/,/g, ' ').split(/\s+/).filter(Boolean).join(' ')
  let changed = true
  while (changed) {
    changed = false
    for (const f of LEAD_FILLERS) {
      if (s.startsWith(f)) {
        s = s.slice(f.length).replace(/^[ ,]+|[ ,]+$/g, '')
        changed = true
      }
    }
  }
  return s
}

/** Heuristic check for "the other person just asked me something". */
export function isQuestion(text: string): boolean {
  const trimmed = text.trim()
  if (trimmed.length < 8) return false
  if (trimmed.endsWith('?')) return true
  const sentences = trimmed.split(/[.!?]/).map((s) => s.trim().toLowerCase()).filter(Boolean)
  return sentences.slice(-2).some((sentence) => {
    const s = stripLeadFiller(sentence)
    return OPENERS.some((o) => s.startsWith(o + ' ') || s === o)
  })
}

/**
 * The most recent question among a chunk's last few sentences, or null. Long speech chunks
 * (Gemini's) often carry a question followed by more talk, so checking only the end misses it.
 */
export function lastQuestion(text: string, lookBack = 3): string | null {
  for (const s of sentencesOf(text).slice(-lookBack).reverse()) {
    if (isQuestion(s)) return s
  }
  return null
}

const wordSet = (s: string) => new Set(s.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean))

/** Speakers leak call audio into the mic: does this mic text repeat recent call audio? */
export function isEcho(micText: string, recentCallText: string[], threshold = 0.6): boolean {
  const mic = wordSet(micText)
  if (mic.size < 3) return false
  return recentCallText.some((t) => {
    const call = wordSet(t)
    let shared = 0
    for (const w of mic) if (call.has(w)) shared++
    return shared / mic.size >= threshold
  })
}

/**
 * Drops the sentences of a mic transcript that repeat recent call audio, keeping the rest. Long
 * speech chunks can hold an echo and a real reply together, so judging the whole chunk fails.
 */
export function removeEchoSentences(micText: string, recentCallText: string[]): { kept: string; echoed: string[] } {
  const echoed: string[] = []
  const kept = sentencesOf(micText).filter((s) => {
    if (isEcho(s, recentCallText)) { echoed.push(s); return false }
    return true
  })
  return { kept: kept.join(' '), echoed }
}

/** Whisper invents these on silence or noise; drop a segment that is only one of them. */
const HALLUCINATIONS = new Set([
  'thank you', 'thank you.', 'thanks for watching', 'thanks for watching!', 'thank you for watching',
  'you', 'bye', 'bye.', 'okay', 'okay.', 'so', '.', 'subtitles by the amara.org community',
])

export function isLikelyHallucination(text: string): boolean {
  const t = text.trim().toLowerCase().replace(/[!.]+$/, '')
  return t.length === 0 || HALLUCINATIONS.has(t) || HALLUCINATIONS.has(t + '.')
}
