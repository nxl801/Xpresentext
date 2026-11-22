import Foundation

struct QAModelRequest: Sendable {
    enum Purpose: Sendable {
        case answer, translateQuestion, draft, chart, trackingPreparation
    }

    struct Image: Sendable {
        let bytes: Data
        let mimeType: String
    }

    let purpose: Purpose
    let instructions: String
    let input: String
    let image: Image?
    let maxOutputTokens: Int

    init(purpose: Purpose, instructions: String, input: String, image: Image? = nil, maxOutputTokens: Int) {
        self.purpose = purpose
        self.instructions = instructions
        self.input = input
        self.image = image
        self.maxOutputTokens = maxOutputTokens
    }
}

protocol QAModel: Sendable {
    var answerTimeout: Duration { get }
    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error>
}

extension QAModel {
    var answerTimeout: Duration { .seconds(20) }

    func complete(_ request: QAModelRequest) async throws -> String {
        try Task.checkCancellation()
        var result = ""
        for try await chunk in stream(request) {
            try Task.checkCancellation()
            result.append(chunk)
            if result.utf8.count > 64_000 { throw QAServiceError.invalidResponse }
        }
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw QAServiceError.invalidResponse }
        return text
    }
}

struct GeminiQAModel: QAModel {
    static let defaultModel = "gemini-3.5-flash-lite"

    private let model: String
    private let apiKeyProvider: @Sendable () async throws -> String
    private let session: URLSession

    init(apiKey: String, model: String = Self.defaultModel) {
        self.init(model: model, apiKeyProvider: { apiKey })
    }

    init(
        model: String = Self.defaultModel,
        apiKeyProvider: @escaping @Sendable () async throws -> String,
        session: URLSession? = nil
    ) {
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKeyProvider = apiKeyProvider
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 40
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        }
    }

    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let outgoing = try await urlRequest(request)
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
                    var frame: [String] = []
                    var output = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        // URLSession may omit empty lines when iterating AsyncLineSequence.
                        // Gemini emits one complete JSON object on each data: line.
                        guard line.hasPrefix("data:") else { continue }
                        let item = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if item == "[DONE]" { break }
                        frame.append(item)
                        let payload = frame.joined(separator: "\n")
                        guard payload.utf8.count < 1_000_000 else { throw QAServiceError.invalidResponse }
                        guard let chunks = try GeminiStreamEvent.read(payload) else { continue }
                        frame.removeAll(keepingCapacity: true)
                        for chunk in chunks {
                            output = true
                            continuation.yield(chunk)
                        }
                    }
                    guard output, frame.isEmpty else { throw QAServiceError.invalidResponse }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as QAServiceError {
                    continuation.finish(throwing: error)
                } catch let error as URLError where error.code == .timedOut {
                    continuation.finish(throwing: QAServiceError.timeout)
                } catch {
                    continuation.finish(throwing: QAServiceError.transport)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func urlRequest(_ data: QAModelRequest) async throws -> URLRequest {
        guard model.wholeMatch(of: #/gemini-[A-Za-z0-9][A-Za-z0-9._-]{0,79}/#) != nil,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")
        else { throw QAServiceError.invalidModel }
        let key = try await apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline })
        else { throw QAServiceError.missingCredentials }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        var parts: [[String: Any]] = [["text": data.input]]
        if let image = data.image {
            parts.append(["inlineData": ["mimeType": image.mimeType, "data": image.bytes.base64EncodedString()]])
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": data.instructions]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["maxOutputTokens": data.maxOutputTokens, "temperature": 0.2]
        ])
        return request
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

    private struct GeminiStreamEvent: Decodable, Sendable {
        struct Candidate: Decodable, Sendable {
            struct Content: Decodable, Sendable {
                struct Part: Decodable, Sendable {
                    let text: String?
                    let thought: Bool?
                }

                let parts: [Part]?
            }

            let content: Content?
            let finishReason: String?
        }

        struct Feedback: Decodable, Sendable {
            let blockReason: String?
        }

        let candidates: [Candidate]?
        let promptFeedback: Feedback?

        static func read(_ value: String) throws -> [String]? {
            guard let frame = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)) else {
                if value.first == "{" && value.last != "}" { return nil }
                throw QAServiceError.invalidResponse
            }
            guard frame.promptFeedback?.blockReason == nil else { throw QAServiceError.invalidResponse }
            guard let candidate = frame.candidates?.first else { return [] }
            if let finishReason = candidate.finishReason, finishReason != "STOP", finishReason != "MAX_TOKENS" {
                throw QAServiceError.invalidResponse
            }
            return (candidate.content?.parts ?? []).compactMap { part in
                part.thought == true ? nil : part.text
            }
        }
    }
}
