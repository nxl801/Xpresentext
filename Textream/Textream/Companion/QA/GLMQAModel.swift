import Foundation

struct GLMQAModel: QAModel {
    static let modelID = OpenAIChatQATransport.Provider.bigModel.model
    static let chinaEndpoint = OpenAIChatQATransport.Provider.bigModel.endpoint
    static let internationalEndpoint = OpenAIChatQATransport.Provider.zAI.endpoint

    private let transport: OpenAIChatQATransport?

    init(
        endpoint: URL,
        apiKeyProvider: @escaping @Sendable () async throws -> String,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        let provider: OpenAIChatQATransport.Provider
        switch endpoint.absoluteString {
        case Self.chinaEndpoint.absoluteString: provider = .bigModel
        case Self.internationalEndpoint.absoluteString: provider = .zAI
        default:
            transport = nil
            return
        }
        transport = OpenAIChatQATransport(provider: provider, apiKeyProvider: apiKeyProvider, configuration: configuration)
    }

    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        guard let transport else {
            return AsyncThrowingStream { $0.finish(throwing: QAServiceError.rejectedConnection) }
        }
        return transport.stream(request)
    }
}
