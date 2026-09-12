import Foundation

/// Decides when the other side has asked something worth answering.
///
/// Interviewers (and videos) rarely go quiet after a question, so waiting for silence misses
/// most of them. Instead: arm on a question fragment, fire after `settleDelay` unless more of
/// the question arrives, and fire immediately once the speaker moves on to a non-question.
public struct QuestionTrigger: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Wait `settleDelay`, then call `fireIfStillPending(token:)`.
        case arm(token: Int)
        case fire(question: String)
    }

    public var settleDelay: TimeInterval
    private var pending: (token: Int, text: String)?
    private var nextToken = 0
    private var answered: [String] = []

    public init(settleDelay: TimeInterval = 1.2) {
        self.settleDelay = settleDelay
    }

    /// `turn` is the speaker's current turn including this fragment; its tail becomes the quoted question.
    public mutating func otherPartyFinal(fragment: String, turn: String) -> Action {
        if QuestionDetector.isQuestion(fragment) {
            nextToken += 1
            pending = (nextToken, Self.tail(turn))
            return .arm(token: nextToken)
        }
        guard let p = pending else { return .none }
        pending = nil
        return fire(p.text)
    }

    public mutating func fireIfStillPending(token: Int) -> Action {
        guard let p = pending, p.token == token else { return .none }
        pending = nil
        return fire(p.text)
    }

    public mutating func reset() {
        pending = nil
        answered = []
    }

    private mutating func fire(_ text: String) -> Action {
        let key = text.lowercased()
        guard !answered.contains(key) else { return .none }
        answered.append(key)
        return .fire(question: text)
    }

    /// The last few sentences of a turn — enough context for the question without the whole monologue.
    static func tail(_ text: String, maxSentences: Int = 3, maxCharacters: Int = 400) -> String {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?".contains(ch) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current) }
        var out = sentences.suffix(maxSentences).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > maxCharacters {
            let cut = out.suffix(maxCharacters)
            out = "…" + (cut.firstIndex(of: " ").map { String(cut[cut.index(after: $0)...]) } ?? String(cut))
        }
        return out
    }
}

/// Keeps call audio that leaks into the mic (laptop speakers) out of the "You" transcript,
/// regardless of which transcriber finishes first.
///
/// Mic fragments are held for `hold` seconds and dropped if call audio explains them. Call
/// audio can finalize later than that, so fragments already shown are remembered for `window`
/// seconds and retracted if matching call audio arrives afterwards.
public struct EchoGate: Sendable {
    public struct Held: Equatable, Sendable {
        public let id: Int
        public let text: String
        public let at: Date
    }

    public struct Retraction: Equatable, Sendable {
        public let utterance: UUID
        public let text: String
    }

    public var hold: TimeInterval
    public var window: TimeInterval
    /// Fragments under three words ("Great.", "Next question.") only count as echo when the exact
    /// phrase was in call audio this recently, so a genuine "Yes." isn't dropped.
    public var shortPhraseWindow: TimeInterval = 5

    private var held: [Held] = []
    private var recentCall: [(text: String, at: Date)] = []
    private var shown: [(utterance: UUID, text: String, at: Date)] = []
    private var nextID = 0

    public init(hold: TimeInterval = 2.0, window: TimeInterval = 15) {
        self.hold = hold
        self.window = window
    }

    /// Queues a mic fragment and returns its id, or nil if it already matches recent call audio.
    public mutating func mic(_ text: String, at time: Date) -> Int? {
        prune(now: time)
        if matchesRecentCall(text, at: time) { return nil }
        nextID += 1
        held.append(Held(id: nextID, text: text, at: time))
        return nextID
    }

    /// Records call audio and discards held mic fragments it explains. Returns how many were dropped.
    @discardableResult
    public mutating func call(_ text: String, at time: Date) -> Int {
        prune(now: time)
        recentCall.append((text, time))
        let echoes = Set(held.filter { matchesRecentCall($0.text, at: $0.at) }.map(\.id))
        held.removeAll { echoes.contains($0.id) }
        return echoes.count
    }

    /// Removes and returns a held fragment once its hold expires; nil if it was dropped as echo.
    public mutating func release(id: Int) -> Held? {
        guard let i = held.firstIndex(where: { $0.id == id }) else { return nil }
        return held.remove(at: i)
    }

    /// Remembers a mic fragment that made it into the transcript, in case matching call audio arrives late.
    public mutating func didShowMic(_ text: String, utterance: UUID, at time: Date) {
        shown.append((utterance, text, time))
    }

    /// Shown mic fragments that recent call audio now explains. Each is returned once.
    public mutating func takeRetractions() -> [Retraction] {
        let echoes = shown.indices.filter { matchesRecentCall(shown[$0].text, at: shown[$0].at) }
        let out = echoes.map { Retraction(utterance: shown[$0].utterance, text: shown[$0].text) }
        for i in echoes.reversed() { shown.remove(at: i) }
        return out
    }

    /// `extra` is call audio still being transcribed (the in-progress partial).
    public func matchesRecentCall(_ text: String, at time: Date = Date(), extra: String? = nil) -> Bool {
        let words = Self.words(text)
        guard !words.isEmpty else { return false }

        if words.count >= 3 {
            // Transcribers segment differently; one mic fragment can span several call fragments.
            let texts = recentCall.map(\.text)
            var candidates = texts + [texts.joined(separator: " ")]
            if let extra, !extra.isEmpty { candidates.append(extra) }
            return EchoFilter.isEcho(text, recentCallText: candidates)
        }

        let phrase = " " + words.joined(separator: " ") + " "
        var nearby = recentCall.filter { abs(time.timeIntervalSince($0.at)) <= shortPhraseWindow }.map(\.text)
        if let extra, !extra.isEmpty { nearby.append(extra) }
        return nearby.contains { (" " + Self.words($0).joined(separator: " ") + " ").contains(phrase) }
    }

    public mutating func reset() {
        held = []
        recentCall = []
        shown = []
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private mutating func prune(now: Date) {
        recentCall.removeAll { now.timeIntervalSince($0.at) > window }
        shown.removeAll { now.timeIntervalSince($0.at) > window }
    }
}
