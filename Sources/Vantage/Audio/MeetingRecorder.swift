import AVFoundation
import VantageCore

/// Seconds on the host clock (mach time), which both AVAudioEngine and ScreenCaptureKit stamp buffers with.
enum HostClock {
    static var now: TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    static func date(_ host: TimeInterval) -> Date { Date().addingTimeInterval(host - now) }
}

/// Opt-in audio recording of a listening session. Mic and call audio are written to separate
/// tracks on one shared timeline (silence fills gaps), then mixed into a single .m4a on finish.
final class MeetingRecorder: @unchecked Sendable {
    let startedAt: Date
    let mic: TrackWriter
    let call: TrackWriter
    private let folder: URL
    private let fileName: String

    static func folder(for meeting: UUID) -> URL {
        AppPaths.support.appendingPathComponent("Recordings/\(meeting.uuidString)", isDirectory: true)
    }

    init(meeting: UUID) throws {
        folder = Self.folder(for: meeting)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let origin = HostClock.now
        startedAt = HostClock.date(origin)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        fileName = "\(f.string(from: startedAt)).m4a"
        let stem = UUID().uuidString
        mic = TrackWriter(url: folder.appendingPathComponent("\(stem)-mic.m4a"), origin: origin)
        call = TrackWriter(url: folder.appendingPathComponent("\(stem)-call.m4a"), origin: origin)
    }

    /// Closes both tracks and mixes them. Returns nil if no audio arrived.
    func finish() async throws -> Recording? {
        let tracks = [mic.close(), call.close()].compactMap { $0 }
        defer { tracks.forEach { try? FileManager.default.removeItem(at: $0) } }
        guard !tracks.isEmpty else { return nil }

        let out = folder.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: out)
        let composition = AVMutableComposition()
        for url in tracks {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw LLMError.failed("Couldn't create the audio exporter.")
        }
        try await export.export(to: out, as: .m4a)
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        return Recording(file: fileName, startedAt: startedAt, duration: duration)
    }
}

/// One mono track. Buffers are copied on the capture thread and encoded on a private queue.
final class TrackWriter: @unchecked Sendable {
    private let url: URL
    private let origin: TimeInterval
    private let queue = DispatchQueue(label: "vantage.recorder")
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var failed = false

    init(url: URL, origin: TimeInterval) {
        self.url = url
        self.origin = origin
    }

    /// `hostTime` is when the buffer's first sample was captured.
    func write(_ buffer: AVAudioPCMBuffer, at hostTime: TimeInterval) {
        guard let mono = Self.monoCopy(buffer) else { return }
        queue.async { self.append(mono, at: hostTime) }
    }

    /// Returns the track file, or nil if nothing was written.
    func close() -> URL? {
        queue.sync {
            let wrote = file != nil && framesWritten > 0
            file = nil
            return wrote ? url : nil
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, at hostTime: TimeInterval) {
        guard !failed else { return }
        do {
            if file == nil {
                // AAC while recording: raw float would be ~700 MB per track per hour.
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: buffer.format.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            guard let file else { return }
            // Keep both tracks on one timeline: pad with silence when capture skipped time.
            let rate = buffer.format.sampleRate
            let expected = AVAudioFramePosition(max(0, hostTime - origin) * rate)
            var gap = expected - framesWritten
            if gap > AVAudioFramePosition(rate * 0.15) {
                gap = min(gap, AVAudioFramePosition(rate * 3600))
                while gap > 0 {
                    let n = AVAudioFrameCount(min(gap, AVAudioFramePosition(rate)))
                    guard let silence = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: n) else { break }
                    silence.frameLength = n  // zero-filled
                    try file.write(from: silence)
                    framesWritten += AVAudioFramePosition(n)
                    gap -= AVAudioFramePosition(n)
                }
            }
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            failed = true
        }
    }

    private static func monoCopy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData, buffer.frameLength > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.format.isInterleaved ? channels : 1
        if buffer.format.isInterleaved || channels == 1 {
            for i in 0..<n { dst[0][i] = src[0][i * stride] }
        } else {
            let scale = 1 / Float(channels)
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += src[c][i] }
                dst[0][i] = sum * scale
            }
        }
        out.frameLength = buffer.frameLength
        return out
    }
}
