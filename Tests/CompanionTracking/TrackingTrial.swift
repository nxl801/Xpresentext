import Foundation

private struct Trial: Decodable {
    let source: String
    let sourcePageNumbers: [Int]
    let provenance: String
    let transcription: String
    let pages: [[String]]
    let clips: [Clip]
}

private struct Clip: Decodable {
    let id: String
    let start: [Int]
    let phase: String
    let audioSha256: String
    let events: [Snapshot]
}

private struct Snapshot: Decodable {
    let referenceMs: Int
    let cutoffMs: Int
    let recognitionMs: Int
    let expected: [Int]
    let kind: String
    let transcript: String
}

private struct ResultRow: Encodable {
    let clip: String
    let snapshot: Int
    let kind: String
    let expected: String
    let actual: String
    let referenceMs: Int
    let recognitionMs: Int
    let delayMs: Int?
    let unexpectedPageFlip: Bool
    let wrongPosition: Bool
    let missedResume: Bool
    let modelDecision: String?
    let modelMs: Int?
}

private struct Results: Encodable {
    let name: String
    let snapshots: Int
    let wrongPositions: Int
    let unexpectedPageFlips: Int
    let expectedResumeMisses: Int
    let expectedFollowMisses: Int
    let modelCalls: Int
    let modelTimeouts: Int
    let modelErrors: Int
    let acceptedMatchingFollowLatencyMs: [Int]
    let acceptedResumeLatencyMs: [Int]
    let rows: [ResultRow]

    init(name: String, rows: [ResultRow]) {
        self.name = name
        snapshots = rows.count
        wrongPositions = rows.filter(\.wrongPosition).count
        unexpectedPageFlips = rows.filter(\.unexpectedPageFlip).count
        expectedResumeMisses = rows.filter(\.missedResume).count
        expectedFollowMisses = rows.filter { $0.kind == "follow" && $0.wrongPosition }.count
        modelCalls = rows.compactMap(\.modelMs).count
        modelTimeouts = rows.filter { $0.modelDecision == "timeout" || $0.modelDecision == "late" }.count
        modelErrors = rows.filter { $0.modelDecision == "error" || $0.modelDecision == "invalid" }.count
        acceptedMatchingFollowLatencyMs = rows.filter { $0.kind == "follow" }.compactMap(\.delayMs)
        acceptedResumeLatencyMs = rows.filter { $0.kind == "resume" }.compactMap(\.delayMs)
        self.rows = rows
    }
}

private struct Summary: Encodable {
    let source: String
    let sourcePageNumbers: [Int]
    let provenance: String
    let transcription: String
    let model: String?
    let audioHashes: [String: String]
    let baseline: Results
    let assisted: Results?
}

private struct Candidate {
    let location: CompanionTrackingPosition
    let lines: [String]
}

private struct LocalAdjudicator {
    let endpoint: URL
    let model: String
    static let modelBudgetMs = 1_800

    func decide(transcript: String, options: [Candidate]) async -> (decision: String, elapsed: Int) {
        let start = ContinuousClock.now
        let context = options.enumerated().map { offset, candidate in
            "\(offset + 1). " + candidate.lines.joined(separator: " FOLLOWED DIRECTLY BY ")
        }.joined(separator: "\n")
        let instruction = """
        Decide whether the speaker is presently delivering one of the numbered local script options.
        Shared topics, an example, a quote, a question, or an accidental phrase are insufficient.
        A two-line option requires both distinct ideas in sequence near the end of speech, without an unrelated digression between them.
        A one-line option requires the complete distinctive idea, even if rephrased.
        Reply with only a single digit. Use 0 to hold when uncertain.
        """
        let messages = [
            ["role": "system", "content": instruction],
            ["role": "user", "content": "Options\n\(context)\n\nRecent speech\n\(transcript)"]
        ]
        let payload: [String: Any] = [
            "model": model, "messages": messages, "temperature": 0, "max_tokens": 16,
            "chat_template_kwargs": ["enable_thinking": false]
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: Double(Self.modelBudgetMs) / 1000)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let decision: String
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let completion = try? JSONDecoder().decode(Completion.self, from: data),
                  let content = completion.choices.first?.message.content else {
                return ("error", Self.milliseconds(since: start))
            }
            let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
            decision = Int(value).map { (0...options.count).contains($0) } == true ? value : "invalid"
        } catch let error as URLError where error.code == .timedOut {
            decision = "timeout"
        } catch {
            decision = "error"
        }
        return (decision, Self.milliseconds(since: start))
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }
}

@main
struct TrackingTrial {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 1 || arguments.count == 3 else {
            print("Usage: tracking-trial <shared-transcripts.json> [<loopback-port> <model-name>]")
            exit(2)
        }
        let trial = try JSONDecoder().decode(Trial.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
        var adjudicator: LocalAdjudicator?
        if arguments.count == 3 {
            guard let port = UInt16(arguments[1]), port > 0 else { throw URLError(.badURL) }
            let localURL = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
            adjudicator = LocalAdjudicator(endpoint: localURL, model: arguments[2])
        }
        let baseline = await run(trial, using: nil)
        let assisted: Results?
        if let adjudicator {
            assisted = await run(trial, using: adjudicator)
        } else {
            assisted = nil
        }
        let summary = Summary(
            source: trial.source, sourcePageNumbers: trial.sourcePageNumbers, provenance: trial.provenance,
            transcription: trial.transcription, model: adjudicator?.model,
            audioHashes: Dictionary(uniqueKeysWithValues: trial.clips.map { ($0.id, $0.audioSha256) }),
            baseline: baseline, assisted: assisted
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(summary) + Data([10]))
    }

