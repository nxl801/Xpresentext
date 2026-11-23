import Foundation
import NaturalLanguage

enum CompanionTrackingMode: Equatable {
    case english
    case chineseKeyPoints
}

enum CompanionTrackingPhase: Equatable {
    case following
    case listeningQuestion
    case awaitingResume
}

struct CompanionTrackingPosition: Hashable, Codable {
    let pageIndex: Int
    let sentenceIndex: Int?
}

struct CompanionTrackingPage: Equatable, Sendable {
    let sentences: [String]
    let isAppendix: Bool
    let sentenceAlternatives: [Int: [String]]

    init(sentences: [String], isAppendix: Bool = false, sentenceAlternatives: [Int: [String]] = [:]) {
        self.sentences = sentences
        self.isAppendix = isAppendix
        self.sentenceAlternatives = sentenceAlternatives
    }

    static func sentences(in text: String) -> [String] {
        let characters = Array(text)
        var masked = characters
        // Keep offsets and the action text in the display, but ignore internal punctuation.
        for range in SpeechTextAlignment.annotationRanges(in: text) {
            for offset in range {
                masked[offset] = (offset == range.lowerBound ? "•" : " ")
            }
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        var result: [String] = []
        var lineStart = 0
        for lineEnd in 0...masked.count where lineEnd == masked.count || masked[lineEnd].isNewline {
            let line = String(masked[lineStart..<lineEnd])
            tokenizer.string = line
            var sentenceStart = lineStart
            tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                let sentenceEnd = lineStart + line.distance(from: line.startIndex, to: range.upperBound)
                // NLTokenizer sees spaces at the end of a masked action. Keep those original
                // characters with the sentence before breaking at the next visible token.
                var end = sentenceEnd
                while end < lineEnd && masked[end].isWhitespace { end += 1 }
                let sentence = String(characters[sentenceStart..<end]).trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { result.append(sentence) }
                sentenceStart = end
                return true
            }
            if sentenceStart < lineEnd {
                let remainder = String(characters[sentenceStart..<lineEnd]).trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty { result.append(remainder) }
            }
            lineStart = lineEnd + 1
        }
        return result
    }

    /// Source ranges share the speech tokenizer's letter/number boundaries.
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        let annotations = IndexSet(SpeechTextAlignment.annotationRanges(in: text).flatMap { Array($0) })
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for (offset, index) in text.indices.enumerated() {
            if !annotations.contains(offset), text[index].isLetter || text[index].isNumber {
                if start == nil { start = index }
            } else if let lower = start {
                ranges.append(lower..<index)
                start = nil
            }
        }
        if let start { ranges.append(start..<text.endIndex) }
        return ranges
    }

    static func withoutActions(_ sentence: String) -> String {
        var text = Array(sentence)
        for range in SpeechTextAlignment.annotationRanges(in: sentence) {
            for offset in range { text[offset] = " " }
        }
        return String(text)
    }
}

struct CompanionPointingCue: Identifiable {
    let id: String
    let instruction: String
    let context: String
    let nearbyText: String

    static func active(in lines: [String], sentence index: Int, read: IndexSet) -> Self? {
        guard lines.indices.contains(index) else { return nil }
        let text = lines[index]
        let ranges = CompanionTrackingPage.wordRanges(in: text)
        var action: (Int, Range<Int>)?
        func lastAction(on i: Int) -> (Int, Range<Int>)? {
            SpeechTextAlignment.annotationRanges(in: lines[i]).last.map { (i, $0) }
        }
        for previous in lines.indices.prefix(index).reversed() {
            if let recent = lastAction(on: previous) { action = recent; break }
        }
        for range in SpeechTextAlignment.annotationRanges(in: text) {
            let boundary = text.index(text.startIndex, offsetBy: range.lowerBound)
            let preceding = ranges.prefix { $0.upperBound <= boundary }.count
            if preceding == 0 || (read.last ?? -1) >= preceding - 1 { action = (index, range) }
        }
        if !ranges.isEmpty, read.last == ranges.count - 1, lines.indices.contains(index + 1),
           CompanionTrackingPage.wordRanges(in: lines[index + 1]).isEmpty, let upcoming = lastAction(on: index + 1) {
            action = upcoming
        }
        guard let (line, offsets) = action else { return nil }
        let source = lines[line]
        let lower = source.index(source.startIndex, offsetBy: offsets.lowerBound)
        let upper = source.index(lower, offsetBy: offsets.count)
        let instruction = String(source[lower..<upper].dropFirst().dropLast())
        guard instruction.range(of: #"\b(point|indicate|highlight|gesture|show|look)\b|指向|指着|指一下|指出|请看|看向|看一下|标出|標出|第[一二三四五0-9]+个?(点|框|方框|要点|項|项)|\b(first|second|third|fourth|fifth)\s+(box|point|bullet|item)\b"#,
                                options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let tail = CompanionTrackingPage.withoutActions(String(source[upper...])).trimmingCharacters(in: .whitespaces)
        let context = tail.isEmpty ? lines.dropFirst(line + 1).map(CompanionTrackingPage.withoutActions)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "" : tail
        let following = ([String(source[upper...])] + Array(lines.dropFirst(line + 1).prefix(3))).joined(separator: " ")
        let nearby = following.prefix { $0 != "[" }
        return Self(id: "\(line)|\(offsets.lowerBound)|\(source)|\(context)", instruction: instruction,
                    context: context, nearbyText: String(nearby))
    }
}

struct CompanionTrackingMatcher {
    private struct Token {
        let word: String
        let index: Int
    }

    private struct Line {
        let position: CompanionTrackingPosition
        let fullWords: [String]
        let words: [Token]
        let assertion: Assertion
        let alternatives: [[Token]]
    }

    private struct Assertion: Equatable {
        enum Condition { case none, possible, ifTrue, onlyIf, unless }

        let negative: Bool
        let condition: Condition

