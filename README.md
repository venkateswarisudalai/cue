# Vantage

A native macOS app that listens to a conversation, transcribes it **on your Mac**, and uses Claude to suggest what to say and what to ask — for meetings and customer calls.

- **Two-sided live transcript.** Your mic is labeled *You*; whatever the Mac plays (Zoom, Meet, Teams, a browser tab) is *Them*. No speaker diarization guesswork.
- **Auto-cue.** When the other side asks a question, a suggested answer streams in without pressing anything — no pause needed, so it keeps up with fast talkers and videos. Call audio leaking into your mic from speakers is filtered out of the *You* transcript.
- **On demand:** ⌘1 *Answer* (or *Evaluate* in interviewer mode), ⌘2 *Ask* — the three best questions to ask right now, ⌘3 *Recap* — decisions, open questions, next steps, ⌘L ask anything about the conversation.
- **Context notes per mode.** Paste or import (txt/pdf/rtf) your résumé + job description, an agenda, or account notes. Suggestions use those real details and write `[placeholders]` rather than inventing experience.
- **Sessions saved as Markdown** in `~/Documents/Vantage Sessions/` when you stop.

Modes: *Meeting* and *Customer call*.

The window works like a notepad (Granola-style): a sidebar of notes, your own notes while you listen, and Claude's structured notes when you stop (⌘E to regenerate). Switch between **Notes / My notes / Transcript** at the top of each note; the live transcript is also one click away in the bottom bar (⌘T). Live suggestions are optional — toggle ✨ Suggestions (⇧⌘S).

**Call detection (on by default):** when Zoom, Teams, Webex, FaceTime, Slack, Discord, WhatsApp, or a browser call starts using the microphone, Vantage shows a notification: *"Zoom call detected — Start listening?"* When the call ends while you're listening, it offers to stop. It never starts on its own and only reads *which* apps use the mic (CoreAudio process list), not their audio. A menu bar icon keeps Vantage running after you close the window; Settings has *Open Vantage at login*.

**Recording (optional, off by default):** click ⏺ in the bottom bar or turn it on in Settings. Mic and call audio are mixed into one `.m4a` per listening session, stored in `~/Library/Application Support/com.venka.vantage/Recordings/`. On the Transcript page, click a line's timestamp to play from there. Tell people before you record.

## Requirements

- macOS 26 (Tahoe) or later on Apple silicon — uses Apple's on-device `SpeechAnalyzer`.
- One AI backend:
  - an **Anthropic API key** (Settings → *Anthropic API key*, stored in Keychain; `ANTHROPIC_API_KEY` also works), or
  - **Claude Code** installed and logged in — Vantage runs `claude -p` with tools, MCP, and settings disabled. No key needed.
- Xcode 26 / Swift 6.2 to build.

## Build & install

```bash
scripts/build-app.sh --install      # builds dist/Vantage.app and copies it to /Applications
scripts/build-app.sh --dmg          # also produces dist/Vantage.dmg to share
```

First launch: right-click Vantage.app → **Open** (it's ad-hoc signed, not notarized).

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
