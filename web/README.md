# Vantage for the web (Windows, Linux, ChromeOS, Mac)

The browser version of Vantage: the same meeting notepad, transcripts, AI notes, and optional
suggestions as the Mac app, running in Chrome or Edge with no install.

**Open it:** https://venkateswarisudalai.github.io/vantage/

## Set up (1 minute, free)

1. Open **Settings** (⚙︎, or Ctrl+,) and pick **Google Gemini** under *Quick start*.
2. Get a free key at [aistudio.google.com/apikey](https://aistudio.google.com/apikey) (no card) and paste it.
3. Press **Test connection**, then **Start listening**.

One key covers both speech-to-text and notes. Groq works the same way
([console.groq.com/keys](https://console.groq.com/keys)) and transcribes closer to live.

With Gemini, speech is sent in 15–45 s chunks at pauses to stay inside the free daily limit, so the
transcript updates in bursts. Vantage uses Google's `gemini-flash-latest` (notes) and
`gemini-flash-lite-latest` (speech) and retries on the lighter one if Gemini is busy.

**Your keys** are in ⚙︎ Settings: a saved key shows masked, with **Show / Hide**, **Copy**, and
**Remove**, and **Test connection** checks both speech and notes. The sidebar's bottom line shows
which AI is in use.

| Speech-to-text | Notes & suggestions |
|---|---|
| Gemini (free), Groq Whisper (free), OpenAI Whisper, any OpenAI-compatible Whisper server, or the browser's built-in recognizer (Chrome/Edge, mic only, no key) | Gemini, Groq, OpenRouter `:free` models, Mistral, Ollama or LM Studio on your computer, OpenAI, Claude, DeepSeek, Together, or any OpenAI-compatible server |

## Hearing the other side of a call

Your microphone is **You**. To transcribe the other side, leave **Call audio** on: when you press
Start, the browser asks what to share.

- **Chrome / Edge (Windows, Linux, Mac):** pick the **tab** with your call (Google Meet, Teams or Zoom
  on the web) and tick **Share tab audio**.
- **Windows:** you can also share the **entire screen** and tick **Share system audio**, which captures
  desktop apps like Zoom or Teams.
- **Firefox / Safari:** can't share audio — use mic-only mode (fine for in-person meetings).

Use headphones so your mic doesn't pick up the other side.

## Privacy

Notes, transcripts, recordings, and API keys are stored only in your browser (localStorage and
IndexedDB). Audio and text go only to the providers you choose. Clearing site data deletes them.

The site counts visits anonymously with [GoatCounter](https://www.goatcounter.com): no cookies, no
personal data, and none of your notes, transcripts, audio, or keys. It also counts a few moments
(a key saved for a provider, listening started, notes written) to show whether people get set up.

## Local models (free, private)

- **Ollama:** `OLLAMA_ORIGINS=https://venkateswarisudalai.github.io ollama serve`, then pick Ollama.
  Chrome may ask to allow the site to access devices on your local network — allow it.
- **Local Whisper:** `whisper-server -m ggml-base.en.bin --port 8178 --inference-path /v1/audio/transcriptions`,
  then choose *Custom* for speech with URL `http://localhost:8178/v1`.

## Tested on

Browser end-to-end tests pass on the live site on **macOS** and **Linux** (Ubuntu 24.04), in Chromium,
with real Google Gemini and with local Whisper + Ollama. They cover the first run, keys, a full
meeting, and a two-sided call. **Windows hasn't been tested yet**; it uses the same Chrome/Edge
engine, and reports are welcome.

## Develop

```bash
npm ci
npm run dev                          # http://localhost:5173/vantage/
npm test                             # unit tests (Vitest)
npm run e2e                          # browser end-to-end: fake mic → local Whisper → Ollama (see e2e/README.md)
GEMINI_KEY=… npx playwright test --workers=1   # the same tests against real Gemini
e2e/linux/run.sh                     # the same suite on Linux, in Docker (BASE_URL=… for the live site)
../scripts/deploy-web.sh             # build and publish to GitHub Pages
```

Never commit an API key: the tests read it from `GEMINI_KEY` only.
