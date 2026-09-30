// A listening session: captures the mic ("You") and, optionally, a shared tab or screen's audio
// ("Them"), cuts speech at pauses, transcribes each piece, and folds it into the transcript.
import { BLOCK, encodeWav, Resampler, Segmenter, rms, type Segment } from '../core/segmenter'
import { isLikelyHallucination, lastQuestion, removeEchoSentences } from '../core/text'
import { TranscriptAssembler, type Speaker, type Utterance } from '../core/transcript'
import { segmentPolicy, transcribe, withRateLimitRetry, type Backend } from './ai'

export interface SessionCallbacks {
  onTranscript(utterances: Utterance[]): void
  onPartial(speaker: Speaker, text: string | null): void
  onLevel(source: 'mic' | 'call', level: number): void
  onQuestion(text: string): void
  onError(message: string): void
  onCallAudioEnded(): void
}

export interface SessionOptions {
  speech: Backend | 'browser'
  shareCallAudio: boolean
  record: boolean
  vocabulary: string
}

/** Chrome/Edge's built-in recognizer (sends mic audio to the browser vendor; no key needed). */
type BrowserRecognition = {
  continuous: boolean; interimResults: boolean; lang: string
  onresult: ((e: any) => void) | null; onerror: ((e: any) => void) | null; onend: (() => void) | null
  start(): void; stop(): void
}
export const browserSpeechAvailable = () =>
  typeof window !== 'undefined' && ('webkitSpeechRecognition' in window || 'SpeechRecognition' in window)

/** After this long with no sound at all, tell the user what to check. */
const SILENCE_CHECK_MS = 12_000
/** Below any speech or music: digital silence or a muted source. */
const SILENT_RMS = 0.003

class Pipeline {
  private resampler: Resampler
  private segmenter: Segmenter
  private pending = new Float32Array(0)
  private node: AudioWorkletNode
  private source: MediaStreamAudioSourceNode
  private onSegment: (s: Segment) => void
  private onLevel: (l: number) => void
  /** Loudest 100 ms block so far (RMS), to tell "silent" from "quiet". */
  peak = 0

  constructor(ctx: AudioContext, stream: MediaStream, policy: ReturnType<typeof segmentPolicy>,
              onSegment: (s: Segment) => void, onLevel: (l: number) => void) {
    this.onSegment = onSegment
    this.onLevel = onLevel
    this.resampler = new Resampler(ctx.sampleRate)
    this.segmenter = new Segmenter(policy)
    this.source = ctx.createMediaStreamSource(stream)
    this.node = new AudioWorkletNode(ctx, 'pcm-forwarder')
    this.node.port.onmessage = (e: MessageEvent<Float32Array>) => this.take(e.data)
    this.source.connect(this.node)
    // Keep the node pulling audio without playing it back.
    const mute = ctx.createGain()
    mute.gain.value = 0
    this.node.connect(mute).connect(ctx.destination)
  }

  private take(frames: Float32Array) {
    const down = this.resampler.process(frames)
    const merged = new Float32Array(this.pending.length + down.length)
    merged.set(this.pending)
    merged.set(down, this.pending.length)
    let offset = 0
    const now = Date.now()
    const blocks = Math.floor(merged.length / BLOCK)
    for (let i = 0; i < blocks; i++) {
      const block = merged.slice(offset, offset + BLOCK)
      offset += BLOCK
      const at = now - (blocks - i) * 100
      const level = rms(block)
      if (level > this.peak) this.peak = level
      this.onLevel(Math.min(1, level * 8))
      for (const seg of this.segmenter.push(block, at)) this.onSegment(seg)
    }
    this.pending = merged.slice(offset)
  }

  stop() {
    for (const seg of this.segmenter.flush()) this.onSegment(seg)
    this.node.port.onmessage = null
    this.source.disconnect()
    this.node.disconnect()
  }
}

export class Session {
  private assembler: TranscriptAssembler
  private ctx?: AudioContext
  private streams: MediaStream[] = []
  private pipelines: Pipeline[] = []
  private queues: Record<'mic' | 'call', Promise<void>> = { mic: Promise.resolve(), call: Promise.resolve() }
  private abort = new AbortController()
  private recognition?: BrowserRecognition
  private recorder?: MediaRecorder
  private recordChunks: Blob[] = []
  private recordStartedAt = 0
  private callActive = false
  private micSpeaker: Speaker = 'room'
  /** Recent call text, for dropping speaker echo from the mic transcript. */
  private recentCall: { text: string; at: number }[] = []
  private shownMic: { id: string; text: string; at: number }[] = []
  private stopped = false
  private silenceCheck?: ReturnType<typeof setTimeout>
  private opts: SessionOptions
  private cb: SessionCallbacks

