import Foundation

protocol CompanionSpeechSocket: Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close()
}

private struct FoundationSpeechSocket: CompanionSpeechSocket {
    let session: URLSession
    let socket: URLSessionWebSocketTask

    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 8
        session = URLSession(configuration: configuration, delegate: QuestionSpeechNoRedirect(), delegateQueue: nil)
        socket = session.webSocketTask(with: request)
        socket.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await socket.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await socket.receive() }
    func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

enum ParaformerSegmentation: String, Sendable, CaseIterable, Identifiable {
    case pause, semantic

    var id: String { rawValue }
    var label: String { self == .semantic ? "语义断句" : "按停顿断句" }
}

struct ParaformerCloudSpeech: CompanionCloudSpeech {
    let name = "阿里云实时语音"
    let sendsWhileListening = true

    let workspaceID: String
    let localeIdentifier: String
    let vocabularyID: String?
    var segmentation: ParaformerSegmentation = .pause
    var credential: @Sendable () async throws -> String
    var connect: @Sendable (URLRequest) -> any CompanionSpeechSocket = { FoundationSpeechSocket(request: $0) }

    static func endpoint(workspaceID: String) -> URL? {
        guard workspaceID.wholeMatch(of: #/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?/#) != nil else { return nil }
        return URL(string: "wss://\(workspaceID).cn-beijing.maas.aliyuncs.com/api-ws/v1/inference")
    }

    func preauthorizedForSample() async throws -> any CompanionCloudSpeech {
        guard Self.endpoint(workspaceID: workspaceID) != nil else { throw CompanionCloudSpeechError.configuration }
        let key: String
        do { key = try await credential() } catch { throw CompanionCloudSpeechError.credential }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CompanionCloudSpeechError.credential }
        var copy = self
        copy.credential = { key }
        return copy
    }

