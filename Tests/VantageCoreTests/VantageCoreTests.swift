import Foundation
import Testing
@testable import VantageCore

@Suite struct TranscriptAssemblerTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func mergesFragmentsFromSameSpeakerWithinGap() {
        var a = TranscriptAssembler(turnGap: 3)
        a.appendFinal("Tell me about", from: .them, at: t0)
        a.appendFinal("a hard outage.", from: .them, at: t0.addingTimeInterval(1.5))
        #expect(a.utterances.count == 1)
        #expect(a.utterances[0].text == "Tell me about a hard outage.")
    }

    @Test func splitsOnPauseLongerThanGap() {
        var a = TranscriptAssembler(turnGap: 3)
        a.appendFinal("First thought.", from: .them, at: t0)
        a.appendFinal("Second thought.", from: .them, at: t0.addingTimeInterval(4))
        #expect(a.utterances.count == 2)
    }

    @Test func splitsWhenSpeakerChanges() {
        var a = TranscriptAssembler()
        a.appendFinal("Question?", from: .them, at: t0)
        a.appendFinal("Answer.", from: .you, at: t0.addingTimeInterval(0.5))
        a.appendFinal("Follow up?", from: .them, at: t0.addingTimeInterval(1))
        #expect(a.utterances.map(\.speaker) == [.them, .you, .them])
        #expect(a.lastOtherPartyUtterance?.text == "Follow up?")
    }

    @Test func ignoresBlankFragments() {
        var a = TranscriptAssembler()
        #expect(a.appendFinal("   ", from: .you, at: t0) == nil)
        #expect(a.utterances.isEmpty)
    }
}

@Suite struct EchoFilterTests {
    @Test func flagsMicTextThatRepeatsCallAudio() {
        let call = ["So how did you handle the database migration last year?"]
        #expect(EchoFilter.isEcho("how did you handle the database migration", recentCallText: call))
    }

    @Test func keepsGenuineReplies() {
        let call = ["So how did you handle the database migration last year?"]
        #expect(!EchoFilter.isEcho("we ran both schemas side by side for two weeks", recentCallText: call))
    }

    @Test func ignoresVeryShortMicText() {
        #expect(!EchoFilter.isEcho("yeah okay", recentCallText: ["yeah okay sure"]))
    }
}

@Suite struct QuestionDetectorTests {
    @Test(arguments: [
        "What does your deploy pipeline look like?",
        "walk me through a time you disagreed with your manager",
        "So, tell me about yourself",
        "That makes sense. Can you explain how the cache is invalidated",
        "okay um describe your on-call rotation",
    ])
    func detectsQuestions(_ text: String) {
        #expect(QuestionDetector.isQuestion(text))
    }

    @Test(arguments: [
        "Thanks, that was really helpful.",
        "We shipped the migration in March.",
        "ok",
        "I think what matters is the rollout plan.",
    ])
    func ignoresStatements(_ text: String) {
        #expect(!QuestionDetector.isQuestion(text))
    }
}

@Suite struct StreamParserTests {
    @Test func parsesSSETextDelta() {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#
        #expect(StreamParser.parseSSELine(line) == .text("Hi"))
    }

    @Test func skipsThinkingDeltasAndEventLines() {
        let thinking = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#
        #expect(StreamParser.parseSSELine(thinking) == nil)
        #expect(StreamParser.parseSSELine("event: content_block_delta") == nil)
    }

    @Test func parsesStopReasonAndErrors() {
        let stop = #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{}}"#
        #expect(StreamParser.parseSSELine(stop) == .stop(reason: "refusal"))
        let err = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        #expect(StreamParser.parseSSELine(err) == .failure("Overloaded"))
    }

    @Test func parsesCLIStreamJSON() {
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ong"}},"session_id":"x"}"#
        #expect(StreamParser.parseCLILine(delta) == .text("ong"))
        let result = #"{"type":"result","is_error":true,"result":"Not logged in"}"#
        #expect(StreamParser.parseCLILine(result) == .failure("Not logged in"))
        #expect(StreamParser.parseCLILine(#"{"type":"system","subtype":"init"}"#) == nil)
    }

    @Test func extractsAPIErrorMessage() {
        let body = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        #expect(StreamParser.errorMessage(fromBody: body, status: 401) == "HTTP 401: invalid x-api-key")
    }
}