  constructor(existing: Utterance[], opts: SessionOptions, cb: SessionCallbacks) {
    this.assembler = new TranscriptAssembler(existing)
    this.opts = opts
    this.cb = cb
  }

  get hasCallAudio() { return this.callActive }

  async start() {
    const mic = await navigator.mediaDevices.getUserMedia({
      // The browser's echo canceller removes call audio played from this computer.
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    })
    this.streams.push(mic)

    let call: MediaStream | undefined
    if (this.opts.shareCallAudio) {
      try {
        call = await navigator.mediaDevices.getDisplayMedia({
          video: true,
          audio: { echoCancellation: false, noiseSuppression: false } as MediaTrackConstraints,
          // Chrome: offer the "share tab audio" / "share system audio" checkbox.
          ...({ systemAudio: 'include', selfBrowserSurface: 'exclude', surfaceSwitching: 'include' } as object),
        } as DisplayMediaStreamOptions)
        call.getVideoTracks().forEach((t) => t.stop()) // only the audio is used
        if (call.getAudioTracks().length === 0) {
          call.getTracks().forEach((t) => t.stop())
          call = undefined
          this.cb.onError('No call audio was shared. To hear the other side, share a tab (or on Windows, your screen) and tick "Share audio". Transcribing your mic only.')
        } else {
          this.streams.push(call)
          call.getAudioTracks()[0].addEventListener('ended', () => {
            this.callActive = false
            this.cb.onCallAudioEnded()
          })
        }
      } catch {
        this.cb.onError('Call audio wasn’t shared, so only your mic is transcribed. Press Start again and pick a tab with "Share audio" to include the other side.')
      }
    }
    this.callActive = !!call
    this.micSpeaker = this.callActive ? 'you' : 'room'

    if (this.opts.speech === 'browser') {
      this.startBrowserRecognition()
    }
    this.ctx = new AudioContext()
    await this.ctx.audioWorklet.addModule(import.meta.env.BASE_URL + 'pcm-worklet.js')
    if (this.opts.speech !== 'browser') {
      const policy = segmentPolicy(this.opts.speech)
      this.pipelines.push(new Pipeline(this.ctx, mic, policy, (s) => this.enqueue('mic', s), (l) => this.cb.onLevel('mic', l)))
      if (call) this.pipelines.push(new Pipeline(this.ctx, call, policy, (s) => this.enqueue('call', s), (l) => this.cb.onLevel('call', l)))
    } else if (call) {
      this.cb.onError('Browser speech can only hear your mic. Pick Gemini, Groq, or OpenAI for speech to transcribe call audio too.')
    }
    if (this.opts.record) this.startRecording(mic, call)
    this.silenceCheck = setTimeout(() => this.warnIfSilent(), SILENCE_CHECK_MS)
  }

  /** Nothing to transcribe usually means the wrong tab, an unticked "Share tab audio", or a muted mic. */
  private warnIfSilent() {
    if (this.stopped) return
    const [micPipe, callPipe] = this.pipelines
    if (callPipe && this.callActive && callPipe.peak < SILENT_RMS) {
      this.cb.onError('The shared tab is silent. Make sure the call or video is playing in the tab you shared (not muted), then press Stop and Start again if you picked the wrong tab.')
    } else if (micPipe && !this.callActive && micPipe.peak < SILENT_RMS) {
      this.cb.onError('Your microphone isn’t picking anything up. Check that it isn’t muted. To transcribe a call or video playing on this computer, turn on 🖥 Call audio and share that tab.')
    }
  }

  private enqueue(source: 'mic' | 'call', seg: Segment) {
    if (this.opts.speech === 'browser') return
    const backend = this.opts.speech
    const speaker: Speaker = source === 'call' ? 'them' : this.micSpeaker
    this.cb.onPartial(speaker, '…')
    // One request at a time per source keeps each side's lines in order.
    this.queues[source] = this.queues[source].then(async () => {
      try {
        const wav = encodeWav(seg.samples)
        const text = await withRateLimitRetry(() => transcribe(backend, wav, this.opts.vocabulary, this.abort.signal), this.abort.signal)
        if (text && !(isLikelyHallucination(text) && seg.peakRms < 0.05)) {
          this.commit(text, speaker, seg.startedAt, seg.startedAt + seg.durationMs)
        }
      } catch (e) {
        if ((e as Error).name !== 'AbortError') this.cb.onError(`Transcription failed: ${(e as Error).message}`)
      } finally {
        this.cb.onPartial(speaker, null)
      }
    })
  }

