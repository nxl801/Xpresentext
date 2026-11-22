import Foundation

extension CompanionQATests {
    @MainActor
    static func liveQuestionFlow() async throws {
        let unavailable = RecordedModel { _, stream in stream.finish(throwing: QAServiceError.transport) }
        let local = RecordedModel { request, stream in
            defer { stream.finish() }
            let input = try? JSONDecoder().decode(RequestInput.self, from: Data(request.input.utf8))
            let evidence = input?.evidence.first { $0.text.contains("83%") }
            stream.yield(line("short", "grounded", "Orchid coverage reached 83%.", evidence))
        }
        let session = CompanionQASession(service: .init(model: unavailable), fallback: { .init(model: local) })
        session.setDeck(deck())
        session.prepareSources(for: "Cedar logger", currentPageIndex: 0, followUp: false)
        session.prepareSources(for: "Orchid coverage", currentPageIndex: 0, followUp: false)
        try await until("revised local partial finds Orchid") { session.suggestedSources.first?.pageNumber == 5 }
        let before = await unavailable.requests.count
        try expect(before == 0 && session.question.isEmpty, "A partial utterance submitted a question")
        session.submit("Orchid coverage", currentPageIndex: 0, fromSpeech: true)
        try await until("local fallback finishes") { session.state == .completed }
        try expect(session.usingLocalModel && session.answer.shortAnswer?.contains("83%") == true &&
                   session.answer.citations.first?.pageNumber == 5 && session.suggestedSources.isEmpty,
                   "Offline answer lost its verified page")
        let cloudCalls = await unavailable.requests.count
        let localCalls = await local.requests.count
        try expect(cloudCalls == 1 && localCalls == 1, "Request was duplicated after a provider failed")
        session.prepareSources(for: "Cedar logger", currentPageIndex: 0, followUp: false)
        session.setDeck(deck(revisionID: "new"))
        try await Task.sleep(for: .milliseconds(250))
        try expect(session.suggestedSources.isEmpty && session.question.isEmpty, "Old presearch survived a deck change")

        let interrupted = RecordedModel { request, stream in
            let input = try? JSONDecoder().decode(RequestInput.self, from: Data(request.input.utf8))
            let evidence = input?.evidence.first { $0.text.contains("83%") }
            stream.yield(line("short", "grounded", "Orchid coverage reached 83%.", evidence))
            stream.finish(throwing: QAServiceError.transport)
        }
        let midAnswer = CompanionQASession(service: .init(model: interrupted), fallback: { .init(model: local) })
        midAnswer.setDeck(deck())
        midAnswer.submit("Orchid coverage")
        try await until("partial answer interruption") { midAnswer.state == .failed(.transport) }
        try expect(midAnswer.answer.shortAnswer != nil && midAnswer.answer.citations.first?.pageNumber == 5 &&
                   !midAnswer.usingLocalModel, "Connection loss replaced an already readable sentence")

        let offline = CompanionQASession(service: .init(model: unavailable), fallback: { nil })
        offline.setDeck(deck())
        offline.submit("Orchid 的覆盖率是什么？")
        try await until("offline Chinese evidence lookup") { offline.state == .failed(.transport) }
        try expect(offline.answer.shortAnswer == nil && offline.answer.citations.contains { $0.pageNumber == 5 },
                   "Offline mixed-language question lost the original slide")
        print("PASS live question flow: revised partial stays local, verified loopback fallback, interruption preserves sentence and source, stale search discarded")
    }

    @MainActor
    static func actualLocalFallback(port: UInt16, model: String) async throws {
        let failedNetwork = RecordedModel { _, stream in stream.finish(throwing: QAServiceError.transport) }
        let client = OpenAIChatQATransport(provider: .loopback(port: port, model: model), apiKeyProvider: {
            throw TestFailure(description: "Loopback tried to read a cloud key")
        })
        let session = CompanionQASession(service: .init(model: failedNetwork), fallback: { .init(model: client) })
        session.setDeck(deck())
        session.submit("What coverage did Orchid reach?")
        let deadline = ContinuousClock.now.advanced(by: .seconds(26))
        while session.state == .answering, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
        try expect(session.usingLocalModel && session.answer.shortAnswerPoint?.kind == .grounded &&
                   session.answer.citations.contains { $0.pageNumber == 5 } && session.answer.shortAnswer?.contains("83%") == true,
                   "Actual oMLX failed the grounded short answer: \(session.state)")
        print("PASS actual oMLX via production fallback | \(session.answer.shortAnswer ?? "") | page 5 | \(session.answer.firstSentenceElapsed ?? .zero) | \(session.state)")
    }
}
