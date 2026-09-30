import Foundation

public enum StreamEvent: Equatable, Sendable {
    case text(String)
    case stop(reason: String?)
    case failure(String)
}

/// Parses Claude streaming output into text deltas.
///
/// Handles both the Messages API's server-sent events (`data: {...}` lines)
/// and the Claude Code CLI's `--output-format stream-json` lines, which wrap
/// the same events in `{"type":"stream_event","event":{...}}`.
public enum StreamParser {
    /// One line of an SSE body from `POST /v1/messages` with `stream: true`.
    public static func parseSSELine(_ line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let obj = json(payload) else { return nil }
        return parseMessageEvent(obj)
    }

    /// One line of `claude -p --output-format stream-json --include-partial-messages`.
    public static func parseCLILine(_ line: String) -> StreamEvent? {
        guard let obj = json(line), let type = obj["type"] as? String else { return nil }
        switch type {
        case "stream_event":
            guard let event = obj["event"] as? [String: Any] else { return nil }
            return parseMessageEvent(event)
        case "result":
            if (obj["is_error"] as? Bool) == true {
                return .failure((obj["result"] as? String) ?? "Claude CLI reported an error")
            }
            return nil
        default:
            return nil
        }
    }

    static func parseMessageEvent(_ event: [String: Any]) -> StreamEvent? {
        switch event["type"] as? String {
        case "content_block_delta":
            // Only text reaches the user; thinking deltas and fallback blocks are skipped.
            guard let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "message_delta":
            guard let delta = event["delta"] as? [String: Any],
                  let reason = delta["stop_reason"] as? String else { return nil }
            return .stop(reason: reason)
        case "error":
            let err = event["error"] as? [String: Any]
            return .failure((err?["message"] as? String) ?? "Stream error")
        default:
            return nil
        }
    }

    /// Pulls a readable message out of a non-200 API response body.
    public static func errorMessage(fromBody body: String, status: Int) -> String {
        // Most APIs send {"error":{…}}; Google wraps it in an array: [{"error":{…}}].
        let obj = json(body) ?? (jsonArray(body)?.first)
        if let err = obj?["error"] as? [String: Any], let message = err["message"] as? String {
            return "HTTP \(status): \(message)"
        }
        return "HTTP \(status)" + (body.isEmpty ? "" : ": \(body.prefix(300))")
    }

    static func jsonArray(_ s: String) -> [[String: Any]]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    static func json(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
