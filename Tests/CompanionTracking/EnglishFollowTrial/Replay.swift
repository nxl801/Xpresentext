import Foundation

private struct Fixture: Decodable {
    struct Line: Decodable { let id: String; let text: String }
    struct Example: Decodable {
        let id: String
        let state: String
        let transcript: String
        let expected: String
    }

    let script: [Line]
    let prepared: [Line]
    let cases: [Example]
}

private struct Callback: Decodable {
    let atMs: Int?
    let transcript: String
    let isFinal: Bool
}

private struct Decision: Encodable {
    let arrivalMs: Int?
    let lineID: String
}

private struct Result: Encodable {
    let input: String
    let example: String
    let prepared: Bool
    let expected: String
    let callbacks: Int
    let finalCallbacks: Int
    let decisions: [Decision]
    let passed: Bool
}

@main
private enum EnglishFollowReplay {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 3, arguments.count.isMultiple(of: 2) == false else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let reader = JSONDecoder()
        let fixture = try reader.decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
        let alternatives = Dictionary(grouping: fixture.prepared, by: \.id)
        let prepared = Dictionary(uniqueKeysWithValues: fixture.script.enumerated().compactMap { index, line in
            alternatives[line.id].map { (index, $0.map(\.text)) }
        })
        var results: [Result] = []
        for index in stride(from: 1, to: arguments.count, by: 2) {
            let input = arguments[index]
            let directory = arguments[index + 1]
            for example in fixture.cases {
                let callbacks: [Callback]
                if directory == "-" {
                    callbacks = [Callback(atMs: nil, transcript: example.transcript, isFinal: false)]
                } else {
                    let file = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(example.id + ".jsonl")
                    callbacks = try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline)
                        .map { try reader.decode(Callback.self, from: Data($0.utf8)) }
                    let timed = callbacks.compactMap(\.atMs)
                    guard callbacks.contains(where: { !$0.transcript.isEmpty }), timed.count == callbacks.count,
                          timed.first.map({ $0 >= 0 }) == true, timed == timed.sorted() else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
                for usePrepared in [false, true] {
                    var matcher = CompanionTrackingMatcher(pages: [CompanionTrackingPage(
                        sentences: fixture.script.map(\.text), sentenceAlternatives: usePrepared ? prepared : [:]
                    )])
                    var waiting = example.state == "awaitingResume"
                    var decisions: [Decision] = []
                    for callback in callbacks {
                        let previous = matcher.position
                        if matcher.process(callback.transcript, awaitingResume: waiting) { waiting = false }
                        if let moved = matcher.position, previous != moved, let sentence = moved.sentenceIndex {
                            decisions.append(Decision(arrivalMs: callback.atMs, lineID: fixture.script[sentence].id))
                        }
                        if callback.isFinal { matcher.resetTranscript() }
                    }
                    let expected = example.expected == "STAY" ? [] : [example.expected]
                    results.append(Result(input: input, example: example.id, prepared: usePrepared, expected: example.expected,
                                          callbacks: callbacks.count, finalCallbacks: callbacks.filter(\.isFinal).count,
                                          decisions: decisions, passed: decisions.map(\.lineID) == expected))
                }
            }
        }
        let writer = JSONEncoder()
        writer.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try writer.encode(results), as: UTF8.self))
    }
}
