import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ result: Bool, _ message: String) throws {
    if !result { throw TestFailure(description: message) }
}

actor RecordedModel: QAModel {
    typealias Responder = @Sendable (QAModelRequest, AsyncThrowingStream<String, Error>.Continuation) async -> Void
    private(set) var requests: [QAModelRequest] = []
    private let responder: Responder
    nonisolated let answerTimeout: Duration

    init(answerTimeout: Duration = .seconds(20), _ responder: @escaping Responder) {
        self.answerTimeout = answerTimeout
        self.responder = responder
    }

    nonisolated func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.respond(request, continuation: continuation)
            }
        }
    }

    private func respond(
        _ request: QAModelRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        requests.append(request)
        await responder(request, continuation)
    }
}

struct RequestInput: Decodable {
    struct Evidence: Decodable {
        let id: String
        let text: String
        let exactNumericClaimsAllowed: Bool
    }

    let question: String
    let evidence: [Evidence]
    let originalQuestion: String?
    let previousQuestion: String?
    let previousShortAnswer: String?
}

func line(
    _ part: String,
    _ kind: String,
    _ text: String,
    _ source: RequestInput.Evidence? = nil,
    quote: String? = nil
) -> String {
    let sources = source.map { [["id": $0.id, "quote": quote ?? $0.text]] } ?? []
    return String(decoding: try! JSONSerialization.data(withJSONObject: [
        "part": part, "kind": kind, "text": text, "sources": sources
    ]), as: UTF8.self)
}

#if !COMPANION_QA_EXTERNAL_MAIN
@main
#endif
struct CompanionQATests {
    private static let region = QARegion(x: 0.2, y: 0.25, width: 0.6, height: 0.5)

