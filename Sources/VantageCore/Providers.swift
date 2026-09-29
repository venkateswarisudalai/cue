import Foundation

/// A service that speaks the OpenAI chat-completions API — hosted open models, other
/// frontier labs, or a model running on this Mac. One client covers all of them.
public struct CompatibleProvider: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// Base URL up to and including the version path; `/chat/completions` is appended.
    public let baseURL: String
    public let defaultModel: String
    public let needsKey: Bool
    /// Where to get a key, or how to set the local server up.
    public let setupURL: String
    public let note: String

    public var isLocal: Bool { baseURL.contains("localhost") || baseURL.contains("127.0.0.1") }

    public static let custom = CompatibleProvider(
        id: "custom", name: "Custom (OpenAI-compatible)", baseURL: "", defaultModel: "",
        needsKey: false, setupURL: "",
        note: "Any server with an OpenAI-style /chat/completions endpoint: vLLM, llama.cpp server, LiteLLM, Azure, a company gateway.")

    public static let all: [CompatibleProvider] = [
        CompatibleProvider(id: "ollama", name: "Ollama (free, on this Mac)", baseURL: "http://localhost:11434/v1",
                           defaultModel: "llama3.2", needsKey: false, setupURL: "https://ollama.com/download",
                           note: "Free and fully private — nothing leaves your Mac. Install Ollama, then run `ollama pull llama3.2`. Bigger models (e.g. qwen3:14b) write better notes if your Mac has 16 GB+ of memory."),
        CompatibleProvider(id: "lmstudio", name: "LM Studio (free, on this Mac)", baseURL: "http://localhost:1234/v1",
                           defaultModel: "", needsKey: false, setupURL: "https://lmstudio.ai",
                           note: "Free and fully private. Load a model in LM Studio and start its local server, then press Load models."),
        CompatibleProvider(id: "gemini", name: "Google Gemini (free tier)", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                           defaultModel: "gemini-2.5-flash", needsKey: true, setupURL: "https://aistudio.google.com/apikey",
                           note: "Best free choice: a free key from Google AI Studio, no card, and it handles hour-long meetings. Google may use free-tier data to improve its products."),
        CompatibleProvider(id: "groq", name: "Groq (free tier)", baseURL: "https://api.groq.com/openai/v1",
                           defaultModel: "llama-3.3-70b-versatile", needsKey: true, setupURL: "https://console.groq.com/keys",
                           note: "Free key, no card, very fast open models. The free tier caps tokens per minute, so notes for long meetings can hit the limit."),
        CompatibleProvider(id: "openrouter", name: "OpenRouter (free models)", baseURL: "https://openrouter.ai/api/v1",
                           defaultModel: "meta-llama/llama-3.3-70b-instruct:free", needsKey: true,
                           setupURL: "https://openrouter.ai/keys",
                           note: "One key for hundreds of models. Models ending in :free cost nothing but allow a limited number of requests per day."),
        CompatibleProvider(id: "mistral", name: "Mistral (free tier)", baseURL: "https://api.mistral.ai/v1",
                           defaultModel: "mistral-small-latest", needsKey: true, setupURL: "https://console.mistral.ai/api-keys",
                           note: "Free \"Experiment\" plan (phone verification) with rate limits; includes Mistral's open-weight models."),
        CompatibleProvider(id: "together", name: "Together AI", baseURL: "https://api.together.xyz/v1",
                           defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo", needsKey: true,
                           setupURL: "https://api.together.ai/settings/api-keys",
                           note: "Paid, pay-as-you-go hosted open models: Llama, Qwen, DeepSeek, Mistral."),
        CompatibleProvider(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
                           defaultModel: "gpt-4.1-mini", needsKey: true, setupURL: "https://platform.openai.com/api-keys",
                           note: "Paid. GPT models with your OpenAI API key."),
        CompatibleProvider(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1",
                           defaultModel: "deepseek-chat", needsKey: true, setupURL: "https://platform.deepseek.com/api_keys",
                           note: "Paid, low-cost DeepSeek models."),
        custom,
    ]

    public static func find(_ id: String) -> CompatibleProvider {
        all.first { $0.id == id } ?? all[0]
    }

    /// `base` + `path`, tolerating a trailing slash or a pasted full `/chat/completions` URL.
    public static func endpoint(base: String, path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["/chat/completions", "/models", "/"] where b.hasSuffix(suffix) {
            b = String(b.dropLast(suffix.count))
        }
        guard !b.isEmpty, let url = URL(string: b + path), url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }
}

/// Ollama's own `/api/chat`. Its OpenAI-style endpoint can't set the context window, and the
/// default (a few thousand tokens) silently truncates a long meeting transcript.
public enum OllamaChat {
    /// `http://localhost:11434/v1` → `http://localhost:11434/api/chat`.
    public static func endpoint(base: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/v1") { b.removeLast(3) }
        return URL(string: b + "/api/chat")
    }

    /// Room for the whole prompt plus a long answer, in steps that keep model reloads rare.
    public static func contextWindow(forPromptCharacters chars: Int) -> Int {
        let needed = chars / 3 + 4096  // ~3 characters per token, conservatively
        for size in [8192, 16384, 32768, 65536, 131072] where needed <= size { return size }
        return 131072
    }

    /// One NDJSON line of a streaming `/api/chat` response.
    public static func parseLine(_ line: String) -> StreamEvent? {
        guard let obj = StreamParser.json(line) else { return nil }
        if let err = obj["error"] as? String { return .failure(err) }
        if let message = obj["message"] as? [String: Any], let text = message["content"] as? String, !text.isEmpty {
            return .text(text)
        }
        return (obj["done"] as? Bool) == true ? .stop(reason: obj["done_reason"] as? String) : nil
    }
}

/// Streaming (`data: {...}` server-sent events) and error parsing for OpenAI-style APIs.
public enum ChatCompletionsParser {
    public static func parseSSELine(_ line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .stop(reason: nil) }
        guard let obj = StreamParser.json(payload) else { return nil }
        if let err = obj["error"] as? [String: Any] {
            return .failure((err["message"] as? String) ?? "Stream error")
        }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return nil }
        // Only the answer reaches the user; reasoning models' `reasoning`/`reasoning_content` is skipped.
        if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
            return .text(text)
        }
        if let reason = choice["finish_reason"] as? String {
            return .stop(reason: reason)
        }
        return nil
    }

    /// Model ids from `GET /models` (OpenAI and Ollama shape: `{"data":[{"id":...}]}`).
    public static func modelIDs(fromBody body: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = obj["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { $0["id"] as? String }.sorted()
    }
}
