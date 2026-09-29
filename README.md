# Vantage

A Granola-style meeting notepad for macOS. Vantage transcribes your calls **on your Mac**, and when the call ends Claude turns your rough notes and the transcript into clean meeting notes: topics, decisions, and action items.

## Install

**One command** (downloads the latest release into /Applications and opens it):

```bash
curl -fsSL https://raw.githubusercontent.com/venkateswarisudalai/cue/main/scripts/install.sh | bash
```

Run the same command again to update. Or download **Vantage.dmg** from [Releases](https://github.com/venkateswarisudalai/cue/releases), open it and drag Vantage into Applications. Vantage isn't notarized yet, so macOS warns the first time you open a downloaded copy: click **Done**, then **System Settings → Privacy & Security → Open Anyway**. The one-command install avoids that warning.

**You'll need:** an Apple silicon Mac on macOS 26 (Tahoe) or later. For AI notes and suggestions, pick any one AI source in **Settings → AI** (transcription works without one):

| Option | Cost | Setup |
|---|---|---|
| **Ollama** or **LM Studio**: an open model on your Mac | Free; nothing leaves your Mac | Install [Ollama](https://ollama.com/download), run `ollama pull llama3.2`, choose *Other provider → Ollama* |
| **Your own API key**: OpenRouter, Groq, Google Gemini, OpenAI, Mistral, DeepSeek, Together | Their pricing (Groq and Gemini have free tiers) | Choose *Other provider*, pick the service, paste your key, press *Load models* |
| **Any OpenAI-compatible server** (vLLM, llama.cpp, LiteLLM, a company gateway) | Yours | *Other provider → Custom*, enter its URL |
| **Claude**: [Claude Code](https://claude.com/claude-code) login or an Anthropic API key | Your plan / API pricing | Log in to Claude Code, or paste the key |

Keys are stored in your Mac's Keychain and sent only to the provider you choose. Bigger models write better notes; small local models work but are less thorough.

**First run:** press **Start listening** and allow **Microphone** and **Screen & System Audio Recording** (the second lets Vantage hear the other side of calls; quit and reopen Vantage after granting it). Allow notifications so Vantage can offer to start when a call begins.

## What it does

- **Notes, not a wall of text.** A sidebar of notes; type your own rough notes while you listen. When you stop, Claude writes structured notes, keeps your points first, and names the meeting (⌘E to regenerate). Switch between **Notes / My notes / Transcript** at the top of each note.
- **Clean, two-sided transcript.** Your mic is *You*; whatever the Mac plays (Zoom, Meet, Teams, a browser tab) is *Them*. Fillers and stutters are tidied up. The full transcript is always one click away, plus a live drawer in the bottom bar (⌘T).
- **Offers to start when a call begins.** When Zoom, Teams, Webex, FaceTime, Slack, Discord, WhatsApp, or a browser call starts using the microphone, Vantage asks *"Zoom call detected — Start listening?"*, and offers to stop when the call ends. It never starts on its own and only checks *which* apps use the mic, not what they hear. A menu bar icon keeps it running after you close the window.
- **Optional recording** (off by default): click ⏺ in the bottom bar. Mic and call audio are saved as one `.m4a` per session; click a transcript timestamp to play from there. Tell people before you record.
- **Optional live suggestions** (✨ or ⇧⌘S): suggested answers when someone asks a question, questions worth asking, a recap, or ask anything (⌘L). Add context (agenda, account notes) so suggestions use real details.
- **Modes:** *Meeting* and *Customer call*.
- Notes are saved automatically; a Markdown copy goes to `~/Documents/Vantage Sessions/`.

## Requirements

- macOS 26 (Tahoe) or later on Apple silicon — uses Apple's on-device `SpeechAnalyzer`.
- One AI backend (optional for transcription):
  - **Other provider or local model**: any OpenAI-compatible `/chat/completions` API (presets for Ollama, LM Studio, OpenRouter, Groq, Together, Gemini, OpenAI, Mistral, DeepSeek, or a custom URL). Keys live in Keychain; `VANTAGE_PROVIDER_KEY` also works.
  - an **Anthropic API key** (stored in Keychain; `ANTHROPIC_API_KEY` also works), or
  - **Claude Code** installed and logged in — Vantage runs `claude -p` with tools, MCP, and settings disabled. No key needed.
- Xcode 26 / Swift 6.2 to build.

## Build from source

```bash
scripts/build-app.sh --install      # builds dist/Vantage.app and copies it to /Applications
scripts/build-app.sh --dmg          # also produces dist/Vantage.dmg to share
```

Release a new version (tests, builds the DMG, publishes a GitHub release with a checksum and `install.sh`):

```bash
scripts/release.sh 1.1.0            # or DRAFT=1 scripts/release.sh 1.1.0 to review first
```

### Permissions

| Permission | Why | When |
|---|---|---|
| Microphone | Transcribe you | Prompted on first Start |
| Screen & System Audio Recording | Hear the other side of calls (ScreenCaptureKit). No video is recorded. | Prompted on first Start; **quit and reopen Vantage after granting** |

Mic-only works without the second one — useful for in-person conversations, where the mic is labeled *Room*.

Rebuilding changes the ad-hoc signature, so macOS may ask for these permissions again after each rebuild.

## Using it well

- **Wear headphones on calls.** With speakers, your mic hears the other side. Vantage drops obvious echoes, but headphones keep the transcript clean.
- **Fill in Context before the call.** Suggestions without context are generic by design.
- **Response speed** (Settings): *Fastest* (default, effort `low`) keeps live answers quick; *Thorough* is better for recaps after the call.
- Pin the window (📌) to keep it above your meeting app.

## Privacy

Audio never leaves the Mac — transcription is Apple's on-device model, and recordings (if on) are local files. Text (transcript + your context notes) is sent to Claude only when a cue is generated. Tell people when you're transcribing a conversation, and follow the rules of the interview or meeting you're in, including any rules about live assistance.

## Development

```
Sources/VantageCore/   pure logic — transcript assembly, echo filter, question detection,
                   vocabulary extraction, prompts, stream parsing (unit-tested)
Sources/Vantage/       app — audio capture, SpeechAnalyzer, API/CLI clients, SwiftUI
```

```bash
swift test                                              # unit tests
swift build && .build/debug/Vantage --selftest-transcribe clip.aiff   # real on-device transcription
.build/debug/Vantage --selftest-llm "Why do you want this role?"     # real streamed cue via your backend
.build/debug/Vantage --selftest-notes                                # real post-meeting notes via your backend
.build/debug/Vantage --selftest-mic-users                        # CoreAudio sees mic use (call detection)
.build/debug/Vantage --selftest-record clip.aiff                     # two offset tracks → one mixed .m4a
.build/debug/Vantage --selftest-snapshot out.png [--live] [--transcript] [--transcript-page]
say -o clip.aiff "Can you walk me through your last outage?"      # make a test clip
```

Model defaults to `claude-opus-5` with adaptive thinking; API requests cache the system prompt and opt into server-side refusal fallbacks (`fallbacks: "default"`).
