import Foundation

struct DeckRegion: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum DeckImageKind: String, Sendable {
    case page
    case thumbnail
}

struct DeckSlideImage: Codable, Hashable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let fingerprint: String
}

struct DeckImageRepairSource: Codable, Hashable, Sendable {
    let filename: String
    let fingerprint: String
    let repairedAt: Date
}

struct DeckChartPoint: Codable, Hashable, Sendable {
    let category: String
    let value: String
    let displayValue: String?
}

struct DeckChartSeries: Codable, Hashable, Sendable {
    let name: String
    let points: [DeckChartPoint]
    let numberFormat: String?
}

struct DeckVisual: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case chart, table, picture
    }

    let id: String
    let kind: Kind
    let title: String
    var text: String
    let region: DeckRegion?
    var rows: [[String]] = []
    var series: [DeckChartSeries] = []
    var externalChartRegions: [DeckRegion]?
}

struct DeckDraftSource: Codable, Hashable, Sendable {
    let revisionID: String
    let pageNumber: Int
    let evidenceIDs: [String]
    let provider: String?
    let generatedAt: Date

    init(revisionID: String, pageNumber: Int, evidenceIDs: [String],
         provider: String? = nil, generatedAt: Date = Date()) {
        self.revisionID = revisionID
        self.pageNumber = pageNumber
        self.evidenceIDs = evidenceIDs
        self.provider = provider
        self.generatedAt = generatedAt
    }
}

struct DeckScript: Codable, Hashable, Sendable {
    enum Origin: String, Codable, Sendable {
        case empty, notes, speaker, ai
    }

    private(set) var text: String
    private(set) var origin: Origin
    private(set) var aiSource: DeckDraftSource?
    private(set) var aiConfirmed = false

    init(notes: String = "") {
        text = notes
        origin = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .notes
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    mutating func edit(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        if origin != .ai { origin = .speaker }
    }

    @discardableResult
    mutating func setAIDraft(_ text: String, source: DeckDraftSource) -> Bool {
        guard isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        self.text = text
        origin = .ai
        aiSource = source
        aiConfirmed = false
        return true
    }

    mutating func confirmAI() {
        if origin == .ai, !isEmpty { aiConfirmed = true }
    }
}

struct DeckSlide: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let pageNumber: Int
    let title: String
    let bodyText: String
    let originalNotes: String
    var script: DeckScript
    var isAppendix = false
    var image: DeckSlideImage?
    var visuals: [DeckVisual]
    var cueTargets: [DeckCueTarget]?
    var hasIndexedCueTargets: Bool {
        cueTargets?.contains(where: { $0.isSlideTitle != nil }) == true
    }

    var manualCueRegions: [String: DeckRegion]?
    let contentFingerprint: String
}

struct DeckRevisionReview: Codable, Hashable, Identifiable, Sendable {
    enum Reason: String, Codable, Sendable {
        case changed, ambiguous, removed
    }

    var id: String { oldRevisionID + ":" + oldSlide.id }
    let oldRevisionID: String
    let oldSlide: DeckSlide
    let candidatePageNumbers: [Int]
    let reason: Reason
}

