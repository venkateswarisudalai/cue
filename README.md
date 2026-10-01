# Vantage

A Granola-style meeting notepad. Vantage transcribes your calls, and when the call ends an AI turns your rough notes and the transcript into clean meeting notes, organized by topic. Live suggestions during the call are optional.

| Your computer | Use | Needs |
|---|---|---|
| **Windows** | [Web app](#windows) in Chrome or Edge | Windows 10 or 11 |
| **Linux** | [Web app](#linux) in Chrome, Chromium, or Edge | Any desktop distro |
| **ChromeOS** | [Web app](#use-it-in-the-browser) in Chrome | — |
| **Mac** | [Native app](#mac) (on-device speech, call detection, menu bar), or the web app | Native app: Apple silicon, macOS 26 (Tahoe) or later |

Every option needs a free AI key. Get one from [Google AI Studio](https://aistudio.google.com/apikey): it takes about a minute and needs no card.

## Install

### Windows

There's nothing to download. Vantage runs in the browser.

1. Open [venkateswarisudalai.github.io/vantage](https://venkateswarisudalai.github.io/vantage/) in **Chrome** or **Edge**.
2. *Optional:* install it as an app so it opens in its own window from the Start menu and taskbar:
   - **Edge:** **⋯ → Apps → Install this site as an app**.
   - **Chrome:** **⋮ → Cast, save, and share → Install page as app**.
3. Set it up as described in [Use it in the browser](#use-it-in-the-browser).

To remove the installed app, right-click it in the Start menu and choose **Uninstall**. Your notes live in the browser, so they're still there next time you open the site.

### Linux

Same as Windows: open [the site](https://venkateswarisudalai.github.io/vantage/) in **Chrome**, **Chromium**, or **Edge**. To add it to your app launcher, use **⋮ → Cast, save, and share → Install page as app** (Chrome/Chromium) or **⋯ → Apps → Install this site as an app** (Edge). Firefox opens Vantage but can't share call audio, so only your microphone is transcribed.

Then continue with [Use it in the browser](#use-it-in-the-browser).

### Mac

**One command** (downloads the latest release into /Applications and opens it):

```bash
curl -fsSL https://raw.githubusercontent.com/venkateswarisudalai/vantage/main/scripts/install.sh | bash
```

Run the same command again to update. Or download **Vantage.dmg** from [Releases](https://github.com/venkateswarisudalai/vantage/releases), open it, and drag Vantage into Applications. Vantage isn't notarized yet, so macOS warns the first time you open a downloaded copy: click **Done**, then **System Settings → Privacy & Security → Open Anyway**. The one-command install avoids that warning.

**Needs:** an Apple silicon Mac on macOS 26 (Tahoe) or later.

**First run:** press **Start listening** and allow **Microphone** and **Screen & System Audio Recording** (the second lets Vantage hear the other side of calls; quit and reopen Vantage after granting it). Allow notifications so Vantage can offer to start when a call begins.

**Add your AI key:** **Settings (⌘,) → AI → Other provider or local model → Google Gemini**, paste the key, and press **Test connection**.

Prefer not to install? The web app works on the Mac too, in Chrome or Edge.

## Use it in the browser

1. **Open** [venkateswarisudalai.github.io/vantage](https://venkateswarisudalai.github.io/vantage/) in Chrome or Edge (or the app you installed above).
2. **Add your key:** open **⚙︎ Settings** (Ctrl+, or ⌘,), pick **Google Gemini** under **Quick start**, and paste the key. Press **Test connection**: it checks both speech and notes.
3. **Choose what to hear.** The **🖥 Call audio** button in the bottom bar decides whether the other side of a call is transcribed. Click it to switch to **Mic only**, which is right for in-person meetings.
4. **Press Start listening.**
   - Allow the **microphone** when the browser asks.
   - With **Call audio** on, the browser then asks what to share. Pick the **tab** with your call (Google Meet, or Teams or Zoom on the web) and tick **Share tab audio**. On Windows you can instead share the **entire screen** and tick **Share system audio**, which captures desktop Zoom or Teams too.
5. **Take notes while you listen.** Type your own rough points in the note; open the live transcript with Ctrl+J (⌘J on Mac).
6. **Click the live pill in the bottom bar to stop.** The AI writes your notes and names the meeting. Switch between **Notes / My notes / Transcript** at the top, press Ctrl+E (⌘E) to rewrite the notes, or use **Export .txt** to save the transcript.

Your notes, transcripts, and keys are saved in that browser only. Use the same browser and profile to find them again, and remember that clearing the site's data deletes them. Wear headphones so your mic doesn't pick up the other side. More detail, including local models, is in [web/README.md](web/README.md).

## Choosing an AI

On the Mac, transcription needs no key: it's Apple's on-device speech recognition. The key only powers notes and suggestions. The web app also uses the key for speech-to-text.

| Option | Cost | Good for |
|---|---|---|
| **Google Gemini** | Free tier, no card | **Best free choice.** Strong notes, handles hour-long meetings, and one key also does speech in the web app. Google may use free-tier data to improve its products. |
| **Groq** | Free tier, no card | **Fastest**, with free Whisper speech-to-text. The free tier caps tokens per minute, so notes for long meetings can hit the limit. |
| **Ollama** or **LM Studio** | Free | **Most private**: runs on your computer. `llama3.2` (2 GB) works anywhere but can miss or invent details; on 16 GB+ of memory, a larger model such as `qwen3:14b` writes much better notes. |
| **OpenRouter** | Models ending in `:free` are free | Hundreds of models on one key; free models allow a limited number of requests per day. |
| **Mistral** | Free "Experiment" plan | Needs phone verification. |
| **OpenAI, Claude, DeepSeek, Together** | Paid | Highest quality or low cost. On the Mac, Claude also works through a [Claude Code](https://claude.com/claude-code) login with no key. |
| **Any OpenAI-compatible server** | Yours | vLLM, llama.cpp, LiteLLM, a company gateway: choose *Custom* and enter its URL. |

Vantage uses Google's `gemini-flash-latest` for notes and `gemini-flash-lite-latest` for speech, so it keeps working when Google retires a model version. If Gemini is overloaded ("high demand") or rate-limited, Vantage retries once on the lighter model. Free-tier terms change, so check each provider's page.

### Where your keys are

- **Mac:** Settings (⌘,) → AI. Keys live in your Mac's Keychain.
- **Web:** ⚙︎ Settings. Keys live in that browser's local storage.

Either way, a saved key appears masked (`sk-a••••••••9xQf`) with **Show / Hide**, **Copy**, and **Remove**. A **Saved keys** line lists which providers have one, and **Test connection** checks them. The bottom of the sidebar shows which AI is in use (for example *AI: Google Gemini · gemini-flash-latest*), and clicking it opens Settings. Keys are sent only to the provider they belong to.

## What it does

- **Notes, not a wall of text.** A sidebar of notes; type your own rough notes while you listen. When you stop, the AI writes structured notes, keeps your points first, and names the meeting (⌘E to regenerate). Switch between **Notes / My notes / Transcript** at the top of each note.
- **Clean, two-sided transcript.** Your mic is *You*; the other side of the call is *Them* (on the Mac, whatever the Mac plays; on the web, a shared tab or screen). Fillers and stutters are tidied up, and your mic picking up the other side is removed. The full transcript is always one click away, plus a live drawer in the bottom bar (⌘T on Mac, Ctrl/⌘J on the web).
- **Offers to start when a call begins** (Mac). When Zoom, Teams, Webex, FaceTime, Slack, Discord, WhatsApp, or a browser call starts using the microphone, Vantage asks *"Zoom call detected — Start listening?"*, and offers to stop when the call ends. It never starts on its own and only checks *which* apps use the mic, not what they hear. A menu bar icon keeps it running after you close the window.
- **Share notes** (web): **Share ▾** on finished notes copies a read-only link, copies the text for Slack or Teams, opens an email, or downloads a `.md` file. The notes travel inside the link itself (after the `#`, which browsers never send to a server), so nothing is uploaded. Anyone with the link can read them.
- **Optional recording** (off by default): click ⏺ in the bottom bar. Click a transcript timestamp to play from there. Tell people before you record.
- **Optional live suggestions** (✨): suggested answers when someone asks a question, questions worth asking, a recap, or ask anything. Add context (agenda, account notes) so suggestions use real details.
- **Modes:** *Meeting* and *Customer call*.
- Notes are saved automatically. On the Mac, a Markdown copy also goes to `~/Documents/Vantage Sessions/`.

## Using it well

- **Wear headphones on calls.** With speakers, your mic hears the other side. Vantage removes echoes it can detect, but headphones keep the transcript clean.
- **Fill in Context before the call.** Suggestions without context are generic by design.
- **Pin the window** (📌, Mac) to keep it above your meeting app.

## Privacy

- **Mac:** audio never leaves the Mac. Transcription is Apple's on-device model, and recordings (if on) are local files.
- **Web:** audio goes to the speech provider you pick. Notes, transcripts, recordings, and keys stay in your browser. The site counts visits anonymously with [GoatCounter](https://www.goatcounter.com) (no cookies, no personal data), plus a few moments such as "started listening", never anything you type or say.
- **Both:** transcript text and your context notes go only to the AI provider you choose, and only when notes or a suggestion are requested. With Ollama or LM Studio, nothing leaves your computer.

Tell people when you're transcribing or recording a conversation, and follow the rules of the meeting you're in.

## What's been tested

| Platform | Status |
|---|---|
| **macOS** (Mac app) | Unit tests, plus the full pipeline on the installed app: spoken clip → on-device transcript → notes → suggestion, with real Google Gemini, Claude, and local Ollama. Recording and call detection too. |
| **macOS** (web, Chromium) | Browser end-to-end tests on the live site with real Gemini and with local Whisper + Ollama: first run, keys Show/Hide/Remove, a full meeting, and a two-sided call with echo removal and automatic suggestions. |
| **Linux** (web, Ubuntu 24.04 Chromium) | The same browser end-to-end tests, in Docker, on the live site with real Gemini. |
| **Windows** (web) | **Not tested yet**; it uses the same Chrome/Edge engine. Reports welcome. |
| Firefox, Safari, phones | Not tested. Firefox and Safari can't share call audio, so use mic-only mode. |

## Development

```
Sources/VantageCore/   Mac: pure logic — transcript cleanup, echo filter, question detection,
                       prompts, providers, stream parsing (unit-tested)
Sources/Vantage/       Mac: audio capture, SpeechAnalyzer, AI clients, call detection, SwiftUI
web/                   Web app (React + Vite + TypeScript): core logic ported from VantageCore
scripts/               build-app.sh, release.sh, install.sh, deploy-web.sh
```

**Mac app** (Xcode 26 / Swift 6.2):

```bash
swift test                                        # unit tests
scripts/build-app.sh --install                    # build dist/Vantage.app and copy to /Applications
scripts/build-app.sh --dmg                        # also produce dist/Vantage.dmg
scripts/release.sh <version>                      # test, build, publish a GitHub release (DRAFT=1 to review first)
```

Self-tests exercise the real pipeline without the UI (`say -o clip.aiff "…"` makes a test clip):

```bash
.build/debug/Vantage --selftest-e2e meeting.aiff  # audio → transcript → notes → suggestion via your AI
.build/debug/Vantage --selftest-e2e meeting.aiff -provider compatible -compatProvider ollama   # …or pick one
VANTAGE_PROVIDER_KEY=… .build/debug/Vantage --selftest-e2e meeting.aiff -provider compatible -compatProvider gemini
.build/debug/Vantage --selftest-transcribe clip.aiff   # on-device transcription only
.build/debug/Vantage --selftest-notes                  # notes from a sample transcript
.build/debug/Vantage --selftest-record clip.aiff       # two offset tracks → one mixed .m4a
.build/debug/Vantage --selftest-mic-users              # CoreAudio sees mic use (call detection)
.build/debug/Vantage --selftest-snapshot out.png [--live] [--transcript] [--transcript-page] [--settings]
```

The Mac app's Claude backends default to `claude-opus-5` with adaptive thinking. API requests cache the system prompt and opt into server-side refusal fallbacks. `ANTHROPIC_API_KEY` and `VANTAGE_PROVIDER_KEY` work in place of saved keys.

**Web app:** see [web/README.md](web/README.md). The short version:

```bash
cd web && npm ci && npm test && npm run e2e       # unit + browser end-to-end tests
GEMINI_KEY=… npx playwright test --workers=1      # the end-to-end tests against real Gemini
scripts/deploy-web.sh                             # publish to GitHub Pages
```

**Never commit API keys.** Tests read them from environment variables only.

### Visitor stats

The web app counts visits with GoatCounter, cookie-free. The dashboard shows visitors, countries, operating systems (Windows / Linux / Mac), browsers, and referrers, plus these events: `saved-key-<provider>`, `started-listening`, `notes-written`. The site code lives in `web/.env.production` (`VITE_GOATCOUNTER=…`); builds without it include no analytics. Local builds and the end-to-end tests are never counted. Open the site once with `#toggle-goatcounter` at the end of the URL to stop counting your own visits in that browser.

Mac downloads: `gh api repos/venkateswarisudalai/vantage/releases -q '.[] | .tag_name + ": " + ([.assets[] | select(.name == "Vantage.dmg") | .download_count] | tostring)'`

### Permissions (Mac)

| Permission | Why | When |
|---|---|---|
| Microphone | Transcribe you | Prompted on first Start |
| Screen & System Audio Recording | Hear the other side of calls (ScreenCaptureKit). No video is recorded. | Prompted on first Start; **quit and reopen Vantage after granting** |
| Notifications | Offer to start when a call begins | Prompted on first launch |

Mic-only works without screen recording, which is useful for in-person conversations; the mic is then labeled *Room*. Rebuilding changes the ad-hoc signature, so macOS may ask for these permissions again after each rebuild.
