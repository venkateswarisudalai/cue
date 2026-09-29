import AVFoundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case microphoneDenied
    case noMicrophone
    case noDisplay
    case screenRecordingDenied

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied: "Screen & System Audio Recording permission is off."
        case .microphoneDenied: "Microphone access is off. Enable Vantage in System Settings → Privacy & Security → Microphone."
        case .noMicrophone: "No microphone input is available."
        case .noDisplay: "No display found for capturing call audio."
        }
    }
}

/// The buffer and the host-clock time (seconds) of its first sample.
typealias BufferHandler = (AVAudioPCMBuffer, TimeInterval) -> Void

/// The user's own voice.
final class MicCapture {
    private let engine = AVAudioEngine()
    var onBuffer: BufferHandler?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            let host = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : HostClock.now
            self?.onBuffer?(buffer, host)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Everything the Mac is playing — the other side of a Zoom/Meet/Teams call.
/// Uses ScreenCaptureKit, so macOS asks for Screen & System Audio Recording permission.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "vantage.system-audio")
    var onBuffer: BufferHandler?
    var onStopped: ((Error) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Video is mandatory for an SCStream; keep it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = sampleBuffer.copyPCMBuffer() else { return }
        // ScreenCaptureKit stamps audio on the host clock; fall back to arrival time if that ever changes.
        let pts = sampleBuffer.presentationTimeStamp.seconds
        let now = HostClock.now
        onBuffer?(pcm, pts.isFinite && abs(now - pts) < 5 ? pts : now)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}

extension CMSampleBuffer {
    func copyPCMBuffer() -> AVAudioPCMBuffer? {
        guard let desc = formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}

enum AudioLevel {
    /// 0...1, roughly perceptual, for the input meters.
    static func of(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return max(0, min(1, (db + 55) / 50))
    }
}