/// Sequences taken from a real session: a YouTube interview that never pauses after its questions.
@Suite struct QuestionTriggerTests {
    let setup = "Moving on, the next scenario-based question is, you have multiple environments, dev, stage, prod, for your application, and you want to use the same code for all these environments."

    @Test func firesWhenSpeakerMovesOnWithoutPausing() {
        var t = QuestionTrigger()
        #expect(t.otherPartyFinal(fragment: setup, turn: setup) == .none)
        let turn = setup + " can you do that?"
        #expect(t.otherPartyFinal(fragment: "can you do that?", turn: turn) == .arm(token: 1))
        let action = t.otherPartyFinal(fragment: "So according to the question, there are different environments.", turn: turn + " So according to the question")
        guard case .fire(let question) = action else {
            Issue.record("expected fire, got \(action)")
            return
        }
        #expect(question.hasSuffix("can you do that?"))
        #expect(question.contains("same code for all these environments"))
    }

    @Test func firesAfterSettleDelayWhenNothingElseArrives() {
        var t = QuestionTrigger()
        guard case .arm(let token) = t.otherPartyFinal(fragment: "How would you structure the modules?", turn: "How would you structure the modules?") else {
            Issue.record("expected arm")
            return
        }
        #expect(t.fireIfStillPending(token: token) == .fire(question: "How would you structure the modules?"))
        #expect(t.fireIfStillPending(token: token) == .none)
    }

    @Test func laterQuestionFragmentReplacesStaleTimer() {
        var t = QuestionTrigger()
        #expect(t.otherPartyFinal(fragment: "What is a module?", turn: "What is a module?") == .arm(token: 1))
        #expect(t.otherPartyFinal(fragment: "And how is it versioned?", turn: "What is a module? And how is it versioned?") == .arm(token: 2))
        #expect(t.fireIfStillPending(token: 1) == .none)
        #expect(t.fireIfStillPending(token: 2) == .fire(question: "What is a module? And how is it versioned?"))
    }

    @Test func doesNotAnswerTheSameQuestionTwice() {
        var t = QuestionTrigger()
        _ = t.otherPartyFinal(fragment: "Why Terraform?", turn: "Why Terraform?")
        #expect(t.otherPartyFinal(fragment: "Okay.", turn: "Why Terraform? Okay.") == .fire(question: "Why Terraform?"))
        _ = t.otherPartyFinal(fragment: "Why Terraform?", turn: "Why Terraform?")
        #expect(t.otherPartyFinal(fragment: "Okay.", turn: "Why Terraform? Okay.") == .none)
    }

    @Test func quotesOnlyTheTailOfALongTurn() {
        let long = (1...20).map { "Sentence number \($0) about state files." }.joined(separator: " ") + " How do you lock state?"
        let tail = QuestionTrigger.tail(long)
        #expect(tail.count <= 401)
        #expect(tail.hasSuffix("How do you lock state?"))
        #expect(!tail.contains("number 1 "))
    }
}

@Suite struct EchoGateTests {
    let t0 = Date(timeIntervalSince1970: 5_000)
    let line = "you have multiple environments dev stage prod for your application and you want to use the same code"

    @Test func dropsMicEchoThatArrivesBeforeCallAudio() {
        var g = EchoGate()
        let id = g.mic(line, at: t0)
        #expect(id != nil)
        #expect(g.call(line + " can you do that", at: t0.addingTimeInterval(0.4)) == 1)
        #expect(g.release(id: id!) == nil)
    }

    @Test func dropsMicEchoThatArrivesAfterCallAudio() {
        var g = EchoGate()
        g.call(line, at: t0)
        #expect(g.mic(line, at: t0.addingTimeInterval(0.3)) == nil)
    }

    @Test func dropsEchoSpanningSeveralCallFragments() {
        var g = EchoGate()
        g.call("you have multiple environments dev stage prod", at: t0)
        g.call("for your application and you want to use the same code", at: t0.addingTimeInterval(1))
        #expect(g.mic(line, at: t0.addingTimeInterval(1.2)) == nil)
    }

    @Test func releasesGenuineSpeech() {
        var g = EchoGate()
        let id = g.mic("I would use one root module with a tfvars file per environment", at: t0)
        g.call("can you do that", at: t0.addingTimeInterval(0.5))
        #expect(g.release(id: id!)?.text == "I would use one root module with a tfvars file per environment")
    }
}