    @MainActor
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 3, arguments[0] == "--local-fallback", let port = UInt16(arguments[1]), port > 0 {
            try await actualLocalFallback(port: port, model: arguments[2])
            return
        }
        if arguments.first == "--replay-synthetic-capture", arguments.count == 2 {
            try await replaySyntheticCapture(URL(fileURLWithPath: arguments[1]))
            return
        }
        if arguments.first == "--replay-captures" {
            do {
                try await replayCapturedArrays()
            } catch {
                FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
                exit(1)
            }
            return
        }
        if arguments.first == "--live" {
            guard arguments.count == 2 else {
                FileHandle.standardError.write(Data("Usage: run.sh --live OUTPUT_DIRECTORY\n".utf8))
                exit(2)
            }
            try await liveTrial(output: URL(fileURLWithPath: arguments[1]))
            return
        }
        try retrieval()
        try await serviceGrounding()
        try await replayCapturedArrays()
        try await answerStreamFormats()
        try await quantifiedEvidenceGap()
        try await mixedLanguageAnswer()
        try await draftStatusGrounding()
        try await draftMultiplierGrounding()
        try await structuredNumberGrounding()
        try await sessionLifecycle()
        try await liveQuestionFlow()
        try await timings()
        try await transport()
        try await chart(artifactDirectory: CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) })
        print("PASS Companion QA suite")
    }

    static func deck(revisionID: String = "original") -> QADeckSnapshot {
        let moved = revisionID == "original" ? 7 : 9
        let percent = revisionID == "original" ? "37%" : "31%"
        let pages = (0..<12).map { page in
            switch page {
            case 3:
                QAPage(
                    index: page, title: "Pilot controls", bodyText: "Meter commissioning and pilot controls.",
                    originalNotes: "The Cedar logger verified integrity with a rolling checksum.\nKeep these notes on this page."
                )
            case 4:
                QAPage(
                    index: page, title: "Orchid results", bodyText: "Orchid coverage reached 83%.",
                    originalNotes: "", aiDraft: "The Orchid trial cut standby power by 20%."
                )
            case moved:
                QAPage(
                    index: page, title: "Orchid algorithm", bodyText: "Reference method.",
                    originalNotes: "The Orchid coverage algorithm weights every interval by its recorded duration."
                )
            case 10:
                QAPage(
                    index: page, title: "Regional share", bodyText: "", originalNotes: "", isAppendix: true,
                    visualEvidence: [
                        QAVisualEvidence(
                            id: "north", kind: .chart, region: region, text: "Regional share · North · \(percent)"
                        ),
                        QAVisualEvidence(
                            id: "south", kind: .chart, region: region, text: "Regional share · South · 31%"
                        )
                    ]
                )
            default:
                QAPage(
                    index: page, title: "Pilot page \(page + 1)", bodyText: "Bench setup and operating conditions.",
                    originalNotes: "", speakerScript: page == 11 ? "Rotate the coupler clockwise after the lamp clears." : nil
                )
            }
        }
        return QADeckSnapshot(revisionID: revisionID, pages: pages)
    }

    static func retrieval() throws {
        let index = QADeckIndex(deck())
        let cases: [(String, Int, QACitation.Kind)] = [
            ("Which checksum did the Cedar logger use?", 3, .speakerNotes),
            ("What was Orchid coverage?", 4, .slideText),
            ("How does the Orchid coverage algorithm weight intervals?", 7, .speakerNotes),
            ("What was the North regional share?", 10, .chart),
            ("How should I rotate the coupler?", 11, .speakerScript)
        ]
        for (query, page, kind) in cases {
            let hits = index.search(query, focusPageIndex: 11)
            try expect(hits.first?.citation.pageIndex == page, "Top retrieval mismatch for \(query): \(hits.map { $0.citation.pageNumber })")
            try expect(hits.first?.citation.kind == kind, "Wrong source kind for \(query)")
        }
        try expect(index.search("quasar redshift uncertainty").isEmpty, "An unrelated question sent excerpts")
        let both = index.search("How does the Orchid algorithm calculate coverage and what did it reach?")
            .map { $0.citation.pageNumber }
        try expect(both.contains(5) && both.contains(8), "Cross-page evidence missing")
        try expect(index.search("standby power").isEmpty, "AI draft entered retrieval")
        let revised = QADeckIndex(deck(revisionID: "refreshed"))
        let newAlgorithm = revised.search("How does the Orchid coverage algorithm weight intervals?").first?.citation
        let newChart = revised.search("What was the North regional share?").first?.citation
        try expect(newAlgorithm?.pageNumber == 10 && newAlgorithm?.revisionID == "refreshed", "Moved slide uses old page number")
        try expect(newChart?.excerpt.contains("31%") == true && newChart?.region == region, "Chart retains stale value or loses region")
        let chinese = index.search("Orchid 的覆盖率和算法是什么？", translation: "What are Orchid's coverage and algorithm?")
        try expect(chinese.contains(where: { $0.citation.pageNumber == 5 }) && chinese.contains(where: { $0.citation.pageNumber == 8 }), "Cross-language retrieval failed")
        print("PASS retrieval: 5 top-ranked sources, cross-page, mixed language, no-match, revision")
    }

    static func serviceGrounding() async throws {
        let model = RecordedModel { request, continuation in
            defer { continuation.finish() }
            if request.purpose == .translateQuestion {
                continuation.yield("What was the Orchid coverage and what algorithm did the pilot use?")
                return
            }
            if request.purpose == .draft {
                continuation.yield("Orchid coverage reached 83%. [Point to the result] That is the result to remember.")
                return
            }
            guard let input = try? JSONDecoder().decode(RequestInput.self, from: Data(request.input.utf8)) else { return }
            let result = input.evidence.first { $0.text.contains("reached 83%") }
            let method = input.evidence.first { $0.text.contains("recorded duration") }
            continuation.yield(line("short", "grounded", "Orchid coverage reached 83%.", result))
            if input.question.contains("calculation") {
                continuation.yield(line("detail", "missingEvidence", "These excerpts do not specify the calculation.", nil))
            } else {
                continuation.yield(line("bullet", "grounded", "The coverage algorithm weights intervals by their recorded duration.", method))
                continuation.yield(line("detail", "grounded", "The algorithm uses the recorded duration of each interval.", method))
            }
            continuation.yield(line("detail", "grounded", "The trial cut standby power by 20%.", result))
            continuation.yield(line("detail", "grounded", "Orchid coverage reached 83% because the algorithm verified each record.", result))
            continuation.yield(line("detail", "grounded", "Orchid coverage was calculated by adjusting its 83% result.", result))
            continuation.yield(line("detail", "grounded", "The trial cut standby power by twenty percent.", result))
            continuation.yield(line("detail", "grounded", "The trial used a frequency filter.", method, quote: "The frequency filter controls the rate."))
            continuation.yield(line("bullet", "supplemental", "The trial saved energy.", nil))
            continuation.yield(line("detail", "supplemental", "In general, coverage can be measured in different ways."))
        }
        let service = CompanionQAService(model: model)
        var updates: [CompanionQAService.Update] = []
        for try await update in service.streamAnswer(
            "Orchid 的覆盖率和算法是什么？", index: QADeckIndex(deck()), currentPageIndex: 11, previous: nil
        ) { updates.append(update) }
        try expect(updates.count == 5, "Wrong number of validated answer updates: \(updates.count)")
        guard case .shortAnswer(let point) = updates[1], case .detail(let detail) = updates[3],
              case .detail(let supplement) = updates[4]
        else { throw TestFailure(description: "Grounded response order mismatch") }
        try expect(point.citations.map(\.pageNumber) == [5] && detail.citations.map(\.pageNumber) == [8], "Claim IDs did not resolve by source")
        try expect(supplement.kind == .supplemental && supplement.citations.isEmpty, "Supplement became deck evidence")
        let requests = await model.requests
        try expect(requests.count == 2 && requests.allSatisfy { $0.image == nil }, "Answer attached imagery")
        try expect(!requests[0].input.contains("recorded duration") && !requests[1].input.contains("standby") && !requests[1].input.contains("Keep these notes"), "Unrelated or untrusted text reached cloud payload")
        let resultOnly = QADeckSnapshot(revisionID: "result-only", pages: [deck().pages[4]])
        var missingCalculation = false
        for try await update in service.streamAnswer(
            "What calculation produced the Orchid coverage?", index: QADeckIndex(resultOnly),
            currentPageIndex: 4, previous: nil
        ) {
            if case .detail(let point) = update, point.kind == .missingEvidence, point.citations.isEmpty {
                missingCalculation = point.text.contains("do not specify the calculation")
            }
        }
        try expect(missingCalculation, "The result-only answer did not expose the missing calculation")
        let draft = try await service.generateDraft(for: deck().pages[4])
        try expect(draft.contains("[Point to the result]") && draft.contains("83%"), "Draft lost the stage direction or source figure")
        let overclaiming = RecordedModel { _, continuation in
            continuation.yield("Orchid coverage rose to 99%.")
            continuation.finish()
        }
        do {
            _ = try await CompanionQAService(model: overclaiming).generateDraft(for: deck().pages[4])
            throw TestFailure(description: "Generated draft introduced an unsupported number")
        } catch QAServiceError.invalidResponse {}
        print("PASS service: cited result and method, source quotes, numeric guards, draft, supplemental isolation")
    }

    static func draftStatusGrounding() async throws {
        let page = deck().pages[4]
        let failedReplay = "Orchid coverage reached 83%. This is the verified result for the Orchid project. The data confirms the final coverage level."
        let withCues = """
        [Point to the chart]
        Orchid coverage reached 83%. This is the verified result for the Orchid project.

        [Pause]
        The data confirms the final coverage level.
        """
        let confirmed = "The Orchid coverage was verified and final at 83%."
        let confirmedParaphrase = "Verified and final Orchid coverage was 83%."
        let forecast = "The Orchid coverage is expected to reach 83%."
        let unverified = "Orchid coverage reached 83%, but the figure is not yet verified."
        let cases: [(material: String, draft: String, expected: String?)] = [
            (page.bodyText, failedReplay, "Orchid coverage reached 83%."),
            (page.bodyText, withCues, "[Point to the chart]\nOrchid coverage reached 83%.\n\n[Pause]"),
            (confirmed, confirmed, confirmed),
            (confirmed, confirmedParaphrase, confirmedParaphrase),
            (forecast, forecast, forecast),
            (forecast, failedReplay, nil),
            (unverified, "The Orchid coverage was verified at 83%.", nil),
            (page.bodyText + "\nThe Cedar logger was verified.", "The Orchid coverage was verified at 83%.", nil),
            (page.bodyText, "Orchid coverage was verified at 83%, but more checks are planned.", nil)
        ]
        for fixture in cases {
            let service = CompanionQAService(model: RecordedModel { _, output in
                output.yield(fixture.draft)
                output.finish()
            })
            let input = QAPage(index: page.index, title: page.title, bodyText: fixture.material, originalNotes: "")
            let draft: String?
            do { draft = try await service.generateDraft(for: input) }
            catch QAServiceError.invalidResponse { draft = nil }
            try expect(draft == fixture.expected, "Draft changed the source status or lost valid speech: \(draft ?? "rejected")")
        }
        print("PASS draft status: replayed verified/final escalation removed, projections and cues preserved")
    }

    static func draftMultiplierGrounding() async throws {
        let material = "North recorded 18 items. South recorded 6 items. The review has 3 checkpoints."
        let explicit = "The North group recorded 3 times more than the South group."
        let otherSubject = "The East group recorded 3 times more than the West group."
        let rewrite = "North recorded 3 times more than South."
        let retained = "North recorded 18 items. [Point to the chart]"
        let combined = retained + " " + rewrite
        try expect(QASearchText.permitsNumbers(in: combined, from: [material]),
                   "The multiplier fixture must pass the existing literal number guard")
        for (source, draft, expected) in [
            (material, combined, retained),
            (material + "\n" + otherSubject, combined, retained),
            (material + "\n" + explicit, retained + " South recorded 3 times more than North.", retained),
            (explicit, rewrite, rewrite)
        ] {
            let model = RecordedModel { _, output in
                output.yield(draft)
                output.finish()
            }
            let page = QAPage(index: 0, title: "Recorded totals", bodyText: source, originalNotes: "")
            let actual = try await CompanionQAService(model: model).generateDraft(for: page)
            try expect(actual == expected, "A multiplier comparison crossed subjects or dropped valid speech")
        }
        print("PASS draft multiplier: reject inferred/unrelated comparisons, preserve the cited comparison and cue")
    }

    static func structuredNumberGrounding() async throws {
        let region = QARegion(x: 0.15, y: 0.20, width: 0.70, height: 0.62)
        let data = QADeckSnapshot(revisionID: "numeric-bindings", pages: [
            QAPage(
                index: 0, title: "Regional share", bodyText: "", originalNotes: "",
                visualEvidence: [
                    QAVisualEvidence(id: "native", kind: .chart, region: region,
                                     text: "Regional share (%)\nNorth | Pilot | 37%\nSouth | Pilot | 31%"),
                    QAVisualEvidence(id: "online", kind: .imageText, region: region,
                                     text: "Regional share · North · 37%"),
                    QAVisualEvidence(id: "online2", kind: .imageText, region: region,
                                     text: "Regional share · South · 31%")
                ]
            ),
            QAPage(
                index: 1, title: "Production plan by series", bodyText: "", originalNotes: "",
                visualEvidence: [
                    QAVisualEvidence(id: "units", kind: .table, region: region,
                                     text: "Series | Verified units\nDelta | 42 units\nGamma | 11 units")
                ]
            )
        ])
        let model = RecordedModel { request, continuation in
            defer { continuation.finish() }
            guard let input = try? JSONDecoder().decode(RequestInput.self, from: Data(request.input.utf8)) else { return }
            let isTable = input.question.contains("units")
            let isOnline = input.question.contains("screenshot")
            let filter: @Sendable (RequestInput.Evidence) -> Bool = { evidence in
                if isTable { return evidence.text.contains("units") }
                return isOnline ? evidence.text.contains(" · ") : evidence.text.contains(" | ")
            }
            let leftLabel = isTable ? "Delta" : "North"
            let rightLabel = isTable ? "Gamma" : "South"
            guard let left = input.evidence.first(where: { filter($0) && $0.text.contains(leftLabel) }),
                  let right = input.evidence.first(where: { filter($0) && $0.text.contains(rightLabel) })
            else { return }
            let safe = isTable ? "Delta recorded 42 units." : "For North, the regional share was 37%."
            let wrongSingle = isTable ? "Delta had 11 units." : (isOnline
                ? "The North regional share was 31%." : "North recorded a Pilot share of 31%.")
            let wrongBoth = isTable ? "Delta had 11 units and Gamma had 42 units." : "North recorded 31% and South recorded 37%."
            let validComparison = isTable ? "Delta had 42 units while Gamma had 11 units." : "North recorded 37%, and South recorded 31%."
            let validRespectively = isTable ? "For Delta and Gamma, the counts were 42 and 11 units, respectively."
                : "For North and South, the regional shares were 37% and 31%, respectively."
            func pairLine(_ text: String) -> String {
                String(decoding: try! JSONSerialization.data(withJSONObject: [
                    "part": "detail", "kind": "grounded", "text": text,
                    "sources": [["id": left.id, "quote": left.text], ["id": right.id, "quote": right.text]]
                ]), as: UTF8.self)
            }
            continuation.yield(line("short", "grounded", wrongSingle, right))
            continuation.yield(line("short", "grounded", safe, left))
            continuation.yield(pairLine(wrongBoth))
            continuation.yield(pairLine(validComparison))
            continuation.yield(pairLine(validRespectively))
        }

        let service = CompanionQAService(model: model)
        var failures: [String] = []
        for (query, expected) in [
            ("What was North and South regional share?", "For North, the regional share was 37%."),
            ("What does the screenshot say for North and South regional share?", "For North, the regional share was 37%."),
            ("How many units did Delta and Gamma record?", "Delta recorded 42 units.")
        ] {
            var short: String?
            var details: [QAAnswerPoint] = []
            for try await update in service.streamAnswer(query, index: QADeckIndex(data), currentPageIndex: nil, previous: nil) {
                if case .shortAnswer(let answer) = update { short = answer.text }
                if case .detail(let point) = update { details.append(point) }
            }
            if short != expected {
                failures.append("Wrong row number became the short answer: \(short ?? "none")")
            }
            if details.count != 2 || details.last?.text.contains("respectively") != true {
                failures.append("Swapped numbers were accepted or a valid comparison was rejected: \(details.map(\.text))")
            }
        }
        try expect(failures.isEmpty, failures.joined(separator: "\n"))
        let labelled = QADeckSnapshot(revisionID: "bilingual-label", pages: [
            QAPage(
                index: 0, title: "Mosaic coverage", bodyText: "", originalNotes: "",
                visualEvidence: [
                    QAVisualEvidence(id: "bilingual", kind: .chart, region: region, text: "北区 | Mosaic | 37%")
                ]
            )
        ])
        let bilingual = RecordedModel { request, continuation in
            defer { continuation.finish() }
            let input = try? JSONDecoder().decode(RequestInput.self, from: Data(request.input.utf8))
            let source = input?.evidence.first { $0.text.contains("37%") }
            continuation.yield(line("short", "grounded", "The 北区 series reached 37%.", source))
        }
        var namedInEnglish = false
        for try await update in CompanionQAService(model: bilingual).streamAnswer(
            "What was the Mosaic coverage for its northern region?", index: QADeckIndex(labelled),
            currentPageIndex: 0, previous: nil
        ) {
            if case .shortAnswer(let point) = update {
                namedInEnglish = point.kind == .grounded && point.text == "The 北区 series reached 37%."
            }
        }
        try expect(namedInEnglish, "A valid numeric answer could not retain the original Chinese series label")
        print("PASS structured numbers: reject wrong chart/table row and swapped comparisons, preserve valid comparisons")
    }

    @MainActor
    static func sessionLifecycle() async throws {
        let model = RecordedModel(answerTimeout: .milliseconds(220)) { request, continuation in
            if request.input.contains("timeout question") || request.input.contains("older question") {
                try? await Task.sleep(for: .milliseconds(280))
            }
            let text = request.input.contains("successor question")
                ? "Here is the newer response."
                : "Here is a complete response."
            let short = line("short", "supplemental", text)
            continuation.yield(String(short.prefix(18)))
            try? await Task.sleep(for: .milliseconds(55))
            continuation.yield(String(short.dropFirst(18)))
            try? await Task.sleep(for: .milliseconds(55))
            continuation.yield(line("bullet", "supplemental", "Here is the first extra point."))
            continuation.yield(line("bullet", "supplemental", "Here is the second extra point."))
            continuation.finish()
        }
        let session = CompanionQASession(service: CompanionQAService(model: model))
        session.submit("initial question", submittedAt: .now.advanced(by: .milliseconds(-15)))
        session.submit("initial question")
        try await Task.sleep(for: .milliseconds(20))
        try expect(session.answer.shortAnswer == nil, "A first fragment became an answer")
        try await until("complete first sentence") { session.answer.shortAnswer != nil }
        try expect(session.state == .answering && session.answer.bullets.isEmpty, "First sentence waited for the entire answer")
        try expect(session.answer.firstSentenceElapsed ?? .zero >= .milliseconds(55), "First sentence timer used first chunk")
        try await until("complete first response") { session.state == .completed }
        try expect(session.canFollowUp && session.answer.citations.isEmpty, "Standalone result had a citation or lost follow-up")
        session.submit("follow-up", followUp: true)
        try await until("complete follow-up") { session.state == .completed }
        session.submit("new topic")
        try await until("complete unrelated question") { session.state == .completed }
        let inputs = await model.requests.compactMap { try? JSONDecoder().decode(RequestInput.self, from: Data($0.input.utf8)) }
        try expect(inputs.count == 3, "Duplicate Enter submitted again")
        try expect(inputs[1].previousQuestion == "initial question" && inputs[1].previousShortAnswer?.contains("complete") == true, "Explicit follow-up missed prior answer")
        try expect(inputs[2].previousQuestion == nil, "Unrelated question retained follow-up context")

        session.submit("misheard follow-up", followUp: true, fromSpeech: true)
        try await until("spoken follow-up finishes") { session.state == .completed }
        guard let transcript = session.editableTranscriptID else { throw TestFailure(description: "Missing spoken turn") }
        session.submitCorrection("corrected follow-up", for: transcript)
        try await until("corrected follow-up finishes") { session.state == .completed }
        let corrected = try await model.requests.last.map { try JSONDecoder().decode(RequestInput.self, from: Data($0.input.utf8)) }
        try expect(corrected?.question == "corrected follow-up" && corrected?.previousQuestion == "new topic",
                   "The correction lost the original context or used the misheard question as its anchor")
        session.submitCorrection("obsolete draft", for: transcript)
        try expect(session.question == "corrected follow-up", "A stale correction replaced a newer question")
        session.submit("timeout question")
        try expect(session.editableTranscriptID == nil, "Typed question retained a voice edit action")
        try await until("timeout indicator") { session.state == .failed(.timeout) }
        session.submit("older question")
        try await Task.sleep(for: .milliseconds(10))
        session.submit("successor question")
        try await until("finish new question") { session.state == .completed }
        try await Task.sleep(for: .milliseconds(310))
        try expect(session.answer.shortAnswer == "Here is the newer response.", "Late answer replaced newer result")
        session.submit("older question")
        session.setDeck(deck(revisionID: "new version"))
        try await Task.sleep(for: .milliseconds(320))
        try expect(session.state == .idle && session.answer.citations.isEmpty && !session.canFollowUp, "Old turn survived a deck switch")
        print("PASS session: complete sentence before bullets, dedup, explicit follow-up, timeout, late return, deck switch")
    }

    @MainActor
    static func timings() async throws {
        let sample = deck()
        let distractors = (12..<120).map { index in
            QAPage(index: index, title: "Run \(index) specification", bodyText: "A thermal assembly was assessed for this cycle.",
                   originalNotes: "This page describes the housing and input rotation. The mechanical harness stayed in position. Panels are separated by a support.")
        }
        let largeDeck = QADeckSnapshot(revisionID: "timed", pages: sample.pages + distractors)

        let coldStart = ContinuousClock.now
        let index = QADeckIndex(largeDeck)
        let build = ms(coldStart.duration(to: .now))
        var searches: [Double] = []
        for _ in 0..<18 {
            let start = ContinuousClock.now
            let found = index.search("Orchid results coverage and duration weighting algorithm", focusPageIndex: 11)
            searches.append(ms(start.duration(to: .now)))
            try expect(found.contains(where: { $0.citation.pageNumber == 5 }) && found.contains(where: { $0.citation.pageNumber == 8 }),
                       "The 120-slide timing query lost one supporting page")
        }

        let model = RecordedModel { request, continuation in
            let input = try? JSONDecoder().decode(RequestInput.self, from: Data(request.input.utf8))
            let match = input?.evidence.first { $0.text.contains("83%") }
            let reply = line("short", "grounded", "Orchid coverage reached 83%.", match)
            continuation.yield(String(reply.prefix(20)))
            try? await Task.sleep(for: .milliseconds(40))
            continuation.yield(String(reply.dropFirst(20)))
            try? await Task.sleep(for: .milliseconds(15))
            continuation.finish()
        }
        let session = CompanionQASession(service: CompanionQAService(model: model))
        session.setDeck(largeDeck)
        var received: [Double] = []
        for _ in 0..<8 {
            session.submit("What was Orchid coverage?", currentPageIndex: 11)
            try await until("controlled timing sample") { session.state == .completed }
            try expect(session.answer.shortAnswerPoint?.kind == .grounded && session.answer.citations.first?.pageNumber == 5,
                       "An unusable answer was included in the timing sample")
            if let firstSentenceElapsed = session.answer.firstSentenceElapsed { received.append(ms(firstSentenceElapsed)) }
        }
        try expect(received.count == 8, "Missing first-sentence measurements")
        print("TIMING 120-slide index build \(String(format: "%.2f", build)) ms")
        print("TIMING local retrieval n=\(searches.count): \(timingSummary(searches)), failures 0")
        print("TIMING controlled text first sentence n=\(received.count): \(timingSummary(received)), failures 0; fixtures insert 40 ms before the complete JSON line")
    }

    static func ms(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1_000_000_000_000_000
    }

    static func timingSummary(_ values: [Double]) -> String {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return String(format: "median %.2f ms, max %.2f ms", median, sorted[sorted.count - 1])
    }

    @MainActor
    static func until(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(4))
        }
        try expect(condition(), "Timed out waiting for " + description)
    }
}
