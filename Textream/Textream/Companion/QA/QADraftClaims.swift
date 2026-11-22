import Foundation

/// Checks explicit status claims after drafting. It does not infer status from a value.
nonisolated enum QADraftClaims {
    private static var verification: Regex<Substring> { #/\b(?:verified|confirms?|confirmed|validated|proves?|proven|certified|audited)\b/# }
    private static var finality: Regex<Substring> { #/\b(?:final|finali[sz]ed|definitive|conclusive)\b/# }
    private static var qualification: Regex<Substring> {
        #/\b(?:no|not|never|without|unverified|unconfirmed|unvalidated|preliminary|provisional|estimated|pending|awaiting|expected|projected|forecast|targets?|targeted|goal|plans?|planned|aims?|aimed|may|might|could|would|will)\b/#
    }
    private static var clauseBoundary: Regex<Substring> { #/;|,(?!\d)|\b(?:and|but|while|however)\b/# }
    private static var outcome: Regex<Substring> { #/\b(?:reached|achieved|attained|delivered|completed|hit|recorded|observed|came in at)\b/# }
    private static var multiplierComparison: Regex<Substring> {
        #/\b\p{Nd}+(?:[.,]\p{Nd}+)*\s*(?:times|[x×])\s+(?:more|less|higher|lower|fewer)\s+than\b/#
    }
    private static let genericTerms: Set<String> = ["data", "figure", "level", "measurement", "metric", "number", "project", "result"]

    private struct Multiplier {
        let expression: String
        let subject: Set<String>
        let comparisonTarget: Set<String>

        func supported(by source: Multiplier) -> Bool {
            expression == source.expression && !subject.isEmpty && !comparisonTarget.isEmpty
                && subject.isSubset(of: source.subject) && comparisonTarget.isSubset(of: source.comparisonTarget)
        }
    }

    private struct Statement {
        let text: String
        let subjects: Set<String>
        let numbers: Set<String>
        let verified: Bool
        let final: Bool
        let qualified: Bool
        let reportsOutcome: Bool
        let multipliers: [Multiplier]

        init(_ sentence: String) {
            let normalized = QASearchText.normalized(sentence)
            text = normalized
            numbers = Set(QASearchText.numericLiterals(sentence))
            multipliers = normalized.matches(of: multiplierComparison).map { match in
                Multiplier(
                    expression: String(match.output),
                    subject: QADraftClaims.subjects(in: String(normalized[..<match.range.lowerBound])),
                    comparisonTarget: QADraftClaims.subjects(in: String(normalized[match.range.upperBound...]))
                )
            }
            qualified = text.contains(qualification) || text.hasSuffix("?")
            let clauses = text.split(separator: clauseBoundary)
            verified = !text.hasSuffix("?") && clauses.contains { asserts(verification, in: $0) }
            final = !text.hasSuffix("?") && clauses.contains { asserts(finality, in: $0) }
            reportsOutcome = !text.hasSuffix("?") && clauses.contains {
                !$0.contains(qualification) && ($0.contains(outcome) || $0.contains(where: \.isNumber))
            }
            subjects = QADraftClaims.subjects(in: text)
        }

        func isAboutSameSubject(as source: Statement) -> Bool {
            !subjects.isEmpty && subjects.isSubset(of: source.subjects) && numbers.isSubset(of: source.numbers)
        }
    }

    private static func subjects(in text: String) -> Set<String> {
        let subjectText = text.replacing(verification, with: "").replacing(finality, with: "")
            .replacing(qualification, with: "").replacing(outcome, with: "").replacing(multiplierComparison, with: "")
        return QASearchText.terms(subjectText).subtracting(genericTerms).filter { !$0.allSatisfy(\.isNumber) }
    }

    private static func asserts(_ status: Regex<Substring>, in clause: Substring) -> Bool {
        clause.matches(of: status).contains { match in
            let lead = clause[..<match.range.lowerBound].split(whereSeparator: \.isWhitespace).suffix(4).joined(separator: " ")
            return !lead.contains(qualification)
        }
    }

    static func keepingSupportedStatus(in draft: String, from material: String) -> String? {
        let sources = QASearchText.excerpts(material).map(Statement.init)
        var hasSpeech = false
        let lines = draft.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).compactMap { line -> String? in
            guard !line.allSatisfy(\.isWhitespace) else { return String(line) }
            let pieces = speechAndCues(in: line)
            let kept = pieces.filter { piece in
                if piece.isCue { return true }
                let claim = Statement(piece.text)
                guard accepts(claim, from: sources) else { return false }
                hasSpeech = true
                return true
            }
            guard !kept.isEmpty else { return nil }
            return kept.count == pieces.count ? String(line) : kept.map(\.text).joined(separator: " ")
        }
        return hasSpeech ? lines.joined(separator: "\n") : nil
    }

    private static func accepts(_ claim: Statement, from sources: [Statement]) -> Bool {
        if sources.contains(where: { $0.text == claim.text }) { return true }
        if !claim.multipliers.isEmpty, !sources.contains(where: { source in
            claim.isAboutSameSubject(as: source) && claim.multipliers.allSatisfy { multiplier in
                source.multipliers.contains(where: multiplier.supported)
            }
        }) { return false }
        if claim.verified || claim.final {
            return sources.contains {
                (!claim.verified || $0.verified) && (!claim.final || $0.final) && claim.isAboutSameSubject(as: $0)
            }
        }
        let couldUpgrade = claim.reportsOutcome && sources.contains {
            $0.qualified && (claim.isAboutSameSubject(as: $0) || !claim.numbers.isDisjoint(with: $0.numbers))
        }
        return !couldUpgrade || sources.contains { !$0.qualified && $0.reportsOutcome && claim.isAboutSameSubject(as: $0) }
    }

    private static func speechAndCues(in line: Substring) -> [(text: String, isCue: Bool)] {
        var pieces: [(String, Bool)] = []
        var start = line.startIndex
        for cue in line.matches(of: #/\[[^\[\]]*\]/#) {
            pieces.append(contentsOf: QASearchText.excerpts(String(line[start..<cue.range.lowerBound])).map { ($0, false) })
            pieces.append((String(line[cue.range]), true))
            start = cue.range.upperBound
        }
        pieces.append(contentsOf: QASearchText.excerpts(String(line[start...])).map { ($0, false) })
        return pieces
    }
}
