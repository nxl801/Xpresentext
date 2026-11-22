import Foundation
import NaturalLanguage

struct QADeckIndex: Sendable {
    struct Match: Sendable {
        let citation: QACitation
        let exactNumericClaimsAllowed: Bool
        let numericBinding: QANumericBinding?
    }

    private struct Entry: Sendable {
        let match: Match
        let textTokens: Set<String>
        let titleTokens: Set<String>
    }

    private let entries: [Entry]
    private let termCounts: [String: Int]
    private let pageTitles: [Int: String]
    let revisionID: String

    init(_ deck: QADeckSnapshot) {
        revisionID = deck.revisionID
        pageTitles = Dictionary(deck.pages.map { ($0.index, $0.title) }, uniquingKeysWith: { first, _ in first })
        var allEntries: [Entry] = []
        var counts: [String: Int] = [:]
        for page in deck.pages {
            let titleTokens = QASearchText.terms(page.title)
            func add(
                _ text: String,
                kind: QACitation.Kind,
                region: QARegion? = nil,
                exactNumbers: Bool = true
            ) {
                for excerpt in QASearchText.excerpts(text) {
                    let citation = QACitation(
                        id: "E\(allEntries.count + 1)", revisionID: deck.revisionID,
                        pageIndex: page.index, pageTitle: page.title, excerpt: excerpt,
                        kind: kind, region: region.flatMap { $0.isValid ? $0 : nil }
                    )
                    let terms = QASearchText.terms(excerpt)
                    guard !terms.isEmpty else { continue }
                    allEntries.append(Entry(
                        match: Match(
                            citation: citation, exactNumericClaimsAllowed: exactNumbers,
                            numericBinding: exactNumbers ? QANumericBinding(excerpt: excerpt, kind: kind) : nil
                        ),
                        textTokens: terms, titleTokens: titleTokens
                    ))
                    for term in terms.union(titleTokens) { counts[term, default: 0] += 1 }
                }
            }

            add([page.title, page.bodyText].filter { !$0.isEmpty }.joined(separator: "\n"), kind: .slideText)
            add(page.originalNotes, kind: .speakerNotes)
            if page.aiDraft == nil, let script = page.speakerScript,
               QASearchText.normalized(script) != QASearchText.normalized(page.originalNotes) {
                add(script, kind: .speakerScript)
            }
            for visual in page.visualEvidence {
                let kind: QACitation.Kind
                switch visual.kind {
                case .chart: kind = .chart
                case .table: kind = .table
                case .imageText: kind = .imageText
                }
                add(visual.text, kind: kind, region: visual.region, exactNumbers: visual.exactNumericClaimsAllowed)
            }
        }
        entries = allEntries
        termCounts = counts
    }

    /// Score across every page. Current page is a weak cue for questions with an implicit subject.
    func search(
        _ question: String,
        translation: String? = nil,
        previousQuestion: String? = nil,
        focusPageIndex: Int? = nil
    ) -> [Match] {
        let query = QASearchText.terms(question + " " + (translation ?? ""))
        let preceding = QASearchText.terms(previousQuestion ?? "")
        let isDeictic = QASearchText.hasDeicticReference(question)
        let focusTitle = isDeictic ? focusPageIndex.flatMap { pageTitles[$0] } : nil
        let focusTerms = QASearchText.terms(focusTitle ?? "").subtracting(query)
        let wantsNumber = QASearchText.requestsNumber(question + " " + (translation ?? ""))

        func weight(_ words: Set<String>) -> Double {
            words.reduce(0) { sum, word in
                sum + log(1 + Double(entries.count) / Double(1 + termCounts[word, default: 0]))
            }
        }

        let scored: [(match: Match, score: Double)] = entries.compactMap { entry in
            let direct = entry.textTokens.intersection(query)
            let titleHits = entry.titleTokens.intersection(query).subtracting(direct)
            let earlier = entry.textTokens.union(entry.titleTokens).intersection(preceding).subtracting(query)
            let focused = entry.textTokens.intersection(focusTerms)
            var score = weight(direct) + 0.42 * weight(titleHits) + 0.48 * weight(earlier) + 0.22 * weight(focused)
            if isDeictic && entry.match.citation.pageIndex == focusPageIndex { score += 0.65 }
            guard score > 0 else { return nil }
            if wantsNumber && entry.match.exactNumericClaimsAllowed
                && !QASearchText.numericLiterals(entry.match.citation.excerpt).isEmpty {
                score *= 1.32
            }
            if entry.match.citation.kind == .chart || entry.match.citation.kind == .table { score *= 1.08 }
            return (entry.match, score)
        }.sorted {
            if abs($0.score - $1.score) > 0.000_001 { return $0.score > $1.score }
            if $0.match.citation.pageIndex == focusPageIndex { return $1.match.citation.pageIndex != focusPageIndex }
            if $1.match.citation.pageIndex == focusPageIndex { return false }
            return $0.match.citation.id < $1.match.citation.id
        }

        var selected: [Match] = []
        var excerpts: Set<String> = []
        var counts: [Int: Int] = [:]
        var characters = 0
        for (match, score) in scored {
            let citation = match.citation
            guard score >= (scored.first?.score ?? 0) * 0.17,
                  counts[citation.pageIndex, default: 0] < 4,
                  characters + citation.excerpt.count <= 4_000,
                  excerpts.insert(QASearchText.normalized(citation.excerpt)).inserted else { continue }
            selected.append(match)
            counts[citation.pageIndex, default: 0] += 1
            characters += citation.excerpt.count
            if selected.count == 9 { break }
        }
        return selected
    }
    func numericLabels(relatedTo matches: [Match]) -> Set<String> {
        let numericCitations = matches.filter { $0.numericBinding != nil }.map(\.citation)
        let labels = entries.compactMap { entry -> String? in
            guard let binding = entry.match.numericBinding else { return nil }
            let citation = entry.match.citation
            return numericCitations.contains {
                $0.pageIndex == citation.pageIndex && $0.kind == citation.kind && $0.region == citation.region
            } ? binding.label : nil
        }
        return Set(labels)
    }

}

