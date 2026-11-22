import Foundation

/// Normalized page coordinates measured from the upper-left corner.
struct QARegion: Sendable, Codable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var isValid: Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.000_001 && y + height <= 1.000_001
    }
}

struct QAVisualEvidence: Sendable, Codable, Hashable, Identifiable {
    enum Kind: String, Sendable, Codable {
        case chart, table, imageText
    }

    let id: String
    let kind: Kind
    let region: QARegion?
    let text: String
    let exactNumericClaimsAllowed: Bool

    init(id: String, kind: Kind, region: QARegion?, text: String, exactNumericClaimsAllowed: Bool = true) {
        self.id = id
        self.kind = kind
        self.region = region
        self.text = text
        self.exactNumericClaimsAllowed = exactNumericClaimsAllowed
    }
}

struct QAPage: Sendable, Equatable {
    let index: Int
    let title: String
    let bodyText: String
    let originalNotes: String
    let speakerScript: String?
    let aiDraft: String?
    let isAppendix: Bool
    let visualEvidence: [QAVisualEvidence]

    init(
        index: Int,
        title: String,
        bodyText: String,
        originalNotes: String,
        speakerScript: String? = nil,
        aiDraft: String? = nil,
        isAppendix: Bool = false,
        visualEvidence: [QAVisualEvidence] = []
    ) {
        self.index = index
        self.title = title
        self.bodyText = bodyText
        self.originalNotes = originalNotes
        self.speakerScript = speakerScript
        self.aiDraft = aiDraft
        self.isAppendix = isAppendix
        self.visualEvidence = visualEvidence
    }
}

struct QADeckSnapshot: Sendable, Equatable {
    let revisionID: String
    let pages: [QAPage]
    let projectID: UUID?

    init(revisionID: String, pages: [QAPage], projectID: UUID? = nil) {
        self.revisionID = revisionID
        self.pages = pages
        self.projectID = projectID
    }
}

struct QACitation: Sendable, Codable, Hashable, Identifiable {
    enum Kind: String, Sendable, Codable {
        case slideText, speakerNotes, speakerScript, chart, table, imageText

        var label: String {
            switch self {
            case .slideText: "胶片正文"
            case .speakerNotes: "演讲者备注"
            case .speakerScript: "演讲者讲稿"
            case .chart: "图表"
            case .table: "表格"
            case .imageText: "图片文字"
            }
        }
    }

    let id: String
    let revisionID: String
    let pageIndex: Int
    let pageTitle: String
    let excerpt: String
    let kind: Kind
    let region: QARegion?

    var pageNumber: Int { pageIndex + 1 }
}

struct QAAnswerPoint: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, Equatable {
        case grounded, missingEvidence, supplemental

        var label: String {
            switch self {
            case .grounded: "材料依据"
            case .missingEvidence: "证据缺口"
            case .supplemental: "补充说明"
            }
        }
    }

    let id = UUID()
    let text: String
    let kind: Kind
    let citations: [QACitation]
}

struct QAAnswer: Sendable, Equatable {
    var citations: [QACitation] = []
    var shortAnswerPoint: QAAnswerPoint?
    var bullets: [QAAnswerPoint] = []
    var details: [QAAnswerPoint] = []
    var firstSentenceElapsed: Duration?

    var shortAnswer: String? { shortAnswerPoint?.text }
}

enum QAServiceError: Error, Sendable, Equatable, LocalizedError {
    case missingCredentials
    case missingBigmodelStandardCredentials
    case missingGrokCLI
    case missingGrokLogin
    case grokCLIImagesUnsupported
    case grokCLIIsolationUnavailable
    case invalidModel
    case invalidResponse
    case insufficientDraftMaterial
    case rejectedConnection
    case httpStatus(Int)
    case transport
    case timeout

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "请在「模型与显示设置」中保存所选服务的 API 密钥。"
        case .missingBigmodelStandardCredentials: "请在「模型与显示设置」中保存智谱国内标准 API 密钥。Coding Plan 套餐密钥供智谱支持的工具使用。"
        case .missingGrokCLI: "未找到 Grok Build CLI。请先安装 Grok Build，再重新打开 Textream Studio。"
        case .missingGrokLogin: "Grok Build CLI 尚未登录或登录已失效。请在终端运行 ~/.grok/bin/grok login，再回到 Textream Studio 重试。"
        case .grokCLIImagesUnsupported: "Grok CLI 当前只接收文字。可使用本机图表证据，或手动选择支持读图的服务。"
        case .grokCLIIsolationUnavailable: "无法在隔离模式下启动 Grok CLI。请检查本机 Grok Build 安装与受管理配置，或选择其他模型。"
        case .invalidModel: "所选模型的设置不可用。"
        case .invalidResponse: "本题暂时没有可用回答，可以重试。"
        case .insufficientDraftMaterial: "这一页的材料不足，无法生成有依据的讲稿。"
        case .rejectedConnection: "无法连接所选模型服务，请检查网络后重试。"
        case .httpStatus(401), .httpStatus(403): "服务拒绝访问，请核对提供方、密钥和模型权限。"
        case .httpStatus(402): "模型服务报告可用余额不足，请核对该服务的账户余额。"
        case .httpStatus(429): "模型服务达到请求限额，请稍后重试。"
        case .httpStatus(404): "所选模型不可用，请检查模型设置。"
        case .httpStatus, .transport: "模型服务暂时不可用，可以重试。"
        case .timeout: "本题等待超时，可以重试。"
        }
    }
}