        private static let contractedNegatives: Set<String> = [
            "ain", "aren", "can", "couldn", "didn", "doesn", "don", "hadn", "hasn", "haven", "isn", "mustn",
            "needn", "shan", "shouldn", "wasn", "weren", "won", "wouldn"
        ]
        private static let writtenNegatives: Set<String> = [
            "arent", "cannot", "cant", "couldnt", "didnt", "doesnt", "dont", "hadnt", "hasnt", "havent",
            "isnt", "mustnt", "neednt", "shant", "shouldnt", "wasnt", "werent", "wont", "wouldnt"
        ]

        init(_ words: ArraySlice<String>, firstAnchor: Int) {
            var negative = false
            var condition = Condition.none
            var mainClause = true
            for index in words.indices {
                let word = words[index]
                let next = index + 1 < words.endIndex ? words[index + 1] : ""
                let previous = index > words.startIndex ? words[index - 1] : ""
                if index > firstAnchor, ["so", "because", "although"].contains(word) { mainClause = false }
                if mainClause && (Self.writtenNegatives.contains(word) || Self.contractedNegatives.contains(word) && next == "t"
                    || ["no", "never", "neither", "nor", "without"].contains(word)
                    || word == "not" && !["only", "just"].contains(next)) {
                    negative = true
                }
                if word == "unless" { condition = .unless }
                else if word == "if", previous == "only", condition != .unless { condition = .onlyIf }
                else if condition == .none || condition == .possible {
                    if ["if", "assume", "assuming", "suppose", "supposing", "imagine", "whether", "hypothetically"].contains(word)
                        || word == "provided" && next == "that" || word == "in" && next == "case" {
                        condition = .ifTrue
                    } else if ["may", "might", "could", "would"].contains(word) {
                        condition = .possible
                    }
                }
            }
            self.negative = negative
            self.condition = condition
        }
    }

    private struct Speech: Equatable {
        let words: [String]
        let clauseBreaks: [Int]

        init(_ text: String) {
            let text = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en-US"))
            var words: [String] = []
            var breaks: [Int] = [0]
            var word = ""
            for index in text.indices {
                let character = text[index]
                if character.isLetter || character.isNumber {
                    word.append(character)
                } else {
                    let next = text.index(after: index)
                    let decimalPoint = character == "." && word.last?.isNumber == true
                        && next < text.endIndex && text[next].isNumber
                    if !word.isEmpty {
                        words.append(word)
                        word = ""
                    }
                    if !decimalPoint, (character.isNewline || ".!?;".contains(character)), breaks.last != words.count {
                        breaks.append(words.count)
                    }
                }
            }
            if !word.isEmpty { words.append(word) }
            self.words = words
            clauseBreaks = breaks
        }

        func assertion(for match: Match, since lowerBound: Int) -> Assertion {
            let clauseStart = clauseBreaks.last(where: { $0 <= match.start }) ?? 0
            let clauseEnd = clauseBreaks.first(where: { $0 > match.end }) ?? words.count
            let start = max(lowerBound, clauseStart)
            let end = min(clauseEnd, match.end + 5)
            return Assertion(words[start..<end], firstAnchor: match.start)
        }
    }

    private struct Match {
        let start: Int
        let end: Int
        let coverage: Double
        let anchors: Int
        var wordStart: Int? = nil

        var score: Double { coverage + Double(min(anchors, 8)) * 0.025 }
    }

    private static let stopWords: Set<String> = [
        "a", "about", "all", "also", "an", "and", "are", "as", "at", "be", "been", "but", "by",
        "can", "do", "does", "for", "from", "had", "has", "have", "here", "how", "i", "if",
        "in", "into", "is", "it", "its", "let", "lets", "may", "more", "must", "my", "not", "now",
        "of", "on", "one", "or", "our", "out", "per", "should", "so", "some", "such", "than",
        "that", "the", "their", "them", "then", "there", "these", "they", "this", "those", "to",
        "too", "up", "us", "use", "very", "was", "we", "were", "what", "when", "where", "which",
        "who", "why", "will", "with", "would", "you", "your"
    ]

    private let pages: [CompanionTrackingPage]
    private let spokenLines: [[Line]]
    private let mode: CompanionTrackingMode
    private(set) var position: CompanionTrackingPosition?

    private(set) var readWords: [CompanionTrackingPosition: IndexSet] = [:]
    private var lastMarkedSpeechIndex = -1
    private var acceptedMatch: Match?
    private var acceptedOriginal = false
    private var requiresConfirmation = false
    private var lastSpeech: Speech?
    private var transcriptBeforeRestart: Speech?
    private var segmentBeganOnScript = false
    private var completedSegmentWords: [String]?
    private var endedBeforeSegment: CompanionTrackingPosition?
    private struct SegmentLead {
        let line: Line
        let evidence: Match
        let speech: Speech
    }
    private var previousSegmentLead: SegmentLead?
    private var rollingPreview = false

    private var consumedThrough: Int { acceptedMatch?.end ?? -1 }

    init(pages: [CompanionTrackingPage] = [], mode: CompanionTrackingMode = .english) {
        self.pages = pages
        self.mode = mode
        spokenLines = pages.enumerated().map { pageIndex, page in
            page.sentences.enumerated().compactMap { sentenceIndex, sentence in
                let speech = CompanionTrackingPage.withoutActions(sentence)
                let fullWords = Self.words(in: speech)
                let words = Self.contentTokens(fullWords)
                let visibleKeyPoint = mode == .chineseKeyPoints && !speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard !fullWords.isEmpty || visibleKeyPoint else { return nil }
                let position = CompanionTrackingPosition(pageIndex: pageIndex, sentenceIndex: sentenceIndex)
                let assertion = Assertion(fullWords[...], firstAnchor: words.first?.index ?? 0)
                let alternatives = (page.sentenceAlternatives[sentenceIndex] ?? []).prefix(4).compactMap { text -> [Token]? in
                    Self.preparedWords(text, source: fullWords, assertion: assertion)
                }
                return Line(position: position, fullWords: fullWords, words: words, assertion: assertion, alternatives: alternatives)
            }
        }
        if let page = pages.firstIndex(where: { !$0.isAppendix }) ?? pages.indices.first {
            select(pageIndex: page, sentenceIndex: nil)
        }
    }

