import Foundation

private final class ChatFixtureProtocol: URLProtocol, @unchecked Sendable {
    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = 0
        private var redirected = 0

        func recordStop() { lock.withLock { stopped += 1 } }
        func recordRedirect() { lock.withLock { redirected += 1 } }
        var stops: Int { lock.withLock { stopped } }
        var redirects: Int { lock.withLock { redirected } }
    }

    private static let activity = Activity()
    static var cancellations: Int { activity.stops }
    static var followedRedirects: Int { activity.redirects }
    private let stateLock = NSLock()
    private var hanging = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return fail() }
        if url.host == "redirect.invalid" || request.value(forHTTPHeaderField: "X-Redirect-Fixture") == "1" {
            Self.activity.recordRedirect()
            return fail()
        }
        let expectedKey: String
        let deepSeek: Bool
        switch url.absoluteString {
        case "https://open.bigmodel.cn/api/paas/v4/chat/completions":
            expectedKey = "fake-china-token"
            deepSeek = false
        case "https://api.z.ai/api/paas/v4/chat/completions":
            expectedKey = "fake-international-token"
            deepSeek = false
        case "https://api.deepseek.com/chat/completions":
            expectedKey = "fake-deepseek-token"
            deepSeek = true
        default: return fail()
        }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(expectedKey)",
              request.value(forHTTPHeaderField: "Accept") == "text/event-stream",
              request.value(forHTTPHeaderField: "Content-Type") == "application/json",
              request.httpMethod == "POST",
              let bytes = try? bodyData(),
              !String(decoding: bytes, as: UTF8.self).contains(expectedKey),
              let body = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              body["model"] as? String == (deepSeek ? "deepseek-flash" : "glm-5.3-flash"),
              body["stream"] as? Bool == true,
              deepSeek ? body["reasoning_effort"] == nil : body["reasoning_effort"] as? String == "low",
              (body["thinking"] as? [String: String])?["type"] == (deepSeek ? "disabled" : "enabled"),
              let messages = body["messages"] as? [[String: Any]],
              messages.count == 2,
              messages[0]["role"] as? String == "system",
              messages[1]["role"] as? String == "user"
        else { return fail() }

        let input: String
        if let content = messages[1]["content"] as? [[String: Any]] {
            guard content.count == 2, content[0]["type"] as? String == "text",
                  content[1]["type"] as? String == "image_url",
                  body["max_tokens"] as? Int == 92,
                  let text = content[0]["text"] as? String,
                  let image = content[1]["image_url"] as? [String: String],
                  image["url"] == (text == "synthetic jpeg" ? "data:image/jpeg;base64,AQID" : "data:image/png;base64,AQID"),
                  image["detail"] == (deepSeek ? "high" : nil) else { return fail() }
            input = text
        } else {
            guard let text = messages[1]["content"] as? String else { return fail() }
            input = text
        }

        if let code = Int(input), [400, 401, 402, 403, 422, 429, 500, 503].contains(code) {
            sendHeaders(status: code)
            send("{\"error\":{\"message\":\"Fixture response body\"}}")
            return finish()
        }
        if input == "redirect" {
            let destination = deepSeek ? GLMQAModel.chinaEndpoint : URL(string: "https://redirect.invalid/")!
            let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: [
                "Location": destination.absoluteString
            ])!
            var redirected = request
            redirected.url = destination
            redirected.setValue("1", forHTTPHeaderField: "X-Redirect-Fixture")
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            // If the transfer rejects the redirect, the original 307 response
            // remains available to its consumer.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            finish()
            return
        }
        if input == "not SSE" {
            sendHeaders(contentType: "application/json")
            send("{\"choices\":[]}")
            return finish()
        }
        if input == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        if input == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        sendHeaders()
        if input == "only reasoning" {
            send("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"fixture thought could not become an answer\"}}]}\n\n")
            send("data: [DONE]\n\n")
            return finish()
        }
        if input == "truncated" {
            sendFrame("Incomplete")
            return finish()
        }
        if input == "bad finish" {
            sendFrame("Possible incomplete answer", finishReason: "content_filter")
            return finish()
        }
        if input == "backend interrupted" {
            sendFrame("", finishReason: "insufficient_system_resource")
            return finish()
        }
        if input == "refused image" {
            sendFrame("Unverified description")
            send("data: {\"choices\":[{\"delta\":{\"refusal\":\"Image refused\"},\"finish_reason\":\"stop\"}]}\n\n")
            return finish()
        }
        if input == "stream error" {
            send("data: {\"error\":{\"code\":\"fixture\",\"message\":\"Provider text is never forwarded.\"}}\n\n")
            return finish()
        }
        if input.contains("hold stream for first sentence") {
            stateLock.withLock { hanging = true }
            sendFrame("{\"part\":\"short\",\"kind\":\"supplemental\",\"text\":\"The first sentence ")
            sendFrame("is complete.\",\"sources\":[]}\n")
            return
        }

        send(": keepalive\r\n\r\n")
        send("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hidden fixture thought\"}}]}\n\n")
        send("data: {\"choices\":\n")
        send("data: [{\"delta\":{\"content\":\"Usable \"}}]}\n\n")
        sendFrame("sentence.", finishReason: "stop")
        send("data: {\"choices\":[],\"usage\":{\"completion_tokens\":2}}\n\n")
        send("data: [DONE]\n\n")
        finish()
    }

    override func stopLoading() {
        if stateLock.withLock({ hanging }) { Self.activity.recordStop() }
    }

    private func bodyData() throws -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { throw URLError(.badServerResponse) }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read >= 0 else { throw URLError(.badServerResponse) }
            if read == 0 { return data }
            data.append(contentsOf: buffer.prefix(read))
        }
    }

    private func sendHeaders(status: Int = 200, contentType: String = "text/event-stream") {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    private func sendFrame(_ content: String, finishReason: String? = nil) {
        var choice: [String: Any] = ["delta": ["content": content]]
        choice["finish_reason"] = finishReason
        let payload = try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
        send("data: \(String(decoding: payload, as: UTF8.self))\n\n")
    }

    private func send(_ text: String) {
        client?.urlProtocol(self, didLoad: Data(text.utf8))
    }

    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)) }
    private func finish() { client?.urlProtocolDidFinishLoading(self) }
}

