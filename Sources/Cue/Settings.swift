import CueCore
import Foundation
import Security

enum Provider: String, CaseIterable, Identifiable {
    case auto, api, cli
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Automatic"
        case .api: "Anthropic API key"
        case .cli: "Claude Code login"
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

    static let defaultModel = "claude-opus-5"

    static func register() {
        UserDefaults.standard.register(defaults: [
            mode: Mode.candidate.rawValue,
            autoRespond: true,
            useMic: true,
            useCallAudio: true,
            provider: Provider.auto.rawValue,
            model: defaultModel,
            effort: "low",
            saveSessions: true,
            cliPath: "",
            floatOnTop: false,
        ])
    }

    static func notesKey(_ mode: Mode) -> String { "contextNotes.\(mode.rawValue)" }

    static var d: UserDefaults { .standard }
    static var currentModel: String {
        let m = d.string(forKey: model)?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? defaultModel : m
    }
}

enum Keychain {
    static let service = "com.venka.cue"
    static let apiKeyAccount = "anthropic-api-key"

    static func read(_ account: String = apiKeyAccount) -> String? {
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

    static func make() throws -> LLMClient {
        let model = Pref.currentModel
        switch Provider(rawValue: Pref.d.string(forKey: Pref.provider) ?? "") ?? .auto {
        case .api:
            guard let key = apiKey else { throw LLMError.missingKey }
            return AnthropicAPIClient(apiKey: key, model: model)
        case .cli:
            guard let url = ClaudeCLI.locate() else { throw LLMError.cliNotFound }
            return ClaudeCLIClient(executable: url, model: model)
        case .auto:
            if let key = apiKey { return AnthropicAPIClient(apiKey: key, model: model) }
            if let url = ClaudeCLI.locate() { return ClaudeCLIClient(executable: url, model: model) }
            throw LLMError.noBackend
        }
    }
}
