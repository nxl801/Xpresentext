import Foundation

@MainActor
private final class ReplaySpeech: CompanionSpeechInput {
    private var listener: (@MainActor (CompanionSpeechEvent) -> Void)?
    func start(localeIdentifier: String, reportLevel: Bool,
               onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void) {
        listener = onEvent
        onEvent(.started)
    }
    func finish() {}
    func cancel() { listener = nil }
    func deliver(_ transcript: String) { listener?(.transcript(transcript, isFinal: false)) }
}

private struct OfflineTrialModel: QAModel {
    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: QAServiceError.transport) }
    }
}

@MainActor
enum VoiceWorkspaceAcceptance {
    struct Corpus: Decodable {
        struct Clip: Decodable {
            struct Event: Decodable { let expected: [Int]; let transcript: String; let kind: String }
            let id: String
            let start: [Int]
            let phase: String
            let events: [Event]
        }
        let sourcePageNumbers: [Int]
        let pages: [[String]]
        let clips: [Clip]
    }

    static func run(ppt: URL, manifest: URL, scratch: URL) async throws {
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: manifest))
        let store = DeckStore(rootURL: scratch.appendingPathComponent("Rehearsal"))
        let speech = ReplaySpeech()
        let tracking = CompanionTrackingController(speech: speech)
        let ws = StudioWorkspace(store: store, model: OfflineTrialModel(), chartCacheDirectory: scratch.appendingPathComponent("Evidence"), tracking: tracking)
        ws.openURL(ppt)
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while ws.importing != nil || ws.preparingCharts {
            guard ContinuousClock.now < deadline else { throw StudioError.message("Trial import timed out") }
            try await Task.sleep(for: .milliseconds(80))
        }
        guard let project = ws.project, corpus.pages.count == corpus.sourcePageNumbers.count else {
            throw StudioError.message("Could not open the presentation and its matching corpus")
        }
        ws.updateAppendix(from: 1)
        for (index, number) in corpus.sourcePageNumbers.enumerated() {
            guard ws.slides.indices.contains(number - 1) else { throw StudioError.message("Trial slide missing") }
            ws.updateAppendix(single: (number, false))
            tracking.select(pageIndex: number - 1)
            ws.editCurrentSlide { slide in
                slide.script.edit("")
                let source = DeckDraftSource(revisionID: project.activeRevisionID, pageNumber: number,
                                             evidenceIDs: [slide.id], provider: "Local test corpus")
                slide.script.setAIDraft(corpus.pages[index].joined(separator: "\n"), source: source)
            }
        }
        guard await ws.flushSave() else { throw StudioError.message("Could not prepare the isolated test project") }
        var total = 0, wrongSentence = 0, wrongPage = 0, missedResume = 0
        for clip in corpus.clips {
            tracking.select(pageIndex: corpus.sourcePageNumbers[clip.start[0]] - 1, sentenceIndex: clip.start[1])
            tracking.startFollowing()
            if clip.phase == "listeningQuestion" { tracking.startQuestion { _ in } }
            if clip.phase == "awaitingResume" { ws.submitQuestion("Please repeat that.", followUp: false) }
            for event in clip.events {
                speech.deliver(event.transcript)
                total += 1
                let page = corpus.sourcePageNumbers[event.expected[0]]
                if ws.currentSlide?.pageNumber != page { wrongPage += 1 }
                if tracking.position?.sentenceIndex != event.expected[1] { wrongSentence += 1 }
                if event.kind == "resume", tracking.phase != .following { missedResume += 1 }
                if clip.phase == "listeningQuestion", tracking.phase != .listeningQuestion {
                    throw StudioError.message("Replayed question released its position lock")
                }
            }
            tracking.cancelQuestion()
            tracking.stopFollowing()
        }
        print("WORKSPACE REPLAY pages=\(ws.slides.count) speechPages=\(corpus.sourcePageNumbers) clips=\(corpus.clips.count) checkpoints=\(total) wrongPages=\(wrongPage) wrongSentences=\(wrongSentence) missedResume=\(missedResume)")
        guard total > 0, wrongPage == 0, wrongSentence <= 1, missedResume == 0 else {
            throw StudioError.message("Workspace positions regressed against the saved corpus")
        }
    }
}
