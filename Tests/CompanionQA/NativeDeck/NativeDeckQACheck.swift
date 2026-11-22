import Foundation

@main
struct NativeDeckQACheck {
    private struct FixtureError: Error {}

    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(Data("Usage: run-native.sh FIXTURES OUTPUT_DIRECTORY\n".utf8))
            exit(2)
        }
        let fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let store = DeckStore(rootURL: work.appendingPathComponent("decks"))
        let reader = QAChartReader(cacheDirectory: work.appendingPathComponent("charts"))
        for (file, pageNumber, northValue) in [
            ("original", 8, "37%"), ("reordered", 10, "37%"), ("changed", 10, "29%")
        ] {
            let project = try await store.importDeck(from: fixtureDirectory.appendingPathComponent(file + ".pptx"))
            let revision = project.activeRevision
            let slide = revision.slides[pageNumber - 1]
            guard let visual = slide.visuals.first(where: { $0.kind == .chart }),
                  let region = visual.region,
                  let page = try await store.imageData(projectID: project.id, revisionID: revision.id, pageNumber: pageNumber)
            else { throw FixtureError() }
            let snapshot = QADeckSnapshot(
                revisionID: revision.id,
                pages: revision.slides.enumerated().map { index, slide in pageMaterial(index, slide: slide) },
                projectID: project.id
            )
            let hits = QADeckIndex(snapshot).search("What was the North adoption percentage?", focusPageIndex: 11)
            guard let citation = hits.first(where: {
                $0.citation.kind == .chart && $0.citation.excerpt.contains("North") && $0.citation.excerpt.contains(northValue)
            })?.citation,
                  citation.pageNumber == pageNumber, citation.revisionID == revision.id, citation.region == QARegion(region)
            else { throw FixtureError() }
            let local = try await reader.prepare(
                projectID: project.id, revisionID: revision.id, pageIndex: pageNumber - 1,
                imageData: page, candidate: QAVisualCandidate(id: visual.id, title: visual.title, region: QARegion(region)),
                onlineImageReadingEnabled: false
            )
            guard local.evidence.contains(where: { $0.text.contains(northValue) }),
                  local.evidence.contains(where: { $0.text.contains("31%") }),
                  local.evidence.contains(where: { $0.text.contains("North") }),
                  local.evidence.contains(where: { $0.text.contains("South") }),
                  let crop = try await store.imageData(
                    projectID: project.id, revisionID: revision.id, pageNumber: pageNumber, region: region
                  )
            else { throw FixtureError() }
            try crop.write(to: output.appendingPathComponent("powerpoint-chart-" + file + ".png"), options: .atomic)
            print("PASS native PowerPoint \(file): page \(pageNumber), \(citation.excerpt), Vision saw \(northValue) and 31%, region verified")

            if file == "original" {
                let tableHits = QADeckIndex(snapshot).search("What were the Delta verified units?", focusPageIndex: 0)
                guard tableHits.contains(where: {
                    $0.citation.kind == .table && $0.citation.pageNumber == 10 && $0.citation.excerpt.contains("42")
                }) else { throw FixtureError() }
                print("PASS native PowerPoint table: page 10, Delta 42, table evidence")
            }
        }
    }

    private static func pageMaterial(_ index: Int, slide: DeckSlide) -> QAPage {
        QAPage(
            index: index, title: slide.title, bodyText: slide.bodyText, originalNotes: slide.originalNotes,
            visualEvidence: slide.visuals.compactMap { visual in
                guard !visual.text.isEmpty else { return nil }
                let kind: QAVisualEvidence.Kind
                switch visual.kind {
                case .chart: kind = .chart
                case .table: kind = .table
                case .picture: kind = .imageText
                }
                return QAVisualEvidence(
                    id: visual.id, kind: kind, region: visual.region.map(QARegion.init),
                    text: visual.text, exactNumericClaimsAllowed: kind != .imageText
                )
            }
        )
    }
}

private extension QARegion {
    init(_ deck: DeckRegion) {
        self.init(x: deck.x, y: deck.y, width: deck.width, height: deck.height)
    }
}
