import Foundation

/// Heuristic check for "the other person just asked me something".
///
/// On-device transcription punctuates, so a trailing "?" is the strongest
/// signal. Interview prompts are often imperatives ("walk me through…"), so
/// those count too.
public enum QuestionDetector {
    static let openers: [String] = [
        "what", "how", "why", "when", "where", "who", "which",
        "can you", "could you", "would you", "will you", "do you", "did you",
        "have you", "are you", "were you", "is there", "is it", "should we",
        "tell me", "walk me through", "talk me through", "describe", "explain",
        "give me an example", "share an example", "talk about", "take me through",
    ]

    public static func isQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }
        if trimmed.hasSuffix("?") { return true }

        // Look at the last sentence or two; long monologues often end in the ask.
        let sentences = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        for sentence in sentences.suffix(2) {
            let s = stripFiller(sentence)
            if openers.contains(where: { s.hasPrefix($0 + " ") || s == $0 }) { return true }
        }
        return false
    }

    static func stripFiller(_ s: String) -> String {
        var s = s.replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").joined(separator: " ")
        let fillers = ["so ", "okay ", "ok ", "alright ", "and ", "um ", "uh ", "great ", "cool ", "right ", "now "]
        var changed = true
        while changed {
            changed = false
            for f in fillers where s.hasPrefix(f) {
                s = String(s.dropFirst(f.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                changed = true
            }
        }
        return s
    }
}
