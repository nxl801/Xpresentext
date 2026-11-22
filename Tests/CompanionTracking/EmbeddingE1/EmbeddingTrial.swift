import Foundation
import NaturalLanguage

private struct TrialInput: Decodable {
    struct TrialCase: Decodable {
        struct Sample: Decodable {
            let timeMs: Int?
            let oracle: String
            let tail: String
        }

        let id: String
        let phase: String
        let group: String
        let target: String?
        let source: String
        let annotationMs: Int?
        let samples: [Sample]
    }
    let groups: [String: [String: String]]
    let cases: [TrialCase]
}

private struct Score: Encodable {
    let scriptPosition: String
    let cosine: Double
}

private struct Observation: Encodable {
    let timeMs: Int?
    let view: String
    let tokenCount: Int
    let elapsedMs: Double
    let scores: [Score]
    var winner: String { scores[0].scriptPosition }
    var best: Double { scores[0].cosine }
    var margin: Double { best - scores[1].cosine }
}

private struct TrialCaseResult: Encodable {
    let id: String
    let phase: String
    let group: String
    let target: String?
    let source: String
    let annotationMs: Int?
    let observations: [Observation]
}

private struct Evaluation: Encodable {
    let minimumScore: Double
    let minimumMargin: Double
    let view: String
    let replayOnly: Bool
    let phaseAware: Bool
    let positiveTotal: Int
    let acceptedCorrectly: Int
    let wrongPositives: [String]
    let missedPositives: [String]
    let negativeTotal: Int
    let falseAdvances: [String]
}

private struct Report: Encodable {
    let model: String
    let revision: Int
    let dimensions: Int
    let coldLoadMs: Double
    let firstVectorMs: Double
    let scoringMsMedian: Double
    let scoringMsMaximum: Double
    let evaluations: [Evaluation]
    let cases: [TrialCaseResult]
}

@main
struct EmbeddingTrial {
    static func main() throws {
        let start = ContinuousClock.now
        guard let model = NLEmbedding.sentenceEmbedding(for: .english) else {
            print("No installed English sentence embedding")
            exit(2)
        }
        let loadMs = milliseconds(since: start)
        let firstStart = ContinuousClock.now
        guard model.vector(for: "A local sentence embedding check.") != nil else {
            print("The system could not produce a local English sentence vector")
            exit(2)
        }
        let firstVector = milliseconds(since: firstStart)
        let args = CommandLine.arguments
        guard args.count == 2 else { exit(2) }
        let input = try JSONDecoder().decode(TrialInput.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let cachedReferences = input.groups.mapValues { group in group.compactMapValues { vector($0, using: model) } }
        let results = input.cases.map { item in
            let references = cachedReferences[item.group]!
            let observations = item.samples.flatMap { sample in
                [("annotated-phrase", sample.oracle), ("latest-ten-words", sample.tail)].compactMap { view, text -> Observation? in
                    let count = text.split(whereSeparator: \.isWhitespace).count
                    guard count >= 3 else { return nil }
                    let started = ContinuousClock.now
                    guard let query = vector(text, using: model) else { return nil }
                    let scores = references.map { location, reference in
                        Score(scriptPosition: location, cosine: zip(query, reference).reduce(0) { $0 + $1.0 * $1.1 })
                    }.sorted {
                        if $0.cosine == $1.cosine { return $0.scriptPosition < $1.scriptPosition }
                        return $0.cosine > $1.cosine
                    }
                    guard scores.count >= 2 else { return nil }
                    return Observation(timeMs: sample.timeMs, view: view, tokenCount: count, elapsedMs: milliseconds(since: started), scores: scores)
                }
            }
            return TrialCaseResult(
                id: item.id, phase: item.phase, group: item.group, target: item.target, source: item.source,
                annotationMs: item.annotationMs, observations: observations
            )
        }
        let times = results.flatMap(\.observations).map(\.elapsedMs).sorted()
        guard !times.isEmpty else { exit(2) }

        var evaluations: [Evaluation] = []
        for view in ["annotated-phrase", "latest-ten-words"] {
            for (score, margin) in [(0.70, 0.04), (0.85, 0.08)] {
                for replayOnly in [true, false] {
                    evaluations.append(evaluate(
                        results, view: view, replayOnly: replayOnly, phaseAware: true, score: score, margin: margin
                    ))
                }
            }
        }
        let report = Report(
            model: "macOS NaturalLanguage NLEmbedding English sentence", revision: model.revision, dimensions: model.dimension,
            coldLoadMs: loadMs, firstVectorMs: firstVector, scoringMsMedian: times[times.count / 2],
            scoringMsMaximum: times.last!, evaluations: evaluations, cases: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report) + Data([10]))
    }

    private static func vector(_ text: String, using model: NLEmbedding) -> [Double]? {
        let normalized = text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        guard let values = model.vector(for: normalized) else { return nil }
        let magnitude = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return nil }
        return values.map { $0 / magnitude }
    }

    private static func evaluate(
        _ results: [TrialCaseResult], view: String, replayOnly: Bool, phaseAware: Bool, score: Double, margin: Double
    ) -> Evaluation {
        let items = replayOnly ? results.filter { $0.annotationMs != nil } : results
        var correct = 0
        var wrong: [String] = []
        var missed: [String] = []
        var falseAdvance: [String] = []
        for item in items {
            let first = item.observations.first {
                $0.view == view && $0.best >= score && $0.margin >= margin
                    && (!phaseAware || item.phase == "following")
            }
            if let target = item.target {
                if first?.winner == target { correct += 1 }
                else if first == nil { missed.append(item.id) }
                else { wrong.append(item.id) }
            } else if first != nil {
                falseAdvance.append(item.id)
            }
        }
        return Evaluation(
            minimumScore: score, minimumMargin: margin, view: view, replayOnly: replayOnly, phaseAware: phaseAware,
            positiveTotal: items.filter { $0.target != nil }.count, acceptedCorrectly: correct, wrongPositives: wrong,
            missedPositives: missed, negativeTotal: items.filter { $0.target == nil }.count, falseAdvances: falseAdvance
        )
    }

    private static func milliseconds(since time: ContinuousClock.Instant) -> Double {
        let elapsed = time.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
}