    var nextPosition: CompanionTrackingPosition? {
        position.flatMap { nextLine(after: $0)?.position }
    }

    private var finishedCurrentLine: Bool {
        guard let position, let marked = readWords[position],
              let line = spokenLines[position.pageIndex].first(where: { $0.position == position }) else { return false }
        return marked.last == line.fullWords.count - 1 && marked.count * 3 >= line.fullWords.count * 2
    }

    private var hasSpokenPrefix: Bool {
        guard let position, let read = readWords[position],
              let line = spokenLines[position.pageIndex].first(where: { $0.position == position }),
              read.count >= 3, read.count * 2 >= min(line.fullWords.count, 12) else { return false }
        return line.words.filter { read.contains($0.index) }.prefix(2).count == 2
    }

    func openingPosition(on page: Int) -> CompanionTrackingPosition {
        spokenLines[page].first?.position ?? CompanionTrackingPosition(pageIndex: page, sentenceIndex: nil)
    }

    // Word highlights may move on a shared opening. Turn the displayed page
    // only once the actually heard part distinguishes the final spoken line.
    var nextPageAfterSpokenEnding: Int? {
        guard let position, let line = spokenLines[position.pageIndex].last,
              position == line.position, let next = nextBodyPage(after: position.pageIndex),
              let marked = readWords[position], !marked.isEmpty else { return nil }
        let neighbors = (spokenLines[position.pageIndex] + spokenLines[next]).filter { $0.position != position }
        for run in marked.rangeView {
            let phrase = line.fullWords[run]
            guard phrase.count >= min(3, line.fullWords.count),
                  phrase.contains(where: { !Self.stopWords.contains($0) }) else { continue }
            let ambiguous = neighbors.contains { other in
                guard other.fullWords.count >= phrase.count else { return false }
                return (0...(other.fullWords.count - phrase.count)).contains { start in
                    other.fullWords[start..<(start + phrase.count)].elementsEqual(phrase)
                }
            }
            if !ambiguous { return next }
        }
        return nil
    }

    var previousReadPosition: CompanionTrackingPosition? {
        guard let prompt = promptPosition else { return nil }
        let here = (prompt.pageIndex, prompt.sentenceIndex ?? -1)
        return readWords.keys.filter { ($0.pageIndex, $0.sentenceIndex ?? -1) < here }
            .max { ($0.pageIndex, $0.sentenceIndex ?? -1) < ($1.pageIndex, $1.sentenceIndex ?? -1) }
    }

    /// Make the next prompt readable during the pause. Page turns still require spoken evidence.
    var promptPosition: CompanionTrackingPosition? {
        guard finishedCurrentLine, let nextPosition, nextPosition.pageIndex == position?.pageIndex else { return position }
        return nextPosition
    }

    var twoPagePreviewIndex: Int? {
        guard let position else { return nil }
        if !pages[position.pageIndex].isAppendix, let body = nextBodyPage(after: position.pageIndex) { return body }
        let next = position.pageIndex + 1
        return pages.indices.contains(next) ? next : nil
    }

    var previewPageIndex: Int? {
        guard let position, !pages[position.pageIndex].isAppendix else { return nil }
        let sentence = promptPosition?.sentenceIndex ?? 0
        let remaining = spokenLines[position.pageIndex].filter { ($0.position.sentenceIndex ?? 0) >= sentence }
        guard rollingPreview || remaining.count <= 3 else { return nil }
        return nextBodyPage(after: position.pageIndex)
    }

    func sentences(on page: Int) -> [String] { pages.indices.contains(page) ? pages[page].sentences : [] }

    func sentence(at position: CompanionTrackingPosition?) -> String? {
        guard let position, let sentence = position.sentenceIndex, pages.indices.contains(position.pageIndex),
              pages[position.pageIndex].sentences.indices.contains(sentence) else { return nil }
        return pages[position.pageIndex].sentences[sentence]
    }

    /// Uses the same next spoken line as automatic tracking, but never changes the anchor.
    func readingWindow(upcoming limit: Int, startingAt anchor: CompanionTrackingPosition? = nil) -> [CompanionTrackingPosition] {
        guard let start = anchor ?? position, let firstIndex = start.sentenceIndex else { return [] }
        var firstVisible = firstIndex
        let spoken = Set(spokenLines[start.pageIndex].compactMap { $0.position.sentenceIndex })
        while firstVisible > 0 && !spoken.contains(firstVisible - 1) { firstVisible -= 1 }
        var result = (firstVisible...firstIndex).map { CompanionTrackingPosition(pageIndex: start.pageIndex, sentenceIndex: $0) }
        var cursor = start
        var index = firstIndex
        func appendRange(_ range: Range<Int>, on page: Int) {
            result.append(contentsOf: range.map { CompanionTrackingPosition(pageIndex: page, sentenceIndex: $0) })
        }
        for _ in 0..<min(8, max(1, limit)) {
            guard let next = nextLine(after: cursor)?.position, let nextIndex = next.sentenceIndex else {
                if !pages[cursor.pageIndex].isAppendix {
                    appendRange((index + 1)..<pages[cursor.pageIndex].sentences.count, on: cursor.pageIndex)
                }
                break
            }
            if cursor.pageIndex == next.pageIndex {
                appendRange((index + 1)..<(nextIndex + 1), on: next.pageIndex)
            } else {
                appendRange((index + 1)..<pages[cursor.pageIndex].sentences.count, on: cursor.pageIndex)
                appendRange(0..<(nextIndex + 1), on: next.pageIndex)
            }
            cursor = next
            index = nextIndex
        }
        return result
    }

