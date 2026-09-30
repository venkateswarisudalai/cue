// Anonymous, cookie-free usage counts via GoatCounter (https://www.goatcounter.com).
// Counts visits and a few moments (a key saved, listening started, notes written) — never
// notes, transcripts, audio, keys, or anything typed. Off unless VITE_GOATCOUNTER is set at build.

const code = import.meta.env.VITE_GOATCOUNTER as string | undefined

type GoatCounter = { count(v: { path: string; title?: string; event?: boolean }): void }
declare global {
  interface Window { goatcounter?: GoatCounter & { no_onload?: boolean } }
}

/** Loads GoatCounter once. It skips localhost and anyone who opted out via #toggle-goatcounter. */
export function initAnalytics() {
  if (!code || typeof document === 'undefined' || document.querySelector('script[data-goatcounter]')) return
  const s = document.createElement('script')
  s.async = true
  s.src = 'https://gc.zgo.at/count.js'
  s.dataset.goatcounter = `https://${code}.goatcounter.com/count`
  document.head.appendChild(s)
}

/** Counts a moment as an event. `name` must never contain user content. */
export function track(name: string, title?: string) {
  try {
    window.goatcounter?.count({ path: name, title: title ?? name, event: true })
  } catch {
    // Analytics must never break the app.
  }
}
