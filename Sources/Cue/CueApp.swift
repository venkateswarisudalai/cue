import AVFoundation
import CueCore
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest-transcribe"), i + 1 < args.count {
            SelfTest.runAndExit { try await SelfTest.transcribe(path: args[i + 1]) }
        }
        if let i = args.firstIndex(of: "--selftest-llm") {
            let text = i + 1 < args.count ? args[i + 1] : "Tell me about a time you handled a production outage?"
            SelfTest.runAndExit { try await SelfTest.cue(question: text) }
        }
        if let i = args.firstIndex(of: "--selftest-simulate"), i + 1 < args.count {
            let path = args[i + 1]
            let echo = args.contains("--echo")
            SelfTest.runAndExit { try await SelfTest.simulate(path: path, echo: echo) }
        }
        if let i = args.firstIndex(of: "--selftest-snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { SelfTest.snapshot(to: args[i + 1]) }
            exit(0)
        }
        CueApp.main()
    }
}

struct CueApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Cue", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 460)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandMenu("Session") {
                Button(model.isRunning ? "Stop Listening" : "Start Listening", action: model.toggle)
                    .keyboardShortcut("r")
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
    }
}

/// Headless checks that exercise the real pipeline: `Cue --selftest-transcribe file.aiff`, `Cue --selftest-llm`.
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
        let model = AppModel()
        model.loadDemoSession()
        let size = NSRect(x: 0, y: 0, width: 1120, height: 720)
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
        let model = AppModel()
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
        transcriber.onFinal = { text in
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

    static func cue(question: String) async throws {
        Pref.register()
        let client = try LLMFactory.make()
        print("backend: \(client.displayName)")
        let utterances = [Utterance(speaker: .them, text: question, startedAt: Date())]
        let system = PromptBuilder.system(mode: .candidate, contextNotes: "Platform engineer, 8 years, AWS and Kubernetes.")
        let user = PromptBuilder.userMessage(kind: .respond, mode: .candidate, utterances: utterances)
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
