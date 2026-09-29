import AppKit
import VantageCore
import SwiftUI

/// Granola-style layout: notes list on the left, a notepad in the middle, the transcript tucked
/// behind the bottom bar, and live suggestions in an optional inspector on the right.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Pref.floatOnTop) private var floatOnTop = false
    @AppStorage(Pref.showSuggestions) private var showSuggestions = false

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            MeetingView()
                .inspector(isPresented: $showSuggestions) {
                    SuggestionsInspector()
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { floatOnTop.toggle() } label: {
                            Label("Pin", systemImage: floatOnTop ? "pin.fill" : "pin")
                        }
                        .help(floatOnTop ? "Stop keeping Vantage above other windows" : "Keep Vantage above other windows")
                        Toggle(isOn: $showSuggestions) {
                            Label("Suggestions", systemImage: "sparkles")
                        }
                        .help("Live suggestions while you talk (⇧⌘S)")
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                    }
                }
        }
        .background(WindowLevelSetter(floating: floatOnTop))
        .onAppear { model.showMainWindow = { [openWindow] in openWindow(id: "main") } }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.current.id }, set: { if let id = $0 { model.select(id) } })) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.meetings) { m in
                        MeetingRow(meeting: m, live: model.isRunning && m.id == model.current.id)
                            .tag(m.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) { model.deleteMeeting(m.id) }
                                    .disabled(model.isRunning && m.id == model.current.id)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(model.phase != .idle)
        .safeAreaInset(edge: .bottom) { AIStatus() }
        .safeAreaInset(edge: .top) {
            Button(action: model.newMeeting) {
                Label("New note", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .disabled(model.phase != .idle)
        }
    }

    private var groups: [(title: String, meetings: [Meeting])] {
        let cal = Calendar.current
        var out: [(String, [Meeting])] = []
        func add(_ title: String, _ filter: (Meeting) -> Bool, from pool: inout [Meeting]) {
            let hits = pool.filter(filter)
            pool.removeAll(where: filter)
            if !hits.isEmpty { out.append((title, hits)) }
        }
        var pool = model.meetings
        add("Today", { cal.isDateInToday($0.createdAt) }, from: &pool)
        add("Yesterday", { cal.isDateInYesterday($0.createdAt) }, from: &pool)
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        add("Previous 7 days", { $0.createdAt > weekAgo }, from: &pool)
        if !pool.isEmpty { out.append(("Earlier", pool)) }
        return out
    }
}

/// Which AI writes the notes, and the way into Settings to change it or add a key.
private struct AIStatus: View {
    @State private var label = ""
    @State private var ok = true

    var body: some View {
        SettingsLink {
            HStack(spacing: 6) {
                Image(systemName: ok ? "sparkles" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? Color.secondary : Color.orange)
                Text(label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("AI provider and API keys (⌘,)")
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: Keychain.didChange)) { _ in refresh() }
    }

    private func refresh() {
        do {
            label = "AI: " + (try LLMFactory.make().displayName)
            ok = true
        } catch {
            label = "Set up AI — add a key"
            ok = false
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let live: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.displayTitle)
                    .lineLimit(1)
                    .foregroundStyle(meeting.title.isEmpty ? .secondary : .primary)
                Text(meeting.createdAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if live {
                Circle().fill(.red).frame(width: 7, height: 7).help("Listening")
            } else if !meeting.enhancedNotes.isEmpty {
                Image(systemName: "sparkles").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Meeting (notepad)

private struct MeetingView: View {
    @EnvironmentObject var model: AppModel
    @State private var showTranscript = CommandLine.arguments.contains("--transcript")  // self-test snapshots
    @State private var chosenPage: Page? = CommandLine.arguments.contains("--transcript-page") ? .transcript : nil
    @StateObject private var player = RecordingPlayer()

    enum Page: Hashable { case notes, mine, transcript }

    private var hasEnhanced: Bool { !model.current.enhancedNotes.isEmpty || model.enhancing }
    private var hasTranscriptPage: Bool { model.hasTranscript || !model.current.recordings.isEmpty }
    private var page: Page {
        switch chosenPage ?? (hasEnhanced ? .notes : .mine) {
        case .notes: hasEnhanced ? .notes : .mine
        case .transcript: hasTranscriptPage ? .transcript : .mine
        case .mine: .mine
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    switch page {
                    case .notes: EnhancedNotesView(text: model.current.enhancedNotes, streaming: model.enhancing)
                    case .mine: MyNotesEditor(text: $model.current.userNotes, listening: model.isRunning)
                    case .transcript: TranscriptPage()
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 140)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.never)

            VStack(spacing: 10) {
                if showTranscript {
                    TranscriptDrawer(isPresented: $showTranscript)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                BottomBar(showTranscript: $showTranscript, transcriptPageOpen: page == .transcript)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .overlay(alignment: .top) { banners }
        .background(Color(nsColor: .textBackgroundColor))
        .animation(.snappy(duration: 0.22), value: showTranscript)
        .environmentObject(player)
        .onChange(of: model.current.id) { chosenPage = nil; showTranscript = false; player.stop() }
        .onChange(of: model.enhancing) { if model.enhancing { chosenPage = .notes } }
        .onChange(of: page) { if page == .transcript { showTranscript = false } }
        .background(Button("") { showTranscript.toggle() }.keyboardShortcut("t").hidden())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("New note", text: $model.current.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .semibold))
            HStack(spacing: 8) {
                Chip(systemImage: "calendar") {
                    Text(model.current.createdAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                }
                Menu {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Chip(systemImage: modeIcon) { Text(model.mode.shortTitle) }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(model.isRunning)
                .help("What kind of conversation this is — shapes notes and suggestions")
                if model.current.duration > 0 {
                    Chip(systemImage: "clock") { Text(durationText) }
                }
                if model.isRecording {
                    Chip(systemImage: "record.circle") { Text("Recording") }
                        .foregroundStyle(.red)
                }
                Spacer()
                if hasEnhanced || hasTranscriptPage {
                    Picker("", selection: Binding(get: { page }, set: { chosenPage = $0 })) {
                        if hasEnhanced { Label("Notes", systemImage: "sparkles").tag(Page.notes) }
                        Text("My notes").tag(Page.mine)
                        if hasTranscriptPage { Text("Transcript").tag(Page.transcript) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Vantage's notes, what you typed, or the full transcript")
                }
            }
        }
    }

    private var modeIcon: String {
        switch model.mode {
        case .meeting: "person.3"
        case .sales: "briefcase"
        }
    }

    private var durationText: String {
        let minutes = max(1, Int((model.current.duration / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                Banner(message: message) { model.errorMessage = nil }
            }
            if let url = model.lastSavedURL, model.phase == .idle, !model.enhancing {
                SavedBanner(url: url)
            }
        }
    }
}

private struct Chip<Content: View>: View {
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).imageScale(.small)
            content
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }
}

private struct MyNotesEditor: View {
    @Binding var text: String
    let listening: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(minHeight: 320)
            if text.isEmpty {
                Text(listening
                     ? "Jot down anything that matters — Vantage fills in the rest from the transcript."
                     : "Write notes…\nPress Start listening when the meeting begins. When you stop, Vantage turns your notes and the transcript into clean meeting notes.")
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Renders Claude's Markdown notes as a document: section headings, nested bullets, paragraphs.
private struct EnhancedNotesView: View {
    let text: String
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                row(block)
            }
            if streaming {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text.isEmpty ? "Writing notes from your meeting…" : "Writing…")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func row(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let t):
            Text(Self.inline(t))
                .font(level <= 2 ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .padding(.top, 14)
                .padding(.bottom, 2)
        case .bullet(let depth, let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(depth == 0 ? "•" : "◦").foregroundStyle(.secondary)
                Text(Self.inline(t))
            }
            .font(.system(size: 15))
            .lineSpacing(3)
            .padding(.leading, CGFloat(depth) * 20)
        case .numbered(let depth, let marker, let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).monospacedDigit().foregroundStyle(.secondary)
                Text(Self.inline(t))
            }
            .font(.system(size: 15))
            .padding(.leading, CGFloat(depth) * 20)
        case .paragraph(let t):
            Text(Self.inline(t)).font(.system(size: 15)).lineSpacing(3)
        case .divider:
            Divider().padding(.vertical, 6)
        }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.showSuggestions) private var showSuggestions = false
    @AppStorage(Pref.recordAudio) private var recordAudio = false
    @Binding var showTranscript: Bool
    let transcriptPageOpen: Bool
    @State private var ask = ""
    @FocusState private var askFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            listenControl
            if model.phase == .idle { recordToggle }
            Button { showTranscript.toggle() } label: {
                Image(systemName: showTranscript ? "chevron.down" : "text.bubble")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(showTranscript ? "Hide transcript (⌘T)" : "Show transcript (⌘T)")
            .disabled((!model.hasTranscript && model.partial.isEmpty && !model.isRunning) || transcriptPageOpen)

            Divider().frame(height: 20)

            TextField("Ask anything about this meeting…", text: $ask)
                .textFieldStyle(.plain)
                .focused($askFocused)
                .onSubmit(send)
                .background(Button("") { askFocused = true }.keyboardShortcut("l").hidden())

            notesButton
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    @ViewBuilder private var listenControl: some View {
        switch model.phase {
        case .idle:
            Button(action: model.toggle) {
                Label(model.hasTranscript ? "Resume" : "Start listening", systemImage: "waveform")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .help("Transcribe this meeting (⌘R)")
        case .preparing(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8)
        case .running:
            Button(action: model.toggle) {
                HStack(spacing: 8) {
                    if model.isRecording {
                        Circle().fill(.red).frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    }
                    Waveform(level: max(model.micLevel, model.callLevel))
                    if let start = model.sessionStart {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(PromptBuilder.timestamp(context.date.timeIntervalSince(start)))
                                .monospacedDigit()
                        }
                    }
                    Image(systemName: "stop.fill").imageScale(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(.white)
                .background(Color.green.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(sourcesHelp + " — click to stop (⌘R)")
        case .stopping:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finishing…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
        }
    }

    private var sourcesHelp: String {
        let sources = model.callAudioActive ? "Listening to your mic and call audio" : "Listening to your mic"
        return model.isRecording ? sources + ", recording audio" : sources
    }

    /// Opt-in: also keep an audio file of the session.
    private var recordToggle: some View {
        Button { recordAudio.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: recordAudio ? "record.circle.fill" : "record.circle")
                if recordAudio { Text("Rec").font(.caption.weight(.semibold)) }
            }
            .foregroundStyle(recordAudio ? Color.red : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(recordAudio
              ? "Audio will be recorded when you start. Let everyone know you're recording. Click to turn off."
              : "Also record audio (off). Transcripts are always kept.")
    }

    @ViewBuilder private var notesButton: some View {
        if model.enhancing {
            Button("Stop", systemImage: "stop.circle", action: model.cancelNotes)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        } else {
            Button(action: model.generateNotes) {
                Label(model.current.enhancedNotes.isEmpty ? "Generate notes" : "Regenerate", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(model.isRunning || (!model.hasTranscript && model.current.userNotes.isEmpty))
            .keyboardShortcut("e")
            .help("Turn your notes and the transcript into meeting notes (⌘E)")
        }
    }

    private func send() {
        let q = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        showSuggestions = true
        model.requestCue(.custom, customQuestion: q)
        ask = ""
    }
}

/// Animated bars for the live-listening pill.
private struct Waveform: View {
    let level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4) { i in
                    let wobble = (sin(t * 7 + Double(i) * 1.3) + 1) / 2
                    let h = 4 + CGFloat(Double(level) * (0.5 + wobble * 0.5)) * 10
                    Capsule().fill(.white).frame(width: 2.5, height: h)
                }
            }
            .frame(height: 14)
        }
    }
}

// MARK: - Transcript page

/// The full transcript as a readable page, with the recording's player when there is one.
private struct TranscriptPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: RecordingPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.current.recordings.isEmpty { PlayerBar() }
            HStack(spacing: 12) {
                Text("\(model.utterances.count) lines · \(wordCount) words")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc", action: model.copyTranscript)
                Button("Export…", systemImage: "square.and.arrow.up", action: exportText)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!model.hasTranscript)

            if !model.hasTranscript {
                Text(model.isRunning ? "Listening… lines appear as people talk." : "No transcript for this note.")
                    .foregroundStyle(.secondary)
            }
            let origin = model.utterances.first.map { $0.spokenAt ?? $0.startedAt } ?? model.current.createdAt
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(model.utterances.enumerated()), id: \.element.id) { i, u in
                    TranscriptLine(utterance: u, origin: origin,
                                   showsSpeaker: i == 0 || model.utterances[i - 1].speaker != u.speaker)
                }
                ForEach(Speaker.allCases, id: \.self) { speaker in
                    if let text = model.partial[speaker], !text.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("").frame(width: 44)
                            Text(text).italic().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var wordCount: Int {
        model.utterances.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    private func exportText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(model.current.displayTitle) transcript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PromptBuilder.formatTranscript(model.utterances).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.errorMessage = "Couldn't export the transcript: \(error.localizedDescription)"
        }
    }
}

private struct TranscriptLine: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: RecordingPlayer
    let utterance: Utterance
    let origin: Date
    let showsSpeaker: Bool

    var body: some View {
        let playback = model.current.playback(for: utterance)
        VStack(alignment: .leading, spacing: 3) {
            if showsSpeaker {
                Text(utterance.speaker.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(utterance.speaker == .you ? Color.accentColor : .primary)
                    .padding(.leading, 56)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                let stamp = PromptBuilder.timestamp((utterance.spokenAt ?? utterance.startedAt).timeIntervalSince(origin))
                if let playback {
                    Button { player.play(playback.recording, url: model.recordingURL(playback.recording), from: playback.offset) } label: {
                        Label(stamp, systemImage: "play.fill").labelStyle(StampLabel()).monospacedDigit()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                    .frame(width: 44, alignment: .trailing)
                    .help("Play from here")
                } else {
                    Text(stamp).monospacedDigit().font(.caption).foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing)
                }
                Text(utterance.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct StampLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small).font(.system(size: 7))
            configuration.title
        }
    }
}

private struct PlayerBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: RecordingPlayer
    @State private var scrub: Double?

    private var recording: Recording? { player.loaded ?? model.current.recordings.first }

    var body: some View {
        if let r = recording {
            HStack(spacing: 10) {
                Button {
                    if player.loaded == nil { player.play(r, url: model.recordingURL(r)) } else { player.toggle() }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .buttonStyle(.borderless)
                Slider(value: Binding(get: { scrub ?? player.time }, set: { scrub = $0 }), in: 0...max(r.duration, 1)) { editing in
                    if !editing, let t = scrub {
                        if player.loaded == nil { player.play(r, url: model.recordingURL(r), from: t) } else { player.seek(to: t) }
                        scrub = nil
                    }
                }
                .controlSize(.small)
                Text("\(PromptBuilder.timestamp(scrub ?? player.time)) / \(PromptBuilder.timestamp(r.duration))")
                    .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                if model.current.recordings.count > 1 {
                    Menu {
                        ForEach(model.current.recordings) { rec in
                            Button(rec.startedAt.formatted(date: .omitted, time: .shortened)
                                   + " · " + PromptBuilder.timestamp(rec.duration)) {
                                player.play(rec, url: model.recordingURL(rec))
                            }
                        }
                    } label: { Image(systemName: "list.bullet") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("\(model.current.recordings.count) recordings — one per listening session")
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.recordingURL(r)]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show the audio file in Finder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Transcript drawer

private struct TranscriptDrawer: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcript").font(.headline)
                if model.isRunning {
                    Text("Live").font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
                Spacer()
                Button("Copy", systemImage: "doc.on.doc", action: model.copyTranscript)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!model.hasTranscript)
                    .help("Copy transcript")
                Button { isPresented = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if !model.hasTranscript && model.partial.isEmpty {
                Text(model.isRunning ? "Listening… the transcript appears as people talk."
                     : "No transcript yet. **Mic** is you; **call audio** is whatever your Mac plays — Zoom, Meet, Teams. Use headphones so your mic doesn't pick up the other side.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(model.utterances.enumerated()), id: \.element.id) { i, u in
                                Bubble(utterance: u, showsSpeaker: i == 0 || model.utterances[i - 1].speaker != u.speaker)
                            }
                            ForEach(Speaker.allCases, id: \.self) { speaker in
                                if let text = model.partial[speaker], !text.isEmpty {
                                    Bubble(utterance: Utterance(speaker: speaker, text: text, startedAt: Date()),
                                           showsSpeaker: model.utterances.last?.speaker != speaker, isPartial: true)
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(14)
                    }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: model.utterances.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: model.partial) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .frame(height: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
    }
}

/// Chat-style line: you on the right, everyone else on the left.
private struct Bubble: View {
    @EnvironmentObject var model: AppModel
    let utterance: Utterance
    let showsSpeaker: Bool
    var isPartial = false
    @State private var hovering = false

    private var mine: Bool { utterance.speaker == .you }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if showsSpeaker {
                Text(utterance.speaker.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if mine { Spacer(minLength: 60) }
                Text(utterance.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(isPartial ? .secondary : .primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(mine ? Color.accentColor.opacity(isPartial ? 0.08 : 0.16) : Color.primary.opacity(isPartial ? 0.03 : 0.06),
                                in: RoundedRectangle(cornerRadius: 12))
                if !mine, !isPartial {
                    Button { model.requestCue(.respond, focus: utterance) } label: { Image(systemName: "sparkles") }
                        .buttonStyle(.borderless)
                        .help("Suggest a reply to this")
                        .opacity(hovering ? 1 : 0)
                }
                if !mine { Spacer(minLength: 60) }
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .onHover { hovering = $0 }
    }
}

// MARK: - Suggestions inspector

private struct SuggestionsInspector: View {
    @State private var tab: Tab = .suggestions
    enum Tab: String, CaseIterable { case suggestions = "Suggestions", context = "Context" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch tab {
            case .suggestions: CuesPane()
            case .context: ContextPane()
            }
        }
    }
}

private struct CuesPane: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.autoRespond) private var autoRespond = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.requestCue(.respond) } label: {
                    Label("Answer", systemImage: "text.bubble")
                }
                .keyboardShortcut("1", modifiers: .command)
                .help("Suggest a reply to the latest from the other side (⌘1)")
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
            .controlSize(.small)
            .disabled(!model.hasTranscript)
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Toggle("Suggest automatically when someone asks a question", isOn: $autoRespond)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.cues.isEmpty {
                        Text(model.hasTranscript
                             ? "Suggestions appear here — tap Answer, Ask, or Recap, or ask anything from the bottom bar."
                             : "While you listen, Vantage suggests answers and questions here. Add context so suggestions use real details.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(.top, 40)
                            .padding(.horizontal, 16)
                    }
                    ForEach(model.cues) { CueCardView(card: $0) }
                }
                .padding(10)
            }
        }
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
                Text(EnhancedNotesView.inline(card.text))
                    .font(.system(size: 13.5))
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
}

private struct ContextPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context for \(model.mode.shortTitle.lowercased()) mode").font(.headline)
            Text("Sent to Claude with suggestions and notes so they use real details instead of guesses. Saved separately for each mode.")
                .font(.callout).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.contextNotes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if model.contextNotes.isEmpty {
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
                Text("\(model.contextNotes.split(whereSeparator: \.isWhitespace).count) words")
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
                model.contextNotes += (model.contextNotes.isEmpty ? "" : "\n\n") + "## \(url.lastPathComponent)\n\(text)"
            }
        }
    }
}

// MARK: - Banners

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
        .background(.orange.opacity(0.12))
        .background(.background)
    }
}

private struct SavedBanner: View {
    let url: URL
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Saved a copy to \(url.lastPathComponent)").lineLimit(1)
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.green.opacity(0.08))
        .background(.background)
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
