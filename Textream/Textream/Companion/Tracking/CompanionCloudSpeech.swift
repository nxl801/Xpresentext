import Foundation

enum CompanionQuestionSpeechStatus: Equatable, Sendable {
    case local
    case connecting(String)
    case streaming(String)
    case recordingForUpload(String)
    case finishingOnline(String)
    case usedOnline(String)
    case fallback(String)

    var label: String {
        switch self {
        case .local: "本机听题"
        case .connecting(let provider): "正在连接\(provider)，本机同时听题"
        case .streaming(let provider): "\(provider)正在接收本题音频"
        case .recordingForUpload(let provider): "本机正在收题，结束后发给\(provider)"
        case .finishingOnline(let provider): "\(provider)正在完成本题转写"
        case .usedOnline(let provider): "转写来自\(provider)"
        case .fallback(let reason): "\(reason) 已切换本机听题。"
        }
    }
}

enum CompanionCloudSpeechError: LocalizedError, Equatable {
    case credential
    case configuration
    case transport
    case rejected
    case invalidResponse
    case tooLong
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .credential: "语音服务的密钥不可用。"
        case .configuration: "语音服务尚未配置。"
        case .transport: "在线语音连接中断。"
        case .rejected: "语音服务未接受本题。"
        case .invalidResponse: "在线语音返回异常。"
        case .tooLong: "本题超过在线语音的录音限制。"
        case .noSpeech: "在线语音未识别出本题。"
        }
    }
}

enum CompanionCloudSpeechEvent: Sendable, Equatable {
    case ready
    case preview(String, atSentenceBoundary: Bool)
    case complete(String)
}

enum CompanionCloudAudio: Sendable {
    case packet(Data)
    case finish
}

protocol CompanionCloudSpeech: Sendable {
    var name: String { get }
    var sendsWhileListening: Bool { get }
    func recognize(_ audio: AsyncStream<CompanionCloudAudio>) -> AsyncThrowingStream<CompanionCloudSpeechEvent, Error>
    func preauthorizedForSample() async throws -> any CompanionCloudSpeech
}

extension CompanionCloudSpeech {
    func preauthorizedForSample() async throws -> any CompanionCloudSpeech { self }
}

enum CompanionQuestionPCM {
    static let sampleRate = 16_000
    static let bytesPerSecond = sampleRate * 2
    static let maximumBytes = 120 * bytesPerSecond

    static func wav(_ pcm: Data) throws -> Data {
        guard !pcm.isEmpty else { throw CompanionCloudSpeechError.noSpeech }
        guard pcm.count <= maximumBytes, pcm.count.isMultiple(of: 2) else { throw CompanionCloudSpeechError.tooLong }
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        var header = Data("RIFF".utf8)
        append(UInt32(pcm.count + 36), to: &header)
        header.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &header)
        append(UInt16(1), to: &header)
        append(UInt16(1), to: &header)
        append(UInt32(sampleRate), to: &header)
        append(UInt32(bytesPerSecond), to: &header)
        append(UInt16(2), to: &header)
        append(UInt16(16), to: &header)
        header.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count), to: &header)
        header.append(pcm)
        return header
    }
}

struct DeepSeekCloudSpeech: CompanionCloudSpeech {
    static let endpoint = URL(string: "https://api.deepseek.com/v1/tools/asr")!
    let name = "DeepSeek"
    let sendsWhileListening = false

    private var credential: @Sendable () async throws -> String
    private let session: URLSession

    init(credential: @escaping @Sendable () async throws -> String, configuration: URLSessionConfiguration = .ephemeral) {
        self.credential = credential
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: QuestionSpeechNoRedirect(), delegateQueue: nil)
    }

    func preauthorizedForSample() async throws -> any CompanionCloudSpeech {
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
                    let key: String
                    do { key = try await credential() } catch { throw CompanionCloudSpeechError.credential }
                    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CompanionCloudSpeechError.credential }
                    try Task.checkCancellation()
                    output.yield(.ready)
                    var pcm = Data()
                    var finished = false
                    capture: for await item in audio {
                        try Task.checkCancellation()
                        switch item {
                        case .finish:
                            finished = true
                            break capture
                        case .packet(let chunk):
                            guard chunk.count <= CompanionQuestionPCM.maximumBytes - pcm.count else {
                                throw CompanionCloudSpeechError.tooLong
                            }
                            pcm.append(chunk)
                        }
                    }
                    // Closing the audio source without an explicit finish is cancellation.
                    guard finished else { throw CancellationError() }
                    try Task.checkCancellation()
                    let file = try CompanionQuestionPCM.wav(pcm)
                    let boundary = UUID().uuidString
                    let prefix = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"question.wav\"\r\n"
                    var body = Data((prefix + "Content-Type: audio/wav\r\n\r\n").utf8)
                    body.append(file)
                    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
                    var request = URLRequest(url: Self.endpoint)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.httpBody = body
                    let (data, response) = try await session.data(for: request)
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse else { throw CompanionCloudSpeechError.invalidResponse }
                    guard http.statusCode == 200 else { throw CompanionCloudSpeechError.rejected }
                    guard data.count <= 64_000, let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
                        throw CompanionCloudSpeechError.invalidResponse
                    }
                    let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw CompanionCloudSpeechError.noSpeech }
                    output.yield(.complete(text))
                    output.finish()
                } catch {
                    output.finish(throwing: (error as? CompanionCloudSpeechError) ?? .transport)
                }
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    private struct Reply: Decodable {
        let text: String
    }
}

final class QuestionSpeechNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
