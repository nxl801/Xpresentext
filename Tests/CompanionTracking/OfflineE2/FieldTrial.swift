@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Speech

private struct FieldError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private struct FieldCorpus: Decodable {
    struct Clip: Decodable {
        struct Mark: Decodable {
            let expected: [Int]
            let kind: String
            let referenceMs: Int
            let transcript: String?
        }
        let id: String
        let audioFile: String
        let audioSha256: String
        let locale: String
        let start: [Int]
        let phase: String
        let events: [Mark]
    }

    let source: String
    let pages: [[String]]
    let sourcePageNumbers: [Int]
    let clips: [Clip]
}

private struct FieldLocation: Codable, Hashable {
    let page: Int?
    let sentence: Int?
}

private struct FieldMovement: Encodable {
    let timeMs: Int
    let phase: String
    let position: FieldLocation
}

private struct FieldCheckpoint: Encodable {
    let annotatedAtMs: Int
    let checkedAtMs: Int
    let expected: FieldLocation
    let actual: FieldLocation?
    let expectedPhase: String
    let actualPhase: String?
    let passed: Bool
}

private struct FieldSubmission: Encodable {
    let submittedAt: Date
    let timeMs: Int
    let lastSpeechAtMs: Int?
    let lastWords: String
    let containsFirstPhrase: Bool
    let containsLastWords: Bool
    let heardEnglishTerms: [String]
    let unrecognizedEnglishTerms: [String]
    let position: FieldLocation
}

private struct FieldScene: Encodable {
    let id: String
    let startedAt = Date()
    let wavSHA256: String
    let expectedPhraseEndMs: Int?
    var finishedAt: Date?
    var playbackStartedAt: Date?
    var playbackFinished = false
    var completed = false
    var passed = false
    var error: String?
    var captureStarts = 0
    var recognitionCallbacks = 0
    var englishFollowTrace: FieldRecognitionTrace?
    var localSpeechError: String?
    var observedSpeechFailures: [String] = []
    var positions: [FieldMovement] = []
    var checkpoints: [FieldCheckpoint] = []
    var submissions: [FieldSubmission] = []

    mutating func observe(_ event: CompanionSpeechEvent, atMs: Int?) {
        switch event {
        case .started: captureStarts += 1
        case .transcript(let text, let final):
            recognitionCallbacks += 1
            if let atMs {
                let request = captureStarts
                englishFollowTrace?.record(text, final: final, request: request, atMs: atMs)
            }
        case .failure(let message, _): observedSpeechFailures.append(message)
        case .level: break
        }
    }
}

private struct FieldWAV: Encodable {
    let id: String
    let sha256: String
    let sampleRate: Double
    let channels: AVAudioChannelCount
    let frames: AVAudioFramePosition
}

private struct FieldMappedPage: Encodable {
    let page: Int
    let sentences: Int
    let imagePixels: [Int]
    let thumbnailPixels: [Int]
}

private struct FieldPreparation: Encodable {
    let ready = true
    let time = Date()
    let sourceFilename: String
    let sourceSHA256: String
    let importedPages: Int
    let mappings: [FieldMappedPage]
    let wavs: [FieldWAV]
    let recorderCheckUpdates: Int
}

private struct FieldFallback: Encodable {
    let time = Date()
    let modelCondition: String
    let answerError: String?
    let externalTransportCondition: String
    let externalTransportStatus: String
    let externalHTTPStatus: Int?
    let unavailableLocale: String?
    let unavailableLocaleError: String?
    let manualPositionAfterFailure: FieldLocation
    let passed: Bool
}

private struct FieldResult: Encodable {
    let scope: String
    let finishedAt = Date()
    let complete: Bool
    let passed: Bool
    let completedScenarios: [String]
    let passedScenarios: [String]
    let missingScenarios: [String]
    let error: String?
}

private struct OfflineFieldModel: QAModel {
    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: QAServiceError.transport) }
    }
}

