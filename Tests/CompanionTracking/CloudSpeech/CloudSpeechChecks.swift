@preconcurrency import AVFoundation
import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ ok: Bool, _ message: String) throws {
    guard ok else { throw Failure(description: message) }
}

@MainActor
private func until(_ description: String, _ match: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !match() {
        try check(ContinuousClock.now < deadline, description)
        try await Task.sleep(for: .milliseconds(10))
    }
}

private final class WebSocket: CompanionSpeechSocket, @unchecked Sendable {
    typealias Message = URLSessionWebSocketTask.Message
    private let lock = NSLock()
    private var sent: [Message] = []
    private var replies: [Message] = []
    private var waiter: CheckedContinuation<Message, Error>?
    private var request: URLRequest?
    private var closed = false

    var frames: [Message] { lock.withLock { sent } }
    var urlRequest: URLRequest? { lock.withLock { request } }
    var isClosed: Bool { lock.withLock { closed } }

    func connect(_ request: URLRequest) -> any CompanionSpeechSocket {
        lock.withLock { self.request = request }
        return self
    }

    func send(_ message: Message) async throws {
        try lock.withLock {
            if closed { throw CancellationError() }
            sent.append(message)
        }
    }

    func receive() async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if closed { continuation.resume(throwing: CancellationError()) }
                else if !replies.isEmpty { continuation.resume(returning: replies.removeFirst()) }
                else {
                    precondition(waiter == nil)
                    waiter = continuation
                }
            }
        }
    }

    func close() {
        lock.withLock {
            closed = true
            waiter?.resume(throwing: CancellationError())
            waiter = nil
        }
    }

    func reply(_ event: String, id: String, sentence: [String: Any]? = nil) throws {
        var json: [String: Any] = ["header": ["event": event, "task_id": id]]
        if let sentence { json["payload"] = ["output": ["sentence": sentence]] }
        let encoded = try JSONSerialization.data(withJSONObject: json)
        let message = Message.string(String(decoding: encoded, as: UTF8.self))
        lock.withLock {
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: message)
            } else {
                replies.append(message)
            }
        }
    }
}

private final class BatchProtocol: URLProtocol, @unchecked Sendable {
    struct Call: Sendable {
        let url: URL?
        let method: String?
        let auth: String?
        let contentType: String?
        let body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [Call] = []