/// Call audio can finalize seconds after the mic's copy of the same words has been shown.
@Suite struct LateEchoTests {
    let t0 = Date(timeIntervalSince1970: 9_000)

    @Test func retractsShownMicLineWhenMatchingCallAudioArrivesLate() {
        var g = EchoGate()
        var a = TranscriptAssembler()
        a.appendFinal("The answer is to use workspaces.", from: .them, at: t0)
        let id = a.appendFinal("Great. Next question.", from: .you, at: t0.addingTimeInterval(1))!
        g.didShowMic("Great. Next question.", utterance: id, at: t0.addingTimeInterval(1))
        g.call("The answer is to use workspaces. Great. Next question.", at: t0.addingTimeInterval(4))
        let retractions = g.takeRetractions()
        #expect(retractions.count == 1)
        for r in retractions { a.removeFragment(r.text, from: r.utterance) }
        #expect(a.utterances.map(\.speaker) == [.them])
        let again = g.takeRetractions()
        #expect(again.isEmpty)
    }

    @Test func keepsShownGenuineSpeech() {
        var g = EchoGate()
        g.didShowMic("I would split state per environment", utterance: UUID(), at: t0)
        g.call("Great. Next question.", at: t0.addingTimeInterval(1))
        let retractions = g.takeRetractions()
        #expect(retractions.isEmpty)
    }

    @Test func dropsShortEchoFragments() {
        var g = EchoGate()
        g.call("The answer is workspaces. Great. Next question.", at: t0)
        let great = g.mic("Great.", at: t0.addingTimeInterval(1))
        let next = g.mic("Next question.", at: t0.addingTimeInterval(1.5))
        #expect(great == nil)
        #expect(next == nil)
    }

    @Test func retractsShortShownFragmentWhenCallAudioArrivesLate() {
        var g = EchoGate()
        g.didShowMic("Great.", utterance: UUID(), at: t0)
        g.call("The answer is workspaces. Great. Next question.", at: t0.addingTimeInterval(3))
        let retractions = g.takeRetractions()
        #expect(retractions.map(\.text) == ["Great."])
    }

    @Test func keepsShortGenuineReplies() {
        var g = EchoGate()
        g.call("Do you use Terraform?", at: t0)
        let yes = g.mic("Yes.", at: t0.addingTimeInterval(1))
        #expect(yes != nil)
        // An old "great" from the call doesn't swallow the user's "Great." much later.
        g.call("Great to meet you all.", at: t0.addingTimeInterval(2))
        let later = g.mic("Great.", at: t0.addingTimeInterval(12))
        #expect(later != nil)
    }

    @Test func removesOnlyTheEchoedFragmentFromAMergedTurn() {
        var a = TranscriptAssembler()
        let id = a.appendFinal("I think workspaces are fine.", from: .you, at: t0)!
        a.appendFinal("Great. Next question.", from: .you, at: t0.addingTimeInterval(1))
        let removed = a.removeFragment("Great. Next question.", from: id)
        #expect(removed)
        #expect(a.utterances.first?.text == "I think workspaces are fine.")
    }
}

@Suite struct VocabularyTests {
    @Test func extractsNamesAcronymsAndJargonFromNotes() {
        let notes = "Led the migration from Porter to EKS at Unbound Security. Wrote Go services on client-go and K8s operators."
        let terms = Vocabulary.terms(from: notes)
        for expected in ["Porter", "EKS", "Unbound", "Security", "K8s"] {
            #expect(terms.contains(expected), "missing \(expected)")
        }
        #expect(!terms.contains("Led"), "sentence-initial capital isn't a name")
    }

    @Test func notesComeFirstAndBuiltInsAreDeduped() {
        let terms = Vocabulary.terms(from: "We run kubernetes on AWS.")
        #expect(terms.first == "AWS")
        #expect(terms.filter { $0.lowercased() == "aws" }.count == 1)
        #expect(terms.contains("Kubernetes"))
    }

    @Test func respectsLimit() {
        #expect(Vocabulary.terms(from: "", limit: 5).count == 5)
    }
}