  private commit(text: string, speaker: Speaker, at: number, endedAt: number) {
    const now = Date.now()
    // Long enough for Gemini's up-to-45 s chunks from the two sources to overlap.
    const window = 60_000
    this.recentCall = this.recentCall.filter((c) => now - c.at < window)
    this.shownMic = this.shownMic.filter((m) => now - m.at < window)
    if (speaker === 'you') {
      // Speaker echo is judged per sentence: one chunk can hold an echo and a real reply.
      text = removeEchoSentences(text, this.recentCall.map((c) => c.text)).kept
      if (!text) return
    }
    if (speaker === 'them') {
      this.recentCall.push({ text, at: now })
      // Call audio that finished later can still explain mic sentences already shown as "You".
      for (const m of [...this.shownMic]) {
        const { kept, echoed } = removeEchoSentences(m.text, [text])
        for (const sentence of echoed) this.assembler.removeFragment(sentence, m.id)
        this.shownMic = this.shownMic.filter((x) => x !== m)
        if (kept) this.shownMic.push({ ...m, text: kept })
      }
    }
    const id = this.assembler.append(text, speaker, at, endedAt)
    if (!id) return
    if (speaker === 'you') this.shownMic.push({ id, text, at: now })
    this.cb.onTranscript(this.assembler.utterances)
    const question = speaker !== 'you' ? lastQuestion(text) : null
    if (question) this.cb.onQuestion(question)
  }

  private startBrowserRecognition() {
    const Ctor = (window as any).SpeechRecognition ?? (window as any).webkitSpeechRecognition
    if (!Ctor) {
      this.cb.onError('This browser has no built-in speech recognition. Use Chrome or Edge, or pick Gemini, Groq, or OpenAI for speech.')
      return
    }
    const r: BrowserRecognition = new Ctor()
    r.continuous = true
    r.interimResults = true
    r.lang = navigator.language || 'en-US'
    let segmentStart = Date.now()
    r.onresult = (e: any) => {
      for (let i = e.resultIndex; i < e.results.length; i++) {
        const res = e.results[i]
        const text = res[0].transcript as string
        if (res.isFinal) {
          this.cb.onPartial(this.micSpeaker, null)
          this.commit(text, this.micSpeaker, segmentStart, Date.now())
          segmentStart = Date.now()
        } else {
          this.cb.onPartial(this.micSpeaker, text)
        }
      }
    }
    r.onerror = (e: any) => {
      if (e.error !== 'no-speech' && e.error !== 'aborted') this.cb.onError(`Browser speech stopped: ${e.error}`)
    }
    // Chrome ends recognition after a while; restart until the session stops.
    r.onend = () => { if (!this.stopped) try { r.start() } catch { /* already running */ } }
    r.start()
    this.recognition = r
  }

  private startRecording(mic: MediaStream, call?: MediaStream) {
    if (!this.ctx || typeof MediaRecorder === 'undefined') return
    const dest = this.ctx.createMediaStreamDestination()
    this.ctx.createMediaStreamSource(mic).connect(dest)
    if (call) this.ctx.createMediaStreamSource(call).connect(dest)
    const mime = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg'].find((m) => MediaRecorder.isTypeSupported(m))
    this.recorder = new MediaRecorder(dest.stream, mime ? { mimeType: mime } : undefined)
    this.recorder.ondataavailable = (e) => { if (e.data.size) this.recordChunks.push(e.data) }
    this.recordStartedAt = Date.now()
    this.recorder.start(1000)
  }

  /** Stops capture, finishes pending transcriptions, and returns the recording if one was made. */
  async stop(): Promise<{ utterances: Utterance[]; recording?: { blob: Blob; startedAt: number; durationMs: number } }> {
    this.stopped = true
    clearTimeout(this.silenceCheck)
    this.recognition?.stop()
    this.pipelines.forEach((p) => p.stop())
    let recording: { blob: Blob; startedAt: number; durationMs: number } | undefined
    if (this.recorder && this.recorder.state !== 'inactive') {
      const rec = this.recorder
      await new Promise<void>((resolve) => { rec.onstop = () => resolve(); rec.stop() })
      const blob = new Blob(this.recordChunks, { type: rec.mimeType || 'audio/webm' })
      if (blob.size) recording = { blob, startedAt: this.recordStartedAt, durationMs: Date.now() - this.recordStartedAt }
    }
    this.streams.forEach((s) => s.getTracks().forEach((t) => t.stop()))
    await Promise.all([this.queues.mic, this.queues.call])
    await this.ctx?.close()
    return { utterances: this.assembler.utterances, recording }
  }

  /** Abandons in-flight transcriptions (e.g. when the page closes). */
  cancel() {
    this.abort.abort()
    void this.stop()
  }
}