    @discardableResult
    mutating func select(pageIndex: Int, sentenceIndex: Int?, fromPreview: Bool = false) -> Bool {
        guard pages.indices.contains(pageIndex) else { return false }
        if let sentenceIndex, !pages[pageIndex].sentences.indices.contains(sentenceIndex) { return false }
        let firstSentence = spokenLines[pageIndex].first?.position.sentenceIndex
            ?? pages[pageIndex].sentences.indices.first
        position = CompanionTrackingPosition(pageIndex: pageIndex, sentenceIndex: sentenceIndex ?? firstSentence)
        rollingPreview = fromPreview
        readWords = readWords.filter { location, _ in
            location.pageIndex < pageIndex || (location.pageIndex == pageIndex &&
                (location.sentenceIndex ?? 0) < (position?.sentenceIndex ?? 0))
        }
        resetTranscript()
        return true
    }

    mutating func resetTranscript() {
        endedBeforeSegment = nil
        previousSegmentLead = nil
        completedSegmentWords = nil
        segmentBeganOnScript = false
        lastMarkedSpeechIndex = -1
        acceptedMatch = nil
        acceptedOriginal = false
        requiresConfirmation = false
        lastSpeech = nil
        transcriptBeforeRestart = nil
    }

    mutating func beginSpeechSegment() {
        guard let speech = lastSpeech, let position else { return }
        let ending = (finishedCurrentLine || hasSpokenPrefix) && lastMarkedSpeechIndex >= 0
            && speech.words.count - lastMarkedSpeechIndex <= 3 ? position : nil
        let confirmedLead = trailingLead(after: position, in: speech)
        resetTranscript()
        endedBeforeSegment = ending
        previousSegmentLead = confirmedLead
    }

    /// Streaming callbacks contain a revised prefix followed by optional new speech.
    /// Only the part beyond the accepted alignment may move the current position.
    @discardableResult
    mutating func process(_ transcript: String, awaitingResume: Bool, resumeOnCurrentPageOnly: Bool = false) -> Bool {
        guard mode == .english, let position, !pages[position.pageIndex].isAppendix else { return false }
        let speech = Speech(transcript)
        guard !speech.words.isEmpty, speech != lastSpeech else { return false }
        // A recognizer can start a fresh, untimed partial without sending a final.
        // Remember the verified ending until a few words distinguish new speech
        // from a truncated or re-punctuated copy of the old transcription.
        if !awaitingResume, (finishedCurrentLine || hasSpokenPrefix), let next = nextLine(after: position) {
            if completedSegmentWords == nil, segmentBeganOnScript, let old = lastSpeech?.words,
               lastMarkedSpeechIndex == old.count - 1, !speech.words.starts(with: old),
               zip(old, speech.words).prefix(while: ==).count <= 2 {
                completedSegmentWords = old
            }
            if let old = completedSegmentWords {
                if speech.words.starts(with: old) {
                    completedSegmentWords = nil
                } else if !old.starts(with: speech.words),
                          opening(of: next, in: speech, at: 0, samePage: finishedCurrentLine && next.position.pageIndex == position.pageIndex) != nil {
                    resetTranscript()
                    endedBeforeSegment = position
                }
            }
        }
        if !awaitingResume, let old = lastSpeech, previousSegmentLead == nil,
           old.words.count >= 3, old.words.first != speech.words.first,
           !old.words.starts(with: speech.words) {
            // Some untimed Apple partials replace a complete utterance without a final.
            previousSegmentLead = trailingLead(after: position, in: old)
        }
        let oldWords = lastSpeech?.words ?? []
        let common = zip(oldWords, speech.words).prefix { $0 == $1 }.count
        // A recognizer can replace a whole segment. Keep the script cursor and
        // accept fresh audio indices. Old cumulative prefixes never count twice.
        if lastMarkedSpeechIndex >= common, oldWords.indices.contains(lastMarkedSpeechIndex) {
            if let index = revisedWordIndex(in: speech.words, previously: oldWords, endingAt: lastMarkedSpeechIndex) {
                lastMarkedSpeechIndex = index
            } else if common == 0 && speech.words.count < oldWords.count {
                lastMarkedSpeechIndex = -1
            }
        }
        let resumed = locateSentence(speech, from: position, awaitingResume: awaitingResume, resumeOnCurrentPageOnly: resumeOnCurrentPageOnly)
        guard !awaitingResume || resumed, let target = self.position else { return resumed }
        if target.pageIndex != position.pageIndex { rollingPreview = true }
        if target != position || resumed, let match = acceptedMatch {
            let source = Self.words(in: CompanionTrackingPage.withoutActions(sentence(at: target) ?? ""))
            let lead = source.prefix { Self.stopWords.contains($0) }.count
            let start = match.wordStart ?? max(0, match.start - lead)
            if target != position, !awaitingResume {
                markWords(at: position, in: speech.words, from: max(0, common - 1), until: start)
            }
            lastMarkedSpeechIndex = start - 1
            if acceptedOriginal {
                markWords(at: target, in: speech.words, from: start, until: speech.words.count)
            } else {
                lastMarkedSpeechIndex = match.end
            }
        } else {
            markWords(at: target, in: speech.words, from: max(0, common - 1), until: speech.words.count)
        }
        return resumed
    }

