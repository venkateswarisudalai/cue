// Forwards raw mono PCM from the audio graph to the main thread in ~100 ms batches.
class PcmForwarder extends AudioWorkletProcessor {
  constructor() {
    super()
    this.buffer = []
    this.size = 0
    this.target = Math.round(sampleRate / 10)
  }

  process(inputs) {
    const input = inputs[0]
    if (input && input.length > 0) {
      const channels = input.length
      const frames = input[0].length
      const mono = new Float32Array(frames)
      for (let c = 0; c < channels; c++) {
        const data = input[c]
        for (let i = 0; i < frames; i++) mono[i] += data[i] / channels
      }
      this.buffer.push(mono)
      this.size += frames
      if (this.size >= this.target) {
        const out = new Float32Array(this.size)
        let o = 0
        for (const b of this.buffer) { out.set(b, o); o += b.length }
        this.port.postMessage(out, [out.buffer])
        this.buffer = []
        this.size = 0
      }
    }
    return true
  }
}

registerProcessor('pcm-forwarder', PcmForwarder)