enum QASearchText: Sendable {
    private static let hanSet = CharacterSet(charactersIn: "\u{3400}"..."\u{9FFF}")
        .union(CharacterSet(charactersIn: "\u{F900}"..."\u{FAFF}"))
    private static let literalPattern = try! NSRegularExpression(pattern: #"(?i)[+−–-]?\p{Nd}+(?:[,.]\p{Nd}+)*(?:[ \u00A0]*(?:percentage points?|percent(?:age)?|[%‰]|ms\b|kg\b|kWh\b|GHz\b|MHz\b|million\b|billion\b|thousand\b|dollars?\b|euros?\b|seconds?\b|minutes?\b|hours?\b|days?\b|months?\b|years?\b|美元|亿元|万元|千克|毫秒|分钟|小时|秒|天|月|年))?"#)
    private static let stopWords: Set<String> = [
        "a", "an", "are", "as", "at", "be", "been", "by", "can", "could", "did", "do", "does", "for", "from",
        "give", "had", "has", "have", "how", "i", "in", "is", "it", "its", "me", "of", "on", "or", "our",
        "please", "said", "say", "should", "slide", "some", "tell", "that", "the", "their", "there", "they",
        "this", "to", "us", "was", "we", "were", "what", "when", "where", "which", "who", "why", "will",
        "with", "would", "you", "your", "这个", "那个", "这些", "请问", "我们", "什么", "多少", "怎么",
        "为何", "是否", "如何", "是哪", "一下", "一页", "一张"
    ]

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacing(#/\s+/#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { hanSet.contains($0) }
    }

    static func terms(_ text: String) -> Set<String> {
        let value = normalized(text)
        var result: Set<String> = []
        for token in value.matches(of: #/[\p{L}\p{N}]+/#).map({ String($0.output) }) {
            let splits = token.split { character in
                character.unicodeScalars.contains { hanSet.contains($0) }
            }
            for split in splits {
                var word = String(split)
                guard !stopWords.contains(word), word.count > 1 || word.first?.isNumber == true else { continue }
                if word.count > 4 && word.hasSuffix("ies") {
                    word = String(word.dropLast(3)) + "y"
                } else if word.count > 4 && word.hasSuffix("s")
                            && !word.hasSuffix("ss") && !word.hasSuffix("us") && !word.hasSuffix("is") {
                    word.removeLast()
                }
                result.insert(word)
            }
            let chineseRuns = token.split { character in
                !character.unicodeScalars.contains { hanSet.contains($0) }
            }
            for run in chineseRuns {
                if run.count == 1 { result.insert(String(run)); continue }
                for (first, second) in zip(run, run.dropFirst()) {
                    let pair = String([first, second])
                    if !stopWords.contains(pair) { result.insert(pair) }
                }
            }
        }
        return result
    }

    static func excerpts(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        return text.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return [] }
            tokenizer.string = value
            let sentences = tokenizer.tokens(for: value.startIndex..<value.endIndex)
            return (sentences.isEmpty ? [value.startIndex..<value.endIndex] : sentences).flatMap { range in
                var result: [String] = []
                var rest = value[range]
                while !rest.isEmpty {
                    let prefix = rest.prefix(560)
                    let split = prefix.count == rest.count ? prefix.endIndex
                        : prefix.lastIndex(where: { $0.isWhitespace || "。！？.!?;；".contains($0) }).flatMap {
                            prefix.distance(from: prefix.startIndex, to: $0) > 300 ? prefix.index(after: $0) : nil
                        } ?? prefix.endIndex
                    let part = rest[..<split].trimmingCharacters(in: .whitespaces)
                    if !part.isEmpty { result.append(part) }
                    rest = rest[split...]
                }
                return result
            }
        }
    }

    static func hasDeicticReference(_ text: String) -> Bool {
        normalized(text).contains(#/\b(?:this|these|that|current)\b|这[个项张页些]|那[个项张页些]|本页|该[项图页]/#)
    }

    static func requestsNumber(_ text: String) -> Bool {
        let value = normalized(text)
        if value.contains(#/\b(?:what was|what were|what did .+ reach)\b/#)
            && value.contains(#/\b(?:coverage|share|result|total|count|reach)\b/#) { return true }
        return value.contains(#/\b(?:how many|how much|percent|rate|value|share|figure|number|ratio|cost)\b|多少|占比|比例|数值|百分|数据|增幅/#)
    }

    static func numericLiterals(_ text: String) -> [String] {
        let value = normalized(text)
        return literalPattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            return String(value[range])
                .replacing(#/\s*(?:percentage|percent)$/#, with: "%")
                .replacingOccurrences(of: #"(?<=\d),(?=\d{3}(?:[^\d]|$))"#, with: "", options: .regularExpression)
                .replacing(" ", with: "")
                .replacing("−", with: "-")
                .replacing("–", with: "-")
        }
    }

    static func permitsNumbers(in answer: String, from quotes: [String]) -> Bool {
        let allowed = Set(quotes.flatMap(numericLiterals))
        let spokenNumberWithUnit = #/\b(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|half|third|quarter|fifth)(?:[- ][a-z]+){0,2} (?:percent(?:age)?|dollars?|euros?|seconds?|minutes?|hours?|days?|years?)\b/#
        return !normalized(answer).contains(spokenNumberWithUnit)
            && numericLiterals(answer).allSatisfy { allowed.contains($0) }
    }
}
