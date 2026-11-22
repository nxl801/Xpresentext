import AVFoundation
import Darwin
import Foundation
import Speech

private struct Corpus: Decodable {
    struct Clip: Decodable {
        struct Check: Decodable {
            let referenceMs: Int
            let expected: [Int]
        }
        let id: String
        let start: [Int]
        let events: [Check]
    }

    let pages: [[String]]
    let sourcePageNumbers: [Int]
    let clips: [Clip]
}

private struct SpeechEvent: Decodable {
    let atMs: Int
    let transcript: String
    let isFinal: Bool
}

@MainActor
private final class ReplayInput: CompanionSpeechInput {
    typealias Listener = @MainActor (CompanionSpeechEvent) -> Void

    private var streams: [Listener] = []
    private(set) var active: Int?
    private var finishing: Int?
    private var pendingFinal: SpeechEvent?

    func start(localeIdentifier: String, reportLevel: Bool, onEvent: @escaping Listener) {
        streams.append(onEvent)
        active = streams.count - 1
        onEvent(.started)
    }

    func finish() {
        finishing = active
        if let pendingFinal { emit(pendingFinal, forQuestion: true) }
    }

    func cancel() {
        active = nil
        finishing = nil
        pendingFinal = nil
    }

    func emit(_ speech: SpeechEvent, forQuestion: Bool = false, stream: Int? = nil) {
        guard let index = stream ?? active else { return }
        if forQuestion, speech.isFinal, finishing != index {
            pendingFinal = speech
            return
        }
        streams[index](.transcript(speech.transcript, isFinal: speech.isFinal))
    }

    func level(_ value: CGFloat, at time: TimeInterval) {
        guard let active, finishing != active else { return }
        streams[active](.level(value, at: time))
    }
}

private struct LabError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

private actor NetworkAttempts {
    private(set) var outcomes: [String] = []
    func record(_ value: String) { outcomes.append(value) }
}

