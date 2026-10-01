import Foundation

public enum Mode: String, CaseIterable, Codable, Identifiable, Sendable {
    case meeting, sales

    public var id: String { rawValue }

    /// Notes saved under the old interview modes open as meetings.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Mode(rawValue: raw) ?? .meeting
    }

    public var title: String {
        switch self {
        case .meeting: "Meeting"
        case .sales: "Customer call"
        }
    }

    public var shortTitle: String { title }

    public var contextPlaceholder: String {
        switch self {
        case .meeting: "Paste the agenda, your goals, open decisions, and who's attending."
        case .sales: "Paste the account notes, product details, pricing guardrails, and known objections."
        }
    }

    var roleBrief: String {
        switch self {
        case .meeting:
            """
            The user is a participant in a work meeting. "Them" is everyone else on the call.
            Help the user contribute clearly, keep the meeting on track, surface risks, \
            and pin down owners, decisions, and dates.
            """
        case .sales:
            """
            The user is on a customer or sales call. "Them" is the customer.
            Help the user understand the customer's real need, handle objections honestly, \
            and move toward a clear next step. Never suggest misleading claims.
            """
        }
    }
}

public enum CueKind: String, Codable, Sendable {
    case respond, ask, recap, custom

    public func title(for mode: Mode) -> String {
        switch self {
        case .respond: "Suggested answer"
        case .ask: "Questions to ask"
        case .recap: "Recap"
        case .custom: "Your question"
        }
    }
}

public enum PromptBuilder {
    /// Keep prompts well under the context window even for very long calls.
    public static let maxTranscriptCharacters = 400_000

    /// Stable per session (mode + notes), so it caches across requests.
    public static func system(mode: Mode, contextNotes: String) -> String {
        let notes = contextNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are Vantage, a real-time assistant running beside a live conversation. The user glances \
        at your output while talking, so every word must earn its place.

        \(mode.roleBrief)

        The transcript comes from on-device speech recognition: expect missing punctuation, \
        misheard words, and cut-off sentences. Infer intent sensibly; don't comment on transcription errors.
        "You" is the user's microphone. "Them" is the other side of the call. "Room" is a single \
        microphone picking up everyone in the room.

        Rules:
        - Lead with the thing the user can say or do right now. No preamble, no restating the question.
        - Short lines and bullets. Bold only the few words that matter most.
        - Use only facts from the context notes and transcript. Never invent employers, numbers, \
        projects, or credentials. Where a specific example is needed and none is known, write a \
        bracketed placeholder like [your example] instead of making one up.
        - Measured, natural tone. No superlatives or hype.

        \(contextBlock(notes))
        """
    }

    /// Left out when empty: an empty block at the end of the prompt gets copied into the reply by small models.
    static func contextBlock(_ notes: String) -> String {
        notes.isEmpty ? "" : """
        Background the user wrote beforehand. Use it for facts; never copy it or its tags into your reply.
        <context_notes>
        \(notes)
        </context_notes>
        """
    }

    /// Removes prompt blocks or tags a model echoed back (Markdown can render `context_notes` as `contextnotes`).
    public static func stripPromptTags(_ text: String) -> String {
        var t = text.replacing(#/(?is)<(context_?notes|my_?notes|transcript)>.*?</\1>/#, with: "")
        t = t.replacing(#/(?i)</?(context_?notes|my_?notes|transcript)>/#, with: "")
        while let last = t.last, last.isWhitespace { t.removeLast() }
        return t
    }

    public static func userMessage(
        kind: CueKind,
        mode: Mode,
        utterances: [Utterance],
        focus: Utterance? = nil,
        customQuestion: String? = nil
    ) -> String {
        let transcript = formatTranscript(utterances)
        var task: String
        switch kind {
        case .respond:
            let target = focus?.text ?? utterances.last(where: { $0.speaker.isOtherParty })?.text
            let quoted = target.map { "\n\nRespond to this, the latest from the other side:\n\"\($0)\"" } ?? ""
                task = """
                Draft what the user should say next.\(quoted)

                Format:
                **Say:** 2–4 sentences in first person, spoken style, ready to read aloud
                **Points:** 2–3 short bullets to expand on if there's time
                If this isn't really a question for the user, reply with one line saying what's \
                happening and whether they need to respond.
                """
        case .ask:
            task = """
            Suggest the 3 best questions the user could ask at this moment, most valuable first. \
            Build on what was just said; avoid anything already answered.
            Format: numbered, each a single question, then " — " and a few words on why it helps.
            """
        case .recap:
            task = """
            Recap the conversation so far.
            Format:
            **Summary:** 2–3 bullets
            **Decisions / commitments:** bullets, or "none yet"
            **Open questions:** bullets, or "none"
            **Next steps:** bullets with owners where known
            """
        case .custom:
            task = (customQuestion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return """
        <transcript>
        \(transcript.isEmpty ? "(nothing has been said yet)" : transcript)
        </transcript>

        \(task)
        """
    }

    /// Post-meeting write-up: the user's rough notes, fleshed out and checked against the transcript.
    public static func notesSystem(mode: Mode, contextNotes: String) -> String {
        let notes = contextNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You write meeting notes. You get the user's own rough notes and a transcript from \
        on-device speech recognition (expect misheard words and missing punctuation; infer intent, \
        never comment on transcription quality). "You" is the user; "Them" is everyone else on the \
        call; "Room" is a single microphone picking up everyone in the room.

        \(mode.roleBrief)

        \(contextBlock(notes))

        Rules:
        - The user's notes show what they care about. Keep every point they wrote, in their order, \
        expanded with the relevant detail from the transcript. Add other important points after.
        - Only facts from the transcript, the user's notes, and the context notes. Never invent \
        names, numbers, dates, or commitments. If something is unclear, say so briefly.
        - Scannable: short bullets, nested where it helps. Bold only key names, numbers, and decisions.
        - Measured, factual tone. No filler, no hype, no preamble.
        - No separate "Decisions" or "Action items" sections: state a decision or a task (with its \
        owner and date) in the topic it belongs to.

        Output Markdown only, in this shape:
        # <short title for the meeting, 3–7 words>
        ### <topic heading>
        - bullets (as many topic sections as the conversation needs)
        """
    }

    public static func notesUser(title: String, userNotes: String, utterances: [Utterance]) -> String {
        let transcript = formatTranscript(utterances)
        let mine = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(named.isEmpty ? "" : "The user titled this meeting: \(named)\n\n")<my_notes>
        \(mine.isEmpty ? "(the user took no notes)" : mine)
        </my_notes>

        <transcript>
        \(transcript.isEmpty ? "(no transcript)" : transcript)
        </transcript>

        Write the meeting notes.
        """
    }

    public static func formatTranscript(_ utterances: [Utterance]) -> String {
        guard let origin = utterances.first?.startedAt else { return "" }
        var lines = utterances.map { u in
            "[\(timestamp(u.startedAt.timeIntervalSince(origin)))] \(u.speaker.label): \(u.text)"
        }
        var total = lines.reduce(0) { $0 + $1.count + 1 }
        var dropped = false
        while total > maxTranscriptCharacters, lines.count > 1 {
            total -= lines.removeFirst().count + 1
            dropped = true
        }
        if dropped { lines.insert("[earlier conversation omitted for length]", at: 0) }
        return lines.joined(separator: "\n")
    }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