enum GLMTransportTests {
    private static func model(
        _ endpoint: URL = GLMQAModel.internationalEndpoint,
        key: String = "fake-international-token"
    ) -> GLMQAModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatFixtureProtocol.self]
        return GLMQAModel(endpoint: endpoint, apiKeyProvider: { key }, configuration: configuration)
    }

    private static func deepSeek(key: String = "fake-deepseek-token") -> DeepSeekQAModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatFixtureProtocol.self]
        return DeepSeekQAModel(apiKeyProvider: { key }, configuration: configuration)
    }

    @MainActor
    static func run() async throws {
        let international = model()
        let text = try await international.complete(request(input: "synthetic text"))
        try expect(text == "Usable sentence.", "International SSE did not filter reasoning or join the visible frames")
        let china = model(GLMQAModel.chinaEndpoint, key: "fake-china-token")
        let image = QAModelRequest.Image(bytes: Data([1, 2, 3]), mimeType: "image/png")
        let chart = QAModelRequest(purpose: .chart, instructions: "Read this test chart.", input: "synthetic image", image: image, maxOutputTokens: 92)
        let chartText = try await china.complete(chart)
        try expect(chartText == "Usable sentence.", "China image and text were not sent in the expected format")

        try await fails(international, input: "401", expected: .httpStatus(401))
        try await fails(china, input: "429", expected: .httpStatus(429))
        try await fails(china, input: "timeout", expected: .timeout)
        try await fails(international, input: "not SSE", expected: .invalidResponse)
        try await fails(international, input: "only reasoning", expected: .invalidResponse)
        try await fails(international, input: "truncated", expected: .invalidResponse)
        try await fails(international, input: "redirect", expected: .rejectedConnection)
        try expect(ChatFixtureProtocol.followedRedirects == 0, "A GLM redirect could forward a credential")

        let unauthorized = GLMQAModel(endpoint: URL(string: "https://open.bigmodel.cn.redirect.invalid/api/paas/v4/chat/completions")!) {
            throw TestFailure(description: "An unapproved endpoint asked for the key")
        }
        try await fails(unauthorized, input: "invalid endpoint", expected: .rejectedConnection)
        try await fails(model(key: " \n"), input: "missing key", expected: .missingCredentials)
        try await fails(model(key: "fake\r\ninjection"), input: "invalid key", expected: .missingCredentials)

        try await verifyEarlySentenceAndCancellation(international)
        print("PASS GLM HTTPS text and PNG attachment, streamed first sentence, cancellation, credential and redirect isolation, HTTP and SSE errors")
        try await verifyDeepSeek()
    }

    @MainActor
    private static func verifyDeepSeek() async throws {
        let client = deepSeek()
        let text = try await client.complete(request(input: "synthetic text"))
        try expect(text == "Usable sentence.", "DeepSeek SSE did not filter reasoning, preserve chunks or allow a usage event")

        for (mime, prompt) in [("image/png", "synthetic image"), ("image/jpeg", "synthetic jpeg")] {
            let image = QAModelRequest.Image(bytes: Data([1, 2, 3]), mimeType: mime)
            let chart = QAModelRequest(purpose: .chart, instructions: "Read the test image.", input: prompt, image: image, maxOutputTokens: 92)
            let result = try await client.complete(chart)
            try expect(result == "Usable sentence.", "DeepSeek did not upload \(mime) with detail high")
        }
        let badImage = QAModelRequest.Image(bytes: Data([1, 2, 3]), mimeType: "text/plain")
        let invalidChart = QAModelRequest(purpose: .chart, instructions: "", input: "", image: badImage, maxOutputTokens: 92)
        try await fails(client, request: invalidChart, expected: .invalidResponse)
        for code in [400, 401, 402, 403, 422, 429, 500, 503] {
            try await fails(client, input: String(code), expected: .httpStatus(code))
        }
        try await fails(client, input: "offline", expected: .transport)
        try await fails(client, input: "backend interrupted", expected: .transport)
        try await fails(client, input: "timeout", expected: .timeout)
        for input in ["not SSE", "only reasoning", "truncated", "bad finish", "stream error", "refused image"] {
            try await fails(client, input: input, expected: .invalidResponse)
        }
        try await fails(client, input: "redirect", expected: .rejectedConnection)
        try expect(ChatFixtureProtocol.followedRedirects == 0, "A redirect crossed from DeepSeek to BigModel")
        let wrongService = GLMQAModel(endpoint: DeepSeekQAModel.endpoint) {
            throw TestFailure(description: "A GLM client requested a credential for the DeepSeek endpoint")
        }
        try await fails(wrongService, input: "cross-provider endpoint", expected: .rejectedConnection)
        try await fails(deepSeek(key: ""), input: "missing key", expected: .missingCredentials)
        try await fails(deepSeek(key: "fake\r\ninjection"), input: "invalid key", expected: .missingCredentials)
        try await verifyEarlySentenceAndCancellation(client)
        print("PASS DeepSeek fixed endpoint and model, non-thinking requests, PNG/JPEG detail high, split first sentence, cancellation, cross-provider redirect refusal, HTTP and SSE errors")
    }

    @MainActor
    private static func verifyEarlySentenceAndCancellation(_ model: any QAModel) async throws {
        let priorCancellations = ChatFixtureProtocol.cancellations
        let session = CompanionQASession(service: CompanionQAService(model: model))
        session.submit("hold stream for first sentence")
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.answer.shortAnswer == nil && ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(session.answer.shortAnswer == "The first sentence is complete.", "Product did not show a complete first sentence")
        try expect(session.answer.firstSentenceElapsed != nil && session.state == .answering, "Client buffered the first sentence until stream closure")
        session.cancel()
        let cancelDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ChatFixtureProtocol.cancellations == priorCancellations && ContinuousClock.now < cancelDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(ChatFixtureProtocol.cancellations == priorCancellations + 1, "Cancel did not reach the HTTP transfer")
    }

    private static func request(input: String) -> QAModelRequest {
        QAModelRequest(purpose: .answer, instructions: "Synthetic wire check.", input: input, maxOutputTokens: 80)
    }

    private static func fails(_ model: any QAModel, input: String, expected: QAServiceError) async throws {
        try await fails(model, request: request(input: input), expected: expected)
    }

    private static func fails(_ model: any QAModel, request: QAModelRequest, expected: QAServiceError) async throws {
        do {
            _ = try await model.complete(request)
        } catch let actual as QAServiceError {
            try expect(actual == expected, "Unexpected chat transport error for \(request.input): \(actual)")
            return
        }
        throw TestFailure(description: "Missing chat transport error for \(request.input)")
    }
}
