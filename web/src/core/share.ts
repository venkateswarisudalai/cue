// Sharing notes without a server: the note is compressed into the link's #fragment,
// which browsers never send to the host, so nothing is uploaded or stored anywhere.

export interface SharedNote {
  title: string
  /** Meeting start, epoch ms. */
  date: number
  notes: string
}

const PREFIX = '#note='
/** mailto: bodies past ~1,800 characters get cut off by some mail apps. */
const MAILTO_LIMIT = 1_800

async function pipe(bytes: Uint8Array, stream: CompressionStream | DecompressionStream): Promise<Uint8Array> {
  return new Uint8Array(await new Response(new Blob([bytes as BlobPart]).stream().pipeThrough(stream)).arrayBuffer())
}

const toBase64Url = (bytes: Uint8Array) => {
  let s = ''
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

const fromBase64Url = (text: string) => {
  const s = atob(text.replace(/-/g, '+').replace(/_/g, '/'))
  return Uint8Array.from(s, (c) => c.charCodeAt(0))
}

/** `#note=…` for a read-only copy of the note. */
export async function encodeShare(note: SharedNote): Promise<string> {
  const json = JSON.stringify({ t: note.title, d: note.date, n: note.notes })
  return PREFIX + toBase64Url(await pipe(new TextEncoder().encode(json), new CompressionStream('deflate-raw')))
}

/** The note in a `#note=…` hash, or null if the hash isn't a valid share. */
export async function decodeShare(hash: string): Promise<SharedNote | null> {
  if (!hash.startsWith(PREFIX)) return null
  try {
    const bytes = await pipe(fromBase64Url(hash.slice(PREFIX.length)), new DecompressionStream('deflate-raw'))
    const o = JSON.parse(new TextDecoder().decode(bytes))
    if (typeof o?.n !== 'string') return null
    return { title: typeof o.t === 'string' ? o.t : '', date: typeof o.d === 'number' ? o.d : 0, notes: o.n }
  } catch {
    return null
  }
}

export const isShareHash = (hash: string) => hash.startsWith(PREFIX)

/** Title, date, and notes as Markdown, for pasting into chat or email. */
export function shareText(note: SharedNote): string {
  const date = note.date ? new Date(note.date).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) : ''
  return [`# ${note.title.trim() || 'Meeting notes'}`, date, '', note.notes.trim()].filter((l, i) => i !== 1 || l).join('\n')
}

/** A mailto: link with the notes, or with just the link when the notes are too long for a mail URL. */
export function mailtoLink(note: SharedNote, link: string): string {
  const subject = `Meeting notes: ${note.title.trim() || 'Meeting'}`
  const full = `${shareText(note)}\n\n—\nView online: ${link}`
  const body = full.length <= MAILTO_LIMIT ? full : `Here are the notes from ${note.title.trim() || 'our meeting'}:\n${link}`
  return `mailto:?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`
}
