import AVFoundation
import CryptoKit
import Foundation
import NaturalLanguage

private let generalQuestion = "What is a checksum used for?"

private struct VoiceManifest: Decodable {
    struct Question: Decodable, Equatable {
        let id: String
        let question: String
        let currentPageIndex: Int
        let targetPage: Int
        let terms: [String]
        let primer: String?
        var wavSHA256: String?
        var callbackSHA256: String?

        var canonical: Self {
            var value = self
            value.wavSHA256 = nil
            value.callbackSHA256 = nil
            return value
        }
    }

    let probeSHA256: String
    let cases: [Question]
}

private struct AppleCallback: Decodable {
    let atMs: Int
    let transcript: String
    let isFinal: Bool
}

private struct VoiceClip {
    enum Sample {
        case level(CGFloat)
        case callback(AppleCallback)
    }

    struct TimedSample {
        let atMs: Int
        let value: Sample
    }

    let events: [TimedSample]

    init(question: VoiceManifest.Question, directory: URL) throws {
        let wav = directory.appendingPathComponent(question.id + ".wav")
        let trace = directory.appendingPathComponent(question.id + ".jsonl")
        let wavData = try Data(contentsOf: wav)
        let traceData = try Data(contentsOf: trace)
        guard Self.digest(wavData) == question.wavSHA256, Self.digest(traceData) == question.callbackSHA256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let callbacks = try String(decoding: traceData, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(AppleCallback.self, from: Data($0.utf8)) }
        guard callbacks.contains(where: \.isFinal) else { throw CocoaError(.fileReadCorruptFile) }

        let file = try AVAudioFile(forReading: wav)
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate / 40)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let track = buffer.floatChannelData?.pointee else { throw CocoaError(.fileReadCorruptFile) }
        var samples: [TimedSample] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: frames)
            let squared = (0..<Int(buffer.frameLength)).reduce(Float.zero) { $0 + track[$1] * track[$1] }
            let rms = CGFloat(sqrt(squared / Float(buffer.frameLength)))
            let endMs = Int((Double(file.framePosition) / file.processingFormat.sampleRate * 1000).rounded())
            samples.append(.init(atMs: endMs, value: .level(rms)))
        }
        samples += callbacks.map { .init(atMs: $0.atMs, value: .callback($0)) }
        events = samples.sorted { $0.atMs < $1.atMs }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
private final class TimedAppleReplay: CompanionSpeechInput {
    private let clip: VoiceClip
    private var loop: Task<Void, Never>?
    private var callback: (@MainActor (CompanionSpeechEvent) -> Void)?
    private var final: AppleCallback?
    private var ending = false

    init(clip: VoiceClip) { self.clip = clip }

    func start(
        localeIdentifier: String,
        reportLevel: Bool,
        onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void
    ) {
        cancel()
        callback = onEvent
        onEvent(.started)
        let clock = ContinuousClock()
        let started = clock.now
        let uptime = ProcessInfo.processInfo.systemUptime
        loop = Task { [weak self, clip] in
            for event in clip.events {
                try? await clock.sleep(until: started.advanced(by: .milliseconds(event.atMs)))
                guard !Task.isCancelled, let self else { return }
                switch event.value {
                case .level(let level):
                    if !self.ending {
                        let timestamp = uptime + Double(event.atMs) / 1000
                        self.callback?(.level(level, at: timestamp))
                    }
                case .callback(let speech):
                    if speech.isFinal {
                        self.final = speech
                        self.deliverFinalIfReady()
                    } else {
                        self.callback?(.transcript(speech.transcript, isFinal: false))
                    }
                }
            }
        }
    }

    func finish() {
        ending = true
        deliverFinalIfReady()
    }

    func cancel() {
        loop?.cancel()
        loop = nil
        callback = nil
        final = nil
        ending = false
    }

    private func deliverFinalIfReady() {
        // The file probe sends its final after closing its file input. In live
        // capture, the controller closes the input at its own silence endpoint.
        // Keep Apple’s actual final payload and never release it before either.
        guard ending, let final else { return }
        callback?(.transcript(final.transcript, isFinal: true))
    }
}

