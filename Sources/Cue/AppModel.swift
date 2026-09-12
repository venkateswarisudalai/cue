import AVFoundation
import CoreGraphics
import CueCore
import OSLog
import SwiftUI

/// `log show --info --predicate 'subsystem == "com.venka.cue"' --last 10m`
/// Events only — transcript text is never logged.
private let log = Logger(subsystem: "com.venka.cue", category: "session")

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case running
        case stopping
    }

    @Published var phase: Phase = .idle
    @Published private(set) var utterances: [Utterance] = []
    @Published private(set) var partial: [Speaker: String] = [:]
    @Published private(set) var cues: [CueCard] = []
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var callLevel: Float = 0
    @Published private(set) var callAudioActive = false
    @Published private(set) var sessionStart: Date?
    @Published private(set) var lastSavedURL: URL?
    @Published var errorMessage: String?

    @Published var mode: Mode {
        didSet {
            Pref.d.set(mode.rawValue, forKey: Pref.mode)
            notes = Pref.d.string(forKey: Pref.notesKey(mode)) ?? ""
        }
    }
    @Published var notes: String {
        didSet { Pref.d.set(notes, forKey: Pref.notesKey(mode)) }
    }

    private var assembler = TranscriptAssembler()
    private var trigger = QuestionTrigger()
    private var echoGate = EchoGate()
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var micTranscriber: LiveTranscriber?
    private var callTranscriber: LiveTranscriber?
    private var evaluationTask: Task<Void, Never>?
    private var lastEvaluated: (id: UUID, text: String)?
    private var cueTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        Pref.register()
        let m = Mode(rawValue: Pref.d.string(forKey: Pref.mode) ?? "") ?? .candidate
        mode = m
        notes = Pref.d.string(forKey: Pref.notesKey(m)) ?? ""
    }

    var isRunning: Bool { phase == .running }
    var hasTranscript: Bool { !utterances.isEmpty }

    // MARK: - Session

    func toggle() {
        Task {
            switch phase {
            case .idle: await start()
            case .running: await stop()
            default: break
            }
        }
    }

    func start() async {
        guard phase == .idle else { return }
        errorMessage = nil
        let wantMic = Pref.d.bool(forKey: Pref.useMic)
        let wantCall = Pref.d.bool(forKey: Pref.useCallAudio)
        guard wantMic || wantCall else {
            errorMessage = "Turn on the microphone or call audio first."
            return
        }
        log.notice("start: mic=\(wantMic) call=\(wantCall) mode=\(self.mode.rawValue, privacy: .public)")

        phase = .preparing("Checking speech model…")
        do {
            let locale = try await LiveTranscriber.prepareAssets(locale: .current) { fraction in
                Task { @MainActor in self.phase = .preparing("Downloading speech model… \(Int(fraction * 100))%") }
            }
            resetSession()

            if wantCall {
                phase = .preparing("Starting call audio…")
                do {
                    try await startCallAudio(locale: locale)
                    log.notice("call audio started")
                } catch {
                    log.error("call audio failed: \(error.localizedDescription, privacy: .public)")
                    errorMessage = callAudioHelp(error)
                }
            }
            if wantMic {
                phase = .preparing("Starting microphone…")
                guard await MicCapture.requestPermission() else { throw CaptureError.microphoneDenied }
                let speaker: Speaker = callAudioActive ? .you : .room
                try await startMic(locale: locale, speaker: speaker)
                log.notice("mic started as \(speaker.rawValue, privacy: .public)")
            }
            guard mic != nil || system != nil else {
                throw LLMError.failed(errorMessage ?? "No audio source could be started.")
            }
            phase = .running
        } catch {
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
            await teardown()
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    func stop() async {
        guard phase == .running else { return }
        phase = .stopping
        evaluationTask?.cancel()
        await teardown()
        // Let finalized fragments and held mic lines land before saving.
        try? await Task.sleep(for: .seconds(echoGate.hold + 0.3))
        phase = .idle
        log.notice("stopped: \(self.utterances.count) utterances, \(self.cues.count) cues")
        if Pref.d.bool(forKey: Pref.saveSessions), let start = sessionStart, !utterances.isEmpty {
            do {
                lastSavedURL = try SessionExporter.save(mode: mode, startedAt: start, utterances: utterances, cues: cues)
            } catch {
                errorMessage = "Couldn't save the session: \(error.localizedDescription)"
            }
        }
    }

    private func resetSession() {
        cueTasks.values.forEach { $0.cancel() }
        cueTasks.removeAll()
        assembler.reset()
        trigger.reset()
        echoGate.reset()
        utterances = []
        partial = [:]
        cues = []
        lastEvaluated = nil
        lastSavedURL = nil
        sessionStart = Date()
    }

    private func startMic(locale: Locale, speaker: Speaker) async throws {
        let transcriber = makeTranscriber(for: speaker)
        try await transcriber.start(locale: locale, vocabulary: Vocabulary.terms(from: notes))
        let capture = MicCapture()
        let meter = LevelThrottle()
        capture.onBuffer = { [weak self] buffer in
            transcriber.feed(buffer)
            if let level = meter.next(buffer) { Task { @MainActor in self?.micLevel = level } }
        }
        try capture.start()
        micTranscriber = transcriber
        mic = capture
    }

    private func startCallAudio(locale: Locale) async throws {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw CaptureError.screenRecordingDenied
        }
        let transcriber = makeTranscriber(for: .them)
        try await transcriber.start(locale: locale, vocabulary: Vocabulary.terms(from: notes))
        let capture = SystemAudioCapture()
        let meter = LevelThrottle()
        capture.onBuffer = { [weak self] buffer in
            transcriber.feed(buffer)
            if let level = meter.next(buffer) { Task { @MainActor in self?.callLevel = level } }
        }
        capture.onStopped = { [weak self] error in
            Task { @MainActor in
                log.error("call audio stopped: \(error.localizedDescription, privacy: .public)")
                self?.callAudioActive = false
                self?.errorMessage = "Call audio stopped: \(error.localizedDescription)"
            }
        }
        do {
            try await capture.start()
        } catch {
            await transcriber.finish()
            throw error
        }
        callTranscriber = transcriber
        system = capture
        callAudioActive = true
    }

    private func callAudioHelp(_ error: Error) -> String {
        if case CaptureError.screenRecordingDenied = error {
            return "Call audio is off — Cue needs Screen & System Audio Recording permission to hear the other side. "
                + "Enable Cue in System Settings → Privacy & Security, then quit and reopen Cue. Transcribing your mic only for now."
        }
        return "Call audio couldn't start (\(error.localizedDescription)). Transcribing your mic only for now."
    }

    private func makeTranscriber(for speaker: Speaker) -> LiveTranscriber {
        let t = LiveTranscriber()
        t.onVolatile = { [weak self] text in
            Task { @MainActor in self?.handleVolatile(text, from: speaker) }
        }
        t.onFinal = { [weak self] text in
            Task { @MainActor in self?.handleFinal(text, from: speaker) }
        }
        return t
    }

    private func teardown() async {
        mic?.stop()
        await system?.stop()
        await micTranscriber?.finish()
        await callTranscriber?.finish()
        mic = nil
        system = nil
        micTranscriber = nil
        callTranscriber = nil
        callAudioActive = false
        micLevel = 0
        callLevel = 0
        partial = [:]
    }

    // MARK: - Transcript

    private func handleVolatile(_ text: String, from speaker: Speaker) {
        // Don't flash the other side's words under "You" when speakers leak into the mic.
        if speaker == .you, callAudioActive, echoGate.matchesRecentCall(text, extra: partial[.them]) {
            partial[.you] = nil
            return
        }
        partial[speaker] = text
        if mode == .interviewer, speaker.isOtherParty, text.split(separator: " ").count >= 2 {
            evaluationTask?.cancel()
        }
    }

    /// Debug hook for `--selftest-simulate`. Includes transcript text, so it never goes to the system log.
    var trace: ((String) -> Void)?

    private func handleFinal(_ text: String, from speaker: Speaker) {
        partial[speaker] = nil
        let now = Date()
        trace?("final \(speaker.rawValue): \(text)")

        if speaker == .you, callAudioActive {
            guard let id = echoGate.mic(text, at: now) else {
                trace?("  mic dropped: matches recent call audio")
                log.info("dropped mic echo")
                return
            }
            trace?("  mic held #\(id)")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.echoGate.hold ?? 2))
                guard let self else { return }
                guard let held = self.echoGate.release(id: id) else {
                    self.trace?("  mic #\(id) dropped: call audio arrived during hold")
                    log.info("dropped mic echo after call audio arrived")
                    return
                }
                // The call transcriber may still be mid-sentence on the same words.
                if self.echoGate.matchesRecentCall(held.text, at: held.at, extra: self.partial[.them]) {
                    self.trace?("  mic #\(id) dropped: matches call audio in progress")
                    log.info("dropped mic echo matching call audio in progress")
                    return
                }
                self.trace?("  mic #\(id) shown")
                if let utteranceID = self.commit(held.text, from: .you, at: held.at) {
                    self.echoGate.didShowMic(held.text, utterance: utteranceID, at: held.at)
                }
            }
            return
        }
        if speaker == .them {
            let dropped = echoGate.call(text, at: now)
            if dropped > 0 { trace?("  dropped \(dropped) held mic fragments") }
            // Call audio that finalized late can still explain mic lines already shown as "You".
            let retractions = echoGate.takeRetractions()
            if !retractions.isEmpty {
                for r in retractions { assembler.removeFragment(r.text, from: r.utterance) }
                utterances = assembler.utterances
                trace?("  retracted \(retractions.count) shown mic fragments")
                log.info("retracted \(retractions.count) mic echo fragments")
            }
        }
        commit(text, from: speaker, at: now)
    }

    @discardableResult
    private func commit(_ text: String, from speaker: Speaker, at time: Date) -> UUID? {
        guard let id = assembler.appendFinal(text, from: speaker, at: time) else { return nil }
        utterances = assembler.utterances
        guard speaker.isOtherParty, Pref.d.bool(forKey: Pref.autoRespond) else { return id }

        if mode == .interviewer {
            scheduleEvaluation(of: id)
        } else {
            let turn = assembler.utterances.last(where: { $0.id == id })?.text ?? text
            handle(trigger.otherPartyFinal(fragment: text, turn: turn))
        }
        return id
    }

    private func handle(_ action: QuestionTrigger.Action) {
        switch action {
        case .none:
            break
        case .arm(let token):
            log.info("auto-cue armed")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.trigger.settleDelay ?? 1.2))
                guard let self else { return }
                self.handle(self.trigger.fireIfStillPending(token: token))
            }
        case .fire(let question):
            log.notice("auto-cue fired")
            let focus = Utterance(speaker: .them, text: question, startedAt: Date())
            requestCue(.respond, focus: focus, isAuto: true)
        }
    }

    /// Interviewer mode: assess the candidate once they finish a substantial answer.
    private func scheduleEvaluation(of id: UUID) {
        evaluationTask?.cancel()
        evaluationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self,
                  let u = self.assembler.utterances.last(where: { $0.speaker.isOtherParty }), u.id == id,
                  u.text.split(separator: " ").count >= 25 else { return }
            if let last = self.lastEvaluated, last.id == u.id, last.text == u.text { return }
            self.lastEvaluated = (u.id, u.text)
            self.requestCue(.respond, focus: u, isAuto: true)
        }
    }

    // MARK: - Cues

    func requestCue(_ kind: CueKind, focus: Utterance? = nil, customQuestion: String? = nil, isAuto: Bool = false) {
        let client: LLMClient
        do {
            client = try LLMFactory.make()
        } catch {
            log.error("no backend: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            return
        }

        // With nobody else on the line (practice), answer the latest thing said.
        let target = kind == .respond
            ? (focus ?? assembler.lastOtherPartyUtterance ?? assembler.utterances.last)
            : focus
        let system = PromptBuilder.system(mode: mode, contextNotes: notes)
        let user = PromptBuilder.userMessage(kind: kind, mode: mode, utterances: assembler.utterances,
                                             focus: target, customQuestion: customQuestion)
        let effort = Pref.d.string(forKey: Pref.effort) ?? "low"

        if isAuto {
            // A newer question supersedes an auto-answer that's still streaming.
            for c in cues where c.isAuto && c.state == .streaming { cancelCue(c.id) }
        }
        let card = CueCard(kind: kind, title: kind.title(for: mode),
                           quote: kind == .custom ? customQuestion : target?.text, isAuto: isAuto)
        cues.insert(card, at: 0)
        log.notice("cue requested: \(kind.rawValue, privacy: .public) auto=\(isAuto) via \(client.displayName, privacy: .public)")

        let id = card.id
        cueTasks[id] = Task { [weak self] in
            do {
                for try await chunk in client.stream(system: system, user: user, effort: effort) {
                    self?.update(id) { $0.text += chunk }
                }
                self?.update(id) { $0.state = .done }
            } catch is CancellationError {
                self?.update(id) { $0.state = .cancelled }
            } catch {
                if Task.isCancelled {
                    self?.update(id) { $0.state = .cancelled }
                } else {
                    log.error("cue failed: \(error.localizedDescription, privacy: .public)")
                    self?.update(id) { $0.state = .failed(error.localizedDescription) }
                }
            }
            self?.cueTasks[id] = nil
        }
    }

    func cancelCue(_ id: UUID) {
        cueTasks[id]?.cancel()
        cueTasks[id] = nil
        update(id) { if $0.state == .streaming { $0.state = .cancelled } }
    }

    func dismissCue(_ id: UUID) {
        cancelCue(id)
        cues.removeAll { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout CueCard) -> Void) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        change(&cues[i])
    }

    // MARK: - Test harness

    /// Plays an audio file through the pipeline as call audio, paced in real time
    /// (`Cue --selftest-simulate clip.wav [--echo]`). With `echo`, the same audio is also fed
    /// as the mic, reproducing laptop speakers leaking into the microphone.
    func runSimulation(file: URL, echo: Bool) async throws {
        let locale = try await LiveTranscriber.prepareAssets(locale: Locale(identifier: "en-US"))
        resetSession()
        let call = makeTranscriber(for: .them)
        try await call.start(locale: locale)
        var micSim: LiveTranscriber?
        if echo {
            let m = makeTranscriber(for: .you)
            try await m.start(locale: locale)
            micSim = m
        }
        callAudioActive = true
        phase = .running

        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        while audio.framePosition < audio.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try audio.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            call.feed(buffer)
            micSim?.feed(buffer)
            try await Task.sleep(for: .milliseconds(100))
        }
        await call.finish()
        await micSim?.finish()
        try await Task.sleep(for: .seconds(echoGate.hold + trigger.settleDelay + 0.5))
        callAudioActive = false
        phase = .idle
    }

    /// Sample conversation for UI snapshots (`Cue --selftest-snapshot out.png`).
    func loadDemoSession() {
        let t0 = Date().addingTimeInterval(-95)
        assembler.reset()
        assembler.appendFinal("Thanks for making the time today.", from: .them, at: t0)
        assembler.appendFinal("Of course, glad to be here.", from: .you, at: t0.addingTimeInterval(4))
        assembler.appendFinal("So to start, can you walk me through how you migrated your workloads off Porter, and what went wrong along the way?",
                              from: .them, at: t0.addingTimeInterval(9))
        utterances = assembler.utterances
        partial = [.you: "Sure, so the first thing we did was"]
        sessionStart = t0
        callAudioActive = true
        micLevel = 0.7
        callLevel = 0.3
        phase = .running

        var answer = CueCard(kind: .respond, title: CueKind.respond.title(for: mode),
                             quote: utterances.last?.text, isAuto: true)
        answer.text = """
        **Say:** "We moved [N] services from Porter to a self-managed EKS cluster over [timeframe]. \
        I ran both platforms side by side and cut traffic over service by service, so every step had a rollback. \
        The **biggest surprise was [what broke]**, and we fixed it by [fix]."

        **Points:**
        - Why leave Porter: [cost / control / compliance]
        - How you de-risked it: parallel run, per-service cutover
        - What you'd do differently: [lesson]
        """
        answer.state = .done
        var ask = CueCard(kind: .ask, title: CueKind.ask.title(for: mode), quote: nil, isAuto: false)
        ask.text = "1. What does the platform team own today versus product teams? — shows where you'd fit"
        cues = [ask, answer]
    }

    func copyTranscript() {
        let text = PromptBuilder.formatTranscript(utterances)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Publishes at most ~12 level readings per second per source.
private final class LevelThrottle: @unchecked Sendable {
    private var last = Date.distantPast
    func next(_ buffer: AVAudioPCMBuffer) -> Float? {
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.08 else { return nil }
        last = now
        return AudioLevel.of(buffer)
    }
}
