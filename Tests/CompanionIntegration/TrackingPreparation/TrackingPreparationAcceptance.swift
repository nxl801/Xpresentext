import Foundation

private struct Failure: Error, CustomStringConvertible { let description: String }

private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(description: message) }
}

private let sourceSentence = "Discard duplicate deliveries before writing the ledger."
private let paraphrase = "Throw away any event we have already handled so it never gets recorded twice."

@MainActor
private final class SpeechFixture: CompanionSpeechInput {
    private var callback: (@MainActor (CompanionSpeechEvent) -> Void)?
    func start(localeIdentifier: String, reportLevel: Bool, onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void) {
        callback = onEvent
        onEvent(.started)
    }
    func finish() {}
    func cancel() { callback = nil }
    func hear(_ text: String) { callback?(.transcript(text, isFinal: false)) }
}

private final class Model: QAModel, @unchecked Sendable {
    private typealias Stream = AsyncThrowingStream<String, Error>
    enum Reply { case valid, invalid, hold }
    private let lock = NSLock()
    private var reply = Reply.valid
    private var requests: [QAModelRequest] = []
    private var held: Stream.Continuation?
    private var cancellations = 0

    func choose(_ reply: Reply) { lock.withLock { self.reply = reply } }
    var preparationRequests: [QAModelRequest] { lock.withLock { requests.filter { $0.purpose == .trackingPreparation } } }
    var answerRequests: [QAModelRequest] { lock.withLock { requests.filter { $0.purpose == .answer } } }
    var cancelled: Int { lock.withLock { cancellations } }

    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        Stream { output in
            let selected = lock.withLock { requests.append(request); return reply }
            switch request.purpose {
            case .trackingPreparation:
                switch selected {
                case .valid:
                    output.yield(Self.good)
                    output.finish()
                case .invalid:
                    output.yield(#"{"sentences":[{"id":1,"alternatives":["A cross-revision fake sentence cannot be useful."]}]}"#)
                    output.finish()
                case .hold:
                    output.onTermination = { [weak self] termination in
                        if case .cancelled = termination { self?.markCancelled() }
                    }
                    lock.withLock { held = output }
                }
            case .answer:
                do { output.yield(try Self.answer(request.input)); output.finish() }
                catch { output.finish(throwing: error) }
            default: output.finish(throwing: QAServiceError.invalidResponse)
            }
        }
    }

    func releaseOld() {
        let old = lock.withLock { held }
        old?.yield(Self.good)
        old?.finish()
    }

    private func markCancelled() { lock.withLock { cancellations += 1 } }

    private static let good = """
    {"sentences":[{"id":0,"alternatives":[]},
     {"id":1,"alternatives":["\(paraphrase)","Do not discard the repeated deliveries before logging them."]},
     {"id":2,"alternatives":["The local baseline measured 99% node coverage."]}]}
    """