private struct ShortFixtureModel: QAModel {
    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { output in
            let task = Task {
                do {
                    let input = try JSONDecoder().decode(RequestInput.self, from: Data(request.input.utf8))
                    let words = QASearchText.normalized(input.question)
                    if input.question == generalQuestion && input.evidence.isEmpty {
                        try await Task.sleep(for: .milliseconds(240))
                        output.yield(line("short", "supplemental", "A checksum helps detect changes or errors in a piece of data.") + "\n")
                        output.yield(line("bullet", "supplemental", "Compute a checksum for the original data before sending or storing it.") + "\n")
                        output.yield(line("bullet", "supplemental", "Compare that value with a new checksum to check the received data.") + "\n")
                        output.finish()
                        return
                    }
                    let answer: String
                    let distinctive: String
                    if words.contains("calculate") && input.previousQuestion != nil {
                        answer = "The algorithm weights every interval by its recorded duration."
                        distinctive = "weights every interval"
                    } else if words.contains("checksum") && words.contains("cedar") {
                        answer = "The Cedar logger used a rolling checksum."
                        distinctive = "rolling checksum"
                    } else if words.contains("coverage") && words.contains("orchid") {
                        answer = "Orchid coverage reached 83%."
                        distinctive = "83%"
                    } else {
                        throw QAServiceError.invalidResponse
                    }

                    guard let citation = input.evidence.first(where: { $0.text.contains(distinctive) }) else {
                        throw QAServiceError.invalidResponse
                    }
                    let wire = line("short", "grounded", answer, citation)
                    let split = wire.index(wire.startIndex, offsetBy: wire.count / 2)
                    try await Task.sleep(for: .milliseconds(140))
                    output.yield(String(wire[..<split]))
                    try await Task.sleep(for: .milliseconds(100))
                    output.yield(String(wire[split...]) + "\n")
                    output.finish()
                } catch {
                    output.finish(throwing: error)
                }
            }
            output.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// The cold follow-up first builds real conversation context through a
// separate client. The measured request then uses its untouched transport.
private final class PrimerRoute: QAModel, @unchecked Sendable {
    private let lock = NSLock()
    private var model: any QAModel

    init(primer: any QAModel) { model = primer }

    func useMeasuredClient(_ client: any QAModel) {
        lock.withLock { model = client }
    }

    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        let selected = lock.withLock { model }
        return selected.stream(request)
    }
}

@main
@MainActor
struct VoiceQABenchmark {
    private enum Input: String, Encodable, Hashable {
        case typed
        case spoken
    }

    private enum Temperature: String, Encodable {
        case shared
        case cold
        case warm
    }

    private struct Sample: Encodable {
        let questionID: String
        let input: Input
        let temperature: Temperature
        let repetition: Int
        let submittedText: String?
        let matchesCanonicalWords: Bool
        let status: String
        let firstSentence: String?
        let citationPages: [Int]
        let usableFirstSentence: Bool
        let measuredFirstSentenceMs: Int?
        let inputOverheadMs: Int?
        let submitToFirstSentenceMs: Int?
        let primerStatus: String?
        let primerUsesSeparateClient: Bool?
    }

    private struct ModeStatistics: Encodable {
        let input: Input
        let temperature: Temperature
        let attempts: Int
        let completed: Int
        let usable: Int
        let answerTimeouts: Int
        let failures: [String: Int]
        let atOrBelowThreeSeconds: Int
        let usableMedianMs: Int?
        let usableMaximumMs: Int?
    }

    private struct Warmup: Encodable {
        let input: Input
        let status: String
        let acceptedPrimer: Bool
        let firstSentenceMs: Int?
    }

    private struct Standalone: Encodable {
        let question: String
        let status: String
        let firstSentence: String?
        let firstSentenceMs: Int?
        let bullets: [String]
        let hasEnglishAnswer: Bool
        let citations: [Int]
        let passed: Bool
    }