@Suite struct PromptBuilderTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func formatsTranscriptWithRelativeTimestamps() {
        let us = [
            Utterance(speaker: .them, text: "Why this role?", startedAt: t0),
            Utterance(speaker: .you, text: "Because platform work.", startedAt: t0.addingTimeInterval(75)),
        ]
        #expect(PromptBuilder.formatTranscript(us) == "[0:00] Them: Why this role?\n[1:15] You: Because platform work.")
    }

    @Test func respondQuotesTheLatestOtherPartyLine() {
        let us = [
            Utterance(speaker: .them, text: "How do you handle incidents?", startedAt: t0),
            Utterance(speaker: .you, text: "Good question.", startedAt: t0.addingTimeInterval(2)),
        ]
        let msg = PromptBuilder.userMessage(kind: .respond, mode: .sales, utterances: us)
        #expect(msg.contains("\"How do you handle incidents?\""))
        #expect(msg.contains("**Say:**"))
    }

    @Test func onlyMeetingAndCustomerCallModes() throws {
        #expect(Mode.allCases.map(\.title) == ["Meeting", "Customer call"])
        // Notes saved under the removed interview modes still open, as meetings.
        let legacy = try JSONDecoder().decode([Mode].self, from: Data(#"["candidate","interviewer","sales"]"#.utf8))
        #expect(legacy == [.meeting, .meeting, .sales])
    }

    @Test func systemPromptEmbedsNotesAndStaysStable() {
        let a = PromptBuilder.system(mode: .meeting, contextNotes: "Agenda: Q3 budget")
        let b = PromptBuilder.system(mode: .meeting, contextNotes: "Agenda: Q3 budget")
        #expect(a == b)
        #expect(a.contains("Agenda: Q3 budget"))
    }

    @Test func dropsOldestLinesWhenTranscriptIsHuge() {
        let long = String(repeating: "word ", count: 50_000)
        let us = (0..<10).map { Utterance(speaker: .them, text: long, startedAt: t0.addingTimeInterval(Double($0))) }
        let out = PromptBuilder.formatTranscript(us)
        #expect(out.count <= PromptBuilder.maxTranscriptCharacters + 100)
        #expect(out.hasPrefix("[earlier conversation omitted for length]"))
    }

    @Test func timestampFormats() {
        #expect(PromptBuilder.timestamp(59) == "0:59")
        #expect(PromptBuilder.timestamp(3725) == "1:02:05")
    }
}

@Suite struct TranscriptCleanerTests {
    @Test(arguments: [
        ("um so I I think we should uh ship it", "So I think we should ship it"),
        ("we tried that , and it failed .", "We tried that, and it failed."),
        ("it worked uh.", "It worked."),
        ("i'm not sure. i think so", "I'm not sure. I think so"),
        ("The the cache was cold", "The cache was cold"),
        ("Revenue grew 3.5 percent", "Revenue grew 3.5 percent"),
    ])
    func cleans(raw: String, expected: String) {
        #expect(TranscriptCleaner.clean(raw) == expected)
    }

    @Test func isIdempotent() {
        let once = TranscriptCleaner.clean("um, so the the plan is uh fine , right")
        #expect(TranscriptCleaner.clean(once) == once)
    }

    @Test func keepsDeliberateRepeats() {
        #expect(TranscriptCleaner.clean("Very, very important") == "Very, very important")
    }

    @Test func joinsFragmentsNaturally() {
        #expect(TranscriptCleaner.join("We moved the service", "And then it broke.") == "We moved the service and then it broke.")
        #expect(TranscriptCleaner.join("It broke.", "then we fixed it") == "It broke. Then we fixed it")
        #expect(TranscriptCleaner.join("talk to the", "the platform team") == "talk to the platform team")
        #expect(TranscriptCleaner.join("We met", "Priya yesterday") == "We met Priya yesterday")
    }

    @Test func assemblerCleansAndStillRetractsEchoes() {
        var a = TranscriptAssembler()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let id = a.appendFinal("um I think workspaces are fine.", from: .you, at: t0)!
        a.appendFinal("great. next question.", from: .you, at: t0.addingTimeInterval(1))
        #expect(a.utterances[0].text == "I think workspaces are fine. Great. Next question.")
        let removed = a.removeFragment("great. next question.", from: id)
        #expect(removed)
        #expect(a.utterances[0].text == "I think workspaces are fine.")
    }
}

@Suite struct MeetingTests {
    @Test func roundTripsThroughJSON() throws {
        let m = Meeting(title: "Sync", mode: .meeting, userNotes: "a",
                        utterances: [Utterance(speaker: .them, text: "Hi.", startedAt: Date(timeIntervalSince1970: 5))])
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(Meeting.self, from: e.encode(m))
        #expect(back.title == "Sync" && back.utterances.map(\.text) == ["Hi."] && back.mode == .meeting)
    }

    @Test func emptiness() {
        #expect(Meeting().isEmpty)
        #expect(!Meeting(userNotes: "x").isEmpty)
        #expect(Meeting().displayTitle == "New note")
    }

    @Test func takesTitleFromFirstHeading() {
        #expect(Meeting.suggestedTitle(fromNotes: "\n# Payments cutover\n### A\n- b") == "Payments cutover")
        #expect(Meeting.suggestedTitle(fromNotes: "### Topic\n- b") == nil)
    }

    @Test func parsesMarkdownBlocks() {
        let md = """
        ### Decisions
        - Ship **Tuesday**
          - Porter as rollback
        1. First
        Plain line
        continues here

        ---
        """
        #expect(MarkdownBlock.parse(md) == [
            .heading(level: 3, text: "Decisions"),
            .bullet(depth: 0, text: "Ship **Tuesday**"),
            .bullet(depth: 1, text: "Porter as rollback"),
            .numbered(depth: 0, marker: "1.", text: "First"),
            .paragraph("Plain line continues here"),
            .divider,
        ])
    }

    @Test func notesPromptIncludesUserNotesAndTranscript() {
        let u = [Utterance(speaker: .them, text: "Ship Tuesday.", startedAt: Date())]
        let msg = PromptBuilder.notesUser(title: "", userNotes: "rollback?", utterances: u)
        #expect(msg.contains("rollback?") && msg.contains("Them: Ship Tuesday."))
        #expect(PromptBuilder.notesSystem(mode: .meeting, contextNotes: "").contains("Action items"))
    }
}

