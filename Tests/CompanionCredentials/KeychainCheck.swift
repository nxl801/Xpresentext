import Foundation
import Security

private final class StandardAPIFixture: URLProtocol, @unchecked Sendable {
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
    }
    private static let counter = Counter()
    static var requests: Int { counter.lock.withLock { counter.count } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.counter.lock.withLock { Self.counter.count += 1 }
        guard let url = request.url, url == GLMQAModel.chinaEndpoint,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer disposable-new-standard-value",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: QAServiceError.rejectedConnection)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("""
        data: {"choices":[{"delta":{"content":"Fixture response."},"finish_reason":"stop"}]}

        data: [DONE]


        """.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
private enum KeychainCheck {
    private static let legacy = "disposable-refreshed-value"
    private static let standard = "disposable-new-standard-value"
    private static let deepSeek = "disposable-deepseek-value"

    private static func require(_ check: Bool, _ description: String = "The isolated Keychain assertion failed.") throws {
        guard check else { throw StudioError.message(description) }
    }

    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        // Only the unique test services are queried. Never show a Keychain prompt.
        SecKeychainSetUserInteractionAllowed(false)
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, args[1].hasPrefix("local.xpresentext.keychain-acceptance."),
              args[2].hasPrefix("local.xpresentext.keychain-preferences-acceptance.") else { exit(2) }
        let namespace = args[1]
        let preferences = args[2]
        switch args[0] {
        case "running":
            try require(StudioCredentials.hasSavedKey(for: .bigmodel) == false)
            print("ready")
            fflush(stdout)
            try require(readLine() == "publish")
            let first = UUID().uuidString
            try StudioCredentials.update(first, for: .bigmodel)
            try require(StudioCredentials.hasSavedKey(for: .bigmodel) == true)
            try require(try StudioCredentials.apiKey(for: .bigmodel) == first)
            try StudioCredentials.update(legacy, for: .bigmodel)
            try require(StudioCredentials.hasSavedKey(for: .zai) == false)
        case "reopen":
            try require(StudioCredentials.hasSavedKey(for: .bigmodel) == true)
            try require(try StudioCredentials.apiKey(for: .bigmodel) == legacy)
        case "status":
            try require(StudioCredentials.hasSavedKey(for: .bigmodel) == true)
            try require(StudioCredentials.hasSavedKey(for: .zai) == false)
        case "mark":
            try require(!StudioCredentials.bigmodelLegacyIsCodingPlan)
            try require(try StudioCredentials.apiKey(for: .bigmodel) == legacy, "An unmarked standard entry lost compatibility.")
            UserDefaults.standard.setPersistentDomain(
                [StudioCredentials.bigmodelLegacyCodingPlanMarker: true], forName: preferences
            )
            try require(StudioCredentials.bigmodelLegacyIsCodingPlan, "The isolated marker was not visible in the shared application domain.")
        case "missing-marked":
            try require(StudioCredentials.bigmodelLegacyIsCodingPlan, "A fresh process could not see the app-domain marker.")
            try require(StudioCredentials.hasSavedKey(for: .bigmodel) == false, "The Coding Plan entry appeared as saved standard credentials.")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StandardAPIFixture.self]
            let model = GLMQAModel(
                endpoint: GLMQAModel.chinaEndpoint,
                apiKeyProvider: { try StudioCredentials.apiKey(for: .bigmodel) },
                configuration: configuration
            )
            do {
                _ = try await model.complete(fixtureRequest)
                throw StudioError.message("The marked legacy value or ambiguous env var reached the request.")
            } catch QAServiceError.missingBigmodelStandardCredentials {}
            try require(StandardAPIFixture.requests == 0, "The missing standard key attempted a network request.")
            try require(try exactCredential(namespace + "bigmodel") == legacy)
            print("PASS marked legacy and ambiguous environment key rejected before transport in a fresh process")
        case "explicit-standard-environment":
            try require(StudioCredentials.bigmodelLegacyIsCodingPlan)
            try require(StudioCredentials.hasSavedKey(for: .bigmodel) == false)
            try require(try StudioCredentials.apiKey(for: .bigmodel) == "disposable-explicit-standard-env",
                        "The explicit standard process credential was not found.")
            try require(try StudioCredentials.apiKey(for: .deepseek) == "disposable-deepseek-env")
            try require(try exactCredential(namespace + "bigmodel") == legacy)
            print("PASS explicit standard and DeepSeek environment keys use separate routes")
        case "save-marked-standard":
            try require(StudioCredentials.bigmodelLegacyIsCodingPlan)
            try StudioCredentials.update(standard, for: .bigmodel)
            try require(StudioCredentials.hasSavedKey(for: .bigmodel) == true)
            try require(try exactCredential(namespace + "bigmodel") == legacy)
            try require(try exactCredential(namespace + "bigmodel-standard") == standard)
            try require(try StudioCredentials.apiKey(for: .bigmodel) == standard)
            try require(StudioCredentials.hasSavedKey(for: .zai) == false)
            try require(StudioCredentials.hasSavedKey(for: .deepseek) == false)
            do {
                _ = try StudioCredentials.apiKey(for: .deepseek)
                throw StudioError.message("DeepSeek accepted another provider’s credentials.")
            } catch QAServiceError.missingCredentials {}
            try StudioCredentials.update(deepSeek, for: .deepseek)
            try require(try exactCredential(namespace + "deepseek") == deepSeek)
            try require(StudioModelProvider.deepseek.modelID == "deepseek-flash" &&
                        DeepSeekQAModel.baseURL.absoluteString == "https://api.deepseek.com")
            try require(StudioModelProvider.deepseek.client(apiKeyProvider: { deepSeek }) is DeepSeekQAModel)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StandardAPIFixture.self]
            let model = GLMQAModel(
                endpoint: GLMQAModel.chinaEndpoint,
                apiKeyProvider: { try StudioCredentials.apiKey(for: .bigmodel) },
                configuration: configuration
            )
            try require(try await model.complete(fixtureRequest) == "Fixture response.")
            try require(StandardAPIFixture.requests == 1)
            print("PASS saved standard key reached intercepted standard transport; legacy and DeepSeek stayed independent")
        case "reopen-marked":
            try require(StudioCredentials.bigmodelLegacyIsCodingPlan)
            try require(StudioCredentials.hasSavedKey(for: .bigmodel) == true)
            try require(StudioCredentials.hasSavedKey(for: .deepseek) == true)
            try require(StudioCredentials.hasSavedKey(for: .zai) == false && StudioCredentials.hasSavedKey(for: .gemini) == false)
            print("PASS reopened client sees separate saved standard and DeepSeek items")
        case "grok-cli":
            let provider = StudioModelProvider.grokCLI
            try require(Array(StudioModelProvider.allCases.prefix(2)) == [.deepseek, .grokCLI] &&
                        provider.rawValue == "grok-cli" && provider.modelID == GrokCLIQAModel.modelID &&
                        provider.cacheIdentifier == "grok-cli/" + provider.modelID &&
                        provider.cacheIdentifier != StudioModelProvider.deepseek.cacheIdentifier && !provider.usesAPIKey,
                        "The CLI provider was not isolated from credential-backed providers.")
            try require(provider.client() is GrokCLIQAModel && provider.client(apiKeyProvider: { legacy }) is GrokCLIQAModel)
            let service = namespace + provider.rawValue
            var disposable = testItem(service)
            disposable[kSecValueData as String] = Data(legacy.utf8)
            try require(SecItemAdd(disposable as CFDictionary, nil) == errSecSuccess)
            try require(StudioCredentials.hasSavedKey(for: provider) == nil, "CLI status queried a matching Keychain item.")
            do {
                _ = try StudioCredentials.apiKey(for: provider)
                throw CredentialProbeFailure.expectedCLIError
            } catch StudioError.message(let text) {
                try require(text.contains("Grok CLI") && text.contains("本机登录"))
            }
            do {
                try StudioCredentials.update(standard, for: provider)
                throw CredentialProbeFailure.expectedCLIError
            } catch StudioError.message(let text) {
                try require(text.contains("Grok CLI") && text.contains("本机登录"))
            }
            try require(try exactCredential(service) == legacy, "CLI credential update changed the isolated item.")
            print("PASS Grok CLI status, reads and updates stop before the matching isolated Keychain item")
        case "cleanup":
            for name in StudioModelProvider.allCases.map(\.rawValue) + ["bigmodel-standard"] {
                let query = testItem(namespace + name)
                let removed = SecItemDelete(query as CFDictionary)
                try require(removed == errSecSuccess || removed == errSecItemNotFound)
                try require(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
            }
            UserDefaults.standard.removePersistentDomain(forName: preferences)
            try require(!StudioCredentials.bigmodelLegacyIsCodingPlan)
            print("PASS isolated credentials and preference marker removed")
        default: exit(2)
        }
    }

    private enum CredentialProbeFailure: Error { case expectedCLIError }

    private static var fixtureRequest: QAModelRequest {
        QAModelRequest(purpose: .answer, instructions: "Test fixture.", input: "Test fixture.", maxOutputTokens: 40)
    }

    private static func testItem(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key"]
    }

    private static func exactCredential(_ service: String) throws -> String? {
        var query = testItem(service)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try require(status == errSecSuccess)
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
}