@MainActor
private final class PreparationSpeech: CompanionSpeechInput {
    private(set) var unexpectedlyStarted = false

    func start(localeIdentifier: String, reportLevel: Bool, onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void) {
        unexpectedlyStarted = true
        onEvent(.failure("Audio capture is disabled during preparation.", canRestart: false))
    }

    func finish() {}
    func cancel() {}
}

@MainActor
private final class FieldSpeech: CompanionSpeechInput {
    private let local = CompanionLocalSpeechInput()
    var observed: ((CompanionSpeechEvent) -> Void)?

    func start(localeIdentifier: String, reportLevel: Bool, onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void) {
        local.start(localeIdentifier: localeIdentifier, reportLevel: reportLevel) { [weak self] event in
            onEvent(event)
            self?.observed?(event)
        }
    }

    func finish() { local.finish() }
    func cancel() { local.cancel() }
}

@MainActor
private final class FieldPlayback: NSObject, AVAudioPlayerDelegate {
    let player: AVAudioPlayer
    private(set) var completed: Bool?

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
        guard player.prepareToPlay() else { throw FieldError("Could not prepare WAV playback.") }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.completed = flag }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in self?.completed = false }
    }
}

@main
@MainActor
struct FieldTrial {
    private static let sceneIDs = [
        "read-through-3-pages", "answer-then-natural-resume",
        "slow-question-repeats-next-line", "chinese-question-english-terms"
    ]
    private static let fallbackID = "offline-fallback"

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let directory = args.count == 5 ? URL(fileURLWithPath: args[4], isDirectory: true) : nil
        var status: Int32 = 1
        do {
            guard args.count == 5, let directory, ["--prepare", "--field", "--follow"].contains(args[0]) else {
                throw FieldError("Usage: FieldTrial --prepare|--field|--follow PPTX shared-transcripts.json audio-dir run-dir")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result = try await run(
                pptx: URL(fileURLWithPath: args[1]), corpusURL: URL(fileURLWithPath: args[2]),
                audio: URL(fileURLWithPath: args[3], isDirectory: true), directory: directory, mode: args[0]
            )
            if result { status = 0 }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            if let directory { try? write(["error": error.localizedDescription], named: "error.json", in: directory) }
        }
        if let directory {
            do { try Data("\(status)\n".utf8).write(to: directory.appendingPathComponent("status"), options: .atomic) }
            catch {
                FileHandle.standardError.write(Data(("Could not write run status: " + error.localizedDescription + "\n").utf8))
                status = 1
            }
        }
        exit(status)
    }

