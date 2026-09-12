import AppKit
import CueCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.floatOnTop) private var floatOnTop = false
    @State private var tab: Tab = .cues

    enum Tab: String, CaseIterable { case cues = "Cues", context = "Context" }

    var body: some View {
        VStack(spacing: 0) {
            ControlBar()
            if let message = model.errorMessage {
                Banner(message: message) { model.errorMessage = nil }
            }
            if let url = model.lastSavedURL, model.phase == .idle {
                SavedBanner(url: url)
            }
            Divider()
            HSplitView {
                TranscriptPane()
                    .frame(minWidth: 300, idealWidth: 480)
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(10)
                    Divider()
                    switch tab {
                    case .cues: CuesPane()
                    case .context: ContextPane()
                    }
                }
                .frame(minWidth: 340, idealWidth: 460)
            }
        }
        .background(WindowLevelSetter(floating: floatOnTop))
    }
}

// MARK: - Control bar

private struct ControlBar: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.useMic) private var useMic = true
    @AppStorage(Pref.useCallAudio) private var useCallAudio = true
    @AppStorage(Pref.autoRespond) private var autoRespond = true
    @AppStorage(Pref.floatOnTop) private var floatOnTop = false

    var body: some View {
        HStack(spacing: 14) {
            Button(action: model.toggle) {
                Label(model.isRunning ? "Stop" : "Start listening",
                      systemImage: model.isRunning ? "stop.fill" : "waveform")
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(model.isRunning ? .red : .accentColor)
            .disabled(model.phase != .idle && model.phase != .running)

            status

            Spacer(minLength: 8)

            Picker("Mode", selection: $model.mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 260)

            SourceToggle(title: "Mic", systemImage: "mic.fill", isOn: $useMic,
                         level: model.micLevel, live: model.isRunning && useMic)
                .disabled(model.phase != .idle)
            SourceToggle(title: "Call", systemImage: "speaker.wave.2.fill", isOn: $useCallAudio,
                         level: model.callLevel, live: model.callAudioActive)
                .disabled(model.phase != .idle)

            Toggle("Auto-cue", isOn: $autoRespond)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Suggest an answer automatically when the other side asks a question")

            Button { floatOnTop.toggle() } label: {
                Image(systemName: floatOnTop ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(floatOnTop ? "Stop keeping Cue above other windows" : "Keep Cue above other windows")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .idle:
            Text(model.hasTranscript ? "Stopped" : "Ready").foregroundStyle(.secondary)
        case .preparing(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            }
        case .running:
            if let start = model.sessionStart {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(PromptBuilder.timestamp(context.date.timeIntervalSince(start)))
                            .monospacedDigit()
                    }
                }
            }
        case .stopping:
            Text("Finishing…").foregroundStyle(.secondary)
        }
    }
}

private struct SourceToggle: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    let level: Float
    let live: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
                LevelMeter(level: live ? level : 0)
            }
        }
        .toggleStyle(.button)
        .controlSize(.small)
    }
}

private struct LevelMeter: View {
    let level: Float
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > Float(i) * 0.22 + 0.05 ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 5 + CGFloat(i) * 3)
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

private struct Banner: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if message.contains("Privacy") {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}

private struct SavedBanner: View {
    let url: URL
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Saved \(url.lastPathComponent)")
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.08))
    }
}

// MARK: - Transcript

private struct TranscriptPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc", action: model.copyTranscript)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!model.hasTranscript)
                    .help("Copy transcript")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            if !model.hasTranscript && model.partial.isEmpty {
                EmptyTranscript()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.utterances) { u in
                                UtteranceRow(utterance: u, origin: model.utterances.first?.startedAt ?? u.startedAt)
                            }
                            ForEach(Speaker.allCases, id: \.self) { speaker in
                                if let text = model.partial[speaker], !text.isEmpty {
                                    PartialRow(speaker: speaker, text: text)
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(14)
                    }
                    .onChange(of: model.utterances.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: model.partial) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }
}

private struct EmptyTranscript: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Press Start listening (⌘R)").font(.title3)
            Text("**Mic** is you. **Call** is whatever your Mac plays: Zoom, Meet, Teams.\nTranscription runs on this Mac; only text goes to Claude when a cue is requested.\nUse headphones on calls so your mic doesn't pick up the other side.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UtteranceRow: View {
    @EnvironmentObject var model: AppModel
    let utterance: Utterance
    let origin: Date
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                SpeakerTag(speaker: utterance.speaker)
                Text(PromptBuilder.timestamp(utterance.startedAt.timeIntervalSince(origin)))
                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }
            .frame(width: 48, alignment: .leading)
            Text(utterance.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if utterance.speaker.isOtherParty {
                Button { model.requestCue(.respond, focus: utterance) } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.borderless)
                .help("\(model.mode.respondLabel) this")
                .opacity(hovering ? 1 : 0)
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct PartialRow: View {
    let speaker: Speaker
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SpeakerTag(speaker: speaker).frame(width: 48, alignment: .leading)
            Text(text).foregroundStyle(.secondary).italic()
        }
    }
}

