import VantageCore
import Foundation
import Security

enum Provider: String, CaseIterable, Identifiable {
    case auto, api, cli, compatible
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Automatic"
        case .api: "Anthropic API key"
        case .cli: "Claude Code login"
        case .compatible: "Other provider or local model"
        }
    }
}

/// UserDefaults keys shared by `@AppStorage` in views and the model.
enum Pref {
    static let mode = "mode"
    static let autoRespond = "autoRespond"
    static let useMic = "useMic"
    static let useCallAudio = "useCallAudio"
    static let provider = "provider"
    static let model = "model"
    static let effort = "effort"
    static let saveSessions = "saveSessions"
    static let cliPath = "cliPath"
    static let floatOnTop = "floatOnTop"
    static let showSuggestions = "showSuggestions"
    static let autoEnhance = "autoEnhance"
    static let recordAudio = "recordAudio"
    static let detectMeetings = "detectMeetings"
    /// Which `CompatibleProvider` the "Other provider" option uses.
    static let compatProvider = "compatProvider"
    static let compatBaseURL = "compatBaseURL"
    static func compatModelKey(_ id: String) -> String { "compatModel.\(id)" }

    static var compatible: CompatibleProvider {
        CompatibleProvider.find(d.string(forKey: compatProvider) ?? "ollama")
    }
    /// The preset's URL, or the one typed in for a custom server.
    static var compatibleBaseURL: String {
        let p = compatible
        return p.id == CompatibleProvider.custom.id ? (d.string(forKey: compatBaseURL) ?? "") : p.baseURL
    }
    static var compatibleModel: String {
        let p = compatible
        let m = d.string(forKey: compatModelKey(p.id))?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? p.defaultModel : m
    }
    static let meetingDefaultApplied = "meetingDefaultApplied"

    static let defaultModel = "claude-opus-5"

    static func register() {
        UserDefaults.standard.register(defaults: [
            mode: Mode.meeting.rawValue,
            autoRespond: true,
            useMic: true,
            useCallAudio: true,
            provider: Provider.auto.rawValue,
            model: defaultModel,
            effort: "low",
            saveSessions: true,
            cliPath: "",
            floatOnTop: false,
            showSuggestions: false,
            autoEnhance: true,
            recordAudio: false,
            detectMeetings: true,
            compatProvider: "ollama",
        ])
        // Vantage opens as a meeting notepad now; move earlier installs off the old candidate default once.
        if !d.bool(forKey: meetingDefaultApplied) {
            d.set(Mode.meeting.rawValue, forKey: mode)
            d.set(true, forKey: meetingDefaultApplied)
        }
    }

    static func notesKey(_ mode: Mode) -> String { "contextNotes.\(mode.rawValue)" }

    static var d: UserDefaults { .standard }
    static var currentModel: String {
        let m = d.string(forKey: model)?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? defaultModel : m
    }
}

enum Keychain {
    static let service = "com.venka.vantage"
    static let apiKeyAccount = "anthropic-api-key"
    static func providerAccount(_ id: String) -> String { "provider-key.\(id)" }

    static func read(_ account: String = apiKeyAccount, service: String = service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    static func write(_ value: String, account: String = apiKeyAccount) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum AppPaths {
    /// Named by bundle ID: an unrelated app already owns "Application Support/vantage".
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.venka.vantage", isDirectory: true)
    }
}

/// The app was called Cue until 2026-09-29. Carries its settings, API key, notes, recordings,
/// and Markdown copies over to Vantage once; the old files are moved, not copied.
enum LegacyMigration {
    static let oldBundleID = "com.venka.cue"
    private static let doneKey = "migratedFromCue"

    static func run() {
        let d = UserDefaults.standard
        if !d.bool(forKey: doneKey) {
            if let old = d.persistentDomain(forName: oldBundleID) {
                for (key, value) in old where d.object(forKey: key) == nil { d.set(value, forKey: key) }
            }
            if Keychain.read() == nil, let key = Keychain.read(service: oldBundleID) { Keychain.write(key) }
            d.set(true, forKey: doneKey)
        }

        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Each move is skipped once done, so this is safe on every launch.
        for (from, to) in [(support.appendingPathComponent("Cue"), AppPaths.support),
                           (docs.appendingPathComponent("Cue Sessions"), docs.appendingPathComponent("Vantage Sessions"))]
        where fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
            try? fm.moveItem(at: from, to: to)
        }
    }
}

enum ClaudeCLI {
    private static var cached: URL??

    /// Finds the `claude` binary. GUI apps don't inherit the shell PATH, so check the usual spots.
    static func locate() -> URL? {
        let override = Pref.d.string(forKey: Pref.cliPath)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        if let cached { return cached }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        var found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
        if found == nil, let shellPath = loginShellLookup() { found = URL(fileURLWithPath: shellPath) }
        cached = .some(found)
        return found
    }

    private static func loginShellLookup() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

enum LLMFactory {
    static var apiKey: String? {
        Keychain.read() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func makeCompatible() throws -> LLMClient {
        let p = Pref.compatible
        let key = Keychain.read(Keychain.providerAccount(p.id))
            ?? ProcessInfo.processInfo.environment["VANTAGE_PROVIDER_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        if p.needsKey && key == nil { throw LLMError.failed("Add your \(p.name) API key in Settings (⌘,).") }
        let model = Pref.compatibleModel
        guard !model.isEmpty else { throw LLMError.failed("Choose a model for \(p.name) in Settings (⌘,).") }
        return CompatibleClient(provider: p, baseURL: Pref.compatibleBaseURL, apiKey: key, model: model)
    }

    static func make() throws -> LLMClient {
        let model = Pref.currentModel
        switch Provider(rawValue: Pref.d.string(forKey: Pref.provider) ?? "") ?? .auto {
        case .compatible:
            return try makeCompatible()
        case .api:
            guard let key = apiKey else { throw LLMError.missingKey }
            return AnthropicAPIClient(apiKey: key, model: model)
        case .cli:
            guard let url = ClaudeCLI.locate() else { throw LLMError.cliNotFound }
            return ClaudeCLIClient(executable: url, model: model)
        case .auto:
            if let key = apiKey { return AnthropicAPIClient(apiKey: key, model: model) }
            if let url = ClaudeCLI.locate() { return ClaudeCLIClient(executable: url, model: model) }
            // A provider the user set up with a key (local servers need an explicit choice).
            if Pref.compatible.needsKey, let client = try? makeCompatible() { return client }
            throw LLMError.noBackend
        }
    }
}
