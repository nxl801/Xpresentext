import Foundation

extension StudioModelProvider {
    var liveTrialFlag: String {
        self == .grokCLI ? "--use-cli" : "--allow-keychain-access"
    }

    var evidenceTrialFilename: String {
        switch self {
        case .bigmodel, .zai: "\(rawValue)-glm-live-trial.json"
        case .deepseek, .gemini, .grokCLI: "\(rawValue)-live-trial.json"
        }
    }

    // The CLI manages its own login. API clients resolve their credential once
    // before the timed samples, so a Keychain prompt cannot affect latency.
    func makeLiveTrialClients() throws -> () -> any QAModel {
        if self == .grokCLI { return { self.client() } }
        let key = try StudioCredentials.apiKey(for: self)
        return { self.client(apiKeyProvider: { key }) }
    }
}
