import Foundation

nonisolated enum DeckImportError: LocalizedError {
    case unsupportedFormat
    case emptyPresentation
    case invalidPackage(String)
    case missingProject
    case invalidProject
    case saveConflict
    case missingRenderer
    case renderFailed
    case renderMessage(String)
    case imagePageCount(expected: Int, actual: Int)
    case imageAspectRatio(page: Int)
    case imageOrderMismatch(page: Int)
    case imageSourceUnavailable
    case imageRepairUnavailable
    case imageVersionUnverified

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "请选择 PowerPoint 的 .pptx 文件。"
        case .emptyPresentation: return "PPT 没有可导入的胶片。"
        case .invalidPackage(let part): return "无法读取 PPT 中的 \(part)。"
        case .missingProject: return "找不到这份备稿。"
        case .invalidProject: return "备稿文件无法读取。"
        case .saveConflict: return "备稿已被另一次操作更新。请重新打开后编辑。"
        case .missingRenderer: return "没有找到用于生成胶片图的 LibreOffice。可以从 PowerPoint 导出 PDF 后重试。"
        case .renderFailed: return "胶片图生成失败。可以从 PowerPoint 导出 PDF 后重试。"
        case .renderMessage(let message): return message
        case .imagePageCount(let expected, let actual): return "PPT 有 \(expected) 页，生成的 PDF 有 \(actual) 页。请导出包含隐藏胶片的完整 PDF。"
        case .imageAspectRatio(let page): return "第 \(page) 页的 PDF 尺寸与 PPT 不一致。请按胶片导出完整 PDF。"
        case .imageOrderMismatch(let page): return "PDF 第 \(page) 页与 PPT 页序不符。请从这一版 PPT 重新导出完整 PDF。"
        case .imageSourceUnavailable: return "当前版的原 PPT 无法核对。请先重新打开该版的原 PPT。"
        case .imageRepairUnavailable: return "当前版本已有完整页面图，或已切换到其他版本。"
        case .imageVersionUnverified: return "PDF 的胶片文字与当前版无法对上。请从这一版 PPT 导出完整 PDF。"
        }
    }
}
