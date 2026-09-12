# Cue

A native macOS app that listens to a conversation, transcribes it **on your Mac**, and uses Claude to suggest what to say and what to ask — for interviews, meetings, and customer calls.

- **Two-sided live transcript.** Your mic is labeled *You*; whatever the Mac plays (Zoom, Meet, Teams, a browser tab) is *Them*. No speaker diarization guesswork.
- **Auto-cue.** When the other side asks a question, a suggested answer streams in without pressing anything — no pause needed, so it keeps up with fast talkers and videos. Call audio leaking into your mic from speakers is filtered out of the *You* transcript.
- **On demand:** ⌘1 *Answer* (or *Evaluate* in interviewer mode), ⌘2 *Ask* — the three best questions to ask right now, ⌘3 *Recap* — decisions, open questions, next steps, ⌘L ask anything about the conversation.
- **Context notes per mode.** Paste or import (txt/pdf/rtf) your résumé + job description, an agenda, or account notes. Cues use those real details and write `[placeholders]` rather than inventing experience.
- **Sessions saved as Markdown** in `~/Documents/Cue Sessions/` when you stop.

Modes: *Interview — I'm the candidate*, *Interview — I'm interviewing*, *Meeting*, *Customer / sales call*.

## Requirements

- macOS 26 (Tahoe) or later on Apple silicon — uses Apple's on-device `SpeechAnalyzer`.
- One AI backend:
  - an **Anthropic API key** (Settings → *Anthropic API key*, stored in Keychain; `ANTHROPIC_API_KEY` also works), or
  - **Claude Code** installed and logged in — Cue runs `claude -p` with tools, MCP, and settings disabled. No key needed.
- Xcode 26 / Swift 6.2 to build.

## Build & install

```bash
scripts/build-app.sh --install      # builds dist/Cue.app and copies it to /Applications
scripts/build-app.sh --dmg          # also produces dist/Cue.dmg to share
```

First launch: right-click Cue.app → **Open** (it's ad-hoc signed, not notarized).

### Permissions

| Permission | Why | When |
|---|---|---|
| Microphone | Transcribe you | Prompted on first Start |
| Screen & System Audio Recording | Hear the other side of calls (ScreenCaptureKit). No video is recorded. | Prompted on first Start; **quit and reopen Cue after granting** |

Mic-only works without the second one — useful for in-person conversations, where the mic is labeled *Room*.

Rebuilding changes the ad-hoc signature, so macOS may ask for these permissions again after each rebuild.

## Using it well

- **Wear headphones on calls.** With speakers, your mic hears the other side. Cue drops obvious echoes, but headphones keep the transcript clean.
- **Fill in Context before the call.** Cues without context are generic by design.
- **Response speed** (Settings): *Fastest* (default, effort `low`) keeps live answers quick; *Thorough* is better for recaps after the call.
- Pin the window (📌) to keep it above your meeting app.

## Privacy

Audio never leaves the Mac — transcription is Apple's on-device model. Text (transcript + your context notes) is sent to Claude only when a cue is generated. Tell people when you're transcribing a conversation, and follow the rules of the interview or meeting you're in — many interview processes don't allow live assistance, so use candidate mode for practice and prep unless it's allowed.

## Development

```
Sources/CueCore/   pure logic — transcript assembly, echo filter, question detection,
                   vocabulary extraction, prompts, stream parsing (unit-tested)
Sources/Cue/       app — audio capture, SpeechAnalyzer, API/CLI clients, SwiftUI
```

```bash
swift test                                              # unit tests
swift build && .build/debug/Cue --selftest-transcribe clip.aiff   # real on-device transcription
.build/debug/Cue --selftest-llm "Why do you want this role?"     # real streamed cue via your backend
say -o clip.aiff "Can you walk me through your last outage?"      # make a test clip
```

Model defaults to `claude-opus-5` with adaptive thinking; API requests cache the system prompt and opt into server-side refusal fallbacks (`fallbacks: "default"`).
