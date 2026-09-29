# End-to-end tests

`meeting.spec.ts` drives the built app in Chromium with `fixtures/meeting.wav` (a 44 s spoken
meeting) as the microphone, and uses no API keys: speech goes to a local Whisper server through
the *Custom* provider and notes to local Ollama.

```bash
brew install whisper-cpp ollama          # or your distro's packages
curl -LO https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
whisper-server -m ggml-base.en.bin --host 0.0.0.0 --port 8178 --inference-path /v1/audio/transcriptions &
OLLAMA_ORIGINS='*' OLLAMA_HOST=0.0.0.0 ollama serve &
ollama pull llama3.2
npm run e2e                               # macOS/Linux host Chromium
npm run build && npx vite preview --host 0.0.0.0 --port 4173 &  e2e/linux/run.sh   # Linux in Docker
```

`STT_URL`, `NOTES_MODEL`, and `BASE_URL` override the defaults (e.g. `BASE_URL=https://venkateswarisudalai.github.io/cue/`).
