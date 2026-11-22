import Foundation

private actor LocalQATransportLog {
    struct Entry: Encodable, Sendable {
        let purpose: String
        let firstTextMs: Double?
        let durationMs: Double
        let response: String
        let finishReason: String?
        let error: String?
    }

    private(set) var entries: [Entry] = []

    func append(_ entry: Entry) { entries.append(entry) }
}

private struct LoopbackQAModel: QAModel {
    let endpoint: URL
    let modelID: String
    let log: LocalQATransportLog
    let session: URLSession

    init(port: UInt16, modelID: String, log: LocalQATransportLog) {
        self.endpoint = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        self.modelID = modelID
        self.log = log
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let transfer = Task {
                let start = ContinuousClock.now
                var first: Double?
                var text = ""
                var finishReason: String?
                var failure: (any Error)?
                do {
                    let (bytes, response) = try await session.bytes(for: makeRequest(request))
                    guard let response = response as? HTTPURLResponse else { throw QAServiceError.transport }
                    guard (200..<300).contains(response.statusCode) else {
                        throw QAServiceError.httpStatus(response.statusCode)
                    }
                    guard response.mimeType?.lowercased() == "text/event-stream" else {
                        throw QAServiceError.invalidResponse
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        let frame = try JSONDecoder().decode(Frame.self, from: Data(payload.utf8))
                        guard let choice = frame.choices?.first else { continue }
                        if let reason = choice.finish_reason { finishReason = reason }
                        guard let chunk = choice.delta?.content, !chunk.isEmpty else { continue }
                        if first == nil { first = Self.milliseconds(since: start) }
                        text += chunk
                        guard text.utf8.count < 64_000 else { throw QAServiceError.invalidResponse }
                        continuation.yield(chunk)
                    }
                    guard !text.isEmpty else { throw QAServiceError.invalidResponse }
                } catch let error as URLError where error.code == .timedOut {
                    failure = QAServiceError.timeout
                } catch {
                    failure = error
                }
                await log.append(.init(
                    purpose: String(describing: request.purpose), firstTextMs: first, durationMs: Self.milliseconds(since: start),
                    response: text, finishReason: finishReason, error: failure?.localizedDescription
                ))
                continuation.finish(throwing: failure)
            }
            continuation.onTermination = { @Sendable _ in transfer.cancel() }
        }
    }

    private func makeRequest(_ request: QAModelRequest) throws -> URLRequest {
        guard request.image == nil else { throw QAServiceError.rejectedConnection }
        var wire = URLRequest(url: endpoint)
        wire.httpMethod = "POST"
        wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
        wire.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        wire.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "messages": [
                ["role": "system", "content": request.instructions],
                ["role": "user", "content": request.input]
            ],
            "stream": true,
            "max_tokens": request.maxOutputTokens,
            "temperature": 0.2,
            "chat_template_kwargs": ["enable_thinking": false]
        ])
        return wire
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }

    private struct Frame: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta?
            let finish_reason: String?
        }
        let choices: [Choice]?
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

@main
struct LocalQATrial {
    @MainActor
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard (3...4).contains(arguments.count), let port = UInt16(arguments[0]), port > 0,
              let repeats = (arguments.count == 4 ? Int(arguments[3]) : 2), (1...5).contains(repeats)
        else {
            FileHandle.standardError.write(Data("Usage: run.sh <loopback-port> <model-id> <output-directory> [repeats]\n".utf8))
            exit(2)
        }
        let modelID = arguments[1]
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let log = LocalQATransportLog()
        try await CompanionQATests.liveTrial(
            output: output, modelID: modelID, repetitions: repeats,
            reportName: "omlx-live-trial.json", includeCharts: false
        ) {
            LoopbackQAModel(port: port, modelID: modelID, log: log)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let entries = await log.entries
        try encoder.encode(entries).write(to: output.appendingPathComponent("omlx-transport.json"), options: .atomic)
    }
}
