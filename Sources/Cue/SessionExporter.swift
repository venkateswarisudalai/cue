import CueCore
import Foundation

struct CueCard: Identifiable, Equatable {
    enum State: Equatable {
        case streaming
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let kind: CueKind
    let title: String
    /// What the cue is about: the question being answered, or the user's typed ask.
    let quote: String?
    let isAuto: Bool
    let createdAt = Date()
    var text = ""
    var state: State = .streaming
}

enum SessionExporter {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cue Sessions", isDirectory: true)
    }

    static func markdown(mode: Mode, startedAt: Date, utterances: [Utterance], cues: [CueCard]) -> String {
        let date = startedAt.formatted(date: .abbreviated, time: .shortened)
        var out = "# \(mode.shortTitle) — \(date)\n\n## Transcript\n\n"
        let origin = utterances.first?.startedAt ?? startedAt
        for u in utterances {
            out += "**[\(PromptBuilder.timestamp(u.startedAt.timeIntervalSince(origin)))] \(u.speaker.label):** \(u.text)\n\n"
        }
        let finished = cues.filter { $0.state == .done }.reversed()
        if !finished.isEmpty {
            out += "## Cues\n\n"
            for c in finished {
                out += "### \(c.title) (\(PromptBuilder.timestamp(c.createdAt.timeIntervalSince(origin))))\n\n"
                if let q = c.quote { out += "> \(q)\n\n" }
                out += c.text + "\n\n"
            }
        }
        return out
    }

    static func save(mode: Mode, startedAt: Date, utterances: [Utterance], cues: [CueCard]) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let url = directory.appendingPathComponent("\(f.string(from: startedAt)) \(mode.shortTitle).md")
        try markdown(mode: mode, startedAt: startedAt, utterances: utterances, cues: cues)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
