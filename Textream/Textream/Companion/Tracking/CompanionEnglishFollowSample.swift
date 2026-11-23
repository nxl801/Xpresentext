@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import Speech

/// Compares the production matcher on four fixed, public test phrases. Audio
/// can only be loaded from the packaged fixtures whose entire files match.
enum CompanionEnglishFollowSample {
    private static let fixtureDigest = "d5bf3be4b57ed2784f966f9be35762536720565041b29a91015d7ef2618f0ef4"
    private static let approved: [String: (title: String, digest: String)] = [
        "strong-paraphrase": ("强改述", "b666d9fee7ccbff712c375c944aee931df80c40b7323c6566e55c5887537a5ac"),
        "negation": ("否定", "1bc74ed8a8cd2fbb6aaa6bad040c552177a9e4b14d99a5d1896ca1f5ec2bbaab"),
        "hypothetical": ("假设", "3768ee351d12bc01336a753a5268906750dfc90575ebcc788330542450ac8add"),
        "quoted-in-answer": ("口答引用", "93ca8075b55fffc56514ed7ab292619867f6bf04d00a83b2817f1df68587a8b9"),
    ]

    private struct Fixture: Decodable {
        struct Line: Decodable { let id: String; let text: String }
        struct Example: Decodable { let id: String; let state: String; let expected: String }
        let script: [Line]
        let prepared: [Line]
        let cases: [Example]
    }

    struct Clip: Sendable {
        let id: String
        let title: String
        let expected: Int?
        let awaitingResume: Bool
        let page: CompanionTrackingPage
        let url: URL
        let pcm: Data

        var durationMs: Int { pcm.count * 1_000 / CompanionQuestionPCM.bytesPerSecond }
    }

    struct Result: Sendable {
        let decisions: [Int]
        let passed: Bool
        let firstCorrectAtMs: Int?
        let wholeRecordingResponseMs: Int?
        let transcript: String
        let error: String?

        static func unavailable(_ message: String) -> Self {
            Self(decisions: [], passed: false, firstCorrectAtMs: nil, wholeRecordingResponseMs: nil,
                 transcript: "", error: message)
        }
    }

    struct Scorer {
        private var matcher: CompanionTrackingMatcher
        private var awaitingResume: Bool
        private let expected: Int?
        private var decisions: [Int] = []
        private var firstCorrectAtMs: Int?
        private var transcript = ""

        init(_ clip: Clip) {
            matcher = CompanionTrackingMatcher(pages: [clip.page])
            awaitingResume = clip.awaitingResume
            expected = clip.expected
        }

        mutating func observe(_ text: String, atMs: Int?) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            transcript = text
            let previous = matcher.position
            if matcher.process(text, awaitingResume: awaitingResume) { awaitingResume = false }
            guard let next = matcher.position, next != previous, let sentence = next.sentenceIndex else { return }
            decisions.append(sentence)
            if sentence == expected && firstCorrectAtMs == nil { firstCorrectAtMs = atMs }
        }

