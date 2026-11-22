@preconcurrency import AVFoundation
import Foundation
import Speech

enum CompanionSpeechEvent: Sendable {
    case started
    case transcript(String, isFinal: Bool)
    case level(CGFloat, at: TimeInterval)
    case failure(String, canRestart: Bool)
}

@MainActor
protocol CompanionSpeechInput: AnyObject {
    func start(
        localeIdentifier: String,
        reportLevel: Bool,
        onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void
    )
    func finish()
    func cancel()
}

@MainActor
protocol CompanionQuestionPCMInput: CompanionSpeechInput {
    func start(
        localeIdentifier: String,
        reportLevel: Bool,
        onPCM: (@Sendable (Data) -> Void)?,
        onLocalAvailability: @escaping @MainActor (Bool) -> Void,
        onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void
    )
}

@MainActor
final class CompanionLocalSpeechInput: CompanionQuestionPCMInput {
    private var generation = UUID()
    private var starting: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var tap: CompanionAudioTap?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?

    func start(
        localeIdentifier: String,
        reportLevel: Bool,
        onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void
    ) {
        start(localeIdentifier: localeIdentifier, reportLevel: reportLevel, onPCM: nil,
              onLocalAvailability: { _ in }, onEvent: onEvent)
    }

    func start(
        localeIdentifier: String,
        reportLevel: Bool,
        onPCM: (@Sendable (Data) -> Void)?,
        onLocalAvailability: @escaping @MainActor (Bool) -> Void,
        onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void
    ) {
        cancel()
        let candidate = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        let recognizer = candidate?.supportsOnDeviceRecognition == true ? candidate : nil
        guard recognizer != nil || onPCM != nil else {
            onEvent(.failure("这台 Mac 暂时无法离线识别 \(localeIdentifier)。可准备对应语音资源、切换听题语言或点击讲稿定位。", canRestart: false))
            return
        }
        let token = generation
        starting = Task { [weak self] in
            guard let self else { return }
            // An explicitly online question can use the microphone without
            // requesting Apple's separate Speech permission.
            let speechAuthorized = if onPCM != nil {
                SFSpeechRecognizer.authorizationStatus() == .authorized
            } else {
                await Self.speechIsAuthorized()
            }
            guard self.generation == token else { return }
            guard speechAuthorized || onPCM != nil else {
                onEvent(.failure("请在 macOS 的「隐私与安全性」中允许 Textream Studio 使用语音识别。仍可点击讲稿定位。", canRestart: false))
                return
            }
            let available = speechAuthorized ? recognizer : nil
            onLocalAvailability(available != nil)
            guard self.generation == token else { return }
            let microphoneAuthorized = await Self.microphoneIsAuthorized()
            guard self.generation == token else { return }
            guard microphoneAuthorized else {
                onEvent(.failure("请在 macOS 的「隐私与安全性」中允许使用麦克风。仍可输入问题或点击讲稿。", canRestart: false))
                return
            }
            self.begin(recognizer: available, reportLevel: reportLevel, onPCM: onPCM, token: token,
                       onLocalAvailability: onLocalAvailability, onEvent: onEvent)
        }
    }

    /// Stop acquiring audio, and allow Speech to deliver its final text.
    func finish() {
        stopAudio(flushPCM: true)
    }

    private func stopAudio(flushPCM: Bool) {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        tap?.endAudio(flushPCM: flushPCM)
        tap = nil
    }

    func cancel() {
        generation = UUID()
        starting?.cancel()
        starting = nil
        stopAudio(flushPCM: false)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
    }

