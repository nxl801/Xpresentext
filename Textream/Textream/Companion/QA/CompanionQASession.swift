import Foundation
import Observation

@MainActor
@Observable
final class CompanionQASession {
    enum State: Equatable {
        case idle, answering, completed, failed(QAServiceError)
    }

    private(set) var state: State = .idle
    private(set) var answer = QAAnswer()
    private(set) var question = ""
    private(set) var canFollowUp = false
    private(set) var suggestedSources: [QACitation] = []
    private(set) var usingLocalModel = false
    private(set) var previousDisplay: (question: String, answer: QAAnswer)?
    private struct SearchKey: Equatable {
        let question: String
        let page: Int?
        let previousQuestion: String?
    }
    private struct Turn {
        let question: String
        let page: Int?
        let previous: CompanionQAService.PreviousTurn?
        let submittedAt: ContinuousClock.Instant
        let fromSpeech: Bool
    }
    private struct SpokenContext {
        let id: UUID
        let pageIndex: Int?
        let previous: CompanionQAService.PreviousTurn?
    }
    private var spokenContext: SpokenContext?
    var editableTranscriptID: UUID? { spokenContext?.id }

    @ObservationIgnored private let service: CompanionQAService
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var deck: QADeckSnapshot?
    @ObservationIgnored private var indexTask: Task<QADeckIndex, Never>?
    @ObservationIgnored private var previous: CompanionQAService.PreviousTurn?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var responseTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    @ObservationIgnored private let fallback: () -> CompanionQAService?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchID = UUID()
    @ObservationIgnored private var prepared: (SearchKey, [QADeckIndex.Match])?
    @ObservationIgnored private var turn: Turn?

    init(service: CompanionQAService, timeout: Duration? = nil,
         fallback: @escaping () -> CompanionQAService? = OpenAIChatQATransport.configuredLocalFallback) {
        self.fallback = fallback
        self.service = service
        self.timeout = timeout ?? service.model.answerTimeout
    }

    func setDeck(_ deck: QADeckSnapshot?) {
        guard deck != self.deck else { return }
        clearSearch()
        let previousDeck = self.deck
        self.deck = deck
        indexTask = deck.map { snapshot in
            Task.detached(priority: .userInitiated) { QADeckIndex(snapshot) }
        }
        if let old = previousDeck, let deck, old.projectID == deck.projectID, old.revisionID == deck.revisionID,
           old.pages.count == deck.pages.count, zip(old.pages, deck.pages).allSatisfy({ pair in
               let (oldPage, newPage) = pair
               return oldPage.index == newPage.index && oldPage.title == newPage.title &&
                   oldPage.bodyText == newPage.bodyText && oldPage.originalNotes == newPage.originalNotes &&
                   oldPage.speakerScript == newPage.speakerScript &&
                   Set(oldPage.visualEvidence).isSubset(of: Set(newPage.visualEvidence))
           }) {
            // Background chart enrichment keeps the sources already displayed for the current turn valid.
            return
        }
        cancel()
        answer = QAAnswer()
        question = ""
        previousDisplay = nil
        spokenContext = nil
        turn = nil
        usingLocalModel = false
        state = .idle
        setPrevious(nil)
    }

