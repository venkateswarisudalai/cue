// Cuts a live audio stream into speech segments at natural pauses, so each piece can be sent
// for transcription as soon as someone stops talking — without cutting words in half.

export const SAMPLE_RATE = 16_000
export const BLOCK = SAMPLE_RATE / 10 // 100 ms

export interface Segment {
  samples: Float32Array
  /** ms since epoch of the first sample */
  startedAt: number
  durationMs: number
  /** Loudest 100 ms block, for dropping near-silent segments Whisper would hallucinate on. */
  peakRms: number
}

export interface SegmenterOptions {
  silenceToCutMs: number
  minSegmentMs: number
  maxSegmentMs: number
  preRollMs: number
  /** Absolute floor for "speech" RMS; the effective threshold adapts to background noise. */
  minThreshold: number
}

const DEFAULTS: SegmenterOptions = {
  silenceToCutMs: 700,
  minSegmentMs: 1200,
  maxSegmentMs: 20_000,
  preRollMs: 300,
  minThreshold: 0.01,
}

export const rms = (b: Float32Array) => {
  let sum = 0
  for (let i = 0; i < b.length; i++) sum += b[i] * b[i]
  return Math.sqrt(sum / Math.max(1, b.length))
}

export class Segmenter {
  private opts: SegmenterOptions
  private blocks: Float32Array[] = []
  private blocksStart = 0
  private preRoll: Float32Array[] = []
  private speaking = false
  private silentBlocks = 0
  private speechBlocks = 0
  private peak = 0
  private noiseFloor = 0.005

  constructor(opts: Partial<SegmenterOptions> = {}) {
    this.opts = { ...DEFAULTS, ...opts }
  }

  private get threshold() {
    return Math.max(this.opts.minThreshold, this.noiseFloor * 3)
  }

  /** Feed exactly one 100 ms block (1600 samples at 16 kHz) captured at `at` ms. */
  push(block: Float32Array, at: number): Segment[] {
    const level = rms(block)
    const loud = level >= this.threshold
    if (!loud) this.noiseFloor = this.noiseFloor * 0.95 + level * 0.05 // track background slowly

    const out: Segment[] = []
    if (!this.speaking) {
      this.preRoll.push(block)
      const keep = Math.ceil(this.opts.preRollMs / 100) + 1 // lead-in plus this block
      if (this.preRoll.length > keep) this.preRoll.shift()
      if (loud) {
        this.speaking = true
        this.blocks = [...this.preRoll]
        this.blocksStart = at - (this.preRoll.length - 1) * 100
        this.preRoll = []
        this.silentBlocks = 0
        this.speechBlocks = 1
        this.peak = level
      }
      return out
    }

    this.blocks.push(block)
    this.peak = Math.max(this.peak, level)
    if (loud) { this.silentBlocks = 0; this.speechBlocks++ } else this.silentBlocks++

    const lengthMs = this.blocks.length * 100
    const pausedLongEnough = this.silentBlocks * 100 >= this.opts.silenceToCutMs
    if ((pausedLongEnough && lengthMs >= this.opts.minSegmentMs) || lengthMs >= this.opts.maxSegmentMs) {
      const s = this.cut()
      if (s) out.push(s)
    } else if (pausedLongEnough && this.speechBlocks < 3) {
      // A click or cough, not speech.
      this.reset()
    }
    return out
  }

  /** Emits whatever speech is buffered (when listening stops). */
  flush(): Segment[] {
    const s = this.speaking ? this.cut() : null
    return s ? [s] : []
  }

  private cut(): Segment | null {
    // Trim most of the trailing silence, keeping a little so the last word isn't clipped.
    const trailing = Math.max(0, this.silentBlocks - 2)
    const kept = this.blocks.slice(0, this.blocks.length - trailing)
    const speech = this.speechBlocks
    const seg: Segment = {
      samples: concat(kept),
      startedAt: this.blocksStart,
      durationMs: kept.length * 100,
      peakRms: this.peak,
    }
    this.reset()
    return speech >= 3 ? seg : null
  }

  private reset() {
    this.speaking = false
    this.blocks = []
    this.silentBlocks = 0
    this.speechBlocks = 0
    this.peak = 0
  }
}

export function concat(parts: Float32Array[]): Float32Array {
  const out = new Float32Array(parts.reduce((n, p) => n + p.length, 0))
  let o = 0
  for (const p of parts) { out.set(p, o); o += p.length }
  return out
}

/**
 * Resamples device audio (44.1/48 kHz) down to 16 kHz by averaging each output sample's share
 * of the input — a box filter, so it also cuts the aliasing plain decimation would add.
 */
export class Resampler {
  private acc = 0
  private weight = 0
  private need: number
  private readonly ratio: number

  constructor(from: number, to = SAMPLE_RATE) {
    this.ratio = from / to
    this.need = this.ratio
  }

  process(input: Float32Array): Float32Array {
    const out: number[] = []
    for (let i = 0; i < input.length; i++) {
      const x = input[i]
      let w = 1
      while (w > 1e-9) {
        const take = Math.min(w, this.need)
        this.acc += x * take
        this.weight += take
        this.need -= take
        w -= take
        if (this.need <= 1e-9) {
          out.push(this.acc / this.weight)
          this.acc = 0
          this.weight = 0
          this.need = this.ratio
        }
      }
    }
    return Float32Array.from(out)
  }
}

/** 16-bit PCM mono WAV — accepted by every speech API. */
export function encodeWav(samples: Float32Array, sampleRate = SAMPLE_RATE): ArrayBuffer {
  const buf = new ArrayBuffer(44 + samples.length * 2)
  const v = new DataView(buf)
  const str = (o: number, s: string) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)) }
  str(0, 'RIFF'); v.setUint32(4, 36 + samples.length * 2, true); str(8, 'WAVE')
  str(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true)
  v.setUint32(24, sampleRate, true); v.setUint32(28, sampleRate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true)
  str(36, 'data'); v.setUint32(40, samples.length * 2, true)
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]))
    v.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true)
  }
  return buf
}
