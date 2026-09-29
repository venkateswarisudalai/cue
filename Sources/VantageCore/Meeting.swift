import Foundation

/// One note in the sidebar: what the user typed, the transcript, and Claude's enhanced notes.
public struct Meeting: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var mode: Mode
    /// What the user typed during the meeting.
    public var userNotes: String
    /// Claude's write-up of the user's notes plus the transcript. Empty until generated.
    public var enhancedNotes: String
    public var utterances: [Utterance]
    /// Seconds spent listening, across every time the meeting was resumed.
    public var duration: TimeInterval
    /// Audio recordings, one per listening session, when the user turned recording on.
    public var recordings: [Recording]

    public init(id: UUID = UUID(), title: String = "", createdAt: Date = Date(), mode: Mode = .meeting,
                userNotes: String = "", enhancedNotes: String = "", utterances: [Utterance] = [],
                duration: TimeInterval = 0, recordings: [Recording] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.mode = mode
        self.userNotes = userNotes
        self.enhancedNotes = enhancedNotes
        self.utterances = utterances
        self.duration = duration
        self.recordings = recordings
    }

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, mode, userNotes, enhancedNotes, utterances, duration, recordings
    }

    /// Notes saved before recordings existed decode with none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        mode = try c.decode(Mode.self, forKey: .mode)
        userNotes = try c.decode(String.self, forKey: .userNotes)
        enhancedNotes = try c.decode(String.self, forKey: .enhancedNotes)
        utterances = try c.decode([Utterance].self, forKey: .utterances)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        recordings = try c.decodeIfPresent([Recording].self, forKey: .recordings) ?? []
    }

    /// The recording holding the moment `u` was spoken, and the offset into it.
    public func playback(for u: Utterance) -> (recording: Recording, offset: TimeInterval)? {
        // Utterances without an audio timestamp were stamped when their first fragment finished.
        let at = u.spokenAt ?? u.startedAt.addingTimeInterval(-2)
        for r in recordings.reversed() where at >= r.startedAt.addingTimeInterval(-1) {
            let offset = at.timeIntervalSince(r.startedAt)
            return offset <= r.duration + 1 ? (r, max(0, min(offset, r.duration))) : nil
        }
        return nil
    }

    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "New note" : t
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty
            && userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && enhancedNotes.isEmpty && utterances.isEmpty
    }

    /// A title Claude wrote as the first `# heading` of the enhanced notes.
    public static func suggestedTitle(fromNotes notes: String) -> String? {
        for line in notes.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            guard s.hasPrefix("# ") else { return nil }
            let title = s.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }
}

public struct Recording: Equatable, Codable, Sendable, Identifiable {
    /// File name inside the meeting's recordings folder.
    public var file: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var id: String { file }

    public init(file: String, startedAt: Date, duration: TimeInterval) {
        self.file = file
        self.startedAt = startedAt
        self.duration = duration
    }
}

/// Line-level Markdown for rendering notes: headings, bullets (nested by indent), paragraphs.
/// Inline styling (bold, links) is left to `AttributedString(markdown:)` on each block's text.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case bullet(depth: Int, text: String)
    case numbered(depth: Int, marker: String, text: String)
    case paragraph(String)
    case divider

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "***" { flush(); out.append(.divider); continue }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
               line[hashes] == " " {
                flush()
                let level = line.distance(from: line.startIndex, to: hashes)
                out.append(.heading(level: min(level, 3), text: String(line[hashes...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                out.append(.bullet(depth: indent / 2, text: String(line.dropFirst(2))))
                continue
            }
            if let dot = line.firstIndex(where: { !$0.isNumber }), dot != line.startIndex,
               line[dot] == ".", line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                flush()
                out.append(.numbered(depth: indent / 2, marker: String(line[...dot]),
                                     text: String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            paragraph.append(line)
        }
        flush()
        return out
    }
}