@Suite struct RecordingPlaybackTests {
    let t0 = Date(timeIntervalSince1970: 50_000)

    @Test func mapsLinesToTheRecordingThatHoldsThem() {
        let first = Recording(file: "a.m4a", startedAt: t0, duration: 600)
        let second = Recording(file: "b.m4a", startedAt: t0.addingTimeInterval(3600), duration: 300)
        let m = Meeting(recordings: [first, second])
        let early = Utterance(speaker: .them, text: "x", startedAt: t0.addingTimeInterval(95), spokenAt: t0.addingTimeInterval(90))
        #expect(m.playback(for: early)?.recording == first)
        #expect(m.playback(for: early)?.offset == 90)
        let late = Utterance(speaker: .you, text: "y", startedAt: t0.addingTimeInterval(3700), spokenAt: t0.addingTimeInterval(3660))
        #expect(m.playback(for: late)?.recording == second)
        // Between sessions (no audio was recorded then).
        let gap = Utterance(speaker: .you, text: "z", startedAt: t0.addingTimeInterval(1800), spokenAt: t0.addingTimeInterval(1800))
        #expect(m.playback(for: gap) == nil)
    }

    @Test func oldMeetingJSONWithoutRecordingsStillLoads() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"t","createdAt":"2026-09-01T10:00:00Z","mode":"candidate","userNotes":"","enhancedNotes":"","utterances":[],"duration":0}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let m = try d.decode(Meeting.self, from: Data(json.utf8))
        #expect(m.recordings.isEmpty && m.mode == .meeting)
    }
}

@Suite struct MeetingDetectorTests {
    let t0 = Date(timeIntervalSince1970: 70_000)

    @Test func recognizesCallAppsAndHelpers() {
        #expect(MeetingApp.from(bundleID: "us.zoom.xos")?.name == "Zoom")
        #expect(MeetingApp.from(bundleID: "com.google.Chrome.helper")?.promptTitle == "Call detected in Chrome")
        #expect(MeetingApp.from(bundleID: "com.microsoft.teams2")?.promptTitle == "Teams call detected")
        #expect(MeetingApp.from(bundleID: "com.apple.VoiceMemos") == nil)
        #expect(MeetingApp.from(bundleID: "us.zoomer.other") == nil)
    }

