import AVFoundation
import Speech

enum TranscriberError: LocalizedError {
    case unavailable
    case unsupportedLocale(String)
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .unavailable: "On-device speech recognition isn't available on this Mac."
        case .unsupportedLocale(let id): "On-device transcription doesn't support \(id)."
        case .noAudioFormat: "Couldn't agree on an audio format with the speech model."
        }
    }
}

/// Streams one audio source through Apple's on-device SpeechAnalyzer.
/// Audio never leaves the Mac; only finished text is handed to the app.
final class LiveTranscriber: @unchecked Sendable {
    var onVolatile: ((String) -> Void)?
    /// Text, and the host-clock time its first word was spoken (nil if unknown).
    var onFinal: ((String, TimeInterval?) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// Host time of the first buffer fed; result time ranges count from there.
    private var firstHostTime: TimeInterval?

    /// Downloads the speech model for `locale` if needed. Safe to call repeatedly.
    static func prepareAssets(locale: Locale, progress: ((Double) -> Void)? = nil) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.unsupportedLocale(locale.identifier)
        }
        let probe = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            let observation = request.progress.observe(\.fractionCompleted) { p, _ in progress?(p.fractionCompleted) }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }
        return supported
    }

    /// `vocabulary` biases recognition toward names and jargon the conversation is likely to use.
    func start(locale: Locale, vocabulary: [String] = []) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // No .fastResults: it finalizes sooner but with noticeably worse word accuracy.
            reportingOptions: [.volatileResults],
            attributeOptions: [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.noAudioFormat
        }
        analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        let start = result.range.start.seconds
                        let spoken = self?.firstHostTime.flatMap { start.isFinite ? $0 + start : nil }
                        self?.onFinal?(text, spoken)
                    } else {
                        self?.onVolatile?(text)
                    }
                }
            } catch {
                // The stream ends with an error only when analysis is cancelled.
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        self.analyzer = analyzer
    }

    /// Called from the capture thread. Buffers from one source arrive serially.
    func feed(_ buffer: AVAudioPCMBuffer, at hostTime: TimeInterval? = nil) {
        guard let input, let converted = convert(buffer) else { return }
        if firstHostTime == nil { firstHostTime = hostTime ?? HostClock.now }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async {
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        analyzer = nil
        resultsTask = nil
        converter = nil
        firstHostTime = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = analyzerFormat else { return nil }
        if buffer.format == target { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
            converter?.downmix = true
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var delivered = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if delivered {
                // .noDataNow (not .endOfStream) keeps the resampler's state for the next buffer.
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }
}