    // A partial can re-tokenize words already read ("part2" -> "part two").
    // Re-anchor on a unique unchanged phrase before consuming newly spoken words.
    private func revisedWordIndex(in words: [String], previously old: [String], endingAt end: Int) -> Int? {
        let tail = old[max(0, end - 3)...end]
        guard tail.count >= 2, words.count >= tail.count else { return nil }
        let matches = ((tail.count - 1)..<words.count).filter { index in
            abs(index - end) <= 12 && words[(index + 1 - tail.count)...index].elementsEqual(tail)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private mutating func markWords(at location: CompanionTrackingPosition, in heard: [String],
                                    from lower: Int, until upper: Int) {
        var i = max(lower, lastMarkedSpeechIndex + 1)
        guard i < upper, let sentence = sentence(at: location) else { return }
        let source = Self.words(in: CompanionTrackingPage.withoutActions(sentence))
        var marked = readWords[location] ?? []
        var next = (marked.last ?? -1) + 1
        while i < upper, next < source.count {
            let adjacent = i == lastMarkedSpeechIndex + 1
            let paired = i + 1 < upper && next + 1 < source.count &&
                Self.equivalent(source[next + 1], heard[i + 1]) &&
                (!Self.stopWords.contains(source[next]) || !Self.stopWords.contains(source[next + 1]))
            if Self.equivalent(source[next], heard[i]), adjacent || paired {
                if i == 0 { segmentBeganOnScript = true }
                marked.insert(next)
                next += 1
                lastMarkedSpeechIndex = i
            } else if i + 1 < upper {
                // Skipping script words needs two ordered words and a unique
                // local landing place. Skipped words keep their unread styling.
                let end = min(next + 15, source.count - 1)
                if next + 1 < end {
                    let hits = ((next + 1)..<end).filter { index in
                        (!Self.stopWords.contains(source[index]) || !Self.stopWords.contains(source[index + 1])) &&
                        Self.equivalent(source[index], heard[i]) && Self.equivalent(source[index + 1], heard[i + 1])
                    }
                    if hits.count == 1, let hit = hits.first {
                        if i <= 2 { segmentBeganOnScript = true }
                        marked.insert(integersIn: hit..<(hit + 2))
                        next = hit + 2
                        i += 1
                        lastMarkedSpeechIndex = i
                    }
                }
            }
            i += 1
        }
        if !marked.isEmpty { readWords[location] = marked }
    }

    private mutating func locateSentence(_ speech: Speech, from position: CompanionTrackingPosition,
                                         awaitingResume: Bool, resumeOnCurrentPageOnly: Bool) -> Bool {
        let words = speech.words
        let previous = lastSpeech
        let lastWords = previous?.words ?? []
        // Keep the consumed boundary when a partial result is revised. Recheck
        // the revised span before trusting it as the end of the page.
        let firstChangedIndex = zip(lastWords, words).prefix { $0 == $1 }.count
        if firstChangedIndex <= consumedThrough
            || previous?.clauseBreaks.prefix(while: { $0 <= consumedThrough }) != speech.clauseBreaks.prefix(while: { $0 <= consumedThrough }) {
            requiresConfirmation = true
        }
        if !awaitingResume, (1...2).contains(words.count), consumedThrough >= 8,
           lastWords.count > consumedThrough, lastWords.count - words.count >= 8 {
            transcriptBeforeRestart = previous
        }
        lastSpeech = speech
        let content = Self.contentTokens(words)
        // Apple can start a new segment within the same request. Wait for
        // evidence in the new text before replacing the old word positions.
        if !awaitingResume, let (line, match) = recoverRestart(after: position, speech: speech, in: content) {
            accept(line, match)
            return false
        }
        if awaitingResume {
            let tokens = Array(content.filter { $0.index > consumedThrough }.suffix(72))
            guard let (line, match) = resumedLine(from: position, in: tokens, speech: speech, currentPageOnly: resumeOnCurrentPageOnly) else { return false }
            accept(line, match)
            return true
        }

        if let lead = previousSegmentLead, !words.starts(with: lead.speech.words),
           let following = nextLine(after: lead.line.position),
           following.words.map(\.word) != lead.line.words.map(\.word) {
            let fresh = Array(content.prefix(72))
            if let evidence = match(following, in: fresh, speech: speech, since: 0, strict: true),
               evidence.start <= 4, unambiguous([(following, evidence)], comparedTo:
                    recoveryLeads(after: position, in: fresh, speech: speech, since: 0)) != nil {
                recordWords(at: lead.line.position, match: lead.evidence, in: lead.speech, until: lead.speech.words.count)
                acceptedMatch = nil // the old segment's offsets do not apply to this transcript
                lastMarkedSpeechIndex = -1
                accept(following, evidence)
            }
        }
        let tokens = Array(content.filter { $0.index > consumedThrough }.suffix(72))
        // Each accepted alignment consumes fresh speech. A coalesced callback
        // can cover several sentences, even after the recognizer dropped audio.
        for _ in 0..<12 {
            guard let location = self.position else { break }
            if let next = nextLine(after: location),
               let opening = consecutiveOpening(after: location, next: next, speech: speech, unchanged: firstChangedIndex) {
                accept(next, opening)
                continue
            }
            let pending = tokens.filter { $0.index > consumedThrough }
            guard !pending.isEmpty else { break }
            let lines = candidates(from: location)
            let floor = consumedThrough + 1
            let matches = lines.compactMap { line in
                let crossesPage = line.position.pageIndex != location.pageIndex
                return match(line, in: pending, speech: speech, since: floor, strict: crossesPage).map { (line, $0) }
            }
            let eligible = matches.compactMap { line, evidence -> (Line, Match)? in
                guard line.position.pageIndex != location.pageIndex else { return (line, evidence) }
                guard location.pageIndex == position.pageIndex else { return nil }
                // A fresh entry requires either a confirmed, nearby page ending or
                // a second, distinct sentence from the next page.
                let supported = alignments(line, in: pending, speech: speech, since: floor, strict: true).first { entry in
                    let adjacent = confirmsPageEnding(at: location, before: entry, in: content, speech: speech)
                    return adjacent || corroboratesEntry(line, after: entry, in: pending, speech: speech)
                }
                return supported.map { (line, $0) }
            }
            if let (line, evidence) = unambiguous(eligible, comparedTo: matches) {
                accept(line, evidence)
            } else {
                if matches.isEmpty, let (line, evidence) = preparedNext(from: location, among: lines, in: pending,
                                                                      speech: speech, since: floor) {
                    accept(line, evidence, original: false)
                } else if pending.count >= 6, transcriptBeforeRestart == nil,
                          let (line, evidence) = forwardPair(after: location, in: pending, speech: speech) {
                    accept(line, evidence)
                    continue
                }
                break
            }
        }
        return false
    }

    // A single distant line may be a quotation. Require distinct, consecutive
    // lines with fresh, nonoverlapping evidence before moving a stalled cursor.
    private func trailingLead(after location: CompanionTrackingPosition, in speech: Speech) -> SegmentLead? {
        let fresh = Self.contentTokens(speech.words).suffix(72).filter { $0.index > consumedThrough }
        let leads = recoveryLeads(after: location, in: fresh, speech: speech, since: consumedThrough + 1)
        let trailing = leads.filter { speech.words.count - $0.1.end <= 4 }
        guard let (line, evidence) = unambiguous(trailing, comparedTo: leads) else { return nil }
        return SegmentLead(line: line, evidence: evidence, speech: speech)
    }

    private func recoveryLeads(after location: CompanionTrackingPosition, in tokens: [Token],
                               speech: Speech, since floor: Int) -> [(Line, Match)] {
        guard tokens.count >= 3 else { return [] }
        let remaining = spokenLines[location.pageIndex].reversed().prefix {
            ($0.position.sentenceIndex ?? -1) > (location.sentenceIndex ?? -1)
        }
        let nearEnd = remaining.count <= 2 && (hasSpokenPrefix || finishedCurrentLine)
        let nextPage = remaining.isEmpty || nearEnd ? nextBodyPage(after: location.pageIndex) : nil
        var cursor = location
        var leads: [(Line, Match)] = []
        for _ in 0..<12 {
            guard let line = nextLine(after: cursor),
                  line.position.pageIndex == location.pageIndex || line.position.pageIndex == nextPage else { break }
            if line.position.pageIndex != location.pageIndex,
               !spokenLines[line.position.pageIndex].prefix(3).contains(where: { $0.position == line.position }) { break }
            let found = alignments(line, in: tokens, speech: speech, since: floor, strict: true)
            if let evidence = found.max(by: { $0.score < $1.score }) { leads.append((line, evidence)) }
            cursor = line.position
        }
        return leads
    }

    private func forwardPair(after location: CompanionTrackingPosition, in tokens: [Token],
                             speech: Speech) -> (Line, Match)? {
        let leads = recoveryLeads(after: location, in: tokens, speech: speech, since: consumedThrough + 1)
        let supported = leads.filter { line, first in
            guard let following = nextLine(after: line.position), following.position.pageIndex == line.position.pageIndex,
                  line.words.map(\.word) != following.words.map(\.word),
                  let second = continuation(following, after: first, in: tokens, speech: speech) else { return false }
            return unambiguous([(following, second)], comparedTo: leads) != nil
        }
        return unambiguous(supported, comparedTo: leads)
    }

    private mutating func accept(_ line: Line, _ match: Match, original: Bool = true) {
        if let previous = position, previous != line.position, let earlier = acceptedMatch,
           acceptedOriginal, let speech = lastSpeech, earlier.end < match.start {
            // Several sentences may be accepted in one callback. Preserve word
            // evidence for the previous one before moving on to the next.
            recordWords(at: previous, match: earlier, in: speech, until: match.wordStart ?? match.start)
        }
        endedBeforeSegment = nil
        previousSegmentLead = nil
        completedSegmentWords = nil
        position = line.position
        acceptedMatch = match
        acceptedOriginal = original
        requiresConfirmation = false
        transcriptBeforeRestart = nil
    }

    private mutating func recordWords(at position: CompanionTrackingPosition, match: Match, in speech: Speech, until end: Int) {
        let cursor = lastMarkedSpeechIndex
        let began = segmentBeganOnScript
        let start = match.wordStart ?? match.start
        lastMarkedSpeechIndex = start - 1
        markWords(at: position, in: speech.words, from: start, until: end)
        lastMarkedSpeechIndex = cursor
        segmentBeganOnScript = began
    }

    // A verbatim handoff can contain only one content word ("Thank you") or start
    // a fresh recognition segment. Scope this faster path to adjacent spoken lines.
    private func consecutiveOpening(after location: CompanionTrackingPosition, next: Line,
                                    speech: Speech, unchanged: Int) -> Match? {
        guard let current = spokenLines[location.pageIndex].first(where: { $0.position == location }) else { return nil }
        let words = speech.words
        let floor = max(consumedThrough + 1, words.count - 96)
        guard floor < words.count else { return nil }
        let finished = finishedCurrentLine
        let stablePrefix = hasSpokenPrefix && !requiresConfirmation && unchanged > lastMarkedSpeechIndex && lastMarkedSpeechIndex >= 0
        for start in floor..<words.count {
            let freshSegment = endedBeforeSegment == location && start == 0
            let afterMarkedEnd = start == lastMarkedSpeechIndex + 1 && start > 0 && unchanged >= start
                && finished
            let verbatimEnd = start >= current.fullWords.count
                && words[(start - current.fullWords.count)..<start].elementsEqual(current.fullWords)
            let afterPrefix = stablePrefix && start == lastMarkedSpeechIndex + 1
            let atHandoff = freshSegment || afterMarkedEnd || verbatimEnd || afterPrefix
            let samePage = next.position.pageIndex == location.pageIndex
            if atHandoff, finished || verbatimEnd || next.words.count >= 2,
               let evidence = opening(of: next, in: speech, at: start, samePage: (finished || verbatimEnd) && samePage) {
                return evidence
            }
            if samePage, atHandoff || speech.clauseBreaks.contains(start),
               let evidence = distinctivePartialOpening(of: next, heard: words[start...]) {
                return evidence
            }
        }
        return nil
    }

    // A pause may finalize a literal opening before a later "may" or "not" has been
    // spoken. Locate the adjacent line from the words actually present in this segment.
    private func distinctivePartialOpening(of line: Line, heard: ArraySlice<String>) -> Match? {
        guard heard.count >= 4, heard.count < line.fullWords.count,
              line.fullWords.starts(with: heard) else { return nil }
        let anchors = Set(line.words.prefix { $0.index < heard.count }.map(\.word))
        guard anchors.count >= 2 else { return nil }
        for other in spokenLines[line.position.pageIndex] where other.position != line.position {
            guard other.fullWords.count >= heard.count else { continue }
            for start in 0...(other.fullWords.count - heard.count)
                where other.fullWords[start...].starts(with: heard) { return nil }
        }
        return Match(start: heard.startIndex, end: heard.endIndex - 1, coverage: 1,
                     anchors: anchors.count, wordStart: heard.startIndex)
    }

    private func opening(of next: Line, in speech: Speech, at start: Int, samePage: Bool) -> Match? {
        let heard = speech.words
        let script = next.fullWords
        guard start < heard.count, let first = script.first else { return nil }
        func checked(_ end: Int) -> Match? {
            let match = Match(start: start, end: end, coverage: 1, anchors: end - start + 1, wordStart: start)
            return speech.assertion(for: match, since: start) == next.assertion ? match : nil
        }
        if samePage {
            if Self.equivalent(first, heard[start]), !Self.stopWords.contains(first) {
                return checked(start)
            }
            // A misheard name or contraction at the opening need not stall the
            // whole sentence. Two consecutive printed words establish the landing.
            for i in start..<min(start + 3, heard.count - 1) {
                for j in 0..<min(5, script.count - 1) where
                    Self.equivalent(heard[i], script[j]) && Self.equivalent(heard[i + 1], script[j + 1]) &&
                    (!Self.stopWords.contains(script[j]) || !Self.stopWords.contains(script[j + 1])) {
                    return checked(i + 1)
                }
            }
        }
        let secondAnchor = next.words.prefix(2).last?.index ?? script.count - 1
        let length = min(max(3, secondAnchor + 1), script.count)
        guard start + length <= heard.count,
              heard[start..<(start + length)].elementsEqual(script.prefix(length)) else { return nil }
        return checked(start + length - 1)
    }

    private func confirmsPageEnding(at position: CompanionTrackingPosition, before entry: Match, in tokens: [Token], speech: Speech) -> Bool {
        guard acceptedOriginal, let acceptedMatch, entry.start - acceptedMatch.end <= 12 else { return false }
        guard requiresConfirmation else { return true }
        guard let current = spokenLines[position.pageIndex].first(where: { $0.position == position }) else { return false }
        // Restrict revalidation to the original alignment. A later repetition
        // or words from the entry itself cannot repair the disputed ending.
        let revised = tokens.filter { (acceptedMatch.start..<entry.start).contains($0.index) }
        return alignments(current, in: revised, speech: speech, since: 0, strict: true).contains {
            $0.start == acceptedMatch.start && $0.end >= acceptedMatch.end
        }
    }

    private func candidates(from position: CompanionTrackingPosition) -> [Line] {
        var lines: [Line] = []
        if let current = spokenLines[position.pageIndex].first(where: { $0.position == position }) {
            lines.append(current)
        }
        if let next = nextLine(after: position) {
            lines.append(next)
            if let step = nextLine(after: next.position), step.position.pageIndex == next.position.pageIndex,
               next.position.pageIndex == position.pageIndex {
                lines.append(step)
            }
        }
        return lines
    }

    private func nextLine(after position: CompanionTrackingPosition) -> Line? {
        guard !pages[position.pageIndex].isAppendix else { return nil }
        if let later = spokenLines[position.pageIndex].first(where: {
            ($0.position.sentenceIndex ?? -1) > (position.sentenceIndex ?? -1)
        }) {
            return later
        }
        // A body page without a spoken sentence remains manually reachable.
        // Do not use a later page to infer that this one was shown.
        return nextBodyPage(after: position.pageIndex).flatMap { spokenLines[$0].first }
    }

    func nextBodyPage(after index: Int) -> Int? {
        pages.indices.dropFirst(index + 1).first { !pages[$0].isAppendix }
    }

    private func resumedLine(from position: CompanionTrackingPosition, in tokens: [Token], speech: Speech, currentPageOnly: Bool) -> (Line, Match)? {
        let nearby = candidates(from: position)
        var sequences: [(Line, Match)] = []
        for first in nearby {
            guard let second = nextLine(after: first.position),
                  !currentPageOnly || second.position.pageIndex == position.pageIndex,
                  first.position.pageIndex == position.pageIndex
                    || second.position.pageIndex == first.position.pageIndex else { continue }
            // Repetition of the same line is weak evidence for resuming.
            guard first.words.map(\.word) != second.words.map(\.word) else { continue }
            for entry in alignments(first, in: tokens, speech: speech, since: 0, strict: true) {
                if let continuation = continuation(second, after: entry, in: tokens, speech: speech) {
                    sequences.append((second, continuation))
                }
            }
        }
        return sequences.min { $0.1.end < $1.1.end }
    }

    private func recoverRestart(after position: CompanionTrackingPosition, speech: Speech, in content: [Token]) -> (Line, Match)? {
        let words = speech.words
        guard let transcriptBeforeRestart, words.count <= consumedThrough + 1 else { return nil }
        let shared = zip(transcriptBeforeRestart.words, words).prefix { $0 == $1 }.count
        let fresh = content.filter { $0.index >= shared }.suffix(72)
        guard let recovery = samePageContinuation(after: position, in: Array(fresh), speech: speech) else { return nil }
        // Also reject a revised partial that merely replays a pair already
        // present before the old cursor, even if the start of the text changed.
        let consumed = Self.contentTokens(Array(transcriptBeforeRestart.words.prefix(consumedThrough + 1))).suffix(72)
        guard samePageContinuation(after: position, in: Array(consumed), speech: transcriptBeforeRestart) == nil else { return nil }
        return recovery
    }

    private func samePageContinuation(after position: CompanionTrackingPosition, in tokens: [Token], speech: Speech) -> (Line, Match)? {
        guard let first = nextLine(after: position), first.position.pageIndex == position.pageIndex,
              let second = nextLine(after: first.position), second.position.pageIndex == position.pageIndex,
              first.words.map(\.word) != second.words.map(\.word) else { return nil }
        for entry in alignments(first, in: tokens, speech: speech, since: 0, strict: true) {
            if let following = continuation(second, after: entry, in: tokens, speech: speech) { return (second, following) }
        }
        return nil
    }

    private func corroboratesEntry(_ line: Line, after match: Match, in tokens: [Token], speech: Speech) -> Bool {
        guard let following = nextLine(after: line.position),
              following.position.pageIndex == line.position.pageIndex,
              following.words.map(\.word) != line.words.map(\.word) else { return false }
        return continuation(following, after: match, in: tokens, speech: speech) != nil
    }

    private func continuation(_ line: Line, after first: Match, in tokens: [Token], speech: Speech) -> Match? {
        let tail = tokens.filter { $0.index > first.end && $0.index <= first.end + line.words.count * 3 + 12 }
        return alignments(line, in: tail, speech: speech, since: first.end + 1, strict: true)
            .filter { $0.start - first.end <= 12 }
            .max { $0.score < $1.score }
    }

    private func unambiguous(
        _ eligible: [(Line, Match)],
        comparedTo all: [(Line, Match)]
    ) -> (Line, Match)? {
        for (line, evidence) in eligible.sorted(by: { $0.1.start < $1.1.start }) {
            let competitor = all.contains { other, competing in
                other.position != line.position
                    && competing.start <= evidence.end && evidence.start <= competing.end
                    && competing.score >= evidence.score - 0.12
            }
            if !competitor { return (line, evidence) }
        }
        return nil
    }

    private func preparedNext(from position: CompanionTrackingPosition, among nearby: [Line], in tokens: [Token],
                              speech: Speech, since floor: Int) -> (Line, Match)? {
        guard let next = nextLine(after: position), next.position.pageIndex == position.pageIndex,
              !next.alternatives.isEmpty else { return nil }
        let prepared = nearby.flatMap { line in
            line.alternatives.flatMap { wording in
                alignments(line, in: tokens, speech: speech, since: floor, strict: true, wording: wording)
                    .filter { $0.coverage == 1 }.map { (line, $0) }
            }
        }
        return unambiguous(prepared.filter { $0.0.position == next.position }, comparedTo: prepared)
    }

    private func match(_ line: Line, in tokens: [Token], speech: Speech, since floor: Int, strict: Bool) -> Match? {
        alignments(line, in: tokens, speech: speech, since: floor, strict: strict).max { $0.score < $1.score }
    }

    private func alignments(_ line: Line, in tokens: [Token], speech: Speech, since floor: Int,
                            strict: Bool, wording: [Token]? = nil) -> [Match] {
        let script = wording ?? line.words
        let minimumAnchors = strict ? 3 : min(3, script.count)
        let coverageNeeded = strict ? 0.70 : (script.count <= 3 ? 1.0 : 0.58)
        guard script.count >= max(2, minimumAnchors), tokens.count >= minimumAnchors else { return [] }

        // Try each starting anchor. The rest must keep order and remain locally
        // contiguous, so scattered repeated terms cannot add up over the talk.
        var results: [Match] = []
        for (start, heard) in tokens.enumerated() {
            for (first, expected) in script.enumerated() where Self.equivalent(heard.word, expected.word) {
                var matches = 1
                var anchors: Set<String> = [expected.word]
                var last = start
                for word in script.dropFirst(first + 1) {
                    let end = min(last + 4, tokens.count)
                    if let index = (last + 1..<end).first(where: { Self.equivalent(tokens[$0].word, word.word) }) {
                        matches += 1
                        anchors.insert(word.word)
                        last = index
                    }
                }
                let coverage = Double(matches) / Double(script.count)
                guard anchors.count >= minimumAnchors, coverage >= coverageNeeded,
                      last - start + 1 <= matches + 2 else { continue }
                let evidence = Match(start: heard.index, end: tokens[last].index, coverage: coverage, anchors: anchors.count)
                guard speech.assertion(for: evidence, since: floor) == line.assertion else { continue }
                results.append(evidence)
            }
        }
        return results
    }

    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en-US"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// A second check at use time protects older saved preparations as well.
    /// Semantic equivalence is established during preparation, outside the live matcher.
    static func preservesPreparedAssertion(_ alternative: String, source: String) -> Bool {
        let words = words(in: CompanionTrackingPage.withoutActions(source))
        let assertion = Assertion(words[...], firstAnchor: contentTokens(words).first?.index ?? 0)
        return preparedWords(alternative, source: words, assertion: assertion) != nil
    }

    private static func preparedWords(_ text: String, source: [String], assertion: Assertion) -> [Token]? {
        guard text.count <= 240, SpeechTextAlignment.annotationRanges(in: text).isEmpty,
              CompanionTrackingPage.sentences(in: text).count == 1 else { return nil }
        let words = Self.words(in: text)
        let tokens = contentTokens(words)
        guard words.count <= 40, words != source, Set(tokens.map(\.word)).count >= 4,
              Assertion(words[...], firstAnchor: tokens.first?.index ?? 0) == assertion,
              words.filter({ $0.first?.isNumber == true }) == source.filter({ $0.first?.isNumber == true }) else { return nil }
        return tokens
    }

    private static func contentTokens(_ words: [String]) -> [Token] {
        words.enumerated().compactMap { index, word in
            guard !stopWords.contains(word), word.count > 1 || word.first?.isNumber == true else { return nil }
            return Token(word: word, index: index)
        }
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let stem = { (word: String) -> String in
            guard word.count >= 5 else { return word }
            for suffix in ["ies", "ing", "ed", "es", "s"] where word.hasSuffix(suffix) {
                let root = word.dropLast(suffix.count)
                if root.count >= 3 { return String(root) + (suffix == "ies" ? "y" : "") }
            }
            return word
        }
        return stem(lhs) == stem(rhs)
    }
}
