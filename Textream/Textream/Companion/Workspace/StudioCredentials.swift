import Foundation
import Security

enum StudioModelProvider: String, CaseIterable, Identifiable, Sendable {
    case deepseek
    case grokCLI = "grok-cli"
    case bigmodel, zai, gemini

    var id: String { rawValue }
    var label: String {
        switch self {
        case .deepseek: return "DeepSeek V4.1 Flash"
        case .grokCLI: return "Grok CLI"
        case .bigmodel: return "GLM-5.3-Flash · 智谱国内标准 API"
        case .zai: return "GLM-5.3-Flash · Z.ai 国际"
        case .gemini: return "Gemini Flash · Google"
        }
    }
    var modelID: String {
        switch self {
        case .deepseek: DeepSeekQAModel.modelID
        case .grokCLI: GrokCLIQAModel.modelID
        case .bigmodel, .zai: GLMQAModel.modelID
        case .gemini: GeminiQAModel.defaultModel
        }
    }
    var cacheIdentifier: String {
        self == .gemini ? modelID : rawValue + "/" + modelID
    }
    nonisolated var usesAPIKey: Bool { self != .grokCLI }
    var supportsOnlineImages: Bool { self != .grokCLI || GrokCLIQAModel.supportsImages }

    func client() -> any QAModel {
        if self == .grokCLI { return GrokCLIQAModel() }
        return client(apiKeyProvider: { try StudioCredentials.apiKey(for: self) })
    }

    func client(apiKeyProvider: @escaping @Sendable () async throws -> String) -> any QAModel {
        switch self {
        case .deepseek:
            return DeepSeekQAModel(apiKeyProvider: apiKeyProvider)
        case .grokCLI:
            return GrokCLIQAModel()
        case .gemini:
            return GeminiQAModel(apiKeyProvider: apiKeyProvider)
        case .bigmodel, .zai:
            let url = self == .bigmodel ? GLMQAModel.chinaEndpoint : GLMQAModel.internationalEndpoint
            return GLMQAModel(endpoint: url, apiKeyProvider: apiKeyProvider)
        }
    }
}

nonisolated enum StudioCredentials {
    private static let preferencesDomain = "local.xpresentext.companion"
    static let bigmodelLegacyCodingPlanMarker = "studio.bigmodelLegacyIsCodingPlan"

    static var bigmodelLegacyIsCodingPlan: Bool {
        // The app and command-line clients consult the same domain.
        UserDefaults.standard.persistentDomain(forName: preferencesDomain)?[bigmodelLegacyCodingPlanMarker] as? Bool == true
    }

    private static func base(_ provider: StudioModelProvider, separateStandard: Bool) -> [String: Any] {
        let service = separateStandard ? "bigmodel-standard" : provider.rawValue
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "local.xpresentext.companion." + service,
                kSecAttrAccount as String: "api-key"]
    }

    static func hasSavedKey(for provider: StudioModelProvider) -> Bool? {
        guard provider.usesAPIKey else { return nil }
        // Matching the service and account needs no password data.
        let separateStandard = provider == .bigmodel && bigmodelLegacyIsCodingPlan
        switch SecItemCopyMatching(base(provider, separateStandard: separateStandard) as CFDictionary, nil) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: return nil
        }
    }

    static func apiKey(for provider: StudioModelProvider) throws -> String {
        guard provider.usesAPIKey else { throw cliLogin }
        let separateStandard = provider == .bigmodel && bigmodelLegacyIsCodingPlan
        var query = base(provider, separateStandard: separateStandard)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            // A process-scoped key supports local verification without writing it to disk.
            let names: [String]
            switch provider {
            case .grokCLI: throw cliLogin
            case .deepseek: names = ["DEEPSEEK_API_KEY"]
            case .bigmodel:
                names = separateStandard ? ["BIGMODEL_STANDARD_API_KEY"] : ["BIGMODEL_STANDARD_API_KEY", "BIGMODEL_API_KEY"]
            case .zai: names = ["ZAI_API_KEY"]
            case .gemini: names = ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
            }
            for name in names {
                if let key = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !key.isEmpty { return key }
            }
            throw provider == .bigmodel ? QAServiceError.missingBigmodelStandardCredentials : .missingCredentials
        }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw StudioError.message("无法读取钥匙串（\(status)）。")
        }
        return key
    }

    static func update(_ newKey: String, for provider: StudioModelProvider) throws {
        guard provider.usesAPIKey else { throw cliLogin }
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw StudioError.message("请输入密钥。") }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let separateStandard = provider == .bigmodel && bigmodelLegacyIsCodingPlan
        let base = base(provider, separateStandard: separateStandard)
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = base.merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
            }
        }
        if status == 100002 {
            throw StudioError.message("macOS 找不到正在运行的应用文件。请重新打开 Textream Studio，再保存密钥。")
        }
        guard status == errSecSuccess else { throw StudioError.message("无法保存密钥（\(status)）。") }
    }

    private static var cliLogin: StudioError {
        .message("Grok CLI 使用这台 Mac 上的本机登录。")
    }
}

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
