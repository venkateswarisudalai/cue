import Foundation

/// Words the speech model should expect: names and jargon from the context notes,
/// plus common engineering terms that on-device recognition tends to mangle
/// ("Kubernetes" → "Cuber needs").
public enum Vocabulary {
    public static let builtIn: [String] = [
        "Kubernetes", "kubectl", "Helm", "Terraform", "Ansible", "Docker", "container", "EKS", "GKE", "AKS",
        "AWS", "GCP", "Azure", "EC2", "S3", "IAM", "VPC", "Lambda", "CloudFormation", "CloudWatch",
        "Prometheus", "Grafana", "Datadog", "OpenTelemetry", "PagerDuty", "Kafka", "Redis", "PostgreSQL",
        "MySQL", "DynamoDB", "Elasticsearch", "GitHub Actions", "GitOps", "Argo CD", "Jenkins", "CI/CD",
        "SRE", "DevOps", "SLO", "SLA", "on-call", "postmortem", "microservices", "API", "gRPC", "GraphQL",
        "LLM", "SOC 2", "OAuth", "SSO", "Go", "Python", "TypeScript", "Rust", "Java",
    ]

    /// Up to `limit` distinct terms, notes first so the user's own words win.
    public static func terms(from notes: String, limit: Int = 100) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ term: String) {
            let key = term.lowercased()
            guard out.count < limit, term.count >= 2, !stopWords.contains(key), seen.insert(key).inserted else { return }
            out.append(term)
        }
        for term in extract(notes) { add(term) }
        for term in builtIn { add(term) }
        return out
    }

    /// Capitalized words that don't start a sentence, acronyms, and tokens like "C++" or "K8s".
    static func extract(_ text: String) -> [String] {
        var result: [String] = []
        var sentenceStart = true
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "(" || $0 == ")" || $0 == "/" })
        for raw in tokens {
            let endsSentence = raw.last.map { ".!?:;\n".contains($0) } ?? false
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".!?:;\"'“”‘’[]{}*#_-•"))
            defer { sentenceStart = endsSentence }
            guard let first = token.first, first.isLetter else { continue }

            let letters = token.filter(\.isLetter)
            let isAcronym = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
            let hasInnerCapital = token.dropFirst().contains(where: \.isUppercase)
            let hasSymbolOrDigit = token.contains(where: { $0.isNumber || $0 == "+" || $0 == "#" })
            let isCapitalizedMidSentence = first.isUppercase && !sentenceStart

            if isAcronym || hasInnerCapital || (hasSymbolOrDigit && first.isLetter) || isCapitalizedMidSentence {
                result.append(token)
            }
        }
        return result
    }

    static let stopWords: Set<String> = [
        "i", "i'm", "i've", "the", "a", "an", "and", "or", "but", "we", "our", "my", "you", "your",
        "it", "this", "that", "they", "he", "she", "in", "on", "at", "to", "of", "for", "with",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]
}