        func finish(responseMs: Int? = nil, error: String? = nil) -> Result {
            let problem = error ?? (transcript.isEmpty ? "样音未返回可读转写。" : nil)
            return Result(decisions: decisions, passed: problem == nil && decisions == (expected.map { [$0] } ?? []),
                          firstCorrectAtMs: firstCorrectAtMs, wholeRecordingResponseMs: responseMs,
                          transcript: transcript, error: problem)
        }
    }

    static func load(bundle: Bundle = .main) throws -> [Clip] {
        guard let resources = bundle.resourceURL else {
            throw CompanionCloudSpeechError.configuration
        }
        let directory = resources.appendingPathComponent("EnglishFollowSamples", isDirectory: true)
        let grouped = FileManager.default.fileExists(atPath: directory.appendingPathComponent("cases.json").path)
        return try load(directory: grouped ? directory : resources)
    }

    static func load(directory: URL) throws -> [Clip] {
        let bytes = try verified(directory.appendingPathComponent("cases.json"), digest: fixtureDigest)
        let fixture = try JSONDecoder().decode(Fixture.self, from: bytes)
        let names = fixture.script.map(\.id)
        let prepared = Dictionary(grouping: fixture.prepared, by: \.id)
        let alternatives = Dictionary(uniqueKeysWithValues: names.enumerated().compactMap { index, name in
            prepared[name].map { (index, $0.map(\.text)) }
        })
        let page = CompanionTrackingPage(sentences: fixture.script.map(\.text), sentenceAlternatives: alternatives)
        return try fixture.cases.map { example in
            guard let entry = approved[example.id] else { throw CompanionCloudSpeechError.configuration }
            let url = directory.appendingPathComponent(example.id + ".wav")
            let wav = try verified(url, digest: entry.digest)
            let pcm = Data(wav.dropFirst(44))
            guard try CompanionQuestionPCM.wav(pcm) == wav else { throw CompanionCloudSpeechError.invalidResponse }
            return Clip(id: example.id, title: entry.title, expected: names.firstIndex(of: example.expected),
                        awaitingResume: example.state == "awaitingResume", page: page, url: url, pcm: pcm)
        }
    }

    private static func verified(_ url: URL, digest: String) throws -> Data {
        let data = try Data(contentsOf: url)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
            throw CompanionCloudSpeechError.invalidResponse
        }
        return data
    }

    @MainActor
    static func local(_ clip: Clip) async -> Result {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else {
            return .unavailable("本机英语识别授权或离线资源不可用。")
        }
        return await bounded {
            guard let file = try? AVAudioFile(forReading: clip.url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600) else {
                return .unavailable("无法读取内置样音。")
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            let events = AsyncThrowingStream<(String, Bool, ContinuousClock.Instant), Error>.makeStream()
            let origin = ContinuousClock.now
            let recognition = recognizer.recognitionTask(with: request) { @Sendable result, error in
                if let result {
                    events.continuation.yield((result.bestTranscription.formattedString, result.isFinal, .now))
                    if result.isFinal { events.continuation.finish(); return }
                }
                if error != nil { events.continuation.finish(throwing: CompanionCloudSpeechError.transport) }
            }
            let feeder = Task { @MainActor in
                do {
                    while file.framePosition < file.length {
                        try Task.checkCancellation()
                        try file.read(into: buffer)
                        guard buffer.frameLength > 0 else { throw CompanionCloudSpeechError.invalidResponse }
                        request.append(buffer)
                        try await ContinuousClock().sleep(until: origin.advanced(
                            by: .seconds(Double(file.framePosition) / file.processingFormat.sampleRate)
                        ), tolerance: .zero)
                    }
                    request.endAudio()
                } catch {
                    events.continuation.finish(throwing: error)
                }
            }
            defer {
                feeder.cancel()
                recognition.cancel()
                events.continuation.finish()
            }
            var score = Scorer(clip)
            do {
                for try await (text, final, time) in events.stream {
                    score.observe(text, atMs: milliseconds(origin.duration(to: time)))
                    if final {
                        return score.finish(error: file.framePosition == file.length ? nil : "本机识别在样音送完前结束。")
                    }
                }
                return score.finish(error: "本机未完成本段转写。")
            } catch {
                return score.finish(error: "本机样音识别未完成。")
            }
        }
    }

    @MainActor
    static func online(_ clip: Clip, provider: any CompanionCloudSpeech) async -> Result {
        await bounded {
            let audio = AsyncStream<CompanionCloudAudio>.makeStream(bufferingPolicy: .bufferingOldest(100))
            var origin: ContinuousClock.Instant?
            var submitted: ContinuousClock.Instant?
            var feeder: Task<Void, Never>?
            defer {
                feeder?.cancel()
                audio.continuation.finish()
            }
            let streaming = provider.sendsWhileListening
            var score = Scorer(clip)
            do {
                for try await event in provider.recognize(audio.stream) {
                    try Task.checkCancellation()
                    switch event {
                    case .ready:
                        guard origin == nil else { continue }
                        let start = ContinuousClock.now
                        origin = start
                        if streaming {
                            feeder = Task { @MainActor in
                                do {
                                    let packetSize = CompanionQuestionPCM.bytesPerSecond / 10
                                    for offset in stride(from: 0, to: clip.pcm.count, by: packetSize) {
                                        try Task.checkCancellation()
                                        let end = min(offset + packetSize, clip.pcm.count)
                                        audio.continuation.yield(.packet(Data(clip.pcm[offset..<end])))
                                        try await ContinuousClock().sleep(until: start.advanced(
                                            by: .seconds(Double(end) / Double(CompanionQuestionPCM.bytesPerSecond))
                                        ), tolerance: .zero)
                                    }
                                    submitted = .now
                                    audio.continuation.yield(.finish)
                                    audio.continuation.finish()
                                } catch { audio.continuation.finish() }
                            }
                        } else {
                            audio.continuation.yield(.packet(clip.pcm))
                            submitted = .now
                            audio.continuation.yield(.finish)
                            audio.continuation.finish()
                        }
                    case .preview(let text, _):
                        guard streaming, let origin else { continue }
                        score.observe(text, atMs: milliseconds(origin.duration(to: .now)))
                    case .complete(let text):
                        guard let origin, let submitted else { return score.finish(error: "服务提前结束，本段未送完。") }
                        score.observe(text, atMs: streaming ? milliseconds(origin.duration(to: .now)) : nil)
                        return score.finish(responseMs: streaming ? nil : milliseconds(submitted.duration(to: .now)))
                    }
                }
                return score.finish(error: "在线服务未完成本段转写。")
            } catch {
                return score.finish(error: (error as? CompanionCloudSpeechError)?.errorDescription ?? "该段在线测试失败。")
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    @MainActor
    private static func bounded(_ run: @escaping @MainActor () async -> Result) async -> Result {
        let worker = Task { @MainActor in await run() }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(18))
            if !Task.isCancelled { worker.cancel() }
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
