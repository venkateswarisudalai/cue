import AVFoundation
import CoreGraphics
import VantageCore
import OSLog
import SwiftUI

/// `log show --info --predicate 'subsystem == "com.venka.vantage"' --last 10m`
/// Events only — transcript text is never logged.
private let log = Logger(subsystem: "com.venka.vantage", category: "session")

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case running
        case stopping
    }

    @Published var phase: Phase = .idle
    @Published private(set) var meetings: [Meeting] = []
    /// The open note. Edits autosave; while listening, the transcript streams into it.
    @Published var current: Meeting {
        didSet {
            guard current != oldValue else { return }
            if current.id == oldValue.id { scheduleSave() }
            if current.mode != oldValue.mode {
                Pref.d.set(current.mode.rawValue, forKey: Pref.mode)
                contextNotes = Pref.d.string(forKey: Pref.notesKey(current.mode)) ?? ""
            }
        }
    }
    @Published private(set) var partial: [Speaker: String] = [:]
    @Published private(set) var enhancing = false
    @Published private(set) var cues: [CueCard] = []
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var callLevel: Float = 0
    @Published private(set) var callAudioActive = false
    @Published private(set) var sessionStart: Date?
    @Published private(set) var lastSavedURL: URL?
    @Published var errorMessage: String?

    var mode: Mode {
        get { current.mode }
        set { current.mode = newValue }
    }
    var utterances: [Utterance] { current.utterances }
    /// Background for suggestions and notes (résumé, agenda, account notes). Saved per mode.
    @Published var contextNotes: String {
        didSet { Pref.d.set(contextNotes, forKey: Pref.notesKey(current.mode)) }
    }

    private var assembler = TranscriptAssembler()
    private var trigger = QuestionTrigger()
    private var echoGate = EchoGate()
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var micTranscriber: LiveTranscriber?
    private var callTranscriber: LiveTranscriber?
    private var cueTasks: [UUID: Task<Void, Never>] = [:]
    /// Set while listening with recording on.
    private var recorder: MeetingRecorder?
    @Published private(set) var isRecording = false
    private var saveTask: Task<Void, Never>?
    private var enhanceTask: Task<Void, Never>?
    private var exported: [UUID: URL] = [:]

    /// Off for self-tests, so they never touch saved meetings.
    private let persistent: Bool
    /// Watches for calls starting in other apps and offers to listen.
    private(set) var detection: MeetingDetection?
    /// Reopens the main window (set by the window itself; works after it's closed).
    var showMainWindow: (() -> Void)?

    init(loadSaved: Bool = true) {
        Pref.register()
        persistent = loadSaved
        let m = Mode(rawValue: Pref.d.string(forKey: Pref.mode) ?? "") ?? .meeting
        contextNotes = Pref.d.string(forKey: Pref.notesKey(m)) ?? ""
        let saved = loadSaved ? MeetingStore.loadAll() : []
        // Reopen an untouched note rather than piling up blank ones.
        if let blank = saved.first, blank.isEmpty {
            current = blank
            meetings = saved
        } else {
            current = Meeting(mode: m)
            meetings = [current] + saved
        }
        if loadSaved { detection = MeetingDetection(model: self) }
    }

    var isRunning: Bool { phase == .running }
    var hasTranscript: Bool { !utterances.isEmpty }
    var suggestionsOn: Bool { Pref.d.bool(forKey: Pref.showSuggestions) }

    // MARK: - Meetings

    func newMeeting() {
        guard phase == .idle else { return }
        flushSave()
        if current.isEmpty { return }
        let m = Meeting(mode: current.mode)
        meetings.insert(m, at: 0)
        select(m.id)
    }

    func select(_ id: UUID) {
        guard phase == .idle, id != current.id, let m = meetings.first(where: { $0.id == id }) else { return }
        flushSave()
        enhanceTask?.cancel()
        enhancing = false
        cues.forEach { cancelCue($0.id) }
        cues = []
        lastSavedURL = nil
        errorMessage = nil
        // Drop the blank note we're leaving.
        if current.isEmpty { meetings.removeAll { $0.id == current.id } }
        current = m
    }

    func deleteMeeting(_ id: UUID) {
        guard !(isRunning && id == current.id) else { return }
        meetings.removeAll { $0.id == id }
        if persistent {
            MeetingStore.delete(id)
            try? FileManager.default.removeItem(at: MeetingRecorder.folder(for: id))
        }
        if id == current.id {
            saveTask?.cancel()
            enhanceTask?.cancel()
            enhancing = false
            cues = []
            current = meetings.first ?? Meeting(mode: current.mode)
            if meetings.isEmpty { meetings = [current] }
        }
    }

    private func scheduleSave() {
        if let i = meetings.firstIndex(where: { $0.id == current.id }) { meetings[i] = current }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        persist()
    }

    private func persist() {
        guard persistent, !current.isEmpty else { return }
        do { try MeetingStore.save(current) } catch {
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func export() {
        guard persistent, Pref.d.bool(forKey: Pref.saveSessions), !current.utterances.isEmpty else { return }
        do {
            let url = try SessionExporter.save(current, cues: cues)
            if let old = exported[current.id], old != url { try? FileManager.default.removeItem(at: old) }
            exported[current.id] = url
            lastSavedURL = url
        } catch {
            errorMessage = "Couldn't save the session: \(error.localizedDescription)"
        }
    }

    // MARK: - Enhanced notes

    /// Streams Claude's write-up of the user's notes + transcript into the meeting.
    func generateNotes() {
        guard !enhancing, hasTranscript || !current.userNotes.isEmpty else { return }
        let client: LLMClient
        do { client = try LLMFactory.make() } catch {
            errorMessage = error.localizedDescription
            return
        }
        let id = current.id
        let system = PromptBuilder.notesSystem(mode: current.mode, contextNotes: contextNotes)
        let user = PromptBuilder.notesUser(title: current.title, userNotes: current.userNotes, utterances: current.utterances)
        let effort = Pref.d.string(forKey: Pref.effort) == "high" ? "high" : "medium"
        let previous = current.enhancedNotes
        enhancing = true
        current.enhancedNotes = ""
        log.notice("notes requested via \(client.displayName, privacy: .public)")
        enhanceTask = Task { [weak self] in
            var text = ""
            do {
                for try await chunk in client.stream(system: system, user: user, effort: effort) {
                    text += chunk
                    guard let self, self.current.id == id else { return }
                    self.current.enhancedNotes = text
                }
                guard let self, self.current.id == id else { return }
                self.finishNotes(text)
            } catch {
                guard let self else { return }
                if self.current.id == id {
                    self.enhancing = false
                    if text.isEmpty { self.current.enhancedNotes = previous }
                }
                if !(error is CancellationError) && !Task.isCancelled {
                    log.error("notes failed: \(error.localizedDescription, privacy: .public)")
                    self.errorMessage = "Couldn't write notes: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelNotes() {
        enhanceTask?.cancel()
        enhancing = false
    }

    private func finishNotes(_ text: String) {
        enhancing = false
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The first "# heading" is Claude's title; use it if the user didn't name the meeting.
        if let title = Meeting.suggestedTitle(fromNotes: body) {
            if current.title.trimmingCharacters(in: .whitespaces).isEmpty { current.title = title }
            if let firstBreak = body.firstIndex(of: "\n") {
                body = String(body[firstBreak...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                body = ""
            }
        }
        current.enhancedNotes = body
        flushSave()
        export()
    }

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
            if Pref.d.bool(forKey: Pref.recordAudio) {
                do {
                    recorder = try MeetingRecorder(meeting: current.id)
                    isRecording = true
                } catch {
                    errorMessage = "Couldn't start recording (\(error.localizedDescription)). Transcribing without it."
                }
            }

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
            recorder = nil
            isRecording = false
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    func stop() async {
        guard phase == .running else { return }
        phase = .stopping
        await teardown()
        // Let finalized fragments and held mic lines land before saving.
        try? await Task.sleep(for: .seconds(echoGate.hold + 0.3))
        await finishRecording()
        phase = .idle
        if let start = sessionStart { current.duration += Date().timeIntervalSince(start) }
        log.notice("stopped: \(self.utterances.count) utterances, \(self.cues.count) cues")
        flushSave()
        export()
        if Pref.d.bool(forKey: Pref.autoEnhance), hasTranscript, (try? LLMFactory.make()) != nil {
            generateNotes()
        }
    }

    private func finishRecording() async {
        guard let recorder else { return }
        self.recorder = nil
        isRecording = false
        phase = .preparing("Saving recording…")
        do {
            if let r = try await recorder.finish() {
                current.recordings.append(r)
                log.notice("recording saved: \(Int(r.duration))s")
            }
        } catch {
            log.error("recording failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't save the recording: \(error.localizedDescription)"
        }
    }

    func recordingURL(_ r: Recording) -> URL {
        MeetingRecorder.folder(for: current.id).appendingPathComponent(r.file)
    }

    private func resetSession() {
        cueTasks.values.forEach { $0.cancel() }
        cueTasks.removeAll()
        // Listening again on the same note continues its transcript.
        assembler.load(current.utterances)
        trigger.reset()
        echoGate.reset()
        partial = [:]
        lastSavedURL = nil
        sessionStart = Date()
    }

    private func startMic(locale: Locale, speaker: Speaker) async throws {
        let transcriber = makeTranscriber(for: speaker)
        try await transcriber.start(locale: locale, vocabulary: Vocabulary.terms(from: contextNotes + "\n" + current.userNotes))
        let capture = MicCapture()
        let meter = LevelThrottle()
        let track = recorder?.mic
        capture.onBuffer = { [weak self] buffer, host in
            transcriber.feed(buffer, at: host)
            track?.write(buffer, at: host)
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
        try await transcriber.start(locale: locale, vocabulary: Vocabulary.terms(from: contextNotes + "\n" + current.userNotes))
        let capture = SystemAudioCapture()
        let meter = LevelThrottle()
        let track = recorder?.call
        capture.onBuffer = { [weak self] buffer, host in
            transcriber.feed(buffer, at: host)
            track?.write(buffer, at: host)
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
            return "Call audio is off — Vantage needs Screen & System Audio Recording permission to hear the other side. "
                + "Enable Vantage in System Settings → Privacy & Security, then quit and reopen Vantage. Transcribing your mic only for now."
        }
        return "Call audio couldn't start (\(error.localizedDescription)). Transcribing your mic only for now."
    }

    private func makeTranscriber(for speaker: Speaker) -> LiveTranscriber {
        let t = LiveTranscriber()
        t.onVolatile = { [weak self] text in
            Task { @MainActor in self?.handleVolatile(text, from: speaker) }
        }
        t.onFinal = { [weak self] text, spokenHost in
            let spoken = spokenHost.map(HostClock.date)
            Task { @MainActor in self?.handleFinal(text, from: speaker, spokenAt: spoken) }
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
    }

    /// Debug hook for `--selftest-simulate`. Includes transcript text, so it never goes to the system log.
    var trace: ((String) -> Void)?

    private func handleFinal(_ text: String, from speaker: Speaker, spokenAt: Date? = nil) {
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
                if let utteranceID = self.commit(held.text, from: .you, at: held.at, spokenAt: spokenAt) {
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
                current.utterances = assembler.utterances
                trace?("  retracted \(retractions.count) shown mic fragments")
                log.info("retracted \(retractions.count) mic echo fragments")
            }
        }
        commit(text, from: speaker, at: now, spokenAt: spokenAt)
    }

    @discardableResult
    private func commit(_ text: String, from speaker: Speaker, at time: Date, spokenAt: Date? = nil) -> UUID? {
        guard let id = assembler.appendFinal(text, from: speaker, at: time, spokenAt: spokenAt) else { return nil }
        current.utterances = assembler.utterances
        guard speaker.isOtherParty, suggestionsOn, Pref.d.bool(forKey: Pref.autoRespond) else { return id }

        let turn = assembler.utterances.last(where: { $0.id == id })?.text ?? text
        handle(trigger.otherPartyFinal(fragment: text, turn: turn))
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
        let system = PromptBuilder.system(mode: mode, contextNotes: contextNotes)
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
    /// (`Vantage --selftest-simulate clip.wav [--echo]`). With `echo`, the same audio is also fed
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

    /// Sample meeting for UI snapshots (`Vantage --selftest-snapshot out.png [--live]`).
    func loadDemoSession(live: Bool) {
        let t0 = Date().addingTimeInterval(-1260)
        var a = TranscriptAssembler()
        let lines: [(String, Speaker, TimeInterval)] = [
            ("Okay, let's get going. Main thing today is the EKS cutover for the payments service.", .them, 0),
            ("Staging has been on the new cluster for two weeks and error rates look flat.", .you, 8),
            ("Good. What's blocking prod? Is it still the secrets rotation?", .them, 16),
            ("Mostly that, plus the SOC 2 evidence for the change window. I can have both by Thursday.", .you, 22),
            ("Great. Let's plan the cutover for next Tuesday and keep Porter warm for a week as rollback.", .them, 31),
        ]
        for (text, speaker, at) in lines {
            a.appendFinal(text, from: speaker, at: t0.addingTimeInterval(at + 3), spokenAt: t0.addingTimeInterval(at))
        }
        current = Meeting(title: "Payments EKS cutover", createdAt: t0, mode: .meeting,
                          userNotes: "payments → EKS\nblocker: secrets rotation\nSOC2 evidence??",
                          utterances: a.utterances, duration: 1260,
                          recordings: [Recording(file: "demo.m4a", startedAt: t0, duration: 1260)])
        meetings = [current,
                    Meeting(title: "Platform weekly", createdAt: t0.addingTimeInterval(-86_400), mode: .meeting, userNotes: "x"),
                    Meeting(title: "Acme renewal", createdAt: t0.addingTimeInterval(-4 * 86_400), mode: .sales, userNotes: "x")]
        assembler.load(a.utterances)
        if live {
            partial = [.them: "And who owns the runbook for"]
            sessionStart = Date().addingTimeInterval(-1260)
            callAudioActive = true
            micLevel = 0.6
            callLevel = 0.4
            phase = .running
            var ask = CueCard(kind: .ask, title: CueKind.ask.title(for: .meeting), quote: nil, isAuto: false)
            ask.text = """
            1. Who signs off on the cutover on Tuesday? — pins an owner
            2. What's the rollback trigger — error rate or latency? — makes "keep Porter warm" concrete
            3. Does the SOC 2 evidence need the change ticket first? — avoids a Thursday surprise
            """
            ask.state = .done
            cues = [ask]
        } else {
            current.enhancedNotes = """
            ### Payments service → EKS
            - Staging has run on the new cluster for **two weeks**; error rates flat
            - Prod cutover planned for **next Tuesday**
            - Porter stays warm for **one week** as the rollback path

            ### Blockers
            - Secrets rotation still open
            - SOC 2 evidence for the change window needed before prod

            ### Decisions
            - Cut over next Tuesday with Porter as rollback

            ### Action items
            - **You** — secrets rotation + SOC 2 evidence, by **Thursday**
            """
        }
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