    @Test func promptsOnceAfterTheMicStaysBusy() {
        var d = MeetingDetector(confirmDelay: 3, endDelay: 12)
        #expect(d.update(micUsers: ["us.zoom.xos"], listening: false, now: t0) == .none)
        #expect(d.update(micUsers: ["us.zoom.xos"], listening: false, now: t0.addingTimeInterval(2)) == .none)
        let zoom = MeetingApp.from(bundleID: "us.zoom.xos")!
        #expect(d.update(micUsers: ["us.zoom.xos"], listening: false, now: t0.addingTimeInterval(4)) == .started(zoom))
        #expect(d.update(micUsers: ["us.zoom.xos"], listening: false, now: t0.addingTimeInterval(30)) == .none)
    }

    @Test func ignoresQuickMicChecksAndOtherApps() {
        var d = MeetingDetector(confirmDelay: 3, endDelay: 12)
        #expect(d.update(micUsers: ["us.zoom.xos"], listening: false, now: t0) == .none)
        #expect(d.update(micUsers: [], listening: false, now: t0.addingTimeInterval(14)) == .none)
        #expect(d.update(micUsers: ["com.apple.VoiceMemos"], listening: false, now: t0.addingTimeInterval(20)) == .none)
        #expect(d.update(micUsers: ["com.apple.VoiceMemos"], listening: false, now: t0.addingTimeInterval(40)) == .none)
    }

    @Test func doesNotOfferWhenAlreadyListening() {
        var d = MeetingDetector(confirmDelay: 3, endDelay: 12)
        _ = d.update(micUsers: ["us.zoom.xos"], listening: true, now: t0)
        #expect(d.update(micUsers: ["us.zoom.xos"], listening: true, now: t0.addingTimeInterval(10)) == .none)
        // Still reports the end so the app can offer to stop.
        let zoom = MeetingApp.from(bundleID: "us.zoom.xos")!
        #expect(d.update(micUsers: [], listening: true, now: t0.addingTimeInterval(23)) == .ended(zoom))
    }

    @Test func survivesBriefMicReleasesThenEnds() {
        var d = MeetingDetector(confirmDelay: 3, endDelay: 12)
        _ = d.update(micUsers: ["com.microsoft.teams2"], listening: false, now: t0)
        _ = d.update(micUsers: ["com.microsoft.teams2"], listening: false, now: t0.addingTimeInterval(4))
        #expect(d.update(micUsers: [], listening: false, now: t0.addingTimeInterval(10)) == .none)
        #expect(d.update(micUsers: ["com.microsoft.teams2"], listening: false, now: t0.addingTimeInterval(12)) == .none)
        let teams = MeetingApp.from(bundleID: "com.microsoft.teams2")!
        #expect(d.update(micUsers: [], listening: false, now: t0.addingTimeInterval(25)) == .ended(teams))
        // A new call afterwards prompts again.
        _ = d.update(micUsers: ["com.microsoft.teams2"], listening: false, now: t0.addingTimeInterval(60))
        #expect(d.update(micUsers: ["com.microsoft.teams2"], listening: false, now: t0.addingTimeInterval(64)) == .started(teams))
    }
}

@Suite struct CompatibleProviderTests {
    @Test func parsesChatCompletionStream() {
        #expect(ChatCompletionsParser.parseSSELine(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#) == .text("Hi"))
        #expect(ChatCompletionsParser.parseSSELine(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == nil)
        #expect(ChatCompletionsParser.parseSSELine(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#) == .stop(reason: "stop"))
        #expect(ChatCompletionsParser.parseSSELine("data: [DONE]") == .stop(reason: nil))
        #expect(ChatCompletionsParser.parseSSELine(": keep-alive") == nil)
        #expect(ChatCompletionsParser.parseSSELine(#"data: {"error":{"message":"rate limited"}}"#) == .failure("rate limited"))
    }

    @Test func skipsReasoningDeltas() {
        #expect(ChatCompletionsParser.parseSSELine(#"data: {"choices":[{"delta":{"reasoning_content":"hmm","content":""}}]}"#) == nil)
    }

