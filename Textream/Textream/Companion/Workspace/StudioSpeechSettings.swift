import Security
import SwiftUI

enum StudioSpeechProvider: String, CaseIterable, Identifiable, Sendable {
    case paraformer, deepseek

    static let selectionPreference = "studio.speechProvider"
    static let workspacePreference = "studio.speechParaformerWorkspace"
    static let vocabularyPreference = "studio.speechParaformerVocabulary"
    static let segmentationPreference = "studio.speechParaformerSegmentation"
    static let fastEndPreference = "studio.speechFastQuestionEnd"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .paraformer: "阿里云 Paraformer · 北京实时"
        case .deepseek: "DeepSeek · 整题转写"
        }
    }

    static func defaultProvider() -> Self {
        let defaults = UserDefaults.standard
        let workspace = defaults.string(forKey: workspacePreference)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasDashScope = ParaformerCloudSpeech.endpoint(workspaceID: workspace) != nil && StudioSpeechCredentials.hasSavedKey
        if !hasDashScope, StudioCredentials.hasSavedKey(for: .deepseek) == true { return .deepseek }
        return .paraformer
    }

    static func configured(localeIdentifier: String) -> any CompanionCloudSpeech {
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: selectionPreference).flatMap(Self.init(rawValue:)) ?? defaultProvider()
        switch provider {
        case .paraformer:
            return ParaformerCloudSpeech(
                workspaceID: defaults.string(forKey: workspacePreference)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                localeIdentifier: localeIdentifier,
                vocabularyID: defaults.string(forKey: vocabularyPreference)?.trimmingCharacters(in: .whitespacesAndNewlines),
                segmentation: defaults.string(forKey: segmentationPreference).flatMap(ParaformerSegmentation.init(rawValue:)) ?? .pause,
                credential: { try StudioSpeechCredentials.apiKey() }
            )
        case .deepseek:
            return DeepSeekCloudSpeech(credential: { try StudioCredentials.apiKey(for: .deepseek) })
        }
    }
}

nonisolated enum StudioSpeechCredentials {
    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.xpresentext.companion.speech.paraformer",
         kSecAttrAccount as String: "api-key"]
    }

    static var hasSavedKey: Bool { SecItemCopyMatching(item as CFDictionary, nil) == errSecSuccess }

    static func apiKey() throws -> String {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound,
           let key = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty { return key }
        guard status == errSecSuccess, let bytes = result as? Data,
              let key = String(data: bytes, encoding: .utf8), !key.isEmpty
        else { throw CompanionCloudSpeechError.credential }
        return key
    }

    static func save(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 2_048, !key.contains(where: \.isNewline)
        else { throw StudioError.message("请输入百炼 API 密钥。") }
        let value = [kSecValueData as String: Data(key.utf8)]
        let query = item
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            let new = query.merging(value) { _, replacement in replacement }
            status = SecItemAdd(new as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, value as CFDictionary) }
        }
        guard status == errSecSuccess else { throw StudioError.message("无法保存语音密钥（\(status)）。") }
    }
}

struct StudioSpeechSettings: View {
    @AppStorage(StudioSpeechProvider.selectionPreference) private var provider = StudioSpeechProvider.defaultProvider()
    @AppStorage(StudioSpeechProvider.workspacePreference) private var workspace = ""
    @AppStorage(StudioSpeechProvider.vocabularyPreference) private var vocabulary = ""
    @AppStorage(StudioSpeechProvider.segmentationPreference) private var segmentation = ParaformerSegmentation.pause
    @AppStorage(StudioSpeechProvider.fastEndPreference) private var fastEnd = false
    @State private var expanded = false
    @State private var diagnosticsExpanded = false
    @State private var key = ""
    @State private var status = ""
    @State private var sampleResult = ""
    @State private var sampleTask: Task<Void, Never>?

    var body: some View {
        DisclosureGroup("在线语音转写", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("听题服务", selection: $provider) {
                    ForEach(StudioSpeechProvider.allCases) { Text($0.label).tag($0) }
                }
                Toggle("快速结束完整短题", isOn: $fastEnd)
                    .help("完整短题可较早提交。包含多段停顿的问题可关闭此选项。")
                if provider == .paraformer {
                    TextField("百炼北京工作空间 ID", text: $workspace)
                        .textFieldStyle(.roundedBorder)
                    TextField("热词列表 ID（可选）", text: $vocabulary)
                        .textFieldStyle(.roundedBorder)
                    Picker("云端断句", selection: $segmentation) {
                        ForEach(ParaformerSegmentation.allCases) { Text($0.label).tag($0) }
                    }
                    Text("只有本题选用在线语音时，才会边听题边发送音频。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("本题选择在线语音并结束收题后，上传这道题的完整录音。与 DeepSeek 问答共用钥匙串密钥。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SecureField(provider == .paraformer ? "百炼 API 密钥" : "DeepSeek API 密钥", text: $key)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存语音密钥") { save() }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                DisclosureGroup("开发验收", isExpanded: $diagnosticsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("此发行版不包含演示样音。真实麦克风听题与跟随功能不受影响。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                    .onDisappear { clearSample() }
                }
            }.padding(.top, 8)
            .onAppear { refresh() }
            .onDisappear { clearTransient() }
            .onChange(of: provider) { _, _ in
                clearTransient()
                refresh()
            }
        }
    }

    private func refresh() {
        let saved = provider == .paraformer ? StudioSpeechCredentials.hasSavedKey
            : StudioCredentials.hasSavedKey(for: .deepseek) == true
        status = saved ? "已保存到本机钥匙串。" : "此语音服务尚未保存密钥。"
    }

    private func compareSample() {
        sampleResult = ""
        let service = StudioSpeechProvider.configured(localeIdentifier: "zh-CN")
        sampleTask = Task { @MainActor in
            let result = await CompanionSpeechSample.compare(with: service)
            guard !Task.isCancelled else { return }
            sampleResult = result
            sampleTask = nil
        }
    }

    private func clearTransient() {
        key = ""
        clearSample()
    }

    private func clearSample() {
        sampleResult = ""
        sampleTask?.cancel()
        sampleTask = nil
    }

    private func save() {
        do {
            if provider == .paraformer { try StudioSpeechCredentials.save(key) }
            else { try StudioCredentials.update(key, for: .deepseek) }
            key = ""
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }
}

extension StudioWorkspace {
    func startSpokenQuestion(localeIdentifier: String, onlineSpeech: Bool = false, initialText: String = "",
                             onSubmit: @escaping (String) -> Void) {
        let provider = onlineSpeech ? StudioSpeechProvider.configured(localeIdentifier: localeIdentifier) : nil
        tracking.startQuestion(localeIdentifier: localeIdentifier, initialText: initialText,
                               onlineSpeech: provider, preferFastEnding: UserDefaults.standard.bool(forKey: StudioSpeechProvider.fastEndPreference),
                               onSubmit: onSubmit)
    }
}
