import Foundation

extension CompanionQATests {
    private struct RecordedReply: Decodable {
        let caseName: String
        let callNumber: Int
        let question: String
        let expectedPage: Int
        let expectedShortAnswer: String
        let response: String
    }

    static func replayCapturedArrays() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("recorded-array-replies.json")
        let fixture = try JSONDecoder().decode([RecordedReply].self, from: Data(contentsOf: file))
        var failures: [String] = []
        for reply in fixture {
            let model = RecordedModel { _, continuation in
                var start = reply.response.startIndex
                while start < reply.response.endIndex {
                    let end = reply.response.index(start, offsetBy: 17, limitedBy: reply.response.endIndex) ?? reply.response.endIndex
                    continuation.yield(String(reply.response[start..<end]))
                    start = end
                }
                continuation.finish()
            }
            var actual: QAAnswerPoint?
            do {
                for try await update in CompanionQAService(model: model).streamAnswer(
                    reply.question, index: QADeckIndex(deck()), currentPageIndex: 11, previous: nil
                ) {
                    if case .shortAnswer(let point) = update { actual = point }
                }
            } catch {
                failures.append("Call \(reply.callNumber) / \(reply.caseName): \(error.localizedDescription)")
                continue
            }
            print("Recorded call \(reply.callNumber) / \(reply.caseName): \(actual?.text ?? "<no short answer>") \(actual?.citations.map(\.pageNumber) ?? [])")
            if actual?.text != reply.expectedShortAnswer || actual?.citations.map(\.pageNumber) != [reply.expectedPage] {
                failures.append("Recorded call \(reply.callNumber) did not produce the grounded reference answer.")
            }
        }
        try expect(failures.isEmpty, failures.joined(separator: "\n"))
    }
}

private struct SuppliedAnswerStream: QAModel {
    let reply: AsyncThrowingStream<String, Error>

    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> { reply }
}

extension CompanionQATests {
    static func mixedLanguageAnswer() async throws {
        let question = "Cedar logger 用的是什么校验方法？"
        let translation = "What checksum method does Cedar logger use?"
        let notes = "The Cedar logger verified integrity with a rolling checksum."
        let index = QADeckIndex(deck())
        let model = RecordedModel { request, continuation in
            defer { continuation.finish() }
            if request.purpose == .translateQuestion {
                continuation.yield(translation)
                return
            }
            guard let input = try? JSONDecoder().decode(RequestInput.self, from: Data(request.input.utf8)),
                  let source = input.evidence.first(where: { $0.text == notes })
            else { return }
            let chinese = line("short", "grounded", "Cedar logger 使用的是滚动校验和（rolling checksum）。", source)
            if input.question != translation || input.originalQuestion != question {
                continuation.yield(chinese)
                return
            }
            continuation.yield(chinese)
            continuation.yield(line("short", "grounded", notes, source, quote: "The Cedar logger used a rolling checksum."))
            continuation.yield(line("short", "grounded", "The Cedar logger used a rolling checksum.", source))
        }
        var points: [QAAnswerPoint] = []
        for try await update in CompanionQAService(model: model).streamAnswer(question, index: index, currentPageIndex: 11, previous: nil) {
            if case .shortAnswer(let point) = update { points.append(point) }
        }
        try expect(points.count == 1 && points[0].kind == .grounded
            && points[0].text == "The Cedar logger used a rolling checksum."
            && points[0].citations.map(\.pageNumber) == [4]
            && points[0].citations.first?.kind == .speakerNotes
            && points[0].citations.first?.excerpt == notes,
            "The translated question lost its cross-page note, or an invalid answer passed")

        let questionWithFigure = "Orchid 的覆盖率是 83% 吗？"
        let badTranslation = RecordedModel { request, continuation in
            defer { continuation.finish() }
            if request.purpose == .translateQuestion {
                continuation.yield("Did Orchid coverage reach 99%?")
                return
            }
            guard let input = try? JSONDecoder().decode(RequestInput.self, from: Data(request.input.utf8)),
                  let source = input.evidence.first(where: { $0.text == "Orchid coverage reached 83%." })
            else { return }
            if input.question == questionWithFigure {
                continuation.yield(line("short", "grounded", source.text, source))
            }
        }
        var figure: QAAnswerPoint?
        for try await update in CompanionQAService(model: badTranslation).streamAnswer(
            questionWithFigure, index: index, currentPageIndex: 11, previous: nil
        ) {
            if case .shortAnswer(let point) = update { figure = point }
        }
        try expect(figure?.text == "Orchid coverage reached 83%." && figure?.citations.map(\.pageNumber) == [5],
                   "The translation changed the questioned figure or blocked the original query fallback")
        print("PASS mixed-language answers: English model question, original note on page 4, Chinese output and false quote rejected")
    }