    @Test func buildsEndpointsFromWhateverWasPasted() {
        for base in ["http://localhost:11434/v1", "http://localhost:11434/v1/", "http://localhost:11434/v1/chat/completions"] {
            #expect(CompatibleProvider.endpoint(base: base, path: "/chat/completions")?.absoluteString
                    == "http://localhost:11434/v1/chat/completions")
        }
        #expect(CompatibleProvider.endpoint(base: "", path: "/models") == nil)
        #expect(CompatibleProvider.endpoint(base: "ftp://x", path: "/models") == nil)
    }

    @Test func presetsAreConsistent() {
        #expect(Set(CompatibleProvider.all.map(\.id)).count == CompatibleProvider.all.count)
        #expect(CompatibleProvider.find("ollama").isLocal && !CompatibleProvider.find("ollama").needsKey)
        #expect(CompatibleProvider.find("groq").needsKey && !CompatibleProvider.find("groq").isLocal)
        #expect(CompatibleProvider.find("nope").id == "ollama")
        for p in CompatibleProvider.all where p.id != "custom" {
            #expect(CompatibleProvider.endpoint(base: p.baseURL, path: "/chat/completions") != nil, "\(p.id)")
        }
    }

    @Test func readsModelLists() {
        let body = Data(#"{"object":"list","data":[{"id":"qwen3:8b"},{"id":"llama3.2"}]}"#.utf8)
        #expect(ChatCompletionsParser.modelIDs(fromBody: body) == ["llama3.2", "qwen3:8b"])
    }
}

@Suite struct OllamaChatTests {
    @Test func usesTheNativeEndpoint() {
        #expect(OllamaChat.endpoint(base: "http://localhost:11434/v1")?.absoluteString == "http://localhost:11434/api/chat")
        #expect(OllamaChat.endpoint(base: "http://localhost:11434/v1/")?.absoluteString == "http://localhost:11434/api/chat")
    }

    @Test func sizesTheContextToTheTranscript() {
        #expect(OllamaChat.contextWindow(forPromptCharacters: 2_000) == 8192)
        #expect(OllamaChat.contextWindow(forPromptCharacters: 60_000) == 32768)  // ~an hour of talk
        #expect(OllamaChat.contextWindow(forPromptCharacters: 10_000_000) == 131072)
    }

    @Test func parsesStreamingLines() {
        #expect(OllamaChat.parseLine(#"{"message":{"role":"assistant","content":"Hi"},"done":false}"#) == .text("Hi"))
        #expect(OllamaChat.parseLine(#"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#) == .stop(reason: "stop"))
        #expect(OllamaChat.parseLine(#"{"error":"model 'x' not found"}"#) == .failure("model 'x' not found"))
    }

    @Test func freeOptionsComeFirst() {
        let ids = CompatibleProvider.all.map(\.id)
        #expect(Array(ids.prefix(4)) == ["ollama", "lmstudio", "gemini", "groq"])
        #expect(CompatibleProvider.find("openrouter").defaultModel.hasSuffix(":free"))
    }
}

@Suite struct GeminiModelTests {
    @Test func usesLatestAliasesWithAFallback() {
        let g = CompatibleProvider.find("gemini")
        #expect(g.defaultModel == "gemini-flash-latest")
        #expect(g.fallbackModel == "gemini-flash-lite-latest")
    }

    @Test func retriesOnlyOverloadedRateLimitedOrRetiredModels() {
        #expect(ChatCompletionsParser.isRetryable(status: 503, body: ""))
        #expect(ChatCompletionsParser.isRetryable(status: 429, body: ""))
        #expect(ChatCompletionsParser.isRetryable(status: 404, body: #"{"error":{"message":"This model is no longer available to new users."}}"#))
        #expect(ChatCompletionsParser.isRetryable(status: 404, body: #"{"error":{"message":"The model `llama-3.3-70b-versatile` does not exist or you do not have access to it."}}"#))
        #expect(!ChatCompletionsParser.isRetryable(status: 404, body: #"{"error":{"message":"not found"}}"#))
        #expect(!ChatCompletionsParser.isRetryable(status: 400, body: "API key not valid"))
    }

    @Test func readsGooglesArrayWrappedErrors() {
        let body = #"[{"error":{"code":503,"message":"This model is currently experiencing high demand."}}]"#
        #expect(StreamParser.errorMessage(fromBody: body, status: 503) == "HTTP 503: This model is currently experiencing high demand.")
    }
}