    private struct Report: Encodable {
        let mode: String
        let batch: String
        let pairedColdWarm: Bool
        let outputModel: String
        let repetitions: Int
        let answerTimeoutSeconds: Int
        let appleProbeSHA256: String
        let audioHashes: [String: String]
        let modeStatistics: [ModeStatistics]
        let samples: [Sample]
        let warmups: [Warmup]
        let noPresentation: Standalone?
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
        let arguments = Array(CommandLine.arguments.dropFirst())
        let output: URL
        let selectedProvider: StudioModelProvider?
        let tag: String
        let modelName: String
        let optionalArguments: ArraySlice<String>
        if arguments.count >= 2 && arguments[0] == "controlled" {
            output = URL(fileURLWithPath: arguments[1], isDirectory: true)
            selectedProvider = nil
            tag = "controlled"
            modelName = "controlled short response"
            optionalArguments = arguments.dropFirst(2)
        } else if arguments.count >= 4 && arguments[0] == "live",
                  let provider = StudioModelProvider(rawValue: arguments[2]), provider != .gemini,
                  arguments[3] == provider.liveTrialFlag {
            output = URL(fileURLWithPath: arguments[1], isDirectory: true)
            selectedProvider = provider
            tag = "\(provider.rawValue)-live"
            modelName = provider.modelID
            optionalArguments = arguments.dropFirst(4)
        } else {
            print("Usage: run.sh controlled INPUT_DIR [REPEATS=1] [ANSWER_TIMEOUT_SECONDS=20] [CASE=all] [--paired] [--fast-end]")
            print("       run.sh live INPUT_DIR deepseek|bigmodel|zai --allow-keychain-access [REPEATS=1] [ANSWER_TIMEOUT_SECONDS=20] [CASE=all|all-with-evidence|CASE_ID] [--paired] [--fast-end]")
            print("       run.sh live INPUT_DIR grok-cli --use-cli [REPEATS=1] [ANSWER_TIMEOUT_SECONDS=35] [CASE=all|all-with-evidence|CASE_ID] [--paired] [--fast-end]")
            print("       Add --diagnose-evidence in place of the trial arguments to check two synthetic evidence cases.")
            exit(2)
        }
        if optionalArguments.elementsEqual(["--diagnose-evidence"]), let provider = selectedProvider {
            let makeModel = try provider.makeLiveTrialClients()
            try await CompanionQATests.captureLiveQuestionFailures(
                output: output.appendingPathComponent("evidence").appendingPathComponent(provider.rawValue),
                model: makeModel()
            )
            return
        }
        let paired = optionalArguments.contains("--paired")
        let fastEnd = optionalArguments.contains("--fast-end")
        let controls = optionalArguments.filter { $0 != "--paired" && $0 != "--fast-end" }
        let defaultTimeout = selectedProvider == .grokCLI ? GrokCLIQAModel.answerTimeoutSeconds : 20
        guard controls.count <= 3,
              optionalArguments.count - controls.count == (paired ? 1 : 0) + (fastEnd ? 1 : 0),
              let repeats = Int(controls.first ?? "1"), (1...2).contains(repeats),
              let timeout = Int(controls.count >= 2 ? controls[1] : String(defaultTimeout)), (5...35).contains(timeout)
        else {
            print("Repeats must be 1 or 2. The answer timeout must be from 5 to 35 seconds.")
            exit(2)
        }

