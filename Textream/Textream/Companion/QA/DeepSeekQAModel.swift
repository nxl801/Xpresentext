import Foundation

struct DeepSeekQAModel: QAModel {
    static let modelID = OpenAIChatQATransport.Provider.deepSeek.model
    static let baseURL = OpenAIChatQATransport.Provider.deepSeek.baseURL
    static let endpoint = OpenAIChatQATransport.Provider.deepSeek.endpoint

    private let transport: OpenAIChatQATransport

    init(
        apiKeyProvider: @escaping @Sendable () async throws -> String,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        transport = OpenAIChatQATransport(provider: .deepSeek, apiKeyProvider: apiKeyProvider, configuration: configuration)
    }

    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        transport.stream(request)
    }
}
