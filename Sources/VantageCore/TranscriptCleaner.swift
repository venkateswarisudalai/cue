import Foundation

/// Tidies raw speech-recognition fragments so the transcript reads like text, not a live feed:
/// drops fillers ("um", "uh"), collapses stutters ("I I I think"), fixes spacing around
/// punctuation, and capitalizes sentence starts. Deterministic and idempotent.
public enum TranscriptCleaner {
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "mm", "mhm"]

    public static func clean(_ raw: String) -> String {
        var words: [String] = []
        for token in raw.split(whereSeparator: \.isWhitespace).map(String.init) {
            let bare = core(token)
            if fillers.contains(bare) {
                // Keep sentence punctuation the filler carried ("uh." ends the sentence before it).
                if let p = token.last, ".?!".contains(p), let last = words.popLast() {
                    words.append(core(last).isEmpty ? last : strippingTrailingComma(last) + String(p))
                }
                continue
            }
            // "I I I think" → "I think"; only when the repeat carries no punctuation of its own.
            if let last = words.last, !bare.isEmpty, core(last) == bare, token.lowercased() == bare,
               last.lowercased() == bare {
                continue
            }
            words.append(token)
        }
        var text = words.joined(separator: " ")
        text = text.replacingOccurrences(of: #"\s+([,.?!;:])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #",+"#, with: ",", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^[,;:]\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\bi\b"#, with: "I", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\bi'"#, with: "I'", options: .regularExpression)
        return capitalizingSentences(text).trimmingCharacters(in: .whitespaces)
    }

    /// Joins a new fragment onto a turn, dropping a word repeated across the boundary.
    public static func join(_ existing: String, _ fragment: String) -> String {
        guard !existing.isEmpty else { return fragment }
        guard !fragment.isEmpty else { return existing }
        var next = fragment
        if let lastWord = existing.split(separator: " ").last.map(String.init),
           let firstWord = next.split(separator: " ").first.map(String.init),
           lastWord.lowercased() == core(lastWord), core(lastWord) == core(firstWord), !core(firstWord).isEmpty {
            next = String(next.dropFirst(firstWord.count)).trimmingCharacters(in: .whitespaces)
            if next.isEmpty { return existing }
        }
        if let end = existing.last, ".?!".contains(end) {
            next = next.prefix(1).uppercased() + next.dropFirst()
        } else if let first = next.split(separator: " ").first, first != "I",
                  first.first?.isUppercase == true, first.dropFirst().allSatisfy(\.isLowercase),
                  commonWords.contains(first.lowercased()) {
            // The recognizer capitalizes each segment; mid-sentence "And so" → "and so".
            next = next.prefix(1).lowercased() + next.dropFirst()
        }
        return existing + " " + next
    }

    /// Words that are never names, so lowering them mid-sentence is safe.
    static let commonWords: Set<String> = [
        "and", "but", "so", "or", "because", "then", "that", "which", "the", "a", "an", "to", "of",
        "in", "on", "for", "with", "we", "you", "they", "it", "is", "was", "if", "when", "like", "just",
    ]

    static func core(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private static func strippingTrailingComma(_ s: String) -> String {
        s.hasSuffix(",") ? String(s.dropLast()) : s
    }

    private static func capitalizingSentences(_ text: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                out += ch.uppercased()
                capitalizeNext = false
            } else {
                out.append(ch)
                if ".?!".contains(ch) { capitalizeNext = true } else if !ch.isWhitespace { capitalizeNext = false }
            }
        }
        return out
    }
}
