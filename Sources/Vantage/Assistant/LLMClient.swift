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
        case .noBackend: "No AI backend. Add an Anthropic API key in Settings (⌘,) or install Claude Code."
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