        let manifest = try JSONDecoder().decode(VoiceManifest.self, from: Data(contentsOf: output.appendingPathComponent("inputs.json")))
        // Only the three checked-in synthetic cases may reach the live provider.
        let fixture = CompanionQATests.deck()
        let declared = try checkedSyntheticCases()
        let requestedBatch = controls.count == 3 ? controls[2] : "all"
        let includeEvidence = requestedBatch == "all-with-evidence" && selectedProvider != nil
        let batch = includeEvidence ? "all" : requestedBatch
        guard batch == "all" || declared[batch] != nil else { throw QAServiceError.invalidResponse }
        let clips = try manifest.cases.map { question in
            guard declared[question.id] == question.canonical else { throw QAServiceError.invalidResponse }
            return try VoiceClip(question: question, directory: output)
        }
        guard manifest.cases.count == declared.count,
              Set(manifest.cases.map(\.id)) == Set(declared.keys) else { throw QAServiceError.invalidResponse }
        let makeModel: () -> any QAModel
        if let provider = selectedProvider {
            makeModel = try provider.makeLiveTrialClients()
        } else {
            makeModel = { ShortFixtureModel() }
        }
        let temperatures: [Temperature] = paired ? [.cold, .warm] : [.shared]
        let sharedService = paired ? nil : CompanionQAService(model: makeModel())
        var warmSessions: [Input: CompanionQASession] = [:]
        var warmupResults: [Input: Warmup] = [:]
        var samples: [Sample] = []
        for repetition in 1...repeats {
            for (index, question) in manifest.cases.enumerated() where batch == "all" || question.id == batch {
                let modes: [Input] = (repetition + index).isMultiple(of: 2) ? [.spoken, .typed] : [.typed, .spoken]
                for mode in modes {
                    let reverse = (repetition + index + (mode == .typed ? 0 : 1)).isMultiple(of: 2)
                    let order = reverse ? Array(temperatures.reversed()) : temperatures
                    for temperature in order {
                        let session: CompanionQASession
                        var startMeasuredRequest: (() -> Void)?
                        var setupFailure: String?
                        switch temperature {
                        case .shared:
                            session = makeSession(service: sharedService!, timeout: timeout, deck: fixture)
                        case .cold:
                            let measured = makeModel()
                            if question.primer != nil {
                                let route = PrimerRoute(primer: makeModel())
                                session = makeSession(service: CompanionQAService(model: route), timeout: timeout, deck: fixture)
                                startMeasuredRequest = { route.useMeasuredClient(measured) }
                            } else {
                                session = makeSession(service: CompanionQAService(model: measured), timeout: timeout, deck: fixture)
                            }
                        case .warm:
                            if let existing = warmSessions[mode] {
                                session = existing
                            } else {
                                session = makeSession(service: CompanionQAService(model: makeModel()), timeout: timeout, deck: fixture)
                                session.submit("What was the reported coverage for Orchid?", currentPageIndex: 4)
                                try await waitForCompletion(session, timeout: timeout)
                                warmSessions[mode] = session
                                warmupResults[mode] = Warmup(
                                    input: mode, status: status(of: session),
                                    acceptedPrimer: session.state == .completed && hasGroundedPrimer(session),
                                    firstSentenceMs: session.answer.firstSentenceElapsed.map(milliseconds)
                                )
                            }
                            if warmupResults[mode]?.acceptedPrimer != true { setupFailure = "warmup-failed" }
                        }
                        let item = try await measure(
                            question, clip: clips[index], mode: mode, temperature: temperature, repetition: repetition,
                            timeout: timeout, deck: fixture, session: session, startMeasuredRequest: startMeasuredRequest,
                            setupFailure: setupFailure, preferFastEnding: fastEnd
                        )
                        samples.append(item)
                        let elapsed = item.measuredFirstSentenceMs.map(String.init) ?? "unavailable"
                        print("\(item.questionID) \(item.input.rawValue)/\(item.temperature.rawValue): \(item.status), usable \(item.usableFirstSentence), first sentence \(elapsed) ms")
                    }
                }
            }
        }

        let standalone = paired ? try await measureWithoutPresentation(model: makeModel(), timeout: timeout) : nil
        let summary = Report(
            mode: tag, batch: batch, pairedColdWarm: paired, outputModel: modelName, repetitions: repeats, answerTimeoutSeconds: timeout,
            appleProbeSHA256: manifest.probeSHA256,
            audioHashes: Dictionary(uniqueKeysWithValues: manifest.cases.compactMap { item in
                item.wavSHA256.map { (item.id, $0) }
            }),
            modeStatistics: [Input.typed, .spoken].flatMap { mode in
                temperatures.map { statistics(mode, temperature: $0, from: samples) }
            },
            samples: samples, warmups: [Input.typed, .spoken].compactMap { warmupResults[$0] }, noPresentation: standalone
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let batchName = batch == "all" ? tag : tag + "-" + batch
        let reportName = (paired ? batchName + "-paired" : batchName) + (fastEnd ? "-fast-end" : "")
        try encoder.encode(summary).write(to: output.appendingPathComponent(reportName + ".json"), options: .atomic)
        if includeEvidence, let provider = selectedProvider {
            try await CompanionQATests.liveTrial(
                output: output.appendingPathComponent("evidence"), modelID: modelName,
                repetitions: repeats, reportName: provider.evidenceTrialFilename,
                includeCharts: provider.supportsOnlineImages, makeModel: makeModel
            )
        }
        if selectedProvider == nil {
            try expect(
                samples.allSatisfy { $0.usableFirstSentence && $0.status == "complete" && $0.matchesCanonicalWords }
                    && (!paired || standalone?.passed == true),
                "The controlled test did not produce a complete grounded first sentence for every input."
            )
        }
    }

