import Foundation

public enum Speaker: String, Codable, Sendable, CaseIterable {
    case you, them, room

    public var label: String {
        switch self {
        case .you: "You"
        case .them: "Them"
        case .room: "Room"
        }
    }

    /// Speech from this speaker can contain questions aimed at the user.
    public var isOtherParty: Bool { self != .you }
}

public struct Utterance: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let speaker: Speaker
    public var text: String
    public let startedAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), speaker: Speaker, text: String, startedAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
    }
}

/// Folds a stream of finalized speech fragments into speaker turns.
///
/// Fragments from the same speaker are merged into one utterance unless the
/// speaker paused for longer than `turnGap` or someone else spoke in between.
public struct TranscriptAssembler: Sendable {
    public private(set) var utterances: [Utterance] = []
    public var turnGap: TimeInterval
    /// Continuous speech (a video, a monologue) is split into readable chunks at fragment boundaries.
    public var maxTurnCharacters: Int

    public init(turnGap: TimeInterval = 3.0, maxTurnCharacters: Int = 600) {
        self.turnGap = turnGap
        self.maxTurnCharacters = maxTurnCharacters
    }

    /// Returns the id of the utterance the fragment landed in.
    @discardableResult
    public mutating func appendFinal(_ fragment: String, from speaker: Speaker, at time: Date) -> UUID? {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if var last = utterances.last,
           last.speaker == speaker,
           time.timeIntervalSince(last.updatedAt) <= turnGap,
           last.text.count < maxTurnCharacters {
            last.text += " " + trimmed
            last.updatedAt = time
            utterances[utterances.count - 1] = last
            return last.id
        }
        let u = Utterance(speaker: speaker, text: trimmed, startedAt: time)
        utterances.append(u)
        return u.id
    }

    public mutating func reset() {
        utterances.removeAll()
    }

    /// Removes one fragment from an utterance, dropping the utterance if nothing is left.
    @discardableResult
    public mutating func removeFragment(_ fragment: String, from id: UUID) -> Bool {
        guard let i = utterances.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let range = utterances[i].text.range(of: trimmed, options: .backwards) else { return false }
        var text = utterances[i].text
        text.removeSubrange(range)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.isEmpty {
            utterances.remove(at: i)
        } else {
            utterances[i].text = text
        }
        return true
    }

    /// Most recent utterance from anyone other than the user.
    public var lastOtherPartyUtterance: Utterance? {
        utterances.last { $0.speaker.isOtherParty }
    }
}

/// Speakers (not headphones) leak call audio into the mic, which would
/// duplicate "Them" lines as "You". Drop mic fragments that closely match
/// something the call audio produced moments ago.
public enum EchoFilter {
    public static func isEcho(_ micText: String, recentCallText: [String], threshold: Double = 0.6) -> Bool {
        let mic = words(micText)
        guard mic.count >= 3 else { return false }
        return recentCallText.contains { overlap(mic, words($0)) >= threshold }
    }

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    /// Fraction of the mic words that also appear in the call text.
    static func overlap(_ mic: Set<String>, _ call: Set<String>) -> Double {
        guard !mic.isEmpty else { return 0 }
        return Double(mic.intersection(call).count) / Double(mic.count)
    }
}
