import AVFoundation
import VantageCore
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest-transcribe"), i + 1 < args.count {
            SelfTest.runAndExit { try await SelfTest.transcribe(path: args[i + 1]) }
        }
        if let i = args.firstIndex(of: "--selftest-llm") {
            let text = i + 1 < args.count ? args[i + 1] : "What would it take to cut over payments by Tuesday?"
            SelfTest.runAndExit { try await SelfTest.cue(question: text) }
        }
        if let i = args.firstIndex(of: "--selftest-simulate"), i + 1 < args.count {
            let path = args[i + 1]
            let echo = args.contains("--echo")
            SelfTest.runAndExit { try await SelfTest.simulate(path: path, echo: echo) }
        }
        if let i = args.firstIndex(of: "--selftest-record"), i + 1 < args.count {
            let path = args[i + 1]
            SelfTest.runAndExit { try await SelfTest.record(path: path) }
        }
        if args.contains("--selftest-mic-users") {
            SelfTest.runAndExit { try await SelfTest.micUsers() }
        }
        if args.contains("--selftest-notes") {
            SelfTest.runAndExit { try await SelfTest.notes() }
        }
        if let i = args.firstIndex(of: "--selftest-snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { SelfTest.snapshot(to: args[i + 1]) }
            exit(0)
        }
        LegacyMigration.run()
        VantageApp.main()
    }
}

struct VantageApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Vantage", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note", action: model.newMeeting)
                    .keyboardShortcut("n")
                    .disabled(model.phase != .idle)
            }
            CommandMenu("Session") {
                Button(model.isRunning ? "Stop Listening" : "Start Listening", action: model.toggle)
                    .keyboardShortcut("r")
                Button("Generate Notes", action: model.generateNotes)
                    .keyboardShortcut("e")
                    .disabled(model.isRunning || model.enhancing)
                Divider()
                Button("Open Sessions Folder") {
                    try? FileManager.default.createDirectory(at: SessionExporter.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(SessionExporter.directory)
                }
            }
        }

        Settings {
            SettingsView()
        }

        // Keeps Vantage around (and call detection working) after the window is closed.
        MenuBarExtra("Vantage", systemImage: model.isRunning ? "waveform.circle.fill" : "waveform") {
            MenuBarMenu().environmentObject(model)
        }
    }
}

