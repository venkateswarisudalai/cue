// Port of MarkdownBlock in Sources/VantageCore/Meeting.swift, plus inline bold/italic/code.

export type Block =
  | { kind: 'heading'; level: number; text: string }
  | { kind: 'bullet'; depth: number; text: string }
  | { kind: 'numbered'; depth: number; marker: string; text: string }
  | { kind: 'paragraph'; text: string }
  | { kind: 'divider' }

export function parseBlocks(markdown: string): Block[] {
  const out: Block[] = []
  let paragraph: string[] = []
  const flush = () => {
    if (paragraph.length) out.push({ kind: 'paragraph', text: paragraph.join(' ') })
    paragraph = []
  }
  for (const raw of markdown.split('\n')) {
    const indentMatch = raw.match(/^[ \t]*/)?.[0] ?? ''
    const indent = [...indentMatch].reduce((n, c) => n + (c === '\t' ? 4 : 1), 0)
    const line = raw.trim()
    if (!line) { flush(); continue }
    if (line === '---' || line === '***') { flush(); out.push({ kind: 'divider' }); continue }
    const h = line.match(/^(#{1,6}) (.*)$/)
    if (h) { flush(); out.push({ kind: 'heading', level: Math.min(h[1].length, 3), text: h[2].trim() }); continue }
    const b = line.match(/^[-*•] (.*)$/)
    if (b) { flush(); out.push({ kind: 'bullet', depth: Math.floor(indent / 2), text: b[1] }); continue }
    const n = line.match(/^(\d+\.) (.*)$/)
    if (n) { flush(); out.push({ kind: 'numbered', depth: Math.floor(indent / 2), marker: n[1], text: n[2] }); continue }
    paragraph.push(line)
  }
  flush()
  return out
}

export type Inline = { text: string; bold?: boolean; italic?: boolean; code?: boolean }

/** `**bold**`, `*italic*`/`_italic_`, and `` `code` `` — enough for notes and suggestions. */
export function parseInline(s: string): Inline[] {
  const out: Inline[] = []
  const re = /(\*\*[^*]+\*\*|`[^`]+`|\*[^*\s][^*]*\*|_[^_\s][^_]*_)/g
  let last = 0
  for (const m of s.matchAll(re)) {
    if (m.index! > last) out.push({ text: s.slice(last, m.index) })
    const t = m[0]
    if (t.startsWith('**')) out.push({ text: t.slice(2, -2), bold: true })
    else if (t.startsWith('`')) out.push({ text: t.slice(1, -1), code: true })
    else out.push({ text: t.slice(1, -1), italic: true })
    last = m.index! + t.length
  }
  if (last < s.length) out.push({ text: s.slice(last) })
  return out
}
