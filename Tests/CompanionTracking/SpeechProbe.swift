@preconcurrency import AVFoundation
import Foundation
import Speech

@main
struct CompanionSpeechProbe {
    @MainActor
    static func main() async {
        do {
            try await run()
            writeStatus(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            stop(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "status":
            print("Speech authorization: \(SFSpeechRecognizer.authorizationStatus().rawValue)")
            print("Microphone authorization: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
            for locale in ["en-US", "zh-CN", "en-GB"] {
                let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
                print("\(locale) on-device=\(recognizer?.supportsOnDeviceRecognition == true) available=\(recognizer?.isAvailable == true)")
            }
        case "file" where arguments.count >= 3:
            guard await authorized(requestAccess: arguments.contains("--request-access")) else { stop(2) }
            try await transcribeFile(URL(fileURLWithPath: arguments[2]), locale: arguments[1])
        case "file-url" where arguments.count >= 3:
            guard await authorized(requestAccess: arguments.contains("--request-access")) else { stop(2) }
            try await transcribeURL(URL(fileURLWithPath: arguments[2]), locale: arguments[1])
        case "mic" where arguments.count == 3:
            let speech = CompanionLocalSpeechInput()
            let started = ProcessInfo.processInfo.systemUptime
            speech.start(localeIdentifier: arguments[1], reportLevel: false) { event in
                switch event {
                case .started: print("Listening locally"); fflush(nil)
                case .transcript(let text, let final): record(text, final: final, started: started)
                case .failure(let message, _):
                    FileHandle.standardError.write(Data((message + "\n").utf8))
                    stop(2)
                case .level: break
                }
            }
            try await Task.sleep(for: .seconds(Double(arguments[2]) ?? 15))
            speech.finish()
            try await Task.sleep(for: .milliseconds(900))
            speech.cancel()
        default:
            print("Usage: speech-probe status | file <locale> <recording> [--request-access] | file-url <locale> <recording> [--request-access] | mic <locale> <seconds>")
            stop(2)
        }
    }

    private static func authorized(requestAccess: Bool) async -> Bool {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined, requestAccess {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else {
            FileHandle.standardError.write(Data("Local Speech Recognition authorization status \(status.rawValue).\n".utf8))
            return false
        }
        return true
    }

    @MainActor
    private static func transcribeFile(_ url: URL, locale: String) async throws {
        let audio = try AVAudioFile(forReading: url)
        let request = SFSpeechAudioBufferRecognitionRequest()
        let recognition = startFileRecognition(request: request, locale: locale)

        // Feed in real time. Times in the resulting JSONL are relative to
        // playback start and can be aligned with the recording annotations.
        let framesPerBuffer = AVAudioFrameCount(audio.processingFormat.sampleRate / 20)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: framesPerBuffer) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        while audio.framePosition < audio.length {
            try audio.read(into: buffer, frameCount: framesPerBuffer)
            request.append(buffer)
            let next = Double(audio.framePosition) / audio.processingFormat.sampleRate
            try await Task.sleep(for: .seconds(max(0, next - (ProcessInfo.processInfo.systemUptime - recognition.started))))
        }
        request.endAudio()
        try await waitForFinal(recognition, seconds: 3)
    }

    @MainActor
    private static func transcribeURL(_ url: URL, locale: String) async throws {
        let request = SFSpeechURLRecognitionRequest(url: url)
        let recognition = startFileRecognition(request: request, locale: locale)
        try await waitForFinal(recognition, seconds: 30)
    }

    private struct FileRecognition {
        let started: TimeInterval
        let recognizer: SFSpeechRecognizer
        let task: SFSpeechRecognitionTask
        let stream: AsyncStream<FileEvent>
        let continuation: AsyncStream<FileEvent>.Continuation
    }

    private enum FileEvent: Sendable {
        case transcript(ProbeTranscript)
        case failure(String)
    }

    @MainActor
    private static func startFileRecognition(request: SFSpeechRecognitionRequest, locale: String) -> FileRecognition {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.supportsOnDeviceRecognition else {
            FileHandle.standardError.write(Data("This locale does not have on-device speech recognition.\n".utf8))
            stop(2)
        }
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        let started = ProcessInfo.processInfo.systemUptime
        let callbacks = AsyncStream<FileEvent>.makeStream()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                callbacks.continuation.yield(.transcript(ProbeTranscript(
                    atMs: Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                    transcript: result.bestTranscription.formattedString, isFinal: result.isFinal
                )))
                if result.isFinal { callbacks.continuation.finish() }
            }
            if let error {
                callbacks.continuation.yield(.failure(error.localizedDescription))
                callbacks.continuation.finish()
            }
        }
        return FileRecognition(
            started: started, recognizer: recognizer, task: task, stream: callbacks.stream, continuation: callbacks.continuation
        )
    }

    @MainActor
    private static func waitForFinal(_ recognition: FileRecognition, seconds: Double) async throws {
        let stream = recognition.stream
        let continuation = recognition.continuation
        defer { continuation.finish(); recognition.task.cancel() }
        let completed = try await withThrowingTaskGroup(of: Bool.self) { tasks in
            tasks.addTask {
                for await event in stream {
                    switch event {
                    case .transcript(let entry):
                        record(entry)
                        if entry.isFinal { return true }
                    case .failure(let message):
                        FileHandle.standardError.write(Data((message + "\n").utf8))
                        return false
                    }
                }
                return false
            }
            tasks.addTask {
                try await Task.sleep(for: .seconds(seconds))
                continuation.finish()
                return false
            }
            let firstResult = try await tasks.next()
            tasks.cancelAll()
            return firstResult == true
        }
        if !completed {
            FileHandle.standardError.write(Data("Apple Speech did not return a final local transcription.\n".utf8))
            stop(2)
        }
    }

    private static func record(_ text: String, final: Bool, started: TimeInterval) {
        record(ProbeTranscript(
            atMs: Int((ProcessInfo.processInfo.systemUptime - started) * 1000), transcript: text, isFinal: final
        ))
    }

    private static func record(_ entry: ProbeTranscript) {
        if let data = try? JSONEncoder().encode(entry) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }

    private static func stop(_ status: Int32) -> Never {
        writeStatus(status)
        exit(status)
    }

    private static func writeStatus(_ status: Int32) {
        if let path = ProcessInfo.processInfo.environment["TEXTREAM_PROBE_STATUS"] {
            try? String(status).write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

private struct ProbeTranscript: Encodable, Sendable {
    let atMs: Int
    let transcript: String
    let isFinal: Bool
}
