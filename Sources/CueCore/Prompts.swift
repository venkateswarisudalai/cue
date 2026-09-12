import Foundation

public enum Mode: String, CaseIterable, Codable, Identifiable, Sendable {
    case candidate, interviewer, meeting, sales

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .candidate: "Interview — I'm the candidate"
        case .interviewer: "Interview — I'm interviewing"
        case .meeting: "Meeting"
        case .sales: "Customer / sales call"
        }
    }

    public var shortTitle: String {
        switch self {
        case .candidate: "Candidate"
        case .interviewer: "Interviewer"
        case .meeting: "Meeting"
        case .sales: "Customer call"
        }
    }

    /// Label for the "what do I say now" button.
    public var respondLabel: String {
        self == .interviewer ? "Evaluate" : "Answer"
    }

    public var contextPlaceholder: String {
        switch self {
        case .candidate: "Paste your résumé, the job description, company notes, and stories you want to tell."
        case .interviewer: "Paste the role description, what you're assessing, and the candidate's résumé."
        case .meeting: "Paste the agenda, your goals, open decisions, and who's attending."
        case .sales: "Paste the account notes, product details, pricing guardrails, and known objections."
        }
    }

    var roleBrief: String {
        switch self {
        case .candidate:
            """
            The user is the CANDIDATE in a job interview. "Them" is the interviewer.
            Help the user answer well: concrete, structured (STAR for behavioral questions), \
            grounded in the user's real background from the context notes.
            """
        case .interviewer:
            """
            The user is the INTERVIEWER. "Them" is the candidate.
            Help the user assess answers fairly against the role, spot vague or unsupported claims, \
            and probe with sharp follow-ups. Never suggest illegal or discriminatory questions.
            """
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
        case .respond: mode == .interviewer ? "Evaluate & follow up" : "Suggested answer"
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
        You are Cue, a real-time assistant running beside a live conversation. The user glances \
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

        <context_notes>
        \(notes.isEmpty ? "(none provided)" : notes)
        </context_notes>
        """
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
            switch mode {
            case .interviewer:
                task = """
                Assess the candidate's latest answer.\(quoted)

                Format:
                **Signal:** strong / mixed / weak — one line on why
                **Gaps:** up to 2 bullets on what was vague or missing
                **Follow-up:** the single best probing question to ask next
                """
            default:
                task = """
                Draft what the user should say next.\(quoted)

                Format:
                **Say:** 2–4 sentences in first person, spoken style, ready to read aloud
                **Points:** 2–3 short bullets to expand on if there's time
                If this isn't really a question for the user, reply with one line saying what's \
                happening and whether they need to respond.
                """
            }
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