    @MainActor
    static func quantifiedEvidenceGap() async throws {
        let question = "Did the Orchid trial cut standby power by 20%?"
        let snapshot = deck()
        guard let sourceMatch = QADeckIndex(snapshot).search(question).first(where: {
            $0.citation.excerpt == "Orchid coverage reached 83%."
        }) else { throw TestFailure(description: "Expected a related, different result in the fixture") }
        let source = RequestInput.Evidence(
            id: sourceMatch.citation.id, text: sourceMatch.citation.excerpt, exactNumericClaimsAllowed: true
        )
        let echo = "The presentation does not state whether the Orchid trial cut standby power by 20%."
        let unrelated = line("bullet", "grounded", "The only Orchid result given is coverage, which reached 83%.", source)
        let cases: [(String, String?)] = [
            (line("short", "missingEvidence", echo) + "\n" + unrelated,
             "I cannot verify that result from the presentation materials."),
            (line("short", "missingEvidence", "The presentation does not report a change in standby power."),
             "The presentation does not report a change in standby power."),
            (line("short", "missingEvidence", echo.replacingOccurrences(of: "20%", with: "27%")), nil),
            (line("short", "missingEvidence", echo.replacingOccurrences(of: "20%", with: "twenty percent")), nil),
            (line("short", "missingEvidence", echo, source), nil),
            (line("short", "missingEvidence", echo + " Here is another sentence."), nil),
            (line("short", "missingEvidence", "The Orchid trial did not cut standby power by 20%."), nil),
            (line("short", "missingEvidence", "资料没有说明 Orchid 是否将待机能耗降低了 20%."), nil),
            (line("short", "grounded", "The Orchid trial cut standby power by 20%.", source), nil)
        ]
        for (payload, expected) in cases {
            let model = RecordedModel { _, continuation in
                continuation.yield(payload)
                continuation.finish()
            }
            let session = CompanionQASession(service: CompanionQAService(model: model))
            session.setDeck(snapshot)
            session.submit(question, currentPageIndex: 4)
            try await until("quantified evidence response") { session.state != .answering }
            try expect(session.answer.shortAnswer == expected, "Unexpected handling of a quantified evidence gap: \(payload)")
            if expected == nil {
                try expect(session.state == .failed(.invalidResponse), "An invalid response looked like a material gap")
            } else {
                let point = session.answer.shortAnswerPoint
                try expect(session.state == .completed && point?.kind == .missingEvidence
                    && point?.citations.isEmpty == true && session.answer.citations.isEmpty
                    && session.answer.bullets.isEmpty && QASearchText.permitsNumbers(in: expected ?? "", from: []),
                    "An explicit material gap yielded an unverified figure or citation")
            }
        }
        print("PASS quantified evidence gap: disclose missing material without displaying an echoed figure or accepting invalid output")
    }