    static var calls: [Call] { lock.withLock { storage } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buffer.deallocate() }
            var result = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 1024)
                if count <= 0 { break }
                result.append(buffer, count: count)
            }
            body = result
        }
        Self.lock.withLock {
            Self.storage.append(Call(url: request.url, method: request.httpMethod,
                                     auth: request.value(forHTTPHeaderField: "Authorization"),
                                     contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body))
        }
        guard let client, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(#"{"request_id":"fixture","text":"The blue marker is here.","duration_ms":15}"#.utf8))
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private final class LocalCapture: CompanionQuestionPCMInput {
    var receive: (@MainActor (CompanionSpeechEvent) -> Void)?
    var pcm: (@Sendable (Data) -> Void)?
    var finishCount = 0
    var nativeAvailable = true

    func start(localeIdentifier: String, reportLevel: Bool,
               onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void) {
        start(localeIdentifier: localeIdentifier, reportLevel: reportLevel, onPCM: nil,
              onLocalAvailability: { _ in }, onEvent: onEvent)
    }

    func start(localeIdentifier: String, reportLevel: Bool, onPCM: (@Sendable (Data) -> Void)?,
               onLocalAvailability: @escaping @MainActor (Bool) -> Void,
               onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void) {
        pcm = onPCM
        receive = onEvent
        onLocalAvailability(nativeAvailable)
        onEvent(.started)
    }

    func finish() {
        finishCount += 1
        if nativeAvailable { receive?(.transcript("", isFinal: true)) }
    }

    func cancel() {
        pcm = nil
        receive = nil
    }
}

private final class OnlineFixture: CompanionCloudSpeech, @unchecked Sendable {
    let name = "云端夹具"
    let sendsWhileListening: Bool
    private let lock = NSLock()
    private var output: AsyncThrowingStream<CompanionCloudSpeechEvent, Error>.Continuation?
    private var received: [Data] = []
    private var finishes = 0

    var packets: [Data] { lock.withLock { received } }
    var committed: Int { lock.withLock { finishes } }
    var connected: Bool { lock.withLock { output != nil } }
    init(streaming: Bool = true) { sendsWhileListening = streaming }

    func recognize(_ audio: AsyncStream<CompanionCloudAudio>) -> AsyncThrowingStream<CompanionCloudSpeechEvent, Error> {
        AsyncThrowingStream { stream in
            lock.withLock { output = stream }
            stream.yield(.ready)
            let reader = Task {
                for await item in audio {
                    lock.withLock {
                        switch item {
                        case .packet(let bytes): received.append(bytes)
                        case .finish: finishes += 1
                        }
                    }
                }
            }
            stream.onTermination = { _ in reader.cancel() }
        }
    }

    func send(_ event: CompanionCloudSpeechEvent) { _ = lock.withLock { output?.yield(event) } }
    func fail(_ error: CompanionCloudSpeechError) { lock.withLock { output?.finish(throwing: error) } }
}

@main @MainActor
private enum CloudSpeechChecks {
    static func main() async throws {
        try validatePCM()
        try await verifyParaformer()
        try await verifyDeepSeek()
        try await verifyController()
        print("PASS cloud speech protocol, question isolation, cancellation, fallback and speech endpoint checks")
    }

    private static func readCommand(_ frame: WebSocket.Message) throws -> [String: Any] {
        guard case .string(let string) = frame,
              let object = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
        else { throw Failure(description: "Expected a JSON WebSocket command") }
        return object
    }

    static func verifyParaformer() async throws {
        let socket = WebSocket()
        let provider = ParaformerCloudSpeech(workspaceID: "ws-test-beijing", localeIdentifier: "zh-CN",
                                             vocabularyID: "fixture-vocab", credential: { "fixture-key" }, connect: socket.connect)
        let audio = AsyncStream<CompanionCloudAudio>.makeStream()
        let result = Task {
            var events: [CompanionCloudSpeechEvent] = []
            for try await event in provider.recognize(audio.stream) { events.append(event) }
            return events
        }
        let frame = Data(repeating: 2, count: 3_200)
        audio.continuation.yield(.packet(Data(frame.prefix(1_600))))
        audio.continuation.yield(.packet(Data(frame.suffix(1_600))))
        try await until("no handshake") { socket.frames.count == 1 }
        let start = try readCommand(socket.frames[0])
        let header = start["header"] as? [String: String]
        guard let id = header?["task_id"],
              let payload = start["payload"] as? [String: Any],
              let params = payload["parameters"] as? [String: Any] else { throw Failure(description: "Missing Paraformer envelope") }
        try check(socket.urlRequest?.url?.absoluteString == "wss://ws-test-beijing.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"
                  && socket.urlRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key",
                  "WebSocket used wrong host or auth")
        try check(header?["action"] == "run-task" && payload["model"] as? String == "paraformer-realtime-v2"
                  && params["format"] as? String == "pcm" && params["sample_rate"] as? Int == 16_000
                  && params["language_hints"] as? [String] == ["zh", "en"] && params["vocabulary_id"] as? String == "fixture-vocab"
                  && params["semantic_punctuation_enabled"] as? Bool == false && params["max_sentence_silence"] as? Int == 1_300,
                  "Paraformer model or audio config changed")
        try socket.reply("task-started", id: "stale-task")
        try await Task.sleep(for: .milliseconds(35))
        try check(socket.frames.count == 1, "Audio left before confirmed task-started")
        try socket.reply("task-started", id: id)
        try await until("audio did not reach socket") { socket.frames.count == 2 }
        if case .data(let bytes) = socket.frames[1] { try check(bytes == frame, "PCM packet aggregation changed the input") }
        else { throw Failure(description: "Expected binary data") }
        try socket.reply("result-generated", id: id, sentence: ["text": "用 Central", "begin_time": 10, "sentence_end": false])
        try socket.reply("result-generated", id: id, sentence: ["text": "用 Central Park。", "begin_time": 10, "end_time": 1500, "sentence_end": true])
        try socket.reply("result-generated", id: id, sentence: ["text": "重复旧句", "begin_time": 10, "end_time": 1500, "sentence_end": true])
        try socket.reply("result-generated", id: id, sentence: ["text": "另一题", "begin_time": 2000, "sentence_end": false, "heartbeat": true])
        try socket.reply("result-generated", id: "stale-task", sentence: ["text": "不应出现", "begin_time": 2000, "sentence_end": false])
        try socket.reply("result-generated", id: id, sentence: ["text": "怎么走", "begin_time": 2100, "sentence_end": false])
        audio.continuation.yield(.finish)
        audio.continuation.finish()
        try await until("explicit finish was not sent") { socket.frames.count == 3 }
        let command = try readCommand(socket.frames[2])
        try check((command["header"] as? [String: String])?["action"] == "finish-task", "Wrong finalization command")
        try socket.reply("result-generated", id: id, sentence: ["text": "怎么走？", "begin_time": 2100, "end_time": 3500, "sentence_end": true])
        try socket.reply("task-finished", id: id)
        let events = try await result.value
        try check(events == [
            .ready, .preview("用 Central", atSentenceBoundary: false), .preview("用 Central Park。", atSentenceBoundary: true),
            .preview("用 Central Park。 怎么走", atSentenceBoundary: false),
            .preview("用 Central Park。 怎么走？", atSentenceBoundary: true), .complete("用 Central Park。 怎么走？"),
        ] && socket.isClosed, "Paraformer lost a sentence, retained stale text, or did not close")
        try check(ParaformerCloudSpeech.endpoint(workspaceID: "ws-a.example.com") == nil, "Workspace could redirect a credential")
        let semanticSocket = WebSocket()
        let semantic = ParaformerCloudSpeech(workspaceID: "ws-test-beijing", localeIdentifier: "en-US", vocabularyID: nil,
                                             segmentation: .semantic, credential: { "fixture-key" }, connect: semanticSocket.connect)
        let silent = AsyncStream<CompanionCloudAudio>.makeStream()
        let semanticTask = Task {
            for try await _ in semantic.recognize(silent.stream) {}
        }
        try await until("no semantic handshake") { semanticSocket.frames.count == 1 }
        let semanticStart = try readCommand(semanticSocket.frames[0])
        let semanticParams = (semanticStart["payload"] as? [String: Any])?["parameters"] as? [String: Any]
        try check(semanticParams?["semantic_punctuation_enabled"] as? Bool == true
                  && semanticParams?["max_sentence_silence"] == nil && semanticParams?["language_hints"] as? [String] == ["en", "zh"],
                  "Semantic mode enabled VAD or lost the language hints")
        semanticTask.cancel()
        _ = await semanticTask.result
        try await until("cancel did not close WebSocket") { semanticSocket.isClosed }
        try check(semanticSocket.frames.count == 1, "Cancel sent an extra command")
        print("PASS Paraformer Beijing header, readiness gate, 100ms PCM, mixed hints, keyterms, both segmentation modes, final and cancel")
    }

    static func verifyDeepSeek() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BatchProtocol.self]
        let provider = DeepSeekCloudSpeech(credential: { "fixture-key" }, configuration: config)
        let cancel = AsyncStream<CompanionCloudAudio>.makeStream()
        let noUpload = Task {
            do {
                for try await _ in provider.recognize(cancel.stream) {}
                return false
            } catch { return true }
        }
        cancel.continuation.yield(.packet(Data([1, 2])))
        cancel.continuation.finish()
        let cancelled = await noUpload.value
        try check(cancelled && BatchProtocol.calls.isEmpty, "Cancel uploaded a batch WAV without finishing")
        let audio = AsyncStream<CompanionCloudAudio>.makeStream()
        let result = Task {
            var events: [CompanionCloudSpeechEvent] = []
            for try await event in provider.recognize(audio.stream) { events.append(event) }
            return events
        }
        let pcm = Data([1, 2, 3, 4])
        audio.continuation.yield(.packet(pcm))
        try await Task.sleep(for: .milliseconds(40))
        try check(BatchProtocol.calls.isEmpty, "DeepSeek received audio before commit")
        audio.continuation.yield(.finish)
        audio.continuation.finish()
        let events = try await result.value
        try check(events == [.ready, .complete("The blue marker is here.")], "Wrong batch final")
        let call = BatchProtocol.calls.first
        let wav = try CompanionQuestionPCM.wav(pcm)
        try check(BatchProtocol.calls.count == 1 && call?.url == DeepSeekCloudSpeech.endpoint && call?.method == "POST"
                  && call?.auth == "Bearer fixture-key" && call?.contentType?.hasPrefix("multipart/form-data; boundary=") == true
                  && call?.body?.range(of: Data("name=\"file\"".utf8)) != nil && call?.body?.range(of: wav) != nil,
                  "DeepSeek did not send one authenticated multipart WAV")
        try check(wav.prefix(4) == Data("RIFF".utf8) && wav.count == 48 && wav.suffix(4) == pcm,
                  "WAV wrapper changed the audio payload")
        print("PASS DeepSeek protected POST, WAV multipart only on explicit finish, no upload on cancel")
    }

    static func validatePCM() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        input.frameLength = 4_800
        let channel = input.floatChannelData!
        for index in 0..<4_800 {
            let value = Float(sin(Double(index) * 0.12) * 0.2)
            channel[0][index] = value
            channel[1][index] = value
        }
        guard let converter = CompanionPCMResampler(input: format), let converted = converter.convert(input) else {
            throw Failure(description: "48 kHz stereo could not convert to 16 kHz PCM")
        }
        let steady = converter.convert(input) ?? Data()
        let tail = converter.finish() ?? Data()
        let sampleBytes = converted.count + steady.count + tail.count
        try check((6_350...6_450).contains(sampleBytes) && sampleBytes.isMultiple(of: 2)
                  && converted.contains(where: { $0 != 0 }),
                  "Converted buffers lost the resampler tail (\(converted.count), \(steady.count), \(tail.count) bytes)")
        print("PASS stereo hardware resamples to 16 kHz signed mono")
    }

    @MainActor
    static func verifyController() async throws {
        let local = LocalCapture()
        var elapsed: TimeInterval = 100
        let tracker = CompanionTrackingController(speech: local, now: { elapsed })
        tracker.configure(pages: [CompanionTrackingPage(sentences: ["This is the reading anchor."])])
        tracker.startFollowing()
        let anchor = tracker.position
        var submitted: [String] = []
        tracker.startQuestion { submitted.append($0) }
        try check(local.pcm == nil && tracker.questionSpeechStatus == .local, "Default question started a cloud PCM tap")
        tracker.cancelQuestion()
        try check(local.pcm == nil && submitted.isEmpty, "Cancel submitted the default question")

        elapsed = 200
        let online = OnlineFixture()
        tracker.startQuestion(initialText: "请问", onlineSpeech: online) { submitted.append($0) }
        try await until("cloud fixture did not connect") { online.connected && tracker.questionSpeechStatus == .streaming(online.name) }
        try check(tracker.questionTranscript == "请问", "Local seed vanished")
        local.pcm?(Data([0, 1]))
        local.receive?(.transcript("请问，怎么用 Central", isFinal: false))
        online.send(.preview("怎么用 Central Park，或者", atSentenceBoundary: true))
        try await until("missing online preview") { tracker.questionTranscript.contains("或者") }
        elapsed = 203.35
        tracker.checkQuestionSilence()
        try check(!tracker.isQuestionEnding && online.committed == 0, "Open conjunction was cut at an ordinary long pause")
        local.receive?(.transcript("请问，怎么去 Central Park", isFinal: false))
        online.send(.preview("怎么去 Central Park？", atSentenceBoundary: true))
        try await until("final phrase not visible") { tracker.questionTranscript.hasSuffix("Park？") }
        elapsed += 2.38
        tracker.checkQuestionSilence()
        try await until("complete question did not finish promptly") { online.committed == 1 && tracker.isQuestionEnding }
        online.send(.complete("怎么去 Central Park？"))
        try await until("complete question not submitted") { submitted.count == 1 }
        online.send(.complete("迟到的文字"))
        try check(submitted == ["请问 怎么去 Central Park？"] && online.packets == [Data([0, 1])]
                  && tracker.position == anchor && tracker.phase == .awaitingResume,
                  "Online question duplicated, lost local seed or offset the reading anchor")
        try check(local.pcm == nil, "Following received question audio sink after submission")

        let failure = OnlineFixture(streaming: false)
        tracker.startQuestion(onlineSpeech: failure) { submitted.append($0) }
        try await until("fallback fixture did not start") { failure.connected }
        local.receive?(.transcript("How do I resume here?", isFinal: false))
        failure.fail(.credential)
        try await until("did not return to the local source") {
            if case .fallback = tracker.questionSpeechStatus { return true }
            return false
        }
        try check(tracker.questionTranscript == "How do I resume here?", "Fallback lost the local question")
        tracker.submitQuestion()
        try check(submitted == ["请问 怎么去 Central Park？", "How do I resume here?"], "Fallback did not submit once")

        let networkLoss = OnlineFixture()
        tracker.startQuestion(onlineSpeech: networkLoss) { submitted.append($0) }
        try await until("transport fixture did not start") { networkLoss.connected }
        local.receive?(.transcript("What did the guide say?", isFinal: false))
        networkLoss.send(.preview("Unreliable online partial", atSentenceBoundary: false))
        try await until("transport preview not presented") { tracker.questionTranscript == "Unreliable online partial" }
        networkLoss.fail(.transport)
        try await until("did not fall back after connection loss") { tracker.questionTranscript == "What did the guide say?" }
        tracker.cancelQuestion()
        try check(submitted.count == 2 && networkLoss.committed == 0 && tracker.position == anchor,
                  "Cancel sent a request or lost the anchor")

        local.nativeAvailable = false
        elapsed = 310
        let onlineOnly = OnlineFixture(streaming: false)
        tracker.startQuestion(onlineSpeech: onlineOnly) { submitted.append($0) }
        try await until("PCM-only mode did not start") { onlineOnly.connected && tracker.isListening }
        try check(!tracker.canFinishQuestion && tracker.questionTranscript.isEmpty, "Quiet PCM-only capture looked complete")
        local.pcm?(Data([0, 2]))
        local.receive?(.level(0.4, at: elapsed))
        try check(tracker.canFinishQuestion && tracker.questionTranscript.isEmpty, "PCM-only speech could not be submitted")
        elapsed += 2.8
        tracker.checkQuestionSilence()
        try await until("PCM-only question did not end on silence") { onlineOnly.committed == 1 }
        onlineOnly.send(.complete("The clip transcribed with no local recognizer."))
        try await until("PCM-only cloud final did not submit") { submitted.count == 3 }
        try check(submitted.last == "The clip transcribed with no local recognizer.", "PCM-only final lost its content")
        let unavailable = OnlineFixture()
        tracker.startQuestion(onlineSpeech: unavailable) { submitted.append($0) }
        try await until("PCM-only negative fixture did not start") { unavailable.connected }
        unavailable.fail(.transport)
        try await until("double failure did not leave the typing fallback") { tracker.phase == .awaitingResume }
        try check(tracker.speechError?.contains("输入") == true && submitted.count == 3,
                  "Double failure sent an empty question or lacked typing feedback")
        local.nativeAvailable = true
        elapsed = 410
        tracker.startQuestion(preferFastEnding: true) { submitted.append($0) }
        local.receive?(.transcript("What was the Orchid coverage", isFinal: false))
        elapsed += 1.25
        tracker.checkQuestionSilence()
        try check(submitted.last == "What was the Orchid coverage" && submitted.count == 4,
                  "Complete short question did not use fast ending")
        elapsed = 500
        tracker.startQuestion(preferFastEnding: true) { submitted.append($0) }
        local.receive?(.transcript("What was the Orchid coverage, and", isFinal: false))
        elapsed += 3.35
        tracker.checkQuestionSilence()
        try check(!tracker.isQuestionEnding && submitted.count == 4,
                  "Fast mode truncated a paused question that ended in a conjunction")
        local.receive?(.transcript("What was the Orchid coverage, and how was it measured?", isFinal: false))
        elapsed += 1.25
        tracker.checkQuestionSilence()
        try check(submitted.last == "What was the Orchid coverage, and how was it measured?" && submitted.count == 5,
                  "Fast mode did not retain the second phrase")
        print("PASS complete sentence endpoint, long incomplete pause, initial text, stale final, per-question capture, cancel and fallback")
    }
}
