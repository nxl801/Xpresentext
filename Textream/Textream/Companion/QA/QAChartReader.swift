import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct QAChartValueBinding: Sendable, Hashable {
    let series: String
    let category: String
    let visibleValue: String
}

struct QAVisualCandidate: Sendable, Hashable {
    let id: String
    let title: String
    let kind: QAVisualEvidence.Kind
    let region: QARegion?
    let needsFullPage: Bool
    let needsOnlineAnalysis: Bool
    let externalLabelRegions: [QARegion]
    let nativeValues: [QAChartValueBinding]

    init(
        id: String,
        title: String,
        kind: QAVisualEvidence.Kind = .chart,
        region: QARegion? = nil,
        needsFullPage: Bool = false,
        needsOnlineAnalysis: Bool = true,
        externalLabelRegions: [QARegion] = [],
        nativeValues: [QAChartValueBinding] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.region = region
        self.needsFullPage = needsFullPage
        self.needsOnlineAnalysis = needsOnlineAnalysis
        self.externalLabelRegions = externalLabelRegions
        self.nativeValues = nativeValues
    }
}

struct QAChartPreparation: Sendable {
    enum OnlineStatus: Sendable, Equatable {
        case disabled, notNeeded, unavailable, read, ambiguous, failed(QAServiceError)

        var label: String {
            switch self {
            case .disabled: "已在本机识别"
            case .notNeeded: "已在本机识别"
            case .unavailable: "已在本机识别，在线读图暂不可用"
            case .read: "已核对可读标签"
            case .ambiguous: "部分读数无法确认，请查看原图"
            case .failed(let error): "已保留本机识别结果。\(error.localizedDescription)"
            }
        }
    }

    let evidence: [QAVisualEvidence]
    let onlineStatus: OnlineStatus
}

