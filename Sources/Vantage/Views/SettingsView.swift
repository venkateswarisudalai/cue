import AppKit
import VantageCore
import PDFKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.provider) private var provider = Provider.auto.rawValue
    @AppStorage(Pref.compatProvider) private var compatProviderID = "ollama"
    @State private var geminiKeySaved = Keychain.read(Keychain.providerAccount("gemini")) != nil
    @AppStorage(Pref.model) private var modelID = Pref.defaultModel
    @AppStorage(Pref.effort) private var effort = "low"
    @AppStorage(Pref.cliPath) private var cliPath = ""
    @AppStorage(Pref.saveSessions) private var saveSessions = true
    @AppStorage(Pref.recordAudio) private var recordAudio = false
    @AppStorage(Pref.autoEnhance) private var autoEnhance = true
    @AppStorage(Pref.detectMeetings) private var detectMeetings = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""

    @State private var testOutput = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("Google Gemini (recommended)") {
                KeyField(label: "Gemini API key", account: Keychain.providerAccount("gemini"),
                         placeholder: "Paste your key", onSave: useGemini)
                VStack(alignment: .leading, spacing: 4) {
                    Text("One free key writes the notes and suggestions. Transcription stays on this Mac.")
                        .foregroundStyle(.secondary)
                    Link("Get a free key (no card) at aistudio.google.com", destination: URL(string: "https://aistudio.google.com/apikey")!)
                }
                .font(.caption)
                if usingGemini {
                    Label("Vantage is using Google Gemini", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                } else if geminiKeySaved {
                    HStack {
                        Text("Your Gemini key is saved, but Vantage is using \(currentAIName).").font(.callout)
                        Spacer()
                        Button("Use Gemini", action: useGemini)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Keychain.didChange)) { _ in
                geminiKeySaved = Keychain.read(Keychain.providerAccount("gemini")) != nil
            }

            Section("AI") {
                Picker("Use", selection: $provider) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text(backendSummary).font(.caption).foregroundStyle(.secondary)

                if provider == Provider.compatible.rawValue {
                    CompatibleProviderSettings()
                } else {
                    KeyField(label: "Anthropic API key", account: Keychain.apiKeyAccount, placeholder: "sk-ant-…")

                    TextField("Claude Code path", text: $cliPath,
                              prompt: Text(ClaudeCLI.locate()?.path ?? "claude not found — enter a path"))

                    TextField("Claude model", text: $modelID, prompt: Text(Pref.defaultModel))
                    Picker("Response speed", selection: $effort) {
                        Text("Fastest").tag("low")
                        Text("Balanced").tag("medium")
                        Text("Thorough").tag("high")
                    }
                    .pickerStyle(.segmented)
                }

                SavedKeysSummary()
                HStack {
                    Button(testing ? "Testing…" : "Test connection", action: test).disabled(testing)
                    Text(testOutput).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
            }

            Section("Transcription") {
                LabeledContent("Engine", value: "Apple on-device speech (audio never leaves this Mac)")
                LabeledContent("Language", value: Locale.current.identifier)
            }

            Section("Call detection") {
                Toggle("Offer to start listening when a call starts", isOn: $detectMeetings)
                Text("When Zoom, Teams, Webex, FaceTime, Slack, or a browser call starts using the microphone, "
                     + "Vantage shows a notification asking whether to start. It never starts listening on its own, "
                     + "and it only checks which apps use the mic, never what they hear.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open Vantage at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { setOpenAtLogin(openAtLogin) }
                if !loginError.isEmpty {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Recording") {
                Toggle("Record audio while listening", isOn: $recordAudio)
                Text("Saves an .m4a of your mic and call audio with each note; click a transcript timestamp to play from there. "
                     + "Recording people can require their consent — tell everyone before you start.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sessions") {
                Toggle("Write notes automatically when listening stops", isOn: $autoEnhance)
                Toggle("Also save a Markdown copy to Documents/Vantage Sessions", isOn: $saveSessions)
                Button("Open Sessions Folder") {
                    try? FileManager.default.createDirectory(at: SessionExporter.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(SessionExporter.directory)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = ""
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var usingGemini: Bool {
        provider == Provider.compatible.rawValue && compatProviderID == "gemini" && geminiKeySaved
    }

    private var currentAIName: String {
        provider == Provider.compatible.rawValue
            ? CompatibleProvider.find(compatProviderID).name.components(separatedBy: " (").first ?? compatProviderID
            : (Provider(rawValue: provider) ?? .auto).title
    }

    /// Saving a key here should mean Gemini is used; "Automatic" would otherwise prefer Claude.
    private func useGemini() {
        provider = Provider.compatible.rawValue
        compatProviderID = "gemini"
        geminiKeySaved = Keychain.read(Keychain.providerAccount("gemini")) != nil
    }

    private var backendSummary: String {
        switch Provider(rawValue: provider) ?? .auto {
        case .auto: "Uses an Anthropic API key if one is saved, then your Claude Code login, then another provider you've added a key for."
        case .api: "Billed to your Anthropic API account. Fastest option."
        case .cli: "Uses your Claude Code subscription via the claude command. Adds ~2s per cue."
        case .compatible: "Bring your own key for OpenRouter, Groq, Gemini, OpenAI and more — or run an open model on this Mac for free with Ollama or LM Studio."
        }
    }

    private func test() {
        testing = true
        testOutput = ""
        Task {
            do {
                let client = try LLMFactory.make()
                var text = ""
                for try await chunk in client.stream(system: "Reply in five words or fewer.", user: "Say hello to Vantage.", effort: "low") {
                    text += chunk
                }
                testOutput = "✓ \(client.displayName): \(text)"
            } catch {
                testOutput = "✗ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}

/// Provider picker, key, server URL, and model for OpenAI-compatible services.
private struct CompatibleProviderSettings: View {
    @AppStorage(Pref.compatProvider) private var providerID = "ollama"
    @AppStorage(Pref.compatBaseURL) private var customURL = ""
    @State private var model = ""
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelsMessage = ""

    private var provider: CompatibleProvider { CompatibleProvider.find(providerID) }
    private var isCustom: Bool { provider.id == CompatibleProvider.custom.id }
    private var baseURL: String { isCustom ? customURL : provider.baseURL }

    var body: some View {
        Picker("Provider", selection: $providerID) {
            ForEach(CompatibleProvider.all) { Text($0.name).tag($0.id) }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(provider.note).foregroundStyle(.secondary)
            if let url = URL(string: provider.setupURL), !provider.setupURL.isEmpty {
                Link(provider.needsKey ? "Get a \(provider.name) API key" : "Download \(provider.name.components(separatedBy: " (").first ?? provider.name)",
                     destination: url)
            }
        }
        .font(.caption)

        if isCustom {
            TextField("Server URL", text: $customURL, prompt: Text("http://localhost:8000/v1"))
        }
        if provider.needsKey || isCustom {
            KeyField(label: isCustom ? "API key (if needed)" : "\(provider.name.components(separatedBy: " (").first ?? provider.name) API key",
                     account: Keychain.providerAccount(provider.id), placeholder: "Paste your key")
                .id(provider.id)
        }
        HStack {
            TextField("Model", text: $model, prompt: Text(provider.defaultModel.isEmpty ? "model id" : provider.defaultModel))
                .onSubmit(saveModel)
                .onChange(of: model) { saveModel() }
            if !models.isEmpty {
                Menu("Choose") {
                    ForEach(models, id: \.self) { m in Button(m) { model = m } }
                }
                .fixedSize()
            }
            Button(loadingModels ? "Loading…" : "Load models", action: loadModels)
                .disabled(loadingModels || baseURL.isEmpty)
        }
        if !modelsMessage.isEmpty {
            Text(modelsMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        EmptyView()
            .onAppear(perform: reload)
            .onChange(of: providerID) { reload() }
    }

    private func reload() {
        model = Pref.d.string(forKey: Pref.compatModelKey(provider.id)) ?? ""
        models = []
        modelsMessage = ""
    }

    private func saveModel() {
        Pref.d.set(model.trimmingCharacters(in: .whitespaces), forKey: Pref.compatModelKey(provider.id))
    }

    private func loadModels() {
        loadingModels = true
        modelsMessage = ""
        let url = baseURL
        let apiKey = Keychain.read(Keychain.providerAccount(provider.id))
        Task {
            do {
                models = try await CompatibleClient.listModels(baseURL: url, apiKey: apiKey)
                modelsMessage = models.isEmpty ? "The server didn't list any models." : "\(models.count) models — pick one from Choose."
            } catch {
                modelsMessage = provider.isLocal
                    ? "Couldn't reach \(provider.name) at \(url) — is it running? (\(error.localizedDescription))"
                    : "Couldn't load models: \(error.localizedDescription)"
            }
            loadingModels = false
        }
    }
}

/// One API key: shows the saved key masked (Show reveals it), and a field to paste a new one
/// with an eye toggle. Keys live in the login Keychain under com.venka.vantage.
struct KeyField: View {
    let label: String
    let account: String
    let placeholder: String
    var onSave: (() -> Void)? = nil
    @State private var draft = ""
    @State private var saved: String?
    @State private var revealSaved = false
    @State private var revealDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let saved {
                HStack(spacing: 8) {
                    Text(label)
                    Spacer()
                    Text(revealSaved ? saved : Self.mask(saved))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(revealSaved ? "Hide" : "Show") { revealSaved.toggle() }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(saved, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy key")
                    Button("Remove", role: .destructive) {
                        Keychain.write("", account: account)
                        reload()
                    }
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Group {
                    if revealDraft {
                        TextField(saved == nil ? label : "Replace key", text: $draft, prompt: Text(placeholder))
                    } else {
                        SecureField(saved == nil ? label : "Replace key", text: $draft, prompt: Text(placeholder))
                    }
                }
                .onSubmit(save)
                Button { revealDraft.toggle() } label: { Image(systemName: revealDraft ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                    .help(revealDraft ? "Hide what you're typing" : "Show what you're typing")
                Button("Save", action: save).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: reload)
    }

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Keychain.write(draft, account: account)
        draft = ""
        revealDraft = false
        reload()
        onSave?()
    }

    private func reload() {
        saved = Keychain.read(account)
        revealSaved = false
    }

    /// `sk-ant-api03-…` → `sk-a••••••••9xQf`: enough to recognize, not to use.
    static func mask(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(4)) + String(repeating: "•", count: 8) + String(key.suffix(4))
    }
}

/// Which providers have a key saved, so nobody has to click through each one to find out.
struct SavedKeysSummary: View {
    @State private var names: [String] = []

    var body: some View {
        LabeledContent("Saved keys") {
            Text(names.isEmpty ? "None yet" : names.joined(separator: ", ")).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: Keychain.didChange)) { _ in reload() }
    }

    private func reload() {
        var found: [String] = []
        if Keychain.read() != nil { found.append("Anthropic") }
        for p in CompatibleProvider.all where Keychain.read(Keychain.providerAccount(p.id)) != nil {
            found.append(p.name.components(separatedBy: " (").first ?? p.name)
        }
        names = found
    }
}

enum PDFTextExtractor {
    static func text(at url: URL) -> String? {
        PDFDocument(url: url)?.string
    }
}