    func recognize(_ audio: AsyncStream<CompanionCloudAudio>) -> AsyncThrowingStream<CompanionCloudSpeechEvent, Error> {
        AsyncThrowingStream { output in
            let task = Task {
                do {
                    guard let url = Self.endpoint(workspaceID: workspaceID) else { throw CompanionCloudSpeechError.configuration }
                    let key: String
                    do { key = try await credential() } catch { throw CompanionCloudSpeechError.credential }
                    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CompanionCloudSpeechError.credential }
                    try Task.checkCancellation()
                    var request = URLRequest(url: url)
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    let socket = connect(request)
                    try await withTaskCancellationHandler {
                        defer { socket.close() }
                        try await run(socket, audio: audio, output: output)
                    } onCancel: {
                        socket.close()
                    }
                    output.finish()
                } catch {
                    output.finish(throwing: (error as? CompanionCloudSpeechError) ?? .transport)
                }
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ socket: any CompanionSpeechSocket, audio: AsyncStream<CompanionCloudAudio>,
        output: AsyncThrowingStream<CompanionCloudSpeechEvent, Error>.Continuation
    ) async throws {
        let id = UUID().uuidString
        var parameters: [String: Any] = [
            "format": "pcm", "sample_rate": CompanionQuestionPCM.sampleRate,
            "language_hints": localeIdentifier.hasPrefix("en") ? ["en", "zh"] : ["zh", "en"],
            "semantic_punctuation_enabled": segmentation == .semantic,
        ]
        if segmentation == .pause { parameters["max_sentence_silence"] = 1_300 }
        if let vocabularyID, !vocabularyID.isEmpty { parameters["vocabulary_id"] = vocabularyID }
        try await socket.send(try command(action: "run-task", id: id, payload: [
            "task_group": "audio", "task": "asr", "function": "recognition", "model": "paraformer-realtime-v2",
            "parameters": parameters, "input": [String: String](),
        ]))
        while true {
            let event = try await read(socket)
            guard event.header.taskID == id else { continue }
            if event.header.event == "task-failed" { throw CompanionCloudSpeechError.rejected }
            if event.header.event == "task-started" { break }
        }
        output.yield(.ready)

        // The sender may finish first. Keep receiving until the service confirms the task ended.
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    var bytes = 0
                    var pending = Data()
                    let frameSize = CompanionQuestionPCM.bytesPerSecond / 10
                    for await item in audio {
                        try Task.checkCancellation()
                        switch item {
                        case .finish:
                            if !pending.isEmpty { try await socket.send(.data(pending)) }
                            try await socket.send(try command(action: "finish-task", id: id, payload: ["input": [String: String]()]))
                            return false
                        case .packet(let packet):
                            guard packet.count <= CompanionQuestionPCM.maximumBytes - bytes else { throw CompanionCloudSpeechError.tooLong }
                            bytes += packet.count
                            pending.append(packet)
                            while pending.count >= frameSize {
                                try await socket.send(.data(Data(pending.prefix(frameSize))))
                                pending.removeFirst(frameSize)
                            }
                        }
                    }
                    throw CancellationError()
                } catch {
                    socket.close()
                    throw error
                }
            }
            group.addTask {
                var transcript = Transcript()
                do {
                    while !Task.isCancelled {
                        let event = try await read(socket)
                        guard event.header.taskID == id else { continue }
                        switch event.header.event {
                        case "result-generated":
                            if let sentence = event.payload?.output?.sentence, let update = transcript.accept(sentence) {
                                output.yield(update)
                            }
                        case "task-finished":
                            let final = transcript.committed
                            guard !final.isEmpty else { throw CompanionCloudSpeechError.noSpeech }
                            output.yield(.complete(final))
                            return true
                        case "task-failed": throw CompanionCloudSpeechError.rejected
                        default: continue
                        }
                    }
                    throw CancellationError()
                } catch {
                    socket.close()
                    throw error
                }
            }
            defer { group.cancelAll() }
            while let receiverFinished = try await group.next() {
                if receiverFinished {
                    socket.close()
                    return
                }
            }
        }
    }

    private func command(action: String, id: String, payload: [String: Any]) throws -> URLSessionWebSocketTask.Message {
        let data = try JSONSerialization.data(withJSONObject: [
            "header": ["action": action, "task_id": id, "streaming": "duplex"],
            "payload": payload,
        ])
        return .string(String(decoding: data, as: UTF8.self))
    }

    private func read(_ socket: any CompanionSpeechSocket) async throws -> Reply {
        let message = try await socket.receive()
        try Task.checkCancellation()
        guard case .string(let string) = message, string.utf8.count <= 128_000,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(string.utf8))
        else { throw CompanionCloudSpeechError.invalidResponse }
        return reply
    }

    private struct Reply: Decodable {
        struct Header: Decodable {
            let event: String
            let taskID: String

            enum CodingKeys: String, CodingKey { case event; case taskID = "task_id" }
        }

        struct Payload: Decodable {
            struct Output: Decodable { let sentence: Sentence? }
            let output: Output?
        }

        let header: Header
        let payload: Payload?
    }

    private struct Sentence: Decodable {
        let text: String?
        let beginTime: Int?
        let endTime: Int?
        let sentenceEnd: Bool?
        let heartbeat: Bool?

        enum CodingKeys: String, CodingKey {
            case text, heartbeat
            case beginTime = "begin_time"
            case endTime = "end_time"
            case sentenceEnd = "sentence_end"
        }
    }

    private struct Transcript {
        private var confirmed: [(start: Int, end: Int, text: String)] = []
        private var latest: (start: Int, text: String)?
        var committed: String { confirmed.map(\.text).joined(separator: " ") }

        mutating func accept(_ sentence: Sentence) -> CompanionCloudSpeechEvent? {
            guard sentence.heartbeat != true, let begin = sentence.beginTime, begin >= 0,
                  let text = sentence.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            guard (confirmed.last?.end ?? 0) <= begin, !confirmed.contains(where: { $0.start == begin }) else { return nil }
            if sentence.sentenceEnd == true {
                guard let end = sentence.endTime, end >= begin else { return nil }
                confirmed.append((begin, end, text))
                if latest.map({ $0.start < end || $0.start == begin }) == true { latest = nil }
            } else {
                guard latest.map({ $0.start <= begin }) ?? true else { return nil }
                latest = (begin, text)
            }
            let completePreview = [committed, latest?.text ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            return .preview(completePreview, atSentenceBoundary: sentence.sentenceEnd == true && latest == nil)
        }
    }
}