    private static func checkedSyntheticCases() throws -> [String: VoiceManifest.Question] {
        // The wrapper puts this copy beside the executable. It is independent
        // of the recording directory supplied when running the experiment.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let path = executable.deletingLastPathComponent().appendingPathComponent("cases.json")
        let cases = try JSONDecoder().decode([VoiceManifest.Question].self, from: Data(contentsOf: path))
        return Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
    }

    private static func measure(
        _ question: VoiceManifest.Question, clip: VoiceClip, mode: Input, temperature: Temperature,
        repetition: Int, timeout: Int, deck: QADeckSnapshot, session: CompanionQASession,
        startMeasuredRequest: (() -> Void)?,
        setupFailure: String?, preferFastEnding: Bool
    ) async throws -> Sample {
        var submitted: String?
        var endOfVoice: ContinuousClock.Instant?
        var inputOverhead: Int?
        var submittedBenchmarkQuestion = false
        var primerStatus: String?

        if let setupFailure { return result(status: setupFailure) }
        if let primer = question.primer {
            session.submit(primer, currentPageIndex: 4)
            try await waitForCompletion(session, timeout: timeout)
            primerStatus = status(of: session)
            guard hasGroundedPrimer(session) else { return result(status: "primer-failed") }
        }

        startMeasuredRequest?()
        let tracker = CompanionTrackingController(speech: TimedAppleReplay(clip: clip))
        tracker.configure(pages: deck.pages.map { CompanionTrackingPage(sentences: [$0.bodyText]) })
        tracker.select(pageIndex: question.currentPageIndex)
        let followUp = question.primer != nil
        if mode == .typed {
            tracker.holdForTypedAnswer()
            submitted = question.question
            inputOverhead = 0
            submittedBenchmarkQuestion = true
            session.submit(question.question, currentPageIndex: question.currentPageIndex, followUp: followUp, submittedAt: .now)
        } else {
            tracker.startQuestion(localeIdentifier: "en-US", preferFastEnding: preferFastEnding) { captured in
                submitted = captured
                endOfVoice = tracker.lastQuestionSpeechEndedAt
                guard let ended = endOfVoice else { return }
                inputOverhead = milliseconds(ended.duration(to: .now))
                submittedBenchmarkQuestion = true
                session.submit(captured, currentPageIndex: question.currentPageIndex, followUp: followUp, submittedAt: ended)
            }
            let captureLimit = (clip.events.last?.atMs ?? 0) + 4_000
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(captureLimit))
            while submitted == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(15))
            }
            if submitted == nil {
                tracker.cancelQuestion()
                return result(status: "speech-no-submission")
            }
            if endOfVoice == nil {
                return result(status: "no-audible-frame")
            }
        }

        try await waitForCompletion(session, timeout: timeout)
        return result(status: status(of: session))