private struct NetworkProbeModel: QAModel {
    let url: URL
    let attempts: NetworkAttempts

    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { output in
            let task = Task {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
                configuration.timeoutIntervalForRequest = 2
                configuration.timeoutIntervalForResource = 2
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                do {
                    // Connect to a local sentinel without submitting any deck
                    // text, question text, API credentials or audio.
                    let (_, response) = try await session.data(from: url)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    await attempts.record("unexpected HTTP \(status)")
                } catch {
                    let issue = error as NSError
                    await attempts.record("error \(issue.domain) \(issue.code)")
                }
                output.finish(throwing: QAServiceError.transport)
            }
            output.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

@main
@MainActor
struct OfflineWorkspaceReplay {
    private struct Location: Encodable, Equatable {
        let page: Int?
        let sentence: Int?
    }

    private struct Movement: Encodable {
        let timeMs: Int
        let actual: Location
    }

    private struct FollowCheck: Encodable {
        let annotatedAtMs: Int
        let checkedAtMs: Int
        let actual: Location
        let expected: Location
        let matches: Bool
        let transitionOffsetFromPhraseEndMs: Int?
    }

    private struct FollowResult: Encodable {
        let id: String
        let movements: [Movement]
        let checks: [FollowCheck]
        let finalPosition: Location
    }

    private struct QuestionResult: Encodable {
        let id: String
        let submitted: [String]
        let firstSubmissionAtMs: Int?
        let lastPhraseEndMs: Int
        let submittedBeforeLastPhrase: Bool
        let lockedThroughoutQuestion: Bool
        let manualPosition: Location
        let ignoredStaleRecognition: Bool
    }

    private struct Report: Encodable {
        let tcpConnectErrno: Int32
        let importedPages: Int
        let follow: [FollowResult]
        let questions: [QuestionResult]
        let supportedLocales: [String: Bool]
        let missingLanguageMessage: String?
        let manualPageWhileMissingLanguage: Location
        let manualSentenceWhileMissingLanguage: Location
        let networkModelResults: [String]
        let answerError: String?
        let postFailureClick: Location
    }

    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 6, let port = UInt16(args[5]), port > 0 else {
            throw LabError(reason: "Expected PPTX, annotated corpus, WAV directory, Apple traces, scratch workspace and loopback port")
        }
        let tcp = try disconnectedSocket(on: port)
        let decoder = JSONDecoder()
        let deck = URL(fileURLWithPath: args[0])
        let corpus = try decoder.decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let waves = URL(fileURLWithPath: args[2], isDirectory: true)
        let traces = URL(fileURLWithPath: args[3], isDirectory: true)
        let scratch = URL(fileURLWithPath: args[4], isDirectory: true)

        let attemptLog = NetworkAttempts()
        let endpoint = URL(string: "http://127.0.0.1:\(port)/health")!
        let networkModel = NetworkProbeModel(url: endpoint, attempts: attemptLog)
        let input = ReplayInput()
        var simulationUptime = ProcessInfo.processInfo.systemUptime
        let tracker = CompanionTrackingController(speech: input, now: { simulationUptime })
        let workspace = StudioWorkspace(
            store: DeckStore(rootURL: scratch.appendingPathComponent("Decks")),
            model: networkModel, chartCacheDirectory: scratch.appendingPathComponent("Charts"),
            tracking: tracker
        )
        workspace.openURL(deck)
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while workspace.importing != nil || workspace.preparingCharts {
            guard ContinuousClock.now < deadline else { throw LabError(reason: "PPT import timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let project = workspace.project, corpus.sourcePageNumbers.count == corpus.pages.count else {
            throw LabError(reason: "The actual workspace did not import the PPTX")
        }
        let pageCount = workspace.slides.count

        workspace.updateAppendix(from: 1)
        for (index, pageNumber) in corpus.sourcePageNumbers.enumerated() {
            workspace.updateAppendix(single: (pageNumber, false))
            tracker.select(pageIndex: pageNumber - 1)
            workspace.editCurrentSlide { slide in
                slide.script.edit("")
                slide.script.setAIDraft(corpus.pages[index].joined(separator: "\n"), source: DeckDraftSource(
                    revisionID: project.activeRevisionID, pageNumber: pageNumber, evidenceIDs: [slide.id],
                    provider: "Synthetic speech trial corpus"
                ))
            }
        }
        guard await workspace.flushSave() else { throw LabError(reason: "The temporary rehearsal could not be saved") }

        func position() -> Location {
            Location(page: workspace.currentSlide?.pageNumber, sentence: tracker.position?.sentenceIndex.map { $0 + 1 })
        }

        func load(_ id: String) throws -> (Corpus.Clip, [SpeechEvent]) {
            guard let clip = corpus.clips.first(where: { $0.id == id }) else { throw LabError(reason: "Missing corpus clip \(id)") }
            let trace = try String(contentsOf: traces.appendingPathComponent(id + ".jsonl"), encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map { try decoder.decode(SpeechEvent.self, from: Data($0.utf8)) }
            guard trace.contains(where: \.isFinal) else { throw LabError(reason: "Apple final callback unavailable for \(id)") }
            tracker.select(pageIndex: corpus.sourcePageNumbers[clip.start[0]] - 1, sentenceIndex: clip.start[1])
            return (clip, trace)
        }

        var followResults: [FollowResult] = []
        for id in ["read-through-3-pages", "answer-then-natural-resume"] {
            let (clip, trace) = try load(id)
            tracker.startFollowing()
            if id == "answer-then-natural-resume" { tracker.holdForTypedAnswer() }
            var previous = position()
            var movement = [Movement(timeMs: 0, actual: previous)]
            for event in trace {
                input.emit(event)
                if position() != previous {
                    previous = position()
                    movement.append(Movement(timeMs: event.atMs, actual: previous))
                }
            }
            let checks = clip.events.enumerated().map { index, marker in
                let expected = Location(page: corpus.sourcePageNumbers[marker.expected[0]], sentence: marker.expected[1] + 1)
                let cutoff = marker.referenceMs + 650
                let actual = movement.last(where: { $0.timeMs <= cutoff })!.actual
                let previousExpected = index == 0 ? clip.start : clip.events[index - 1].expected
                let firstAtPosition = marker.expected == previousExpected ? nil : movement.first(where: { $0.actual == expected })?.timeMs
                return FollowCheck(
                    annotatedAtMs: marker.referenceMs, checkedAtMs: cutoff, actual: actual, expected: expected,
                    matches: actual == expected, transitionOffsetFromPhraseEndMs: firstAtPosition.map { $0 - marker.referenceMs }
                )
            }
            followResults.append(FollowResult(id: id, movements: movement, checks: checks, finalPosition: position()))
        }

        var questionResults: [QuestionResult] = []
        for (id, locale) in [("slow-question-repeats-next-line", "en-US"), ("chinese-question-english-terms", "zh-CN")] {
            let (clip, trace) = try load(id)
            let levels = try readLevels(waves.appendingPathComponent(id + ".wav"))
            let held = position()
            let epoch = ProcessInfo.processInfo.systemUptime
            simulationUptime = epoch
            var captured: [String] = []
            var submittedAt: Int?
            tracker.startQuestion(localeIdentifier: locale) { text in
                captured.append(text)
                if submittedAt == nil { submittedAt = Int(((simulationUptime - epoch) * 1000).rounded()) }
            }
            let listeningGeneration = input.active
            var voiceIndex = 0
            var textIndex = 0
            var locked = true
            var timeMs = 0
            let replayUntil = max(levels.count * 25, trace.last?.atMs ?? 0) + 4_000
            while timeMs <= replayUntil && captured.isEmpty {
                let nextVoice = voiceIndex < levels.count ? (voiceIndex + 1) * 25 : Int.max
                let nextText = textIndex < trace.count ? trace[textIndex].atMs : Int.max
                let nextTick = ((timeMs / 200) + 1) * 200
                timeMs = min(nextVoice, nextText, nextTick)
                simulationUptime = epoch + Double(timeMs) / 1000
                if timeMs == nextVoice {
                    input.level(levels[voiceIndex], at: simulationUptime)
                    voiceIndex += 1
                }
                if timeMs == nextText {
                    while textIndex < trace.count && trace[textIndex].atMs == timeMs {
                        input.emit(trace[textIndex], forQuestion: true)
                        textIndex += 1
                    }
                }
                if timeMs == nextTick { tracker.checkQuestionSilence() }
                locked = locked && position() == held
            }
            tracker.submitQuestion()
            tracker.select(pageIndex: corpus.sourcePageNumbers.last! - 1, sentenceIndex: 0)
            let manual = position()
            if let listeningGeneration {
                let old = SpeechEvent(atMs: 0, transcript: trace.last(where: { !$0.transcript.isEmpty })?.transcript ?? "", isFinal: false)
                input.emit(old, stream: listeningGeneration)
            }
            let expectedManual = Location(page: corpus.sourcePageNumbers.last, sentence: 1)
            let ignoredStaleRecognition = position() == expectedManual && tracker.phase == .following
            let finalPhrase = clip.events.last!.referenceMs
            questionResults.append(QuestionResult(
                id: id, submitted: captured, firstSubmissionAtMs: submittedAt, lastPhraseEndMs: finalPhrase,
                submittedBeforeLastPhrase: submittedAt.map { $0 < finalPhrase } ?? false,
                lockedThroughoutQuestion: locked, manualPosition: manual, ignoredStaleRecognition: ignoredStaleRecognition
            ))
        }
        tracker.stopFollowing()

        let capabilities = Dictionary(uniqueKeysWithValues: ["en-US", "zh-CN", "en-GB"].map { locale in
            (locale, SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition == true)
        })
        // Only probe the actual production start path if the locale is already
        // known unavailable. That path stops before requesting either permission.
        guard capabilities["en-GB"] == false else { throw LabError(reason: "The missing-locale prerequisite changed") }
        let missing = CompanionTrackingController()
        let screenplay = workspace.slides.map { CompanionTrackingPage(
            sentences: CompanionTrackingPage.sentences(in: $0.script.text), isAppendix: $0.isAppendix
        ) }
        missing.configure(pages: screenplay, localeIdentifier: "en-GB")
        missing.startFollowing()
        let missingMessage = missing.speechError
        let page = corpus.sourcePageNumbers[1]
        missing.select(pageIndex: page - 1)
        let manualPage = Location(page: missing.position.map { $0.pageIndex + 1 }, sentence: missing.position?.sentenceIndex.map { $0 + 1 })
        missing.select(pageIndex: page - 1, sentenceIndex: 1)
        let manualSentence = Location(page: missing.position.map { $0.pageIndex + 1 }, sentence: missing.position?.sentenceIndex.map { $0 + 1 })
        missing.stopFollowing()

        // Exercise the offline-answer failure path without retrieval's possible
        // no-evidence short circuit. Keep the actual rehearsal open for click checks.
        workspace.questions.setDeck(nil)
        workspace.submitQuestion("What is a checksum?", followUp: false)
        let networkDeadline = ContinuousClock.now.advanced(by: .seconds(6))
        while workspace.questions.state == .answering && ContinuousClock.now < networkDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let answerError: String?
        if case .failed(let problem) = workspace.questions.state { answerError = problem.localizedDescription }
        else { answerError = nil }
        tracker.select(pageIndex: page - 1, sentenceIndex: 1)
        let postFailureClick = position()

        let report = Report(
            tcpConnectErrno: tcp, importedPages: pageCount, follow: followResults, questions: questionResults,
            supportedLocales: capabilities, missingLanguageMessage: missingMessage,
            manualPageWhileMissingLanguage: manualPage, manualSentenceWhileMissingLanguage: manualSentence,
            networkModelResults: await attemptLog.outcomes, answerError: answerError, postFailureClick: postFailureClick
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(report) + Data([10]))
        let englishText = questionResults.first?.submitted.first?.lowercased() ?? ""
        guard report.questions.allSatisfy({
            $0.submitted.count == 1 && !$0.submittedBeforeLastPhrase
                && $0.lockedThroughoutQuestion && $0.ignoredStaleRecognition
        }), englishText.contains("your next point"), englishText.contains("what does standardize mean here"),
            missingMessage?.contains("en-GB") == true, manualPage.page == page,
            manualSentence == Location(page: page, sentence: 2), report.networkModelResults.count == 1,
            report.networkModelResults[0].hasPrefix("error "), answerError != nil,
            postFailureClick == Location(page: page, sentence: 2)
        else { throw LabError(reason: "At least one offline workbench acceptance check failed; see JSON") }
    }

    private static func disconnectedSocket(on port: UInt16) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        if descriptor < 0, errno == EPERM || errno == EACCES { return errno }
        guard descriptor >= 0 else { throw LabError(reason: "Could not start the TCP sentinel check") }
        defer { _ = close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let issue = errno
        guard connected < 0, issue == EPERM || issue == EACCES else {
            throw LabError(reason: "TCP was not denied by the process profile (errno \(issue))")
        }
        return issue
    }

    private static func readLevels(_ wav: URL) throws -> [CGFloat] {
        let file = try AVAudioFile(forReading: wav)
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate / 40)
        guard let sample = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let buffer = sample.floatChannelData?.pointee else { throw CocoaError(.fileReadCorruptFile) }
        var levels: [CGFloat] = []
        while file.framePosition < file.length {
            try file.read(into: sample, frameCount: frames)
            let square = (0..<Int(sample.frameLength)).reduce(Float.zero) { $0 + buffer[$1] * buffer[$1] }
            levels.append(CGFloat(sqrt(square / Float(sample.frameLength))))
        }
        return levels
    }
}