    @MainActor
    static func answerStreamFormats() async throws {
        let title = "Pilot storage label"
        let text = #"The label "{Pilot [A]}" marks the C:\drop folder."#
        let excerpt = text + "\nUse the directory for pilot records."
        let snapshot = QADeckSnapshot(revisionID: "stream-formats", pages: [
            QAPage(index: 0, title: title, bodyText: excerpt, originalNotes: "")
        ])
        let question = "Where does the Pilot storage label point?"
        let index = QADeckIndex(snapshot)
        let evidence = index.search(question)
        guard let note = evidence.first(where: { $0.citation.excerpt == text })?.citation,
              let directory = evidence.first(where: { $0.citation.excerpt.contains("directory") })?.citation
        else { throw TestFailure(description: "The format test did not retrieve its required passages") }
        let source = RequestInput.Evidence(id: note.id, text: note.excerpt, exactNumericClaimsAllowed: true)
        let secondary = RequestInput.Evidence(id: directory.id, text: directory.excerpt, exactNumericClaimsAllowed: true)
        let short = line("short", "grounded", text, source)
        let detail = line("detail", "grounded", "Use the directory for pilot records.", secondary)

        let wrapped = AsyncThrowingStream<String, Error>.makeStream()
        let visible = CompanionQASession(service: CompanionQAService(model: SuppliedAnswerStream(reply: wrapped.stream)))
        visible.setDeck(snapshot)
        visible.submit(question)
        wrapped.continuation.yield("``")
        wrapped.continuation.yield("`JSON\r")
        wrapped.continuation.yield("\n [ \n")
        for character in short.dropLast() {
            wrapped.continuation.yield(String(character))
        }
        try await until("candidate evidence before the incomplete object") { !visible.answer.citations.isEmpty }
        try expect(visible.answer.shortAnswer == nil, "An incomplete quoted object produced a short answer")
        wrapped.continuation.yield(String(short.suffix(1)))
        try await until("first sentence before the array closes") { visible.answer.shortAnswer != nil }
        try expect(visible.state == .answering && visible.answer.shortAnswer == text && visible.answer.details.isEmpty,
                   "Quoted brackets or a backslash blocked the first sentence")
        wrapped.continuation.yield(",\n" + detail + "\n]\r\n`")
        wrapped.continuation.yield("``\r\n")
        wrapped.continuation.finish()
        try await until("fenced array completion") { visible.state == .completed }
        try expect(visible.answer.details.map(\.text) == ["Use the directory for pilot records."],
                   "Valid nested source quotes or the following object were lost")

        let raw = AsyncThrowingStream<String, Error>.makeStream()
        let plain = CompanionQASession(service: CompanionQAService(model: SuppliedAnswerStream(reply: raw.stream)))
        plain.setDeck(snapshot)
        plain.submit(question)
        raw.continuation.yield(short + "\r\n" + detail)
        raw.continuation.finish()
        try await until("existing JSONL completion") { plain.state == .completed }
        try expect(plain.answer.shortAnswer == text && plain.answer.details.count == 1, "Existing JSONL stopped streaming")

        let fencedLines = AsyncThrowingStream<String, Error>.makeStream()
        let inFence = CompanionQASession(service: CompanionQAService(model: SuppliedAnswerStream(reply: fencedLines.stream)))
        inFence.setDeck(snapshot)
        inFence.submit(question)
        fencedLines.continuation.yield("```jsonl\n" + short + "\n" + detail + "\n```")
        fencedLines.continuation.finish()
        try await until("fenced JSONL completion") { inFence.state == .completed }
        try expect(inFence.answer.shortAnswer == text && inFence.answer.details.count == 1,
                   "Fenced JSONL lost the sentence or detail")

        let pending = AsyncThrowingStream<String, Error>.makeStream()
        let cancelled = CompanionQASession(service: CompanionQAService(model: SuppliedAnswerStream(reply: pending.stream)))
        var producerCancelled = false
        pending.continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { @MainActor in producerCancelled = true }
            }
        }
        cancelled.setDeck(snapshot)
        cancelled.submit(question)
        pending.continuation.yield("[" + short)
        try await until("visible short answer before cancellation") { cancelled.answer.shortAnswer == text }
        pending.continuation.yield("," + String(detail.dropLast()))
        cancelled.cancel()
        try await until("cancellation propagated to the model stream") { producerCancelled }
        pending.continuation.yield(String(detail.suffix(1)) + "]")
        pending.continuation.finish()
        try expect(cancelled.state == .idle && cancelled.answer.shortAnswer == text && cancelled.answer.details.isEmpty,
                   "Cancelling a partly received record admitted its later bytes")

        let invalidQuote = line("short", "grounded", text, source, quote: "A folder was identified.")
        let invalidSentence = line("short", "grounded", "The label marks the folder. Use it.", source)
        let unsupportedNumber = line("short", "grounded", "The Pilot storage folder contains 99 records.", source)
        let explicitGap = line("short", "missingEvidence", "The presentation does not name the formula used here.")
        let malformed: [String] = [
            "", " \r\n ", "[]", "[{bad}]", "{\"error\":\"upstream failure\"}",
            "```json\n[", String(short.dropLast()), "[" + invalidQuote + "]",
            "[" + invalidSentence + "]", "[" + unsupportedNumber + "]"
        ]
        for payload in malformed {
            let model = RecordedModel { _, continuation in
                if !payload.isEmpty { continuation.yield(payload) }
                continuation.finish()
            }
            let bad = CompanionQASession(service: CompanionQAService(model: model))
            bad.setDeck(snapshot)
            bad.submit(question)
            try await until("invalid model response status") { bad.state != .answering }
            try expect(bad.state == .failed(.invalidResponse) && bad.answer.shortAnswer == nil,
                       "Empty, invalid, unsupported, or incomplete output was presented as insufficient evidence")
        }

        let model = RecordedModel { _, continuation in
            continuation.yield("[" + explicitGap + "]")
            continuation.finish()
        }
        let genuineGap = CompanionQASession(service: CompanionQAService(model: model))
        genuineGap.setDeck(snapshot)
        genuineGap.submit(question)
        try await until("valid model evidence gap") { genuineGap.state == .completed }
        try expect(genuineGap.answer.shortAnswerPoint?.kind == .missingEvidence, "An explicit evidence gap was treated as a model error")

        let noMatch = CompanionQASession(service: CompanionQAService(model: model))
        noMatch.setDeck(snapshot)
        noMatch.submit("quasar redshift uncertainty")
        try await until("local search has no matching sources") { noMatch.state == .completed }
        let modelCallCount = await model.requests.count
        try expect(noMatch.answer.shortAnswerPoint?.kind == .missingEvidence && modelCallCount == 1,
                   "A deterministic search miss unnecessarily invoked the model or lost its evidence gap")
        print("PASS stream formats: early JSONL/array/fence objects, escaped quotes and braces, cancellation, invalid responses versus evidence gaps")
    }
}