        func result(status: String) -> Sample {
            let visible = submittedBenchmarkQuestion ? session.answer : QAAnswer()
            let short = visible.shortAnswerPoint
            let cites = short?.citations.map(\.pageNumber) ?? []
            let text = QASearchText.normalized(short?.text ?? "")
            let acceptable = short?.kind == .grounded && cites.contains(question.targetPage)
                && question.terms.contains { text.contains($0) }
            let first = visible.firstSentenceElapsed.map(milliseconds)
            return Sample(
                questionID: question.id, input: mode, temperature: temperature, repetition: repetition, submittedText: submitted,
                matchesCanonicalWords: wordSequence(submitted ?? "") == wordSequence(question.question),
                status: status, firstSentence: short?.text, citationPages: cites, usableFirstSentence: acceptable,
                measuredFirstSentenceMs: first, inputOverheadMs: inputOverhead,
                submitToFirstSentenceMs: first.flatMap { firstMs in inputOverhead.map { max(0, firstMs - $0) } },
                primerStatus: primerStatus,
                primerUsesSeparateClient: question.primer.map { _ in temperature == .cold }
            )
        }
    }

    private static func makeSession(service: CompanionQAService, timeout: Int, deck: QADeckSnapshot?) -> CompanionQASession {
        let session = CompanionQASession(service: service, timeout: .seconds(timeout))
        session.setDeck(deck)
        return session
    }

    private static func hasGroundedPrimer(_ session: CompanionQASession) -> Bool {
        guard let answer = session.answer.shortAnswerPoint else { return false }
        return session.canFollowUp && answer.kind == .grounded
            && answer.text.contains("83%") && answer.citations.contains { $0.pageNumber == 5 }
    }

    private static func status(of session: CompanionQASession) -> String {
        switch session.state {
        case .completed: "complete"
        case .failed(.timeout): "answer-timeout"
        case .failed(let error): error.localizedDescription
        case .idle, .answering: "incomplete"
        }
    }

    private static func measureWithoutPresentation(model: any QAModel, timeout: Int) async throws -> Standalone {
        let session = makeSession(service: CompanionQAService(model: model), timeout: timeout, deck: nil)
        session.submit(generalQuestion)
        try await waitForCompletion(session, timeout: timeout)
        let answer = session.answer
        let first = answer.shortAnswerPoint
        let bullets = answer.bullets.map(\.text)
        let allPoints = [first].compactMap { $0 } + answer.bullets + answer.details
        let pages = Set((answer.citations + allPoints.flatMap(\.citations)).map(\.pageNumber)).sorted()
        let english = NLLanguageRecognizer.dominantLanguage(for: allPoints.map(\.text).joined(separator: " ")) == .english
        let passed = session.state == .completed && first?.kind == .supplemental && english
            && (2...3).contains(bullets.count) && pages.isEmpty
        print("no-presentation typed: \(status(of: session)), passed \(passed), \(bullets.count) bullets")
        return Standalone(
            question: generalQuestion, status: status(of: session), firstSentence: first?.text,
            firstSentenceMs: answer.firstSentenceElapsed.map(milliseconds), bullets: bullets,
            hasEnglishAnswer: english, citations: pages, passed: passed
        )
    }

    private static func waitForCompletion(_ session: CompanionQASession, timeout: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout + 1))
        while session.state == .answering && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        if session.state == .answering { session.cancel() }
    }

    private static func milliseconds(_ time: Duration) -> Int {
        let pieces = time.components
        return Int(pieces.seconds * 1_000 + pieces.attoseconds / 1_000_000_000_000_000)
    }

    private static func wordSequence(_ value: String) -> [Substring] {
        value.lowercased().split { !$0.isLetter && !$0.isNumber }
    }

    private static func statistics(_ mode: Input, temperature: Temperature, from samples: [Sample]) -> ModeStatistics {
        let attempts = samples.filter { $0.input == mode && $0.temperature == temperature }
        let timings = attempts.filter(\.usableFirstSentence).compactMap(\.measuredFirstSentenceMs).sorted()
        let median: Int?
        if timings.isEmpty {
            median = nil
        } else {
            median = (timings[(timings.count - 1) / 2] + timings[timings.count / 2]) / 2
        }
        let failures = attempts.reduce(into: [String: Int]()) { counts, sample in
            if sample.status != "complete" {
                counts[sample.status, default: 0] += 1
            } else if !sample.usableFirstSentence {
                counts["unusable-first-sentence", default: 0] += 1
            }
        }
        return ModeStatistics(
            input: mode, temperature: temperature, attempts: attempts.count, completed: attempts.filter { $0.status == "complete" }.count,
            usable: timings.count, answerTimeouts: attempts.filter { $0.status == "answer-timeout" }.count, failures: failures,
            atOrBelowThreeSeconds: timings.filter { $0 <= 3000 }.count,
            usableMedianMs: median, usableMaximumMs: timings.last
        )
    }
}