    private static func answer(_ input: String) throws -> String {
        struct Input: Decodable {
            struct Evidence: Decodable { let id: String; let text: String }
            let evidence: [Evidence]
        }
        let answer = try JSONDecoder().decode(Input.self, from: Data(input.utf8))
        guard let evidence = answer.evidence.first(where: { $0.text.contains(sourceSentence) }) else {
            throw Failure(description: "The original statement did not reach the question service")
        }
        let payload: [String: Any] = ["part": "short", "kind": "grounded", "text": sourceSentence,
                                     "sources": [["id": evidence.id, "quote": sourceSentence]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }
}

@main @MainActor
private enum TrackingPreparationAcceptance {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
            if arguments.contains("--live-synthetic") { try await live(in: root) }
            else { try await controlled(in: root) }
        } catch {
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8)); exit(1)
        }
    }

    private static func workspace(in root: URL, model: any QAModel, speech: SpeechFixture) -> StudioWorkspace {
        StudioWorkspace(store: DeckStore(rootURL: root.appendingPathComponent("projects"), officeURL: nil), model: model,
                        chartCacheDirectory: root.appendingPathComponent("charts"), tracking: CompanionTrackingController(speech: speech))
    }

    private static func open(_ ws: StudioWorkspace, in root: URL, name: String = "original.pptx", replacing: Bool = false) async throws {
        ws.openURL(root.appendingPathComponent("fixtures/" + name), replacing: replacing)
        try await until("Fixture import did not finish") { ws.importing == nil && !ws.preparingCharts && ws.project?.activeRevision.sourceName == name }
    }

    private static func locate(_ text: String = paraphrase, on ws: StudioWorkspace, with speech: SpeechFixture) -> Int? {
        ws.tracking.select(pageIndex: 0, sentenceIndex: 0)
        ws.tracking.startFollowing()
        speech.hear(text)
        let result = ws.tracking.position?.sentenceIndex
        ws.tracking.stopFollowing()
        return result
    }

    private static func controlled(in root: URL) async throws {
        let model = Model()
        let speech = SpeechFixture()
        let ws = workspace(in: root, model: model, speech: speech)
        let fixture = root.appendingPathComponent("fixtures/original.pptx")
        let originalBytes = try Data(contentsOf: fixture)
        try await open(ws, in: root)
        ws.updateAppendix(single: (3, true))
        try check(await ws.flushSave(), "The appendix mark did not save")
        guard let original = ws.project else { throw Failure(description: "No original project") }
        let script = ws.slides[0].script.text
        try check(ws.provider == .deepseek && model.preparationRequests.isEmpty && locate(on: ws, with: speech) == 0 &&
                  locate(sourceSentence, on: ws, with: speech) == 1, "The unprepared workspace did not retain its original local follow path")
        ws.prepareTrackingAlternatives()
        try await until("Preparation did not finish") { !ws.preparingTracking }
        guard let request = model.preparationRequests.first else { throw Failure(description: "No model preparation request") }
        struct Sentence: Decodable { let id: Int; let text: String }
        let sent = try JSONDecoder().decode([Sentence].self, from: Data(request.input.utf8))
        try check(model.preparationRequests.count == 1 && request.image == nil && sent.map(\.id) == [0, 1, 2] &&
                  sent[1].text == sourceSentence && !request.input.contains("PACKAGING CUE") &&
                  !request.input.contains("Fixture title") && !request.input.contains("appendix"), "The explicit preparation did not minimize text or exclude stage cues")
        try check(ws.preparedTrackingPageCount == 1 && ws.slides[0].script.text == script && locate(on: ws, with: speech) == 1,
                  "Prepared phrasing did not identify its sentence, or it replaced the original")
        try check(locate("Do not discard the repeated deliveries before logging them.", on: ws, with: speech) == 0,
                  "Unsafe polarity changed preparation")
        let cache = TrackingPreparationCache(directory: ws.store.rootURL.appendingPathComponent("TrackingPreparation"))
        let key = TrackingPreparationCache.Key(projectID: original.id, revisionID: original.activeRevisionID,
                                              modelID: ws.provider.cacheIdentifier)
        let cached = cache.load(key)
        try check(cached.pages[ws.slides[0].id]?.alternatives == [1: [paraphrase]], "An altered numeric or negative claim entered the prepared cache")
        let otherModel = TrackingPreparationCache.Key(projectID: original.id, revisionID: original.activeRevisionID, modelID: "another-model")
        try check(cache.load(otherModel).pages.isEmpty, "Another model could see this preparation")

        ws.submitQuestion("What do we do with duplicate deliveries before writing the ledger?", followUp: false)
        try await until("Question did not complete") { ws.questions.state == .completed }
        try check(model.answerRequests.count == 1 && model.answerRequests.allSatisfy { !$0.input.contains(paraphrase) } &&
                  ws.questions.answer.citations.first?.pageNumber == 1, "Prepared aliases became askable evidence")

        ws.setPreparedTrackingEnabled(false)
        let reopenedSpeech = SpeechFixture()
        let reopened = workspace(in: root, model: model, speech: reopenedSpeech)
        reopened.openProject(original)
        try await until("Reopening did not load the active preparation") { reopened.project != nil && reopened.preparedTrackingPageCount == 1 }
        try check(!reopened.usesPreparedTracking && locate(on: reopened, with: reopenedSpeech) == 0,
                  "Reopening ignored the paused setting or treated aliases as original text")
        reopened.setPreparedTrackingEnabled(true)
        try check(locate(on: reopened, with: reopenedSpeech) == 1 && model.preparationRequests.count == 1,
                  "Reopen missed its cached alias or called the provider again")

        try await open(reopened, in: root, name: "revision.pptx", replacing: true)
        try check(reopened.project?.activeRevisionID != original.activeRevisionID && reopened.preparedTrackingPageCount == 0,
                  "An earlier version's preparation survived the revision boundary")
        reopened.chooseRevision(original.activeRevisionID)
        try await until("The original revision did not reopen") {
            reopened.project?.activeRevisionID == original.activeRevisionID && !reopened.preparingCharts && reopened.importing == nil
        }
        try check(await reopened.flushSave(), "Revision selection did not save")
        try check(reopened.preparedTrackingPageCount == 1, "Selecting a saved revision lost its valid preparation")

        reopened.tracking.select(pageIndex: 0, sentenceIndex: 0)
        reopened.editCurrentSlide { $0.script.edit(script.replacingOccurrences(of: "Discard duplicate deliveries before writing the ledger.",
                                                                                 with: "Audit accepted deliveries after recording the complete ledger.")) }
        try check(reopened.preparedTrackingPageCount == 0 && locate(on: reopened, with: reopenedSpeech) == 0,
                  "Edited lines still used a stale paraphrase")
        model.choose(.invalid)
        reopened.prepareTrackingAlternatives()
        try await until("Failure did not settle") { !reopened.preparingTracking }
        try check(reopened.preparedTrackingPageCount == 0 && reopened.notification?.contains("准备中断") == true &&
                  cache.load(key).pages[ws.slides[0].id] == cached.pages[ws.slides[0].id], "Failed preparation overwrote a saved result or surfaced no error")

        model.choose(.hold)
        reopened.prepareTrackingAlternatives()
        try await until("The first cancellable preparation did not start") { model.preparationRequests.count == 3 }
        reopened.editCurrentSlide { $0.script.edit("Validate retained source records before the storage check.\nThe next phase audits the updated store.") }
        try await until("Editing did not cancel pending model output") { model.cancelled == 1 && !reopened.preparingTracking }
        model.releaseOld()
        try check(reopened.preparedTrackingPageCount == 0, "Late output attached to the edited script")

        reopened.prepareTrackingAlternatives()
        try await until("The second cancellable preparation did not start") { model.preparationRequests.count == 4 }
        reopened.tracking.startFollowing()
        try await until("Starting follow did not cancel preparation") { model.cancelled == 2 && !reopened.preparingTracking }
        model.releaseOld()
        try check(!reopened.canPrepareTracking && reopened.preparedTrackingPageCount == 0, "Active follow accepted preparation")
        reopened.tracking.stopFollowing()
        try check(try Data(contentsOf: fixture) == originalBytes, "Preparation modified the original PPTX")
        print("PASS explicit workspace preparation, minimized payload, local follow, QA isolation, model/revision cache, reopening, pause, edits, invalid reply and cancellation")
    }

    private static func live(in root: URL) async throws {
        let ws = workspace(in: root, model: GrokCLIQAModel(), speech: SpeechFixture())
        try await open(ws, in: root)
        try check(ws.provider == .grokCLI, "The live harness does not select Grok CLI")
        ws.updateAppendix(single: (3, true))
        try check(await ws.flushSave(), "The synthetic appendix mark did not save")
        let start = ContinuousClock.now
        ws.prepareTrackingAlternatives()
        try await until("Live preparation did not complete within the CLI budget", seconds: 45) { !ws.preparingTracking }
        let duration = start.duration(to: .now)
        guard let project = ws.project else { throw Failure(description: "No synthetic project") }
        let cache = TrackingPreparationCache(directory: ws.store.rootURL.appendingPathComponent("TrackingPreparation"))
        let key = TrackingPreparationCache.Key(projectID: project.id, revisionID: project.activeRevisionID,
                                              modelID: ws.provider.cacheIdentifier)
        let alternatives = cache.load(key).pages[ws.slides[0].id]?.alternatives ?? [:]
        try check(ws.preparedTrackingPageCount == 1 && !alternatives.isEmpty,
                  "Live Grok produced no usable preparation after \(duration): \(ws.notification ?? ws.trackingPreparationStatus ?? "unknown")")
        let output = try JSONEncoder().encode(alternatives)
        print("PASS one synthetic page prepared through the actual Grok CLI in \(duration), alternatives: \(String(decoding: output, as: UTF8.self))")
    }

    private static func until(_ message: String, seconds: Int = 15, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            try check(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}