    /// Partial transcripts stay on this Mac. A revision, page change or correction supersedes earlier work.
    func prepareSources(for text: String, currentPageIndex: Int?, followUp: Bool) {
        let query = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))
        let key = SearchKey(question: query, page: currentPageIndex, previousQuestion: followUp ? previous?.question : nil)
        if key == prepared?.0 { return }
        clearSearch()
        guard query.count >= 3, let indexTask else { return }
        let id = searchID
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let index = await indexTask.value
            let matches = await Self.search(index, for: key)
            guard let self, self.searchID == id, !Task.isCancelled else { return }
            self.prepared = (key, matches)
            self.suggestedSources = Array(matches.prefix(2).map(\.citation))
        }
    }

    nonisolated private static func search(_ index: QADeckIndex, for key: SearchKey) async -> [QADeckIndex.Match] {
        index.search(key.question, previousQuestion: key.previousQuestion, focusPageIndex: key.page)
    }

    func clearSearch() {
        searchID = UUID()
        searchTask?.cancel()
        searchTask = nil
        prepared = nil
        suggestedSources = []
    }

    func retry() {
        guard case .failed = state, let turn else { return }
        start(turn.question, pageIndex: turn.page, previous: turn.previous, submittedAt: .now, fromSpeech: turn.fromSpeech)
    }

    func submit(
        _ question: String,
        currentPageIndex: Int? = nil,
        followUp: Bool = false,
        submittedAt: ContinuousClock.Instant = .now,
        fromSpeech: Bool = false
    ) {
        start(question, pageIndex: currentPageIndex, previous: followUp ? previous : nil,
              submittedAt: submittedAt, fromSpeech: fromSpeech)
    }

    func submitCorrection(_ question: String, for transcriptID: UUID) {
        guard let context = spokenContext, context.id == transcriptID else { return }
        start(question, pageIndex: context.pageIndex, previous: context.previous, submittedAt: .now, fromSpeech: true)
    }

    private func start(_ question: String, pageIndex: Int?, previous: CompanionQAService.PreviousTurn?,
                       submittedAt: ContinuousClock.Instant, fromSpeech: Bool) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if state == .answering, question == self.question { return }
        if answer.shortAnswer != nil, !self.question.isEmpty, self.question != question {
            previousDisplay = (self.question, answer)
        }
        let turn = Turn(question: question, page: pageIndex, previous: previous, submittedAt: submittedAt, fromSpeech: fromSpeech)
        self.turn = turn
        spokenContext = fromSpeech ? SpokenContext(id: UUID(), pageIndex: pageIndex, previous: previous) : nil
        setPrevious(nil)
        let key = SearchKey(question: String(question.prefix(1_000)), page: pageIndex, previousQuestion: previous?.question)
        let cached = prepared.flatMap { $0.0 == key ? $0.1 : nil }
        clearSearch()
        self.question = question
        answer = QAAnswer()
        state = .answering
        run(turn, with: service, local: false, cached: cached)
    }

    private func run(_ turn: Turn, with service: CompanionQAService, local: Bool, cached: [QADeckIndex.Match]?) {
        stopTasks()
        let id = UUID()
        requestID = id
        usingLocalModel = local
        let indexTask = indexTask
        let deadline = ContinuousClock.now.advanced(by: local ? service.model.answerTimeout : timeout)
        responseTask = Task { [weak self] in
            do {
                let index = await indexTask?.value
                let key = SearchKey(question: String(turn.question.prefix(1_000)), page: turn.page,
                                    previousQuestion: turn.previous?.question)
                var matches = cached
                if matches == nil, let index { matches = await Self.search(index, for: key) }
                guard self?.requestID == id, !Task.isCancelled else { return }
                self?.answer.citations = Array((matches ?? []).prefix(3).map(\.citation))
                for try await update in service.streamAnswer(
                    turn.question, index: index, currentPageIndex: turn.page, previous: turn.previous, localMatches: matches
                ) {
                    guard let self, self.requestID == id, !Task.isCancelled else { return }
                    self.accept(update, submittedAt: turn.submittedAt)
                }
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.finish(self.answer.shortAnswer == nil ? .failed(.invalidResponse) : .completed)
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.failed(error as? QAServiceError ?? .transport, turn: turn)
            }
        }
        timeoutTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(until: deadline)
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.failed(.timeout, turn: turn)
            } catch {}
        }
    }

    private func failed(_ error: QAServiceError, turn: Turn) {
        if !usingLocalModel, answer.shortAnswer == nil, error.permitsLocalFallback, let service = fallback() {
            run(turn, with: service, local: true, cached: nil)
        } else {
            finish(.failed(error))
        }
    }

    func cancel() {
        stopTasks()
        requestID = UUID()
        if state == .answering { state = .idle }
    }

    private func accept(_ update: CompanionQAService.Update, submittedAt: ContinuousClock.Instant) {
        switch update {
        case .evidence(let citations):
            answer.citations = Array(citations.prefix(3))
        case .shortAnswer(let point):
            answer.citations = point.citations
            answer.shortAnswerPoint = point
            answer.firstSentenceElapsed = max(.zero, submittedAt.duration(to: .now))
        case .bullet(let point):
            answer.bullets.append(point)
        case .detail(let point):
            answer.details.append(point)
        }
    }

    private func finish(_ state: State) {
        stopTasks()
        requestID = UUID()
        if let shortAnswer = answer.shortAnswer {
            setPrevious(CompanionQAService.PreviousTurn(question: question, answer: shortAnswer))
        }
        self.state = state
    }

    private func setPrevious(_ previous: CompanionQAService.PreviousTurn?) {
        self.previous = previous
        canFollowUp = previous != nil
    }

    private func stopTasks() {
        responseTask?.cancel()
        timeoutTask?.cancel()
        responseTask = nil
        timeoutTask = nil
    }
}


private extension QAServiceError {
    var permitsLocalFallback: Bool {
        switch self {
        case .transport, .timeout, .rejectedConnection, .httpStatus(429), .httpStatus(500...599):
            true
        default:
            false
        }
    }
}
