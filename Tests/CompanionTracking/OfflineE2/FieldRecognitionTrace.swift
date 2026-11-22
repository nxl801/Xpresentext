import Foundation

/// Keep enough of the English follow callbacks to distinguish missing speech
/// from a matcher stall. Only words in the prepared script are recoverable.
struct FieldRecognitionTrace: Encodable {
    struct Update: Encodable {
        let atMs: Int
        let request: Int
        let isFinal: Bool
        let prefixCount: Int
        let suffix: [Int]
    }

    let scriptWords: [String]
    private(set) var updates: [Update] = []
    private var ids: [String: Int]
    private var nextUnknown = -1
    private var previous: [Int] = []
    private enum CodingKeys: String, CodingKey { case scriptWords, updates }

    init(script: [String]) {
        scriptWords = Set(script.flatMap(CompanionTrackingMatcher.words(in:))).sorted()
        ids = Dictionary(uniqueKeysWithValues: scriptWords.enumerated().map { ($1, $0) })
    }

    mutating func record(_ text: String, final: Bool, request: Int, atMs: Int) {
        if request != updates.last?.request { previous.removeAll(keepingCapacity: true) }
        let tokens = CompanionTrackingMatcher.words(in: text).map { word in
            if let id = ids[word] { return id }
            let id = nextUnknown
            ids[word] = id
            nextUnknown -= 1
            return id
        }
        let common = zip(tokens, previous).prefix(while: ==).count
        updates.append(Update(atMs: atMs, request: request, isFinal: final, prefixCount: common,
                              suffix: Array(tokens.dropFirst(common))))
        previous = tokens
    }
}