    private func begin(
        recognizer: SFSpeechRecognizer?,
        reportLevel: Bool,
        onPCM: (@Sendable (Data) -> Void)?,
        token: UUID,
        onLocalAvailability: @escaping @MainActor (Bool) -> Void,
        onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void
    ) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            onEvent(.failure("未发现可用的麦克风。仍可输入问题或点击讲稿。", canRestart: false))
            return
        }

        let pcm = onPCM.flatMap { sink in
            CompanionPCMResampler(input: hardware).map { (converter: $0, sink: sink) }
        }
        guard recognizer != nil || pcm != nil else {
            onEvent(.failure("麦克风音频无法送到本题的语音服务。仍可输入问题。", canRestart: false))
            return
        }
        let tap = CompanionAudioTap(reportLevel: reportLevel, pcm: pcm) { [weak self] level, time in
            Task { @MainActor in
                guard self?.generation == token else { return }
                onEvent(.level(level, at: time))
            }
        }
        // Keep the input node's negotiated format, including the channel count of a USB microphone.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(max(1024, hardware.sampleRate / 40)), format: hardware) {
            buffer, _ in tap.consume(buffer)
        }
        self.engine = engine
        self.tap = tap
        self.recognizer = recognizer

        if let recognizer {
            startRecognition(recognizer, tap: tap, streaming: pcm != nil, token: token,
                             onLocalAvailability: onLocalAvailability, onEvent: onEvent)
        }

        do {
            engine.prepare()
            try engine.start()
            onEvent(.started)
        } catch {
            cancel()
            onEvent(.failure("麦克风未能启动。\(error.localizedDescription)", canRestart: false))
        }
    }

    private func startRecognition(
        _ recognizer: SFSpeechRecognizer,
        tap: CompanionAudioTap,
        streaming: Bool,
        token: UUID,
        onLocalAvailability: @escaping @MainActor (Bool) -> Void,
        onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void
    ) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        tap.replaceLocalRequest(request)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let problem = error.map { $0 as NSError }
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if let transcript { onEvent(.transcript(transcript, isFinal: isFinal)) }
                guard self.generation == token else { return }
                if streaming && self.engine != nil {
                    if isFinal, let recognizer = self.recognizer {
                        self.startRecognition(recognizer, tap: tap, streaming: true, token: token,
                                              onLocalAvailability: onLocalAvailability, onEvent: onEvent)
                    } else if problem != nil {
                        tap.replaceLocalRequest(nil)
                        onLocalAvailability(false)
                    }
                    return
                }
                guard !isFinal, let problem else { return }
                let transient = problem.domain == "kAFAssistantErrorDomain" && [1100, 1101, 1110].contains(problem.code)
                onEvent(.failure("本机语音识别已停止。\(problem.localizedDescription)", canRestart: transient))
            }
        }

    }

    nonisolated private static func speechIsAuthorized() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current == .authorized }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    nonisolated private static func microphoneIsAuthorized() async -> Bool {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        guard current == .notDetermined else { return current == .authorized }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}

// AVAudioEngine calls its tap off the main thread. Closing the request and
// appending samples share a lock so a stopped generation cannot get more audio.
private final class CompanionAudioTap: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let reportLevel: Bool
    private let onLevel: @Sendable (CGFloat, TimeInterval) -> Void
    private let pcm: (converter: CompanionPCMResampler, sink: @Sendable (Data) -> Void)?

    init(
        reportLevel: Bool,
        pcm: (converter: CompanionPCMResampler, sink: @Sendable (Data) -> Void)?,
        onLevel: @escaping @Sendable (CGFloat, TimeInterval) -> Void
    ) {
        self.reportLevel = reportLevel
        self.onLevel = onLevel
        self.pcm = pcm
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard isOpen else { return }
            request?.append(buffer)
            if let pcm, let bytes = pcm.converter.convert(buffer), !bytes.isEmpty { pcm.sink(bytes) }
        }
        guard reportLevel, let samples = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else { return }
        var squares: Float = 0
        for index in 0..<Int(buffer.frameLength) { squares += samples[index] * samples[index] }
        let rms = sqrt(squares / Float(buffer.frameLength))
        onLevel(CGFloat(rms), ProcessInfo.processInfo.systemUptime)
    }

    func endAudio(flushPCM: Bool) {
        lock.withLock {
            isOpen = false
            request?.endAudio()
            request = nil
            if flushPCM, let pcm, let bytes = pcm.converter.finish(), !bytes.isEmpty { pcm.sink(bytes) }
        }
    }

    func replaceLocalRequest(_ next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock {
            guard isOpen else { return }
            request?.endAudio()
            request = next
        }
    }
}

/// Used only from the tap, under its lock. Retain the converter across buffers
/// to keep the resampling phase and send the hardware capture just once.
final class CompanionPCMResampler {
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter
    private var destination: AVAudioPCMBuffer?

    init?(input: AVAudioFormat) {
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ), let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.input = input
        self.output = output
        self.converter = converter
        converter.primeMethod = .none
    }

    func convert(_ source: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * output.sampleRate / input.sampleRate)) + 32
        if (destination?.frameCapacity ?? 0) < capacity {
            destination = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)
        }
        guard let destination else { return nil }
        var supplied = false
        return convert(into: destination) { _, state in
            guard !supplied else {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return source
        }
    }

    func finish() -> Data? {
        guard let destination else { return nil }
        return convert(into: destination) { _, state in
            state.pointee = .endOfStream
            return nil
        }
    }

    private func convert(into destination: AVAudioPCMBuffer, input: @escaping AVAudioConverterInputBlock) -> Data? {
        destination.frameLength = 0
        var error: NSError?
        let status = converter.convert(to: destination, error: &error, withInputFrom: input)
        guard status != .error, let samples = destination.int16ChannelData?.pointee else { return nil }
        return Data(bytes: samples, count: Int(destination.frameLength) * MemoryLayout<Int16>.size)
    }
}