struct DeckRevision: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let sourceName: String
    let importedAt: Date
    var slides: [DeckSlide]
    let appendixSuggestion: Int?
    var revisionReviews: [DeckRevisionReview] = []
    var renderWarning: String?
    var imageSetID: UUID?
    var imageGeometryVersion: Int?
    var imageRepairSource: DeckImageRepairSource?
    var chartContextVersion: Int?
    private var appendixHistory: [[Int]] = []

    init(id: String, sourceName: String, importedAt: Date = Date(), slides: [DeckSlide],
         appendixSuggestion: Int?, renderWarning: String? = nil) {
        self.id = id
        self.sourceName = sourceName
        self.importedAt = importedAt
        self.slides = slides
        self.appendixSuggestion = appendixSuggestion
        self.renderWarning = renderWarning
    }

    var bodySlides: [DeckSlide] { slides.filter { !$0.isAppendix } }
    var externalChartRegions: [String: [String: [DeckRegion]]] {
        Dictionary(uniqueKeysWithValues: slides.compactMap { slide in
            let links = slide.visuals.compactMap { visual -> (String, [DeckRegion])? in
                guard let regions = visual.externalChartRegions, !regions.isEmpty else { return nil }
                return (visual.id, regions)
            }
            return links.isEmpty ? nil : (slide.id, Dictionary(links, uniquingKeysWith: { first, _ in first }))
        })
    }
    var needsImageRepair: Bool { slides.contains { $0.image == nil } }
    var hasLegacyImageGeometry: Bool {
        imageGeometryVersion != DeckRenderer.imageGeometryVersion && slides.contains { $0.image != nil }
    }

    func nextBodySlide(after pageNumber: Int) -> DeckSlide? {
        slides.first { $0.pageNumber > pageNumber && !$0.isAppendix }
    }

    mutating func setAppendixStarting(at pageNumber: Int) {
        guard slides.contains(where: { $0.pageNumber == pageNumber }),
              slides.contains(where: { $0.pageNumber >= pageNumber && !$0.isAppendix }) else { return }
        rememberAppendix()
        for index in slides.indices where slides[index].pageNumber >= pageNumber {
            slides[index].isAppendix = true
        }
    }

    mutating func setAppendix(_ isAppendix: Bool, at pageNumber: Int) {
        guard let index = slides.firstIndex(where: { $0.pageNumber == pageNumber }),
              slides[index].isAppendix != isAppendix else { return }
        rememberAppendix()
        slides[index].isAppendix = isAppendix
    }

    @discardableResult
    mutating func undoAppendixChange() -> Bool {
        guard let previous = appendixHistory.popLast() else { return false }
        let marks = Set(previous)
        for index in slides.indices { slides[index].isAppendix = marks.contains(slides[index].pageNumber) }
        return true
    }

    var canUndoAppendixChange: Bool { !appendixHistory.isEmpty }

    private mutating func rememberAppendix() {
        appendixHistory.append(slides.filter(\.isAppendix).map(\.pageNumber))
    }

    mutating func carryPreparation(from old: DeckRevision) {
        let oldByFingerprint = Dictionary(grouping: old.slides, by: \.contentFingerprint)
        let newByFingerprint = Dictionary(grouping: slides, by: \.contentFingerprint)
        let newIndex = Dictionary(uniqueKeysWithValues: slides.indices.map { (slides[$0].pageNumber, $0) })
        for oldSlide in old.slides {
            let exactMatches = newByFingerprint[oldSlide.contentFingerprint] ?? []
            if oldByFingerprint[oldSlide.contentFingerprint]?.count == 1, exactMatches.count == 1,
               let page = exactMatches.first?.pageNumber, let index = newIndex[page] {
                slides[index].script = oldSlide.script
                slides[index].isAppendix = oldSlide.isAppendix
                continue
            }
            let nearby = slides.filter { slide in
                slide.id == oldSlide.id || (!slide.title.isEmpty && slide.title == oldSlide.title)
            }
            let candidates = exactMatches.isEmpty ? nearby : exactMatches
            let reason: DeckRevisionReview.Reason
            if !exactMatches.isEmpty || candidates.count > 1 {
                reason = .ambiguous
            } else {
                reason = candidates.isEmpty ? .removed : .changed
            }
            revisionReviews.append(DeckRevisionReview(oldRevisionID: old.id, oldSlide: oldSlide,
                                                       candidatePageNumbers: candidates.map(\.pageNumber), reason: reason))
        }
    }
}

struct DeckProject: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    private(set) var revisions: [DeckRevision]
    private(set) var activeRevisionID: String
    var onlineImageReadingEnabled = false
    var draftColorHex = "#FFA657"
    var cueColorHex = "#BB86FC"

    init(id: UUID = UUID(), name: String, revision: DeckRevision) {
        self.id = id
        self.name = name
        revisions = [revision]
        activeRevisionID = revision.id
    }

    var activeRevision: DeckRevision {
        // Imports, version selection and decoded manifests all validate this relationship.
        revisions.first { $0.id == activeRevisionID }!
    }

    @discardableResult
    mutating func selectRevision(id: String) -> Bool {
        guard revisions.contains(where: { $0.id == id }) else { return false }
        activeRevisionID = id
        return true
    }

    mutating func updateActiveRevision(_ update: (inout DeckRevision) -> Void) {
        guard let index = revisions.firstIndex(where: { $0.id == activeRevisionID }) else { return }
        update(&revisions[index])
    }

    mutating func addRevision(_ revision: DeckRevision) {
        if selectRevision(id: revision.id) { return }
        revisions.append(revision)
        activeRevisionID = revision.id
    }
}
