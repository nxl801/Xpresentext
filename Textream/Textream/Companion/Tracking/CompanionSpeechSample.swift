import CryptoKit
import Foundation
import Speech

/// The diagnostic uses exactly the bundled public-word clip and does not open the microphone.
enum CompanionSpeechSample {
    private static let sha256 = "cae6a0ef4997d68fed052863317c009a4ea622518fd56735e429a7b1489d198d"

    @MainActor
    static func compare(with provider: any CompanionCloudSpeech) async -> String {
        guard let url = Bundle.main.url(forResource: "CompanionSpeechSample", withExtension: "wav"),
              let wav = try? Data(contentsOf: url, options: .mappedIfSafe),
              wav.count == 227_868,
              SHA256.hash(data: wav).map({ String(format: "%02x", $0) }).joined() == sha256
        else { return "找不到内置样音。未发送音频。" }

        let local = await reference(url)
        guard !Task.isCancelled else { return local }
        // Both system prompts run before the online timer. The provider copy
        // holds the authorized credential only for this one sample.
        do {
            let authorized = try await provider.preauthorizedForSample()
            try Task.checkCancellation()
            return await [local, cloud(Data(wav.dropFirst(44)), with: authorized)].joined(separator: "\n")
        } catch {
            let message = (error as? CompanionCloudSpeechError)?.errorDescription ?? "样音测试已取消。"
            return [local, "\(provider.name) · \(message)"].joined(separator: "\n")
        }
    }

    private static func termCount(_ text: String) -> Int {
        let patterns = [
            #"(?i)(?<![a-z])central\s+park(?![a-z])"#,
            #"(?i)(?<![a-z])g[.\s]*p[.\s]*s(?![a-z])"#,
            #"(?i)(?<![a-z])bicycles(?![a-z])"#,
        ]
        return patterns.filter { text.range(of: $0, options: .regularExpression) != nil }.count
    }

    @MainActor
    private static func reference(_ url: URL) async -> String {
        let authorization = await speechAuthorization()
        guard authorization == .authorized else { return "本机 · 没有 macOS 语音识别权限。" }
        guard !Task.isCancelled else { return "本机 · 样音测试已取消。" }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.supportsOnDeviceRecognition
        else { return "本机 · 此 Mac 缺少中文本机语音识别资源。" }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        let events = AsyncStream<(String, Bool)>.makeStream()
        let task = recognizer.recognitionTask(with: request) { @Sendable result, error in
            if let result {
                events.continuation.yield((result.bestTranscription.formattedString, result.isFinal))
                if result.isFinal { events.continuation.finish() }
            }
            if error != nil { events.continuation.finish() }
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { events.continuation.finish() }
        }
        defer {
            deadline.cancel()
            task.cancel()
        }
        var text = ""
        var final = false
        for await (utterance, complete) in events.stream {
            if !utterance.isEmpty { text = utterance }
            if complete { final = true }
        }
        guard !text.isEmpty else { return "本机 · 未识别出样音。" }
        let completion = final ? "" : "，仅有中间转写"
        return "本机 · 术语 \(termCount(text))/3\(completion)\n\(text)"
    }

    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        // This path is reached only after the user selects the file-only sample.
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    private static func cloud(_ pcm: Data, with provider: any CompanionCloudSpeech) async -> String {
        let worker = Task { @MainActor in
            let input = AsyncStream<CompanionCloudAudio>.makeStream(bufferingPolicy: .bufferingOldest(100))
            let clock = ContinuousClock()
            var sender: Task<Void, Never>?
            var finishedAt: ContinuousClock.Instant?
            defer {
                sender?.cancel()
                input.continuation.finish()
            }
            do {
                for try await event in provider.recognize(input.stream) {
                    switch event {
                    case .ready:
                        guard sender == nil else { continue }
                        sender = Task { @MainActor in
                            let bytesPerPacket = CompanionQuestionPCM.bytesPerSecond / 10
                            let start = clock.now
                            for offset in stride(from: 0, to: pcm.count, by: bytesPerPacket) {
                                guard !Task.isCancelled else { return }
                                let left = pcm.startIndex + offset
                                let right = min(left + bytesPerPacket, pcm.endIndex)
                                let packet = Data(pcm[left..<right])
                                input.continuation.yield(.packet(packet))
                                try? await clock.sleep(until: start.advanced(
                                    by: .seconds(Double(offset + packet.count) / Double(CompanionQuestionPCM.bytesPerSecond))
                                ))
                            }
                            guard !Task.isCancelled else { return }
                            finishedAt = clock.now
                            input.continuation.yield(.finish)
                            input.continuation.finish()
                        }
                    case .preview:
                        continue
                    case .complete(let text):
                        guard let finishedAt else { return "\(provider.name) · 在线服务提前返回。" }
                        let time = finishedAt.duration(to: clock.now).components
                        let seconds = Double(time.seconds) + Double(time.attoseconds) / 1e18 + 0.10
                        return "\(provider.name) · 术语 \(termCount(text))/3，模拟停说后 \(String(format: "%.2f", seconds)) 秒\n\(text)"
                    }
                }
                if Task.isCancelled { return "\(provider.name) · 样音测试超时或已取消。" }
                return "\(provider.name) · 未返回最终转写。"
            } catch {
                let message = (error as? CompanionCloudSpeechError)?.errorDescription ?? "样音在线转写连接失败。"
                return "\(provider.name) · \(message)"
            }
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(17))
            if !Task.isCancelled { worker.cancel() }
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