struct SpeakerTag: View {
    let speaker: Speaker
    var body: some View {
        Text(speaker.label.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(speaker == .you ? Color.blue : Color.purple)
    }
}

// MARK: - Cues

private struct CuesPane: View {
    @EnvironmentObject var model: AppModel
    @State private var ask = ""
    @FocusState private var askFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.requestCue(.respond) } label: {
                    Label(model.mode.respondLabel, systemImage: "text.bubble")
                }
                .keyboardShortcut("1", modifiers: .command)
                .help("\(model.mode.respondLabel) the latest from the other side (⌘1)")
                Button { model.requestCue(.ask) } label: {
                    Label("Ask", systemImage: "questionmark.bubble")
                }
                .keyboardShortcut("2", modifiers: .command)
                .help("Questions worth asking right now (⌘2)")
                Button { model.requestCue(.recap) } label: {
                    Label("Recap", systemImage: "list.bullet.rectangle")
                }
                .keyboardShortcut("3", modifiers: .command)
                .help("Summary, decisions, next steps (⌘3)")
                Spacer()
            }
            .controlSize(.regular)
            .disabled(!model.hasTranscript)
            .padding(10)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.cues.isEmpty {
                        Text(model.hasTranscript
                             ? "Cues appear here. Auto-cue answers questions as they're asked."
                             : "Start listening, or add context notes first so cues use your real background.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(.top, 40)
                    }
                    ForEach(model.cues) { CueCardView(card: $0) }
                }
                .padding(10)
            }

            Divider()
            HStack {
                TextField("Ask Cue about this conversation…  (⌘L)", text: $ask, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused($askFocused)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(ask.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(Button("") { askFocused = true }.keyboardShortcut("l").hidden())
        }
    }

    private func send() {
        let q = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        model.requestCue(.custom, customQuestion: q)
        ask = ""
    }
}

private struct CueCardView: View {
    @EnvironmentObject var model: AppModel
    let card: CueCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(card.title).font(.subheadline.weight(.semibold))
                if card.isAuto {
                    Text("AUTO").font(.caption2.weight(.bold)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                }
                if card.state == .streaming { ProgressView().controlSize(.mini) }
                Spacer()
                Text(card.createdAt, style: .time).font(.caption2).foregroundStyle(.tertiary)
                if card.state == .streaming {
                    Button { model.cancelCue(card.id) } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless).help("Stop")
                } else {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(card.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy")
                }
                Button { model.dismissCue(card.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Dismiss")
            }
            if let quote = card.quote, !quote.isEmpty {
                Text("“\(quote)”").font(.callout).italic().foregroundStyle(.secondary).lineLimit(3)
            }
            if !card.text.isEmpty {
                Text(Self.markdown(card.text))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if card.state == .streaming {
                Text("Thinking…").foregroundStyle(.secondary).font(.callout)
            }
            switch card.state {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.octagon").foregroundStyle(.red).font(.callout)
                    .textSelection(.enabled)
            case .cancelled:
                Text("Stopped").foregroundStyle(.tertiary).font(.caption)
            default:
                EmptyView()
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - Context

private struct ContextPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context for \(model.mode.shortTitle.lowercased()) mode").font(.headline)
            Text("Sent to Claude with every cue so suggestions use real details instead of guesses. Saved separately for each mode.")
                .font(.callout).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.notes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if model.notes.isEmpty {
                    Text(model.mode.contextPlaceholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            HStack {
                Text("\(model.notes.split(whereSeparator: \.isWhitespace).count) words")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Import file…", action: importFile).controlSize(.small)
            }
        }
        .padding(12)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .pdf, .rtf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let text = FileText.read(url), !text.isEmpty {
                model.notes += (model.notes.isEmpty ? "" : "\n\n") + "## \(url.lastPathComponent)\n\(text)"
            }
        }
    }
}

enum FileText {
    static func read(_ url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" {
            return PDFTextExtractor.text(at: url)
        }
        if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return attributed.string
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Window level

private struct WindowLevelSetter: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.level = floating ? .floating : .normal
            view.window?.collectionBehavior = floating ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        }
    }
}
