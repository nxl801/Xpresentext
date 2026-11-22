import Foundation

/// Online services have fixed endpoints. Local inference stays on loopback and never uses a cloud credential.
struct OpenAIChatQATransport: QAModel {
    enum Provider: Sendable, Equatable {
        case bigModel
        case zAI
        case deepSeek
        case loopback(port: UInt16, model: String)

        var baseURL: URL {
            switch self {
            case .loopback(let port, _): URL(string: "http://127.0.0.1:\(port)")!
            case .bigModel: URL(string: "https://open.bigmodel.cn")!
            case .zAI: URL(string: "https://api.z.ai")!
            case .deepSeek: URL(string: "https://api.deepseek.com")!
            }
        }

        var endpoint: URL {
            switch self {
            case .bigModel, .zAI: baseURL.appending(path: "api/paas/v4/chat/completions")
            case .loopback: baseURL.appending(path: "v1/chat/completions")
            case .deepSeek: baseURL.appending(path: "chat/completions")
            }
        }

        var model: String {
            if case .loopback(_, let id) = self { return id }
            return self == .deepSeek ? "deepseek-flash" : "glm-5.3-flash"
        }
        var thinking: String { self == .deepSeek ? "disabled" : "enabled" }
        var reasoningEffort: String? { self == .deepSeek ? nil : "low" }
        var imageDetail: String? { self == .deepSeek ? "high" : nil }

        var imageTypes: Set<String> {
            switch self {
            case .bigModel, .zAI: ["image/png", "image/jpeg"]
            case .loopback: []
            case .deepSeek: ["image/png", "image/jpeg", "image/gif", "image/webp"]
            }
        }
    }

    private let provider: Provider
    private let apiKeyProvider: @Sendable () async throws -> String
    private let session: URLSession

    init(
        provider: Provider,
        apiKeyProvider: @escaping @Sendable () async throws -> String,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.provider = provider
        self.apiKeyProvider = apiKeyProvider
        if case .loopback = provider {
            configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        }
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    static func configuredLocalFallback() -> CompanionQAService? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "studio.offlineAnswerEnabled"),
              let id = defaults.string(forKey: "studio.offlineAnswerModel")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, let port = UInt16(defaults.string(forKey: "studio.offlineAnswerPort") ?? "8000"),
              port > 0 else { return nil }
        let transport = Self(provider: .loopback(port: port, model: id), apiKeyProvider: { "" })
        return CompanionQAService(model: transport, translationTimeout: .seconds(10))
    }

    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let outgoing = try await makeRequest(request)
                    try Task.checkCancellation()
                    let (bytes, response) = try await session.bytes(for: outgoing)
                    guard let response = response as? HTTPURLResponse else { throw QAServiceError.transport }
                    guard (200..<300).contains(response.statusCode) else {
                        if (300..<400).contains(response.statusCode) { throw QAServiceError.rejectedConnection }
                        throw QAServiceError.httpStatus(response.statusCode)
                    }
                    guard response.mimeType?.lowercased() == "text/event-stream" else {
                        throw QAServiceError.invalidResponse
                    }
                    try await receive(bytes, output: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as QAServiceError {
                    continuation.finish(throwing: error)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .timedOut {
                    continuation.finish(throwing: QAServiceError.timeout)
                } catch {
                    continuation.finish(throwing: QAServiceError.transport)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func makeRequest(_ payload: QAModelRequest) async throws -> URLRequest {
        try Task.checkCancellation()
        var content: Any = payload.input
        if let image = payload.image {
            guard !image.bytes.isEmpty, provider.imageTypes.contains(image.mimeType) else {
                throw QAServiceError.invalidResponse
            }
            let url = "data:\(image.mimeType);base64,\(image.bytes.base64EncodedString())"
            var imageURL = ["url": url]
            imageURL["detail"] = provider.imageDetail
            content = [
                ["type": "text", "text": payload.input],
                ["type": "image_url", "image_url": imageURL]
            ] as [[String: Any]]
        }
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        if case .loopback = provider {
            guard payload.image == nil else { throw QAServiceError.rejectedConnection }
        } else {
            let key = try await apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw QAServiceError.missingCredentials
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "model": provider.model,
            "messages": [
                ["role": "system", "content": payload.instructions],
                ["role": "user", "content": content]
            ] as [[String: Any]],
            "stream": true,
            "thinking": ["type": provider.thinking],
            "temperature": 0.2,
            "max_tokens": payload.maxOutputTokens
        ]
        if case .loopback = provider {
            body.removeValue(forKey: "thinking")
            body["chat_template_kwargs"] = ["enable_thinking": false]
        } else {
            body["reasoning_effort"] = provider.reasoningEffort
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func receive(
        _ bytes: URLSession.AsyncBytes,
        output: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let decoder = JSONDecoder()
        var event = ""
        var ended = false
        var visibleText = false
        var textBytes = 0

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                ended = true
                break
            }
            if !event.isEmpty { event.append("\n") }
            event.append(payload)
            guard event.utf8.count < 512_000 else { throw QAServiceError.invalidResponse }
            // The normal wire format uses one JSON object per data line. Keeping
            // an unfinished object also permits SSE events with multiple data lines.
            guard let frame = try? decoder.decode(StreamFrame.self, from: Data(event.utf8)) else { continue }
            event.removeAll(keepingCapacity: true)
            guard frame.error == nil else { throw QAServiceError.invalidResponse }
            guard let choice = frame.choices?.first else { continue }
            if provider == .deepSeek, choice.delta?.refusal?.isEmpty == false {
                throw QAServiceError.invalidResponse
            }
            if let reason = choice.finishReason {
                if provider == .deepSeek, ["insufficient_system_resource", "aborted"].contains(reason) {
                    throw QAServiceError.transport
                }
                guard ["stop", "length"].contains(reason) else { throw QAServiceError.invalidResponse }
                ended = true
            }
            // Reasoning is sent in a different field. Only visible content is
            // forwarded to the QA sentence parser, as soon as each chunk arrives.
            guard let text = choice.delta?.content, !text.isEmpty else { continue }
            textBytes += text.utf8.count
            guard textBytes <= 64_000 else { throw QAServiceError.invalidResponse }
            visibleText = visibleText || text.contains { !$0.isWhitespace }
            output.yield(text)
        }

        guard ended, visibleText, event.isEmpty else { throw QAServiceError.invalidResponse }
    }

    private struct StreamFrame: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let refusal: String?
            }

            let delta: Delta?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }

        struct ServiceError: Decodable {}

        let choices: [Choice]?
        let error: ServiceError?
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
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
