import Foundation
import AVFoundation

@MainActor
final class MurmurySpeechInput: CompanionSpeechInput {
    private let source: String
    private var helper: MurmuryProcess?
    private var pending: Task<Void, Never>?
    private var firstBufferTimeout: Task<Void, Never>?
    enum ModelStage { case downloading, loading, loaded }
    var onStage: ((ModelStage) -> Void)?
    var onStatus: ((String) -> Void)?

    init(source: String = "mic") { self.source = source }

    func start(localeIdentifier: String, reportLevel: Bool,
               onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void) {
        cancel()
        onStatus?("正在启动 Whisper Turbo")
        pending = Task { [weak self] in
            guard let self else { return }
            if source == "mic" {
                let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
                let permitted: Bool
                if authorization == .notDetermined {
                    onStatus?("等待麦克风授权 · 请在 macOS 提示中点「允许」")
                    permitted = await AVCaptureDevice.requestAccess(for: .audio)
                } else {
                    permitted = authorization == .authorized
                }
                guard !Task.isCancelled else { return }
                guard permitted else {
                    onEvent(.failure("请在「系统设置 → 隐私与安全性 → 麦克风」中允许 Xpresentext，然后重新开始跟读。", canRestart: false))
                    return
                }
                onStatus?("正在启动 Whisper Turbo")
            }
            guard !Task.isCancelled else { return }
            do {
                var reportedError = false
                helper = try MurmuryProcess(script: "speech", arguments: [source, localeIdentifier],
                    receive: { [weak self] event in
                        switch event["type"] as? String {
                        case "status":
                            if let stage = event["stage"] as? String {
                                self?.onStage?(stage == "downloading" ? .downloading : .loading)
                            }
                            self?.onStatus?(event["message"] as? String ?? "")
                        case "modelLoaded":
                            self?.onStage?(.loaded)
                            guard self?.source == "mic" else { break }
                            self?.onStatus?("Whisper 已加载，正在打开麦克风")
                            self?.firstBufferTimeout = Task { @MainActor [weak self] in
                                try? await Task.sleep(for: .seconds(10))
                                guard !Task.isCancelled, let self else { return }
                                self.cancel()
                                onEvent(.failure("麦克风没有返回音频。请检查 macOS「声音 → 输入」中选用的设备，再开始跟读。", canRestart: false))
                            }
                        case "ready":
                            self?.firstBufferTimeout?.cancel()
                            self?.onStage?(.loaded)
                            self?.onStatus?("")
                            onEvent(.started)
                        case "level":
                            if let rms = event["rms"] as? Double {
                                onEvent(.level(CGFloat(rms), at: ProcessInfo.processInfo.systemUptime))
                            }
                        case "transcript":
                            if let text = event["text"] as? String { onEvent(.transcript(text, isFinal: event["final"] as? Bool == true)) }
                        case "error":
                            reportedError = true
                            onEvent(.failure(event["message"] as? String ?? "Whisper 无法收音。", canRestart: false))
                        default: break
                        }
                    }, closed: { _ in
                        if !reportedError { onEvent(.failure("Whisper 已停止。可重新开始或选择 Apple 本机跟读。", canRestart: false)) }
                    })
            } catch { onEvent(.failure("本构建缺少 Whisper 运行组件。可选择 Apple 本机跟读。", canRestart: false)) }
        }
    }

    func finish() { cancel() }

    func cancel() {
        firstBufferTimeout?.cancel()
        firstBufferTimeout = nil
        pending?.cancel()
        pending = nil
        helper?.stop()
        helper = nil
    }
}