    private static func run(pptx: URL, corpusURL: URL, audio: URL, directory: URL, mode: String) async throws -> Bool {
        let field = mode != "--prepare"
        func abortCheck() throws {
            try Task.checkCancellation()
            if field && FileManager.default.fileExists(atPath: directory.appendingPathComponent("abort").path) {
                throw FieldError("Stopped because the run directory has an abort marker.")
            }
        }
        try abortCheck()
        let corpus = try JSONDecoder().decode(FieldCorpus.self, from: Data(contentsOf: corpusURL))
        let clips = try sceneIDs.map { id in
            let choices = corpus.clips.filter { $0.id == id }
            guard choices.count == 1, let clip = choices.first, clip.audioFile == id + ".wav" else {
                throw FieldError("Missing or ambiguous approved WAV for \(id).")
            }
            return clip
        }
        guard corpus.source == pptx.lastPathComponent, corpus.sourcePageNumbers == [2, 8, 10],
              corpus.pages.count == corpus.sourcePageNumbers.count, corpus.pages.allSatisfy({ !$0.isEmpty }) else {
            throw FieldError("The supplied presentation and its page-2/8/10 corpus do not match.")
        }
        let expectedPhases = ["following", "awaitingResume", "listeningQuestion", "listeningQuestion"]
        for (clip, phase) in zip(clips, expectedPhases) {
            guard clip.phase == phase, clip.locale == (clip.id == sceneIDs[3] ? "zh" : "en"),
                  valid(clip.start, in: corpus), !clip.events.isEmpty,
                  clip.events.allSatisfy({ valid($0.expected, in: corpus) && $0.referenceMs > 0 }),
                  zip(clip.events, clip.events.dropFirst()).allSatisfy({ $0.referenceMs < $1.referenceMs }) else {
                throw FieldError("Invalid scene annotations for \(clip.id).")
            }
        }

        let wavs = try clips.map {
            try abortCheck()
            return try decodeWAV($0, in: audio)
        }
        let digest = try sha256(pptx)
        let isolated = FileManager.default.temporaryDirectory
            .appendingPathComponent("Textream-E2-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: isolated) }
        let capture = field ? FieldSpeech() : nil
        let preparationSpeech = PreparationSpeech()
        let tracker = CompanionTrackingController(speech: capture.map { $0 as any CompanionSpeechInput } ?? preparationSpeech)
        let store = DeckStore(rootURL: isolated.appendingPathComponent("Decks"))
        let workspace = StudioWorkspace(store: store, model: OfflineFieldModel(),
                                        chartCacheDirectory: isolated.appendingPathComponent("Charts"), tracking: tracker)
        workspace.openURL(pptx)
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while workspace.importing != nil || workspace.preparingCharts {
            try abortCheck()
            guard ContinuousClock.now < deadline else { throw FieldError("Presentation import timed out.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let project = workspace.project, workspace.slides.count == 37,
              project.activeRevision.sourceName == corpus.source,
              let storedSource = await store.sourceURL(projectID: project.id, revisionID: project.activeRevisionID),
              try sha256(storedSource) == digest else {
            throw FieldError("The prepared workspace did not retain the expected 37-page source.")
        }

        workspace.updateAppendix(from: 1)
        var mappings: [FieldMappedPage] = []
        for (page, sentences) in zip(corpus.sourcePageNumbers, corpus.pages) {
            try abortCheck()
            let draft = sentences.joined(separator: "\n")
            workspace.updateAppendix(single: (page, false))
            tracker.select(pageIndex: page - 1)
            workspace.editCurrentSlide { slide in
                slide.script.edit("")
                slide.script.setAIDraft(draft, source: DeckDraftSource(
                    revisionID: project.activeRevisionID, pageNumber: page, evidenceIDs: [slide.id],
                    provider: "Local E2 field corpus"
                ))
            }
            guard let slide = workspace.currentSlide, slide.pageNumber == page, !slide.isAppendix,
                  slide.script.text == draft, slide.script.aiSource?.pageNumber == page,
                  CompanionTrackingPage.sentences(in: draft) == sentences, tracker.currentSentence == sentences.first else {
                throw FieldError("Could not verify the script-to-slide mapping on page \(page).")
            }
            let pageImage = try await store.imageData(projectID: project.id, revisionID: project.activeRevisionID, pageNumber: page)
            let thumbnail = try await store.imageData(
                projectID: project.id, revisionID: project.activeRevisionID, pageNumber: page, kind: .thumbnail
            )
            mappings.append(FieldMappedPage(page: page, sentences: sentences.count,
                                            imagePixels: try pixels(pageImage, page: page),
                                            thumbnailPixels: try pixels(thumbnail, page: page)))
        }
        guard await workspace.flushSave(), !preparationSpeech.unexpectedlyStarted else {
            throw FieldError("The isolated rehearsal could not be saved without audio capture.")
        }
        try abortCheck()
        let ready = FieldPreparation(sourceFilename: corpus.source, sourceSHA256: digest, importedPages: workspace.slides.count,
                                     mappings: mappings, wavs: wavs, recorderCheckUpdates: try checkRecorder(clips[0], corpus: corpus))
        try write(ready, named: "prepare.json", in: directory)
        print(String(decoding: try encoded(ready), as: UTF8.self))
        guard let capture else { return true }

        let conditions = FieldConditions()
        defer { conditions.stop() }
        var completed: [String] = []
        var passed: [String] = []
        let selected = mode == "--follow" ? Array(clips.prefix(1)) : clips
        let expected = selected.map(\.id) + (mode == "--field" ? [fallbackID] : [])
        let scope = mode == "--follow" ? "english-continuous-follow" : "full-field-trial"
        do {
            try await conditions.start(in: directory)
            func check() throws {
                try abortCheck()
                try conditions.check()
            }
            for clip in selected {
                try check()
                let scene = await runScene(clip, corpus: corpus, audio: audio, workspace: workspace, capture: capture, check: check)
                try write(scene, named: clip.id + ".json", in: directory)
                if scene.completed { completed.append(clip.id) }
                if scene.passed { passed.append(clip.id) }
                try check()
            }
            if mode == "--field" {
                let fallback = try await offlineFallback(workspace, check: check)
                try write(fallback, named: fallbackID + ".json", in: directory)
                completed.append(fallbackID)
                if fallback.passed { passed.append(fallbackID) }
            }
            try check()
            let result = FieldResult(scope: scope, complete: completed == expected, passed: passed == expected, completedScenarios: completed,
                                     passedScenarios: passed, missingScenarios: expected.filter { !completed.contains($0) }, error: nil)
            try write(result, named: "field-result.json", in: directory)
            return result.passed
        } catch {
            let result = FieldResult(scope: scope, complete: false, passed: false, completedScenarios: completed,
                                     passedScenarios: passed, missingScenarios: expected.filter { !completed.contains($0) },
                                     error: error.localizedDescription)
            try? write(result, named: "field-result.json", in: directory)
            throw error
        }
    }

    private static func runScene(
        _ clip: FieldCorpus.Clip, corpus: FieldCorpus, audio: URL, workspace: StudioWorkspace,
        capture: FieldSpeech, check: () throws -> Void
    ) async -> FieldScene {
        let isQuestion = clip.phase == "listeningQuestion"
        let tracker = workspace.tracking
        var playbackEpoch: ContinuousClock.Instant?
        var scene = FieldScene(id: clip.id, wavSHA256: clip.audioSha256,
                               expectedPhraseEndMs: isQuestion ? clip.events.last?.referenceMs : nil)
        if !isQuestion { scene.englishFollowTrace = FieldRecognitionTrace(script: corpus.pages.flatMap { $0 }) }
        func observePosition() {
            guard let playbackEpoch else { return }
            let actual = fieldPosition(workspace)
            let phase = String(describing: tracker.phase)
            if scene.positions.last?.position != actual || scene.positions.last?.phase != phase {
                scene.positions.append(FieldMovement(timeMs: elapsed(since: playbackEpoch), phase: phase, position: actual))
            }
        }
        defer {
            capture.observed = nil
            tracker.stopFollowing()
            tracker.cancelQuestion()
        }
        do {
            try check()
            let playback = try FieldPlayback(url: audio.appendingPathComponent(clip.audioFile))
            defer { playback.player.stop() }
            let start = position(clip.start, corpus: corpus)
            tracker.select(pageIndex: corpus.sourcePageNumbers[clip.start[0]] - 1, sentenceIndex: clip.start[1])
            capture.observed = { event in
                if case .level = event { return }
                scene.observe(event, atMs: playbackEpoch.map { elapsed(since: $0) })
                observePosition()
            }
            if isQuestion {
                tracker.startQuestion(localeIdentifier: clip.locale == "zh" ? "zh-CN" : "en-US") { words in
                    guard let playbackEpoch else { return }
                    scene.submissions.append(submission(
                        words, locale: clip.locale, at: playbackEpoch, speechEnd: tracker.lastQuestionSpeechEndedAt,
                        location: fieldPosition(workspace)
                    ))
                    observePosition()
                }
            } else {
                if clip.phase == "awaitingResume" { tracker.holdForTypedAnswer() }
                tracker.startFollowing()
            }
            let startDeadline = ContinuousClock.now.advanced(by: .seconds(45))
            while !tracker.isListening {
                try check()
                if let error = tracker.speechError { throw FieldError(error) }
                guard ContinuousClock.now < startDeadline else { throw FieldError("Microphone capture did not start.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(300))
            try check()
            guard tracker.isListening else { throw FieldError("Capture ended before playback started.") }
            let epoch = ContinuousClock.now
            playbackEpoch = epoch
            scene.playbackStartedAt = Date()
            observePosition()
            guard playback.player.play() else { throw FieldError("WAV playback could not start.") }
            let end = epoch.advanced(by: .seconds(playback.player.duration + (isQuestion ? 6 : 1.2)))
            while ContinuousClock.now < end {
                try check()
                observePosition()
                if playback.completed == false { throw FieldError("The output device did not finish playing the WAV.") }
                if let error = tracker.speechError { throw FieldError(error) }
                if isQuestion && playback.completed == true && !scene.submissions.isEmpty {
                    // Leave time to detect an accidental duplicate submission.
                    if elapsed(since: epoch) >= (scene.submissions.last?.timeMs ?? 0) + 500 { break }
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            try check()
            scene.playbackFinished = playback.completed == true
            guard scene.playbackFinished else { throw FieldError("Playback did not report a successful end.") }
            scene.completed = true
            scene.checkpoints = clip.events.map { mark in
                let cutoff = mark.referenceMs + 650
                let observed = scene.positions.last(where: { $0.timeMs <= cutoff })
                let expected = position(mark.expected, corpus: corpus)
                let phase = clip.phase == "awaitingResume" && mark.kind != "hold" ? "following" : clip.phase
                return FieldCheckpoint(annotatedAtMs: mark.referenceMs, checkedAtMs: cutoff, expected: expected,
                                       actual: observed?.position, expectedPhase: phase, actualPhase: observed?.phase,
                                       passed: observed?.position == expected && observed?.phase == phase)
            }
            if isQuestion {
                let finalPhrase = scene.expectedPhraseEndMs ?? Int.max
                let first = scene.submissions.first
                scene.passed = scene.checkpoints.allSatisfy(\.passed) && scene.submissions.count == 1
                    && scene.positions.allSatisfy { $0.position == start }
                    && first?.position == start && (first?.timeMs ?? -1) >= finalPhrase
                    && first?.lastSpeechAtMs != nil && first?.containsFirstPhrase == true && first?.containsLastWords == true
                    && first?.unrecognizedEnglishTerms.isEmpty == true
                if !scene.passed { scene.error = "A question timing, lock, phrase, or English terminology check failed." }
            } else {
                scene.passed = scene.checkpoints.allSatisfy(\.passed) && followsPlannedOrder(scene.positions, checks: scene.checkpoints)
                if !scene.passed { scene.error = "The physical speech and alignment missed a checkpoint or entered an unplanned position." }
            }
        } catch {
            scene.error = error.localizedDescription
        }
        scene.localSpeechError = tracker.speechError
        scene.finishedAt = Date()
        return scene
    }

    private static func checkRecorder(_ clip: FieldCorpus.Clip, corpus: FieldCorpus) throws -> Int {
        var scene = FieldScene(id: clip.id, wavSHA256: clip.audioSha256, expectedPhraseEndMs: nil)
        scene.englishFollowTrace = FieldRecognitionTrace(script: corpus.pages.flatMap { $0 })
        let receive: (CompanionSpeechEvent, Int?) -> Void = { event, atMs in scene.observe(event, atMs: atMs) }
        receive(.started, nil)
        for (index, mark) in clip.events.enumerated() {
            let text = mark.transcript ?? corpus.pages[mark.expected[0]][mark.expected[1]]
            receive(.transcript(text, isFinal: index == clip.events.count - 1), mark.referenceMs)
        }
        guard let updates = scene.englishFollowTrace?.updates, updates.count == clip.events.count,
              updates.allSatisfy({ $0.request == 1 }), updates.last?.isFinal == true else {
            throw FieldError("The field recorder did not retain the preparation callbacks.")
        }
        return updates.count
    }

    private static func offlineFallback(_ workspace: StudioWorkspace, check: () throws -> Void) async throws -> FieldFallback {
        try check()
        let tracker = workspace.tracking
        tracker.stopFollowing()
        workspace.questions.setDeck(nil)
        workspace.submitQuestion("What makes a good handover in general?", followUp: false)
        defer { workspace.questions.cancel(); tracker.cancelQuestion() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while workspace.questions.state == .answering && ContinuousClock.now < deadline {
            try check()
            try await Task.sleep(for: .milliseconds(25))
        }
        let answerError: String?
        if case .failed(let error) = workspace.questions.state { answerError = error.localizedDescription }
        else { answerError = nil }
        try check()
        let unavailableLocale = locallyUnavailableLocale()
        if let unavailableLocale { tracker.startQuestion(localeIdentifier: unavailableLocale) { _ in } }
        let unavailable = unavailableLocale == nil ? nil : tracker.speechError
        tracker.select(pageIndex: 7, sentenceIndex: 2)
        let actual = fieldPosition(workspace)
        let manualRecovery = actual == FieldLocation(page: 8, sentence: 3) && tracker.phase == .following
        let transport = try await disconnectedDeepSeek(check: check)
        try check()
        return FieldFallback(modelCondition: "Controlled local transport failure. No network request was issued.",
                             answerError: answerError,
                             externalTransportCondition: "Production DeepSeek client after the offline condition check, fixed general question, no presentation or stored key.",
                             externalTransportStatus: transport.status, externalHTTPStatus: transport.http,
                             unavailableLocale: unavailableLocale, unavailableLocaleError: unavailable,
                             manualPositionAfterFailure: actual,
                             passed: answerError == QAServiceError.transport.localizedDescription
                                && transport.status == "transportFailure"
                                && unavailableLocale.map { unavailable?.contains($0) == true } == true && manualRecovery)
    }

    private static func locallyUnavailableLocale() -> String? {
        func key(_ value: String) -> String { value.replacingOccurrences(of: "_", with: "-").lowercased() }
        let supported = Set(SFSpeechRecognizer.supportedLocales().map { key($0.identifier) })
        return ["en-GB", "en-AU", "fr-FR", "ja-JP", "de-DE"].first { id in
            supported.contains(key(id))
                && SFSpeechRecognizer(locale: Locale(identifier: id))?.supportsOnDeviceRecognition == false
        }
    }

    private static func disconnectedDeepSeek(check: () throws -> Void) async throws -> (status: String, http: Int?) {
        try check()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let model = DeepSeekQAModel(apiKeyProvider: { "field-test-placeholder" }, configuration: configuration)
        let session = CompanionQASession(service: CompanionQAService(model: model), timeout: .seconds(5))
        defer { session.cancel() }
        session.submit("In general, what makes a handover useful?")
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while session.state == .answering && ContinuousClock.now < deadline {
            try check()
            try await Task.sleep(for: .milliseconds(50))
        }
        try check()
        switch session.state {
        case .failed(.transport): return ("transportFailure", nil)
        case .failed(.httpStatus(let status)): return ("unexpectedHTTPResponse", status)
        case .failed(.timeout), .answering: return ("timeout", nil)
        case .completed: return ("unexpectedCompletedAnswer", nil)
        case .failed(let error): return ("otherError: \(error)", nil)
        case .idle: return ("didNotStart", nil)
        }
    }

    private static func followsPlannedOrder(_ movements: [FieldMovement], checks: [FieldCheckpoint]) -> Bool {
        var pending = checks[...]
        return movements.allSatisfy { movement in
            guard let index = pending.firstIndex(where: {
                $0.expected == movement.position && $0.expectedPhase == movement.phase
            }) else { return false }
            pending = pending.suffix(from: pending.index(after: index))
            return true
        }
    }

    private static func submission(_ text: String, locale: String, at epoch: ContinuousClock.Instant,
                                   speechEnd: ContinuousClock.Instant?, location: FieldLocation) -> FieldSubmission {
        let words = CompanionTrackingMatcher.words(in: text)
        let folded = words.joined()
        let firstFound: Bool
        let lastFound: Bool
        let terms: [String]
        let lastWords: String
        if locale == "zh" {
            firstFound = (folded.contains("为什么") || folded.contains("為什麼"))
                && (folded.contains("基础") || folded.contains("基礎"))
            lastFound = folded.hasSuffix("关系") || folded.hasSuffix("關係")
            let latin = text.lowercased().split(whereSeparator: { !$0.isASCII || !$0.isLetter }).map(String.init)
            let adjacent = zip(latin, latin.dropFirst()).map { $0 + " " + $1 }
            terms = ["China Hub", "AI", "teams"].filter { latin.contains($0.lowercased()) || adjacent.contains($0.lowercased()) }
            lastWords = String(folded.suffix(8))
        } else {
            firstFound = words.contains("documents")
            lastFound = words.suffix(2).elementsEqual(["mean", "here"])
            terms = []
            lastWords = words.suffix(4).joined(separator: " ")
        }
        return FieldSubmission(submittedAt: Date(), timeMs: elapsed(since: epoch),
                               lastSpeechAtMs: speechEnd.map { elapsed(since: epoch, until: $0) },
                               lastWords: lastWords, containsFirstPhrase: firstFound, containsLastWords: lastFound,
                               heardEnglishTerms: terms,
                               unrecognizedEnglishTerms: locale == "zh" ? ["China Hub", "AI", "teams"].filter { !terms.contains($0) } : [],
                               position: location)
    }

    private static func fieldPosition(_ workspace: StudioWorkspace) -> FieldLocation {
        FieldLocation(page: workspace.currentSlide?.pageNumber, sentence: workspace.tracking.position?.sentenceIndex.map { $0 + 1 })
    }

    private static func position(_ index: [Int], corpus: FieldCorpus) -> FieldLocation {
        FieldLocation(page: corpus.sourcePageNumbers[index[0]], sentence: index[1] + 1)
    }

    private static func valid(_ index: [Int], in corpus: FieldCorpus) -> Bool {
        index.count == 2 && corpus.pages.indices.contains(index[0]) && corpus.pages[index[0]].indices.contains(index[1])
    }

    private static func decodeWAV(_ clip: FieldCorpus.Clip, in directory: URL) throws -> FieldWAV {
        let url = directory.appendingPathComponent(clip.audioFile)
        let digest = try sha256(url)
        guard digest == clip.audioSha256.lowercased() else { throw FieldError("WAV checksum mismatch for \(clip.id).") }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
            throw FieldError("Invalid PCM format for \(clip.id).")
        }
        var frames: AVAudioFramePosition = 0
        while frames < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw FieldError("WAV was truncated for \(clip.id).") }
            frames += AVAudioFramePosition(buffer.frameLength)
        }
        guard Double(frames) / format.sampleRate * 1_000 >= Double(clip.events.last?.referenceMs ?? 0) else {
            throw FieldError("WAV does not cover the last checkpoint for \(clip.id).")
        }
        return FieldWAV(id: clip.id, sha256: digest, sampleRate: format.sampleRate, channels: format.channelCount, frames: frames)
    }

    private static func pixels(_ data: Data?, page: Int) throws -> [Int] {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FieldError("The imported image for page \(page) could not be decoded.")
        }
        return [image.width, image.height]
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    private static func elapsed(since start: ContinuousClock.Instant, until end: ContinuousClock.Instant = .now) -> Int {
        let interval = start.duration(to: end).components
        return Int(interval.seconds * 1_000 + interval.attoseconds / 1_000_000_000_000_000)
    }

    private static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func write(_ value: some Encodable, named name: String, in directory: URL) throws {
        try (encoded(value) + Data([10])).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