actor QAChartReader {
    private let cacheDirectory: URL
    private let model: (any QAModel)?
    private let modelID: String

    init(
        cacheDirectory: URL,
        model: (any QAModel)? = nil,
        modelID: String = GeminiQAModel.defaultModel
    ) {
        self.cacheDirectory = cacheDirectory
        self.model = model
        self.modelID = modelID
    }

    func cachedEvidence(
        projectID: UUID,
        revisionID: String,
        pageIndex: Int,
        onlineImageReadingEnabled: Bool,
        imageFingerprint: String? = nil,
        candidates: [QAVisualCandidate]? = nil
    ) -> [QAVisualEvidence] {
        let directory = pageDirectory(projectID: projectID, revisionID: revisionID, pageIndex: pageIndex)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let expected = imageFingerprint.flatMap { image in candidates.map { Set($0.map { Self.fingerprint(image, $0) }) } }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { url in
            guard let record = load(url), imageFingerprint == nil || record.imageFingerprint == imageFingerprint,
                  expected?.contains(record.fingerprint) ?? true
            else { return [QAVisualEvidence]() }
            return record.local + (
                onlineImageReadingEnabled && record.modelID == modelID ? record.online ?? [] : []
            )
        }
    }

    func prepare(
        projectID: UUID,
        revisionID: String,
        pageIndex: Int,
        imageData: Data,
        candidate: QAVisualCandidate,
        onlineImageReadingEnabled: Bool
    ) async throws -> QAChartPreparation {
        guard candidate.region?.isValid != false, !imageData.isEmpty, pageIndex >= 0
        else { throw QAServiceError.invalidResponse }

        let directory = pageDirectory(projectID: projectID, revisionID: revisionID, pageIndex: pageIndex)
        let url = directory.appendingPathComponent(Self.digest(Data(candidate.id.utf8))).appendingPathExtension("json")
        let imageDigest = Self.digest(imageData)
        let fingerprint = Self.fingerprint(imageDigest, candidate)
        let cached = load(url).flatMap { $0.fingerprint == fingerprint ? $0 : nil }
        let needsOnline = onlineImageReadingEnabled && candidate.needsOnlineAnalysis && candidate.region != nil && model != nil
        if let record = cached, !needsOnline || !record.requiresOnline || (record.modelID == modelID && record.online != nil) {
            return result(
                record, candidate: candidate, onlineEnabled: onlineImageReadingEnabled
            )
        }

        let image = try await Task.detached(priority: .utility) {
            try QAChartImage.prepare(
                imageData: imageData, candidate: candidate, encodeForOnline: needsOnline
            )
        }.value
        try Task.checkCancellation()
        var record = cached ?? CacheRecord(
            fingerprint: fingerprint, imageFingerprint: imageDigest, local: image.localEvidence,
            requiresOnline: image.requiresOnline, modelID: nil, online: nil, unresolved: false
        )
        if cached == nil { try save(record, at: url) }
        guard needsOnline, let model, let png = image.onlineImage
        else { return result(record, candidate: candidate, onlineEnabled: onlineImageReadingEnabled) }

        if let completed = load(url), completed.fingerprint == fingerprint,
           completed.modelID == modelID, completed.online != nil {
            return result(completed, candidate: candidate, onlineEnabled: onlineImageReadingEnabled)
        }
        do {
            let request = QAModelRequest(
                purpose: .chart,
                instructions: """
                Read the specified chart or table image. Extract only data values explicitly printed on a
                data mark or inside a table cell. Return JSON with keys readings (array) and unresolved
                (boolean). Each reading has series, category, value, and unit strings. Use verbatim visible
                labels and digits, and keep a printed value and its symbol together in value when possible.
                Use an empty unit when no separate unit is needed. Use an empty category only for a
                single displayed category, and an empty series only for a single unlabelled series.
                Include the value only if its association with the series and category is unambiguous.
                Never report any axis tick, estimated bar height, interpolated value, value implied by
                a similar color, or guessed label. If exact association or digits are unclear, omit the
                reading and set unresolved to true. Return only the JSON object, no Markdown.
                """,
                input: Self.chartTarget(candidate),
                image: QAModelRequest.Image(bytes: png, mimeType: "image/png"),
                maxOutputTokens: 1_800
            )
            let response = try await model.complete(request)
            try Task.checkCancellation()
            let output = try Self.decode(response)
            let checked = Self.verify(output, observations: image.observations, candidate: candidate)
            record.modelID = modelID
            record.online = checked.evidence
            record.unresolved = checked.unresolved
            if load(url)?.fingerprint == fingerprint { try save(record, at: url) }
            return result(record, candidate: candidate, onlineEnabled: onlineImageReadingEnabled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return QAChartPreparation(evidence: record.local, onlineStatus: .failed(error as? QAServiceError ?? .transport))
        }
    }

    private static func chartTarget(_ candidate: QAVisualCandidate) -> String {
        let title = "Target in the image: " + String(candidate.title.prefix(240))
        guard candidate.needsFullPage, let region = candidate.region else { return title }
        return title + """

        This is one page. The target chart has normalized top-left (\(region.x), \(region.y)),
        width \(region.width) and height \(region.height). Related labels can sit immediately
        outside the chart. Ignore numbers outside the target chart bounds.
        """
    }

    private static func fingerprint(_ image: String, _ candidate: QAVisualCandidate) -> String {
        var parts = [
            image, candidate.id, candidate.title, candidate.kind.rawValue,
            String(candidate.needsFullPage), String(candidate.needsOnlineAnalysis),
            String(candidate.externalLabelRegions.count), String(candidate.nativeValues.count)
        ]
        let regions = [candidate.region].compactMap { $0 } + candidate.externalLabelRegions
        for region in regions {
            parts.append(contentsOf: [region.x, region.y, region.width, region.height].map { String($0) })
        }
        for binding in candidate.nativeValues {
            parts.append(contentsOf: [binding.series, binding.category, binding.visibleValue])
        }
        return digest(Data(parts.joined(separator: "\u{0}").utf8))
    }

    private func result(
        _ record: CacheRecord,
        candidate: QAVisualCandidate,
        onlineEnabled: Bool
    ) -> QAChartPreparation {
        if !onlineEnabled { return QAChartPreparation(evidence: record.local, onlineStatus: .disabled) }
        if !candidate.needsOnlineAnalysis || !record.requiresOnline { return QAChartPreparation(evidence: record.local, onlineStatus: .notNeeded) }
        if record.modelID == modelID, let online = record.online {
            return QAChartPreparation(
                evidence: record.local + online,
                onlineStatus: record.unresolved || online.isEmpty ? .ambiguous : .read
            )
        }
        return QAChartPreparation(evidence: record.local, onlineStatus: .unavailable)
    }

    private struct CacheRecord: Codable, Sendable {
        let fingerprint: String
        let imageFingerprint: String
        let local: [QAVisualEvidence]
        let requiresOnline: Bool
        var modelID: String?
        var online: [QAVisualEvidence]?
        var unresolved: Bool
    }

    private func pageDirectory(projectID: UUID, revisionID: String, pageIndex: Int) -> URL {
        cacheDirectory.appendingPathComponent("4", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.digest(Data(revisionID.utf8)), isDirectory: true)
            .appendingPathComponent(String(pageIndex), isDirectory: true)
    }

    private func save(_ record: CacheRecord, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func load(_ url: URL) -> CacheRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheRecord.self, from: data)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct ModelReadings: Decodable, Sendable {
        struct Reading: Decodable, Sendable {
            let series: String
            let category: String
            let value: String
            let unit: String
        }

        let readings: [Reading]
        let unresolved: Bool
    }

    private static func decode(_ response: String) throws -> ModelReadings {
        let json = response.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
        guard let result = try? JSONDecoder().decode(ModelReadings.self, from: Data(json.utf8))
        else { throw QAServiceError.invalidResponse }
        return result
    }

    private static func verify(
        _ output: ModelReadings,
        observations: [QAChartImage.Observation],
        candidate: QAVisualCandidate
    ) -> (evidence: [QAVisualEvidence], unresolved: Bool) {
        let reliable = observations.filter { $0.confidence >= 0.5 }
        let anchor = candidate.region ?? QAChartImage.pageRegion
        let regionalSupport = candidate.externalLabelRegions
        let labelObservations = regionalSupport.isEmpty ? reliable : reliable.filter { observation in
            observation.region.isCentered(in: anchor) || regionalSupport.contains { observation.region.isCentered(in: $0) }
        }
        let recognizedText = labelObservations.map { QASearchText.normalized($0.text) }
        let valueObservations = reliable.filter { observation in
            observation.region.isCentered(in: anchor) && (
                candidate.kind != .chart || !Self.looksLikeAxisTick(observation, among: reliable, anchor: anchor)
            )
        }
        let recognizedNumbers = Set(valueObservations.flatMap { QASearchText.numericLiterals($0.text) })
        var seen: Set<String> = []
        var conflicting: Set<String> = []
        var valuesByLabel: [String: String] = [:]
        var verified: [(label: String, evidence: QAVisualEvidence)] = []
        var unresolved = output.unresolved || output.readings.isEmpty

        for (index, row) in output.readings.prefix(32).enumerated() {
            let series = row.series.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = row.category.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let unit = row.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            let labels = [series, category].filter { !$0.isEmpty }
            let valueLiterals = QASearchText.numericLiterals(value)
            let valueWithUnit = unit.isEmpty || value.contains(unit) ? value
                : value + (unit == "%" || unit == "‰" ? "" : " ") + unit
            let unitIsVisible = unit.isEmpty || value.contains(unit) || recognizedText.contains {
                Self.containsLabel(unit, in: $0)
            }

            guard !labels.isEmpty, labels.allSatisfy({ label in
                label.count <= 100 && recognizedText.contains { Self.containsLabel(label, in: $0) }
            }), value.count <= 24, unit.count <= 24, valueLiterals.count == 1,
                  value.wholeMatch(of: #/[+−–-]?\p{Nd}+(?:[.,]\p{Nd}+)*(?:\s*[%‰\p{L}]+)?/#) != nil,
                  valueLiterals.allSatisfy({ recognizedNumbers.contains($0) }), unitIsVisible
            else {
                unresolved = true
                continue
            }
            let label = QASearchText.normalized(series + "\u{0}" + category)
            if let previous = valuesByLabel[label], previous != valueWithUnit { conflicting.insert(label) }
            valuesByLabel[label] = valueWithUnit
            guard seen.insert(label + "\u{0}" + valueWithUnit).inserted else { continue }

            // An explicit same-line label/value pairing overrides a contrary generated pairing.
            let directlyPaired = valueObservations.filter { observation in
                QASearchText.numericLiterals(observation.text).contains(valueLiterals[0])
            }.map { QASearchText.normalized($0.text) }
            if !regionalSupport.isEmpty {
                let matchingRow = candidate.nativeValues.filter {
                    QASearchText.normalized($0.series) == QASearchText.normalized(series)
                }
                let categories = Set(matchingRow.map { QASearchText.normalized($0.category) })
                let hasNativePair = matchingRow.contains {
                    [value, valueWithUnit].map(QASearchText.normalized).contains(QASearchText.normalized($0.visibleValue))
                        && (category.isEmpty ? categories.count == 1 : QASearchText.normalized($0.category) == QASearchText.normalized(category))
                }
                let hasExplicitLine = directlyPaired.contains { line in labels.allSatisfy { Self.containsLabel($0, in: line) } }
                guard hasNativePair || (candidate.nativeValues.isEmpty && hasExplicitLine) else {
                    unresolved = true
                    continue
                }
            }
            let namedSeries = output.readings.map(\.series).filter { !$0.isEmpty && QASearchText.normalized($0) != QASearchText.normalized(series) }
            if !series.isEmpty && !directlyPaired.contains(where: { Self.containsLabel(series, in: $0) })
                && directlyPaired.contains(where: { line in
                    namedSeries.contains { Self.containsLabel($0, in: line) }
                }) {
                unresolved = true
                continue
            }
            let excerpt = ([candidate.title] + labels + [valueWithUnit]).filter { !$0.isEmpty }
                .joined(separator: " · ")
            verified.append((label, QAVisualEvidence(
                id: candidate.id + "-online-" + String(index),
                kind: candidate.kind,
                region: candidate.region ?? QAChartImage.pageRegion,
                text: excerpt
            )))
        }
        let resolved = verified.filter { !conflicting.contains($0.label) }.map(\.evidence)
        return (resolved, unresolved || !conflicting.isEmpty || output.readings.count > 32)
    }

    private static func looksLikeAxisTick(
        _ observation: QAChartImage.Observation,
        among others: [QAChartImage.Observation],
        anchor: QARegion
    ) -> Bool {
        let tick = #/^[+−–-]?\d+(?:[.,]\d+)*\s*[%‰]?$/#
        let label = QASearchText.normalized(observation.text)
        guard label.contains(tick) else { return false }
        let x = observation.region.x + observation.region.width / 2
        let y = observation.region.y + observation.region.height / 2
        let left = x <= anchor.x + 0.24 * anchor.width
        let bottom = y >= anchor.y + 0.72 * anchor.height
        guard left || bottom else { return false }

        let aligned = others.filter { other in
            guard other.region.isCentered(in: anchor),
                  QASearchText.normalized(other.text).contains(tick) else { return false }
            let otherX = other.region.x + other.region.width / 2
            let otherY = other.region.y + other.region.height / 2
            return (left && abs(otherX - x) <= 0.035 * anchor.width)
                || (bottom && abs(otherY - y) <= 0.035 * anchor.height)
        }
        return Set(aligned.map { QASearchText.normalized($0.text) }).count >= 3
    }

    private static func containsLabel(_ proposed: String, in observed: String) -> Bool {
        let label = QASearchText.normalized(proposed)
        if label == "%" || label == "‰" { return observed.contains(label) }
        guard let range = observed.range(of: label) else { return false }
        if QASearchText.containsHan(label) { return true }
        let previous = range.lowerBound == observed.startIndex
            ? nil : observed[observed.index(before: range.lowerBound)]
        let next = range.upperBound == observed.endIndex ? nil : observed[range.upperBound]
        return previous?.isLetter != true && previous?.isNumber != true
            && next?.isLetter != true && next?.isNumber != true
    }
}

private enum QAChartImage: Sendable {
    struct Observation: Sendable {
        let text: String
        let confidence: Float
        let region: QARegion
    }

    struct Prepared: Sendable {
        let localEvidence: [QAVisualEvidence]
        let observations: [Observation]
        let requiresOnline: Bool
        let onlineImage: Data?
    }

    static let pageRegion = QARegion(x: 0, y: 0, width: 1, height: 1)

    static func prepare(
        imageData: Data,
        candidate: QAVisualCandidate,
        encodeForOnline: Bool
    ) throws -> Prepared {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let page = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary)
        else { throw QAServiceError.invalidResponse }
        let anchor = candidate.region ?? pageRegion
        let crop = candidate.needsFullPage ? pageRegion : anchor
        let pixels = CGRect(
            x: crop.x * Double(page.width), y: crop.y * Double(page.height),
            width: crop.width * Double(page.width), height: crop.height * Double(page.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: page.width, height: page.height))
        guard !pixels.isEmpty, let image = page.cropping(to: pixels) else { throw QAServiceError.invalidResponse }
        let geometry = QARegion(
            x: pixels.minX / Double(page.width), y: pixels.minY / Double(page.height),
            width: pixels.width / Double(page.width), height: pixels.height / Double(page.height)
        )
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let observations: [Observation] = (request.results ?? []).compactMap { result in
            guard let text = result.topCandidates(1).first, text.confidence >= 0.28 else { return nil }
            let box = result.boundingBox
            return Observation(
                text: text.string, confidence: text.confidence,
                region: QARegion(
                    x: geometry.x + box.minX * geometry.width,
                    y: geometry.y + (1 - box.maxY) * geometry.height,
                    width: box.width * geometry.width, height: box.height * geometry.height
                )
            )
        }

        var local = observations.filter { observation in
            // Nearby labels can help online, while local chart excerpts stay inside their source region.
            observation.region.isCentered(in: anchor)
        }.prefix(64).enumerated().map { offset, observation in
            QAVisualEvidence(
                id: candidate.id + "-ocr-" + String(offset), kind: candidate.kind,
                region: candidate.kind == .imageText ? observation.region : anchor,
                text: [candidate.title, observation.text].filter { !$0.isEmpty }.joined(separator: " · "),
                exactNumericClaimsAllowed: false
            )
        }
        if local.isEmpty {
            local = [QAVisualEvidence(
                id: candidate.id + "-preview", kind: candidate.kind, region: anchor,
                text: candidate.title.isEmpty ? "Chart or image on this slide. Read the original labels in the preview."
                    : candidate.title + " · Read the original labels in the preview.",
                exactNumericClaimsAllowed: false
            )]
        }
        let requiresOnline = candidate.kind != .imageText || mayNeedImageAnalysis(candidate.title, observations: observations)
        return Prepared(
            localEvidence: local, observations: observations, requiresOnline: requiresOnline,
            onlineImage: encodeForOnline && requiresOnline ? try Self.png(image) : nil
        )
    }

    private static func mayNeedImageAnalysis(_ title: String, observations: [Observation]) -> Bool {
        let captions = QASearchText.normalized(([title] + observations.map(\.text)).joined(separator: " "))
        let visualSubject = #/\b(?:chart|figure|graph|plot|table|legend|diagram|workflow|architecture|schematic)\b|图表|示意图|流程图|表格|图例|架构图/#
        return captions.contains(visualSubject) || observations.reduce(into: 0) { count, observation in
            count += QASearchText.numericLiterals(observation.text).count
        } >= 2
    }

    private static func png(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { throw QAServiceError.invalidResponse }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 12_000_000 else {
            throw QAServiceError.invalidResponse
        }
        return output as Data
    }
}

private extension QARegion {
    func isCentered(in anchor: QARegion) -> Bool {
        (anchor.x...anchor.x + anchor.width).contains(x + width / 2)
            && (anchor.y...anchor.y + anchor.height).contains(y + height / 2)
    }
}