    private static func run(_ trial: Trial, using model: LocalAdjudicator?) async -> Results {
        let pages = trial.pages.map { CompanionTrackingPage(sentences: $0) }
        var rows: [ResultRow] = []
        for clip in trial.clips {
            var matcher = CompanionTrackingMatcher(pages: pages)
            matcher.select(pageIndex: clip.start[0], sentenceIndex: clip.start[1])
            var awaitingResume = clip.phase == "awaitingResume"
            let isQuestion = clip.phase == "listeningQuestion"
            var previousTranscript = ""
            var assistedPrefix = ""
            var priorExpected = clip.start[0]

            for (index, event) in clip.events.enumerated() {
                let before = matcher.position
                var modelDecision: String?
                var modelMs: Int?
                let transcript = withoutPrefix(event.transcript, prefix: assistedPrefix)

                if !isQuestion, matcher.process(transcript, awaitingResume: awaitingResume) {
                    awaitingResume = false
                }

                if !isQuestion, let model, matcher.position == before, event.transcript != previousTranscript {
                    let newWords = words(withoutPrefix(event.transcript, prefix: previousTranscript))
                    let options = candidates(for: matcher, awaitingResume: awaitingResume)
                    if newWords.count >= 4, !options.isEmpty {
                        let excerpt = words(transcript).suffix(46).joined(separator: " ")
                        let response = await model.decide(transcript: excerpt, options: options)
                        modelDecision = response.decision
                        modelMs = response.elapsed
                        let deadline = clip.events.dropFirst(index + 1).first.map {
                            $0.cutoffMs + $0.recognitionMs - event.cutoffMs - event.recognitionMs
                        } ?? LocalAdjudicator.modelBudgetMs
                        if response.elapsed > min(deadline, LocalAdjudicator.modelBudgetMs), response.decision != "timeout" {
                            modelDecision = "late"
                        }
                        if let modelDecision, let choice = Int(modelDecision), choice > 0 {
                            let chosen = options[choice - 1]
                            matcher.select(pageIndex: chosen.location.pageIndex, sentenceIndex: chosen.location.sentenceIndex)
                            assistedPrefix = event.transcript
                            awaitingResume = false
                        }
                    }
                }

                let expected = CompanionTrackingPosition(pageIndex: event.expected[0], sentenceIndex: event.expected[1])
                let wrong = matcher.position != expected
                let missedResume = event.kind == "resume" && (awaitingResume || wrong)
                let latency: Int? = !wrong && !missedResume && event.kind != "hold"
                    ? event.cutoffMs + event.recognitionMs + (before == matcher.position ? 0 : (modelMs ?? 0)) - event.referenceMs
                    : nil
                let flipped = before?.pageIndex != matcher.position?.pageIndex
                let unexpected = flipped && (priorExpected == expected.pageIndex || matcher.position?.pageIndex != expected.pageIndex)
                rows.append(ResultRow(
                    clip: clip.id, snapshot: index + 1, kind: event.kind,
                    expected: label(expected, pages: trial.sourcePageNumbers),
                    actual: label(matcher.position, pages: trial.sourcePageNumbers),
                    referenceMs: event.referenceMs, recognitionMs: event.recognitionMs, delayMs: latency,
                    unexpectedPageFlip: unexpected, wrongPosition: wrong, missedResume: missedResume,
                    modelDecision: modelDecision, modelMs: modelMs
                ))
                previousTranscript = event.transcript
                priorExpected = expected.pageIndex
            }
        }
        return Results(name: model == nil ? "baseline" : "local-oMLX-when-stalled", rows: rows)
    }

    private static func candidates(for matcher: CompanionTrackingMatcher, awaitingResume: Bool) -> [Candidate] {
        guard let current = matcher.position, let next = matcher.nextPosition,
              let currentLine = matcher.sentence(at: current), let nextLine = matcher.sentence(at: next) else { return [] }
        if !awaitingResume, current.pageIndex == next.pageIndex {
            return [Candidate(location: next, lines: [nextLine])]
        }
        var candidates = [Candidate(location: next, lines: [currentLine, nextLine])]
        var moved = matcher
        moved.select(pageIndex: next.pageIndex, sentenceIndex: next.sentenceIndex)
        if let after = moved.nextPosition, after.pageIndex == next.pageIndex,
           let afterLine = moved.sentence(at: after) {
            candidates.append(Candidate(location: after, lines: [nextLine, afterLine]))
        }
        return candidates
    }

    private static func label(_ position: CompanionTrackingPosition?, pages: [Int]) -> String {
        guard let position else { return "-" }
        let sentence = position.sentenceIndex.map { String($0 + 1) } ?? "-"
        return "\(pages[position.pageIndex]).\(sentence)"
    }

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    private static func withoutPrefix(_ text: String, prefix: String) -> String {
        guard !prefix.isEmpty else { return text }
        let prior = words(prefix)
        let fresh = words(text)
        let similar = zip(prior, fresh).prefix { $0.lowercased() == $1.lowercased() }.count
        guard similar >= prior.count - 2 else { return text }
        return fresh.dropFirst(min(prior.count, fresh.count)).joined(separator: " ")
    }
}
