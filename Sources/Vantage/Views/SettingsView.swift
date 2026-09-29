import AppKit
import VantageCore
import PDFKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.provider) private var provider = Provider.auto.rawValue
    @AppStorage(Pref.model) private var modelID = Pref.defaultModel
    @AppStorage(Pref.effort) private var effort = "low"
    @AppStorage(Pref.cliPath) private var cliPath = ""
    @AppStorage(Pref.saveSessions) private var saveSessions = true
    @AppStorage(Pref.recordAudio) private var recordAudio = false
    @AppStorage(Pref.autoEnhance) private var autoEnhance = true

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

                TextField("Model", text: $modelID, prompt: Text(Pref.defaultModel))
                Picker("Response speed", selection: $effort) {
                    Text("Fastest").tag("low")
                    Text("Balanced").tag("medium")
                    Text("Thorough").tag("high")
                }
                .pickerStyle(.segmented)

                HStack {
                    Button(testing ? "Testing…" : "Test connection", action: test).disabled(testing)
                    Text(testOutput).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
            }

            Section("Transcription") {
                LabeledContent("Engine", value: "Apple on-device speech (audio never leaves this Mac)")
                LabeledContent("Language", value: Locale.current.identifier)
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

    private var backendSummary: String {
        switch Provider(rawValue: provider) ?? .auto {
        case .auto: "Uses the API key if one is saved, otherwise your Claude Code login."
        case .api: "Billed to your Anthropic API account. Fastest option."
        case .cli: "Uses your Claude Code subscription via the claude command. Adds ~2s per cue."
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

enum PDFTextExtractor {
    static func text(at url: URL) -> String? {
        PDFDocument(url: url)?.string
    }
}
