import Foundation

extension CompanionQATests {
    private struct TrialCase: Sendable {
        let name: String
        let question: String
        let page: Int
        let targetPages: Set<Int>
        let targetTerms: [String]
        var followUpOf: String?
        var shouldLackEvidence = false
    }

    private struct TrialPoint: Codable, Sendable {
        let text: String
        let kind: String
        let pages: [Int]

        init(_ point: QAAnswerPoint) {
            text = point.text
            kind = point.kind.rawValue
            pages = point.citations.map(\.pageNumber)
        }
    }

    private struct TrialAnswer: Codable, Sendable {
        let run: String
        let repetition: Int
        let name: String
        let question: String
        let firstSentenceMilliseconds: Double?
        let firstSentence: TrialPoint?
        let details: [TrialPoint]
        let bullets: [TrialPoint]
        let status: String
        let firstSentenceUsable: Bool
        let supportsExpectedAnswer: Bool
    }

    private struct TrialSummary: Codable, Sendable {
        let model: String
        let samples: [TrialAnswer]
        let draft: String?
        let originalChartEvidence: [QAVisualEvidence]
        let ambiguousChartEvidence: [QAVisualEvidence]
        let originalChartStatus: String
        let ambiguousChartStatus: String
    }

    @MainActor
    static func liveTrial(output: URL) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let key = [environment["GEMINI_API_KEY"], environment["GOOGLE_API_KEY"]]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty })
        else {
            FileHandle.standardError.write(Data("Live trial requires GEMINI_API_KEY or GOOGLE_API_KEY in the environment. No request sent.\n".utf8))
            exit(2)
        }
        let modelID = environment["GEMINI_MODEL"] ?? GeminiQAModel.defaultModel
        guard modelID.wholeMatch(of: #/gemini-[A-Za-z0-9][A-Za-z0-9._-]{0,79}/#) != nil else {
            FileHandle.standardError.write(Data("Invalid GEMINI_MODEL setting. No request sent.\n".utf8))
            exit(2)
        }
        let repetitions = min(5, max(1, Int(environment["TEXTREAM_QA_REPEATS"] ?? "2") ?? 2))
        try await liveTrial(
            output: output, modelID: modelID, repetitions: repetitions,
            reportName: "gemini-live-trial.json", includeCharts: true
        ) { GeminiQAModel(apiKey: key, model: modelID) }
    }

    @MainActor
    static func liveTrial(
        output: URL,
        modelID: String,
        repetitions: Int,
        reportName: String,
        includeCharts: Bool,
        makeModel: () -> any QAModel
    ) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = deck()
        let tests = [
            TrialCase(name: "current-page", question: "What was Orchid coverage?", page: 4, targetPages: [5], targetTerms: ["83%"]),
            TrialCase(name: "cross-page-notes", question: "Which checksum did the Cedar logger use?", page: 11, targetPages: [4], targetTerms: ["rolling", "checksum"]),
            TrialCase(name: "explicit-follow-up", question: "How did the team calculate it?", page: 11, targetPages: [8], targetTerms: ["weight", "duration"], followUpOf: "What was Orchid coverage?"),
            TrialCase(name: "cross-page-two-claims", question: "How was Orchid coverage calculated, and what did it reach?", page: 11, targetPages: [5, 8], targetTerms: ["83%", "weight", "duration"]),
            TrialCase(name: "appendix-chart", question: "What was the North regional share?", page: 11, targetPages: [11], targetTerms: ["north", "37%"]),
            TrialCase(name: "result-without-calculation", question: "What formula did the pilot use to calculate the North regional share?", page: 11, targetPages: [], targetTerms: [], shouldLackEvidence: true),
            TrialCase(name: "draft-only-claim", question: "Did the Orchid trial cut standby power by 20%?", page: 4, targetPages: [], targetTerms: [], shouldLackEvidence: true),
            TrialCase(name: "chinese-cross-page", question: "Cedar logger 用的是什么校验方法？", page: 11, targetPages: [4], targetTerms: ["rolling", "checksum"])
        ]

        func makeSession() -> CompanionQASession {
            CompanionQASession(service: CompanionQAService(model: makeModel()))
        }
        let reusable = makeSession()
        var answers: [TrialAnswer] = []
        for mode in ["cold", "warm"] {
            for repetition in 1...max(1, repetitions) {
                for test in tests {
                    let session = mode == "cold" ? makeSession() : reusable
                    session.setDeck(fixture)
                    if let prime = test.followUpOf {
                        session.submit(prime, currentPageIndex: 4)
                        await waitForTrialAnswer(session)
                        if !session.canFollowUp {
                            answers.append(TrialAnswer(
                                run: mode, repetition: repetition, name: test.name, question: test.question, firstSentenceMilliseconds: nil,
                                firstSentence: nil, details: [], bullets: [], status: "primer-failed", firstSentenceUsable: false, supportsExpectedAnswer: false
                            ))
                            continue
                        }
                    }
                    session.submit(test.question, currentPageIndex: test.page, followUp: test.followUpOf != nil)
                    await waitForTrialAnswer(session)
                    let answer = session.answer
                    let status: String
                    switch session.state {
                    case .completed: status = "complete"
                    case .failed(.timeout): status = "timeout"
                    case .failed(let reason): status = reason.localizedDescription
                    case .idle, .answering: status = "incomplete"
                    }
                    let points = [answer.shortAnswerPoint].compactMap { $0 } + answer.bullets + answer.details
                    let allGrounded = points.filter { $0.kind == .grounded }
                    let allPages = Set(allGrounded.flatMap { $0.citations.map(\.pageNumber) })
                    let text = QASearchText.normalized(allGrounded.map(\.text).joined(separator: " "))
                    let usableFirstSentence = answer.shortAnswerPoint.map { short -> Bool in
                        if test.shouldLackEvidence {
                            return short.kind == .missingEvidence && short.citations.isEmpty
                        }
                        let firstText = QASearchText.normalized(short.text)
                        return short.kind == .grounded
                            && short.citations.contains { test.targetPages.contains($0.pageNumber) }
                            && test.targetTerms.contains { firstText.contains($0) }
                    } ?? false
                    let usable = answer.shortAnswerPoint.map { short -> Bool in
                        if test.shouldLackEvidence {
                            return short.kind == .missingEvidence && short.citations.isEmpty
                                && allGrounded.allSatisfy { !test.name.contains("draft-only") || !$0.text.contains("20%") }
                        }
                        return short.kind == .grounded && test.targetPages.isSubset(of: allPages)
                            && test.targetTerms.allSatisfy { text.contains($0) }
                    } ?? false
                    answers.append(TrialAnswer(
                        run: mode, repetition: repetition, name: test.name, question: test.question,
                        firstSentenceMilliseconds: answer.firstSentenceElapsed.map(ms),
                        firstSentence: answer.shortAnswerPoint.map(TrialPoint.init),
                        details: answer.details.map(TrialPoint.init), bullets: answer.bullets.map(TrialPoint.init),
                        status: status, firstSentenceUsable: usableFirstSentence, supportsExpectedAnswer: usable
                    ))
                    print("Live \(mode) \(repetition) \(test.name): \(status), expected evidence \(usable ? "yes" : "no")")
                }
            }
        }

        let model = makeModel()
        let draft = try? await CompanionQAService(model: model).generateDraft(for: fixture.pages[4])
        var original: QAChartPreparation?
        var ambiguous: QAChartPreparation?
        if includeCharts {
            let chartStore = output.appendingPathComponent("live-chart-cache", isDirectory: true)
            let reader = QAChartReader(cacheDirectory: chartStore, model: model, modelID: modelID)
            let project = UUID()
            let candidate = QAVisualCandidate(
                id: "plot", title: "Regional share", region: QARegion(x: 0.16, y: 0.17, width: 0.68, height: 0.7)
            )
            original = try? await reader.prepare(
                projectID: project, revisionID: "original", pageIndex: 7,
                imageData: chartFixture(north: "37%", south: "31%"), candidate: candidate,
                onlineImageReadingEnabled: true
            )
            ambiguous = try? await reader.prepare(
                projectID: project, revisionID: "unlabelled", pageIndex: 7,
                imageData: chartFixture(north: nil, south: nil), candidate: candidate,
                onlineImageReadingEnabled: true
            )
        }
        let report = TrialSummary(
            model: modelID, samples: answers, draft: draft,
            originalChartEvidence: original?.evidence ?? [], ambiguousChartEvidence: ambiguous?.evidence ?? [],
            originalChartStatus: original?.onlineStatus.label ?? (includeCharts ? "本机图像读取失败" : "未运行"),
            ambiguousChartStatus: ambiguous?.onlineStatus.label ?? (includeCharts ? "本机图像读取失败" : "未运行")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: output.appendingPathComponent(reportName), options: .atomic)
        for mode in ["cold", "warm"] {
            let group = answers.filter { $0.run == mode }
            let usable = group.filter(\.firstSentenceUsable)
            let times = usable.compactMap(\.firstSentenceMilliseconds)
            let timing = times.isEmpty ? "no usable first-sentence times" : timingSummary(times)
            let failed = group.filter { $0.status != "complete" }
            print("Live \(mode): n=\(group.count), usable first sentences \(usable.count), complete expected evidence \(group.filter(\.supportsExpectedAnswer).count), incomplete or failed \(failed.count), timeouts \(failed.filter { $0.status == "timeout" }.count); \(timing)")
        }
    }

    @MainActor
    private static func waitForTrialAnswer(_ session: CompanionQASession) async {
        let until = ContinuousClock.now.advanced(by: .seconds(22))
        while session.state == .answering && ContinuousClock.now < until {
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}
