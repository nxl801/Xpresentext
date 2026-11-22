import SwiftUI

struct StudioEnglishFollowSample: View {
    let provider: StudioSpeechProvider
    let enabled: Bool

    @State private var results = ""
    @State private var running: Task<Void, Never>?

    var body: some View {
        Button(running == nil ? "用英文样音检查跟读" : "停止英文样音检查") {
            if running == nil { start() } else { cancel() }
        }
        .disabled(!enabled && running == nil)
        .help("只发送四段内置英语样音。使用同一套跟读规则，不打开麦克风。")
        .onChange(of: provider) { _, _ in
            cancel()
            results = ""
        }
        .onDisappear { cancel() }
        if !results.isEmpty {
            ScrollView {
                Text(results).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 175)
            .font(.caption)
        }
    }

    private func start() {
        results = "正在准备四段内置英语样音…"
        running = Task { @MainActor in
            guard let clips = try? CompanionEnglishFollowSample.load() else {
                results = "内置样音校验失败，未发送音频。"
                running = nil
                return
            }
            let choice = StudioSpeechProvider.configured(localeIdentifier: "en-US")
            let service = try? await choice.preauthorizedForSample()
            guard !Task.isCancelled else { return }
            var lines = [choice.sendsWhileListening
                ? "本机与在线均按实时速度送入文件。模拟高亮从送入第一块音频开始计。"
                : "在线服务在整段上传后返回。仅评位置和提交到返回的时间。本机按实时速度重放。"]
            results = lines.joined(separator: "\n")
            for clip in clips {
                guard !Task.isCancelled else { return }
                results = (lines + ["正在检查 \(clip.title)…"]).joined(separator: "\n")
                async let local = CompanionEnglishFollowSample.local(clip)
                async let online = compare(clip, with: service)
                let values = await (local, online)
                guard !Task.isCancelled else { return }
                lines += [
                    "",
                    "\(clip.title) · 预期\(clip.expected == nil ? "停留" : "高亮第 2 句")",
                    summarize(values.0, label: "本机", sourceDuration: clip.durationMs),
                    summarize(values.1, label: choice.name, sourceDuration: clip.durationMs),
                ]
                results = lines.joined(separator: "\n")
            }
            running = nil
        }
    }

    private func compare(_ clip: CompanionEnglishFollowSample.Clip, with service: (any CompanionCloudSpeech)?)
        async -> CompanionEnglishFollowSample.Result {
        guard let service else { return .unavailable("在线语音服务配置或密钥不可用。") }
        return await CompanionEnglishFollowSample.online(clip, provider: service)
    }

    private func summarize(_ result: CompanionEnglishFollowSample.Result, label: String, sourceDuration: Int) -> String {
        if let error = result.error, result.transcript.isEmpty { return "\(label) · \(error)" }
        let movement = result.decisions.isEmpty ? "停留" : result.decisions.map { "第 \($0 + 1) 句" }.joined(separator: " → ")
        let status = result.error ?? (result.passed ? "符合预期" : "未符合预期")
        var timing = ""
        if let highlight = result.firstCorrectAtMs {
            timing = "，\(highlight) ms 高亮（样音 \(sourceDuration) ms）"
        } else if let response = result.wholeRecordingResponseMs {
            timing = "，提交后 \(response) ms 返回"
        }
        return "\(label) · \(movement)，\(status)\(timing)\n\(result.transcript)"
    }

    private func cancel() {
        guard let running else { return }
        running.cancel()
        self.running = nil
        results += "\n已停止样音检查。"
    }
}