private struct MenuBarMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Pref.detectMeetings) private var detectMeetings = true

    var body: some View {
        Button(model.isRunning ? "Stop Listening" : "Start Listening") {
            if model.phase == .idle { open() }
            model.toggle()
        }
        .disabled(model.phase != .idle && model.phase != .running)
        Button("Open Vantage", action: open)
        Divider()
        Toggle("Offer to listen when a call starts", isOn: $detectMeetings)
        Divider()
        Button("Quit Vantage") { NSApp.terminate(nil) }
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// Headless checks that exercise the real pipeline: `Vantage --selftest-transcribe file.aiff`, `Vantage --selftest-llm`.
enum SelfTest {
    static func runAndExit(_ body: @escaping @Sendable () async throws -> Void) -> Never {
        Task {
            do {
                try await body()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("SELFTEST FAILED: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    /// Renders the main window with a sample conversation into a PNG. Draws the app's own
    /// view hierarchy, so it needs no Screen Recording permission.
    @MainActor
    static func snapshot(to path: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = AppModel(loadSaved: false)
        model.loadDemoSession(live: CommandLine.arguments.contains("--live"))
        let size = NSRect(x: 0, y: 0, width: 1180, height: 760)
        let host = NSHostingView(rootView: ContentView().environmentObject(model).frame(width: size.width, height: size.height))
        host.frame = size
        let window = NSWindow(contentRect: size, styleMask: [.titled], backing: .buffered, defer: false)
        let dark = CommandLine.arguments.contains("--dark")
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = window.appearance
        host.wantsLayer = true
        window.appearance?.performAsCurrentDrawingAppearance {
            host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))  // let SwiftUI finish layout
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("snapshot: \(path)")
    }

    /// Full pipeline minus capture: file → transcription → echo gate → auto-cue → Claude.
    @MainActor
    static func simulate(path: String, echo: Bool) async throws {
        let model = AppModel(loadSaved: false)
        model.trace = { print("trace: \($0)") }
        print("simulating \(path) echo=\(echo) autoRespond=\(Pref.d.bool(forKey: Pref.autoRespond)) mode=\(model.mode.rawValue)")
        try await model.runSimulation(file: URL(fileURLWithPath: path), echo: echo)

        var waited = 0.0
        while model.cues.contains(where: { $0.state == .streaming }), waited < 120 {
            try await Task.sleep(for: .milliseconds(500))
            waited += 0.5
        }
        print("\n=== TRANSCRIPT ===")
        print(PromptBuilder.formatTranscript(model.utterances))
        print("\n=== CUES (\(model.cues.count)) ===")
        for c in model.cues.reversed() {
            print("\n[\(c.isAuto ? "auto" : "manual")] \(c.title) — \(c.state)")
            print("  quote: \(c.quote ?? "-")")
            print("  " + c.text.prefix(240).replacingOccurrences(of: "\n", with: "\n  "))
        }
        if let message = model.errorMessage { print("\nerror: \(message)") }
    }

    static func transcribe(path: String) async throws {
        let locale = try await LiveTranscriber.prepareAssets(locale: Locale(identifier: "en-US")) { p in
            print(String(format: "downloading speech model %.0f%%", p * 100))
        }
        print("locale: \(locale.identifier)")

        let finals = FinalsBox()
        let transcriber = LiveTranscriber()
        transcriber.onFinal = { text, _ in
            print("final: \(text)")
            finals.append(text)
        }
        try await transcriber.start(locale: locale, vocabulary: Vocabulary.terms(from: ""))

        // Feed the file in 100 ms chunks through the same conversion path live audio uses.
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            transcriber.feed(buffer)
        }
        await transcriber.finish()

        let transcript = finals.joined
        print("transcript: \(transcript)")
        print("question detected: \(QuestionDetector.isQuestion(transcript))")
        guard !transcript.isEmpty else { throw TranscriberError.noAudioFormat }
    }

    /// Writes a clip as the call track and, 1.5s later, as the mic track, then mixes them like a
    /// real session. The result should be ~1.5s longer than the clip.
    static func record(path: String) async throws {
        let meeting = UUID()
        let recorder = try MeetingRecorder(meeting: meeting)
        defer { try? FileManager.default.removeItem(at: MeetingRecorder.folder(for: meeting)) }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        let t0 = HostClock.now
        var t: TimeInterval = 0
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            recorder.call.write(buffer, at: t0 + t)
            recorder.mic.write(buffer, at: t0 + t + 1.5)
            t += Double(buffer.frameLength) / format.sampleRate
        }
        guard let r = try await recorder.finish() else { throw LLMError.failed("no recording produced") }
        let clip = Double(file.length) / format.sampleRate
        print(String(format: "clip %.2fs → recording %.2fs (%@)", clip, r.duration, r.file))
        guard abs(r.duration - (clip + 1.5)) < 0.5 else { throw LLMError.failed("unexpected duration") }
    }

    /// Lists processes capturing audio before and while this process holds the mic,
    /// checking that call detection would see a mic user.
    static func micUsers() async throws {
        let me = getpid()
        func show(_ label: String) -> Bool {
            let users = MicUsage.users(excludingPID: -1)
            print("\(label): " + (users.isEmpty ? "(none)" : users.map { "\($0.pid) \($0.bundleID ?? "-")" }.joined(separator: ", ")))
            return users.contains { $0.pid == me }
        }
        _ = show("before")
        let mic = MicCapture()
        try mic.start()
        try await Task.sleep(for: .seconds(1.5))
        let seen = show("while using mic")
        mic.stop()
        try await Task.sleep(for: .seconds(1))
        let still = show("after")
        print("detected own mic use: \(seen), released: \(!still)")
        guard seen, !still else { throw LLMError.failed("mic use not reported by CoreAudio") }
    }

    /// Real post-meeting notes from a short sample transcript via your backend.
    static func notes() async throws {
        Pref.register()
        let client = try LLMFactory.make()
        print("backend: \(client.displayName)")
        let t0 = Date()
        let lines: [(Speaker, String)] = [
            (.them, "Okay so main thing today is the EKS cutover for payments."),
            (.you, "Staging's been on the new cluster two weeks, error rates are flat."),
            (.them, "What's blocking prod, still secrets rotation?"),
            (.you, "Mostly, plus the SOC 2 evidence for the change window. I can have both by Thursday."),
            (.them, "Great, let's cut over next Tuesday and keep Porter warm for a week."),
        ]
        let u = lines.enumerated().map { Utterance(speaker: $1.0, text: $1.1, startedAt: t0.addingTimeInterval(Double($0) * 8)) }
        var text = ""
        for try await chunk in client.stream(system: PromptBuilder.notesSystem(mode: .meeting, contextNotes: ""),
                                             user: PromptBuilder.notesUser(title: "", userNotes: "blocker: secrets\nSOC2??", utterances: u),
                                             effort: "medium") {
            text += chunk
        }
        print(text)
        print("title: \(Meeting.suggestedTitle(fromNotes: text) ?? "-")")
    }

    static func cue(question: String) async throws {
        Pref.register()
        let client = try LLMFactory.make()
        print("backend: \(client.displayName)")
        let utterances = [Utterance(speaker: .them, text: question, startedAt: Date())]
        let system = PromptBuilder.system(mode: .meeting, contextNotes: "Platform engineer, 8 years, AWS and Kubernetes.")
        let user = PromptBuilder.userMessage(kind: .respond, mode: .meeting, utterances: utterances)
        let started = Date()
        var first: TimeInterval?
        for try await chunk in client.stream(system: system, user: user, effort: "low") {
            if first == nil { first = Date().timeIntervalSince(started) }
            print(chunk, terminator: "")
            fflush(stdout)
        }
        print(String(format: "\n\nfirst token %.1fs, total %.1fs", first ?? -1, Date().timeIntervalSince(started)))
    }
}

private final class FinalsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.withLock { items.append(s) } }
    var joined: String { lock.withLock { items.joined(separator: " ") } }
}
