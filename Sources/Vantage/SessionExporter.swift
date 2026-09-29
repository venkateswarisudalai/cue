import VantageCore
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

/// Meetings as JSON in Application Support — the sidebar's source of truth.
enum MeetingStore {
    static var directory: URL {
        AppPaths.support.appendingPathComponent("Meetings", isDirectory: true)
    }

    private static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    static func loadAll() -> [Meeting] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Meeting.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ meeting: Meeting) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meeting).write(to: url(for: meeting.id), options: .atomic)
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}

/// Human-readable copies in ~/Documents/Vantage Sessions/.
enum SessionExporter {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vantage Sessions", isDirectory: true)
    }

    static func markdown(_ meeting: Meeting, cues: [CueCard]) -> String {
        let date = meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
        var out = "# \(meeting.displayTitle)\n\n_\(meeting.mode.shortTitle) · \(date)_\n\n"
        if !meeting.enhancedNotes.isEmpty {
            out += "## Notes\n\n" + meeting.enhancedNotes.replacingOccurrences(of: "\n# ", with: "\n## ") + "\n\n"
        }
        let mine = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty { out += "## My notes\n\n\(mine)\n\n" }
        out += "## Transcript\n\n"
        let origin = meeting.utterances.first?.startedAt ?? meeting.createdAt
        for u in meeting.utterances {
            out += "**[\(PromptBuilder.timestamp(u.startedAt.timeIntervalSince(origin)))] \(u.speaker.label):** \(u.text)\n\n"
        }
        let finished = cues.filter { $0.state == .done }.reversed()
        if !finished.isEmpty {
            out += "## Suggestions\n\n"
            for c in finished {
                out += "### \(c.title) (\(PromptBuilder.timestamp(c.createdAt.timeIntervalSince(origin))))\n\n"
                if let q = c.quote { out += "> \(q)\n\n" }
                out += c.text + "\n\n"
            }
        }
        return out
    }

    static func save(_ meeting: Meeting, cues: [CueCard]) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let safeTitle = meeting.displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(f.string(from: meeting.createdAt)) \(safeTitle).md")
        try markdown(meeting, cues: cues).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
