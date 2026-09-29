import AppKit
import VantageCore
import PDFKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.provider) private var provider = Provider.auto.rawValue
    @AppStorage(Pref.model) private var modelID = Pref.defaultModel
    @AppStorage(Pref.effort) private var effort = "low"
    @AppStorage(Pref.cliPath) private var cliPath = ""
    @AppStorage(Pref.saveSessions) private var saveSessions = true
    @AppStorage(Pref.recordAudio) private var recordAudio = false
    @AppStorage(Pref.autoEnhance) private var autoEnhance = true
    @AppStorage(Pref.detectMeetings) private var detectMeetings = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""

    @State private var apiKey = ""
    @State private var keySaved = Keychain.read() != nil
    @State private var testOutput = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("AI") {
                Picker("Use", selection: $provider) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text(backendSummary).font(.caption).foregroundStyle(.secondary)

                if provider == Provider.compatible.rawValue {
                    CompatibleProviderSettings()
                } else {
                    HStack {
                        SecureField("Anthropic API key", text: $apiKey, prompt: Text(keySaved ? "Saved in Keychain" : "sk-ant-…"))
                        Button(keySaved && apiKey.isEmpty ? "Remove" : "Save") {
                            Keychain.write(apiKey)
                            keySaved = Keychain.read() != nil
                            apiKey = ""
                        }
                        .disabled(apiKey.isEmpty && !keySaved)
                    }

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
    @State private var key = ""
    @State private var keySaved = false
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
            HStack {
                SecureField(isCustom ? "API key (if needed)" : "\(provider.name) API key", text: $key,
                            prompt: Text(keySaved ? "Saved in Keychain" : "Paste your key"))
                Button(keySaved && key.isEmpty ? "Remove" : "Save") {
                    Keychain.write(key, account: Keychain.providerAccount(provider.id))
                    keySaved = Keychain.read(Keychain.providerAccount(provider.id)) != nil
                    key = ""
                }
                .disabled(key.isEmpty && !keySaved)
            }
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
        key = ""
        keySaved = Keychain.read(Keychain.providerAccount(provider.id)) != nil
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
        let apiKey = key.isEmpty ? Keychain.read(Keychain.providerAccount(provider.id)) : key
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

enum PDFTextExtractor {
    static func text(at url: URL) -> String? {
        PDFDocument(url: url)?.string
    }
}
