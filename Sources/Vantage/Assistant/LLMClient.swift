import VantageCore
import Foundation

enum LLMError: LocalizedError {
    case noBackend
    case missingKey
    case cliNotFound
    case refused
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noBackend: "No AI backend. In Settings (⌘,), add an API key (Anthropic, OpenRouter, Groq, Gemini, OpenAI…), pick a local model (Ollama, LM Studio), or install Claude Code."
        case .missingKey: "Add your Anthropic API key in Settings (⌘,)."
        case .cliNotFound: "Couldn't find the `claude` command. Set its path in Settings (⌘,)."
        case .refused: "Claude declined this request."
        case .failed(let message): message
        }
    }
}

protocol LLMClient: Sendable {
    var displayName: String { get }
    func stream(system: String, user: String, effort: String) -> AsyncThrowingStream<String, Error>
}

/// Messages API over HTTPS with server-sent events.
struct AnthropicAPIClient: LLMClient {
    let apiKey: String
    let model: String
    var displayName: String { "Anthropic API · \(model)" }

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func stream(system: String, user: String, effort: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: makeRequest(system: system, user: user, effort: effort))
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw LLMError.failed(StreamParser.errorMessage(fromBody: body, status: status))
                    }
                    for try await line in bytes.lines {
                        switch StreamParser.parseSSELine(line) {
                        case .text(let t): continuation.yield(t)
                        case .stop(let reason) where reason == "refusal": throw LLMError.refused
                        case .failure(let message): throw LLMError.failed(message)
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeRequest(system: String, user: String, effort: String) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16_000,
            "stream": true,
            // Cache the mode brief + context notes; they're identical across a session's requests.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
        ]
        var betas: [String] = []
        if !model.contains("haiku") {
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": effort]
        }
        if model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable-5") {
            // If a safety classifier declines, retry server-side on Anthropic's recommended fallback model.
            body["fallbacks"] = "default"
            betas.append("server-side-fallback-2026-07-01")
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty { request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

/// Runs `claude -p` so Vantage can use an existing Claude Code login with no API key.
/// Tools, MCP servers, settings, and session history are all disabled for these calls.
struct ClaudeCLIClient: LLMClient {
    let executable: URL
    let model: String
    var displayName: String { "Claude Code · \(model)" }

    func stream(system: String, user: String, effort: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "-p", "--output-format", "stream-json", "--include-partial-messages", "--verbose",
                "--model", model, "--effort", effort, "--system-prompt", system,
                "--tools", "", "--setting-sources", "", "--strict-mcp-config",
                "--disable-slash-commands", "--no-session-persistence",
            ]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            process.environment = env

            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            let task = Task {
                do {
                    try process.run()
                    stdin.fileHandleForWriting.write(Data(user.utf8))
                    try stdin.fileHandleForWriting.close()

                    var sawText = false
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        switch StreamParser.parseCLILine(line) {
                        case .text(let t):
                            sawText = true
                            continuation.yield(t)
                        case .stop(let reason) where reason == "refusal": throw LLMError.refused
                        case .failure(let message): throw LLMError.failed(message)
                        default: break
                        }
                    }
                    process.waitUntilExit()
                    if process.terminationStatus != 0 && !sawText {
                        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        throw LLMError.failed("claude exited \(process.terminationStatus): \(err.prefix(300))")
                    }
                    continuation.finish()
                } catch {
                    if process.isRunning { process.terminate() }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// OpenAI-style `/chat/completions` streaming: OpenRouter, Groq, Gemini, OpenAI, Ollama, LM Studio…
struct CompatibleClient: LLMClient {
    let provider: CompatibleProvider
    let baseURL: String
    let apiKey: String?
    let model: String
    var displayName: String { "\(provider.name) · \(model)" }

    func stream(system: String, user: String, effort: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: makeRequest(system: system, user: user))
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw LLMError.failed(StreamParser.errorMessage(fromBody: body, status: status))
                    }
                    for try await line in bytes.lines {
                        switch ChatCompletionsParser.parseSSELine(line) {
                        case .text(let t): continuation.yield(t)
                        case .failure(let message): throw LLMError.failed(message)
                        default: break
                        }
                    }
                    continuation.finish()
                } catch let error as URLError where provider.isLocal && error.code == .cannotConnectToHost {
                    continuation.finish(throwing: LLMError.failed(
                        "Couldn't reach \(provider.name) at \(baseURL). Is it running? (\(provider.setupURL))"))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeRequest(system: String, user: String) throws -> URLRequest {
        guard let url = CompatibleProvider.endpoint(base: baseURL, path: "/chat/completions") else {
            throw LLMError.failed("Set a valid server URL for \(provider.name) in Settings (⌘,).")
        }
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "temperature": 0.3,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Local models can take a while to load on first use.
        request.timeoutInterval = provider.isLocal ? 300 : 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        request.setValue("Vantage", forHTTPHeaderField: "x-title")  // OpenRouter's app attribution
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Models the server offers, for the Settings picker.
    static func listModels(baseURL: String, apiKey: String?) async throws -> [String] {
        guard let url = CompatibleProvider.endpoint(base: baseURL, path: "/models") else {
            throw LLMError.failed("Enter a valid server URL first.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw LLMError.failed(StreamParser.errorMessage(fromBody: String(decoding: data, as: UTF8.self), status: status))
        }
        return ChatCompletionsParser.modelIDs(fromBody: data)
    }
}
