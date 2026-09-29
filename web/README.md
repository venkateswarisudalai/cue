# Vantage for the web (Windows, Linux, ChromeOS, Mac)

The browser version of Vantage: the same meeting notepad, transcripts, AI notes, and optional
suggestions as the Mac app, running in Chrome or Edge with no install.

**Open it:** https://venkateswarisudalai.github.io/cue/

## Set up (1 minute, free)

1. Open **Settings** (⚙︎, or Ctrl+,) and pick **Google Gemini** under *Quick start*.
2. Get a free key at [aistudio.google.com/apikey](https://aistudio.google.com/apikey) (no card) and paste it.
3. Press **Test connection**, then **Start listening**.

One key covers both speech-to-text and notes. Groq works the same way
([console.groq.com/keys](https://console.groq.com/keys)) and transcribes closer to live.

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

## Local models (free, private)

- **Ollama:** `OLLAMA_ORIGINS=https://venkateswarisudalai.github.io ollama serve`, then pick Ollama.
  Chrome may ask to allow the site to access devices on your local network — allow it.
- **Local Whisper:** `whisper-server -m ggml-base.en.bin --port 8178 --inference-path /v1/audio/transcriptions`,
  then choose *Custom* for speech with URL `http://localhost:8178/v1`.

## Develop

```bash
npm ci
npm run dev          # http://localhost:5173/cue/
npm test             # unit tests (Vitest)
npm run e2e          # end-to-end in Chromium: fake mic → local Whisper → Ollama notes (see e2e/README.md)
e2e/linux/run.sh     # the same end-to-end suite on Linux, in Docker
../scripts/deploy-web.sh   # build and publish to GitHub Pages
```
