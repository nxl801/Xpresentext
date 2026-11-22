import Foundation
import ImageIO
import Vision

private struct Failure: Error, CustomStringConvertible { let description: String }

private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(description: message) }
}

private actor ImageRecorder: QAModel {
    private(set) var requests: [QAModelRequest] = []

    nonisolated func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { output in
            Task { await respond(request, output: output) }
        }
    }

    private func respond(_ request: QAModelRequest, output: AsyncThrowingStream<String, Error>.Continuation) {
        defer { output.finish() }
        guard request.purpose == .chart, request.image != nil else {
            output.finish(throwing: Failure(description: "Unexpected non-chart request"))
            return
        }
        requests.append(request)
        let full = request.input.contains("This is one page.")
        let rows = [
            ["series": "North", "category": "Pilot", "value": full ? "37" : "37%", "unit": full ? "%" : ""],
            ["series": "South", "category": "Pilot", "value": full ? "31" : "31%", "unit": full ? "%" : ""],
            ["series": "North", "category": "Pilot", "value": "99%", "unit": ""],
        ]
        if let reply = try? JSONSerialization.data(withJSONObject: ["readings": rows, "unresolved": false]) {
            output.yield(String(decoding: reply, as: UTF8.self))
        }
    }
}

@main @MainActor
private enum ChartRoutingCheck {
    static func main() async throws {
        let work = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let fixtures = work.appendingPathComponent("fixtures")
        let separate = ImageRecorder()
        let separatedStore = DeckStore(rootURL: work.appendingPathComponent("Separate"))
        let separateCache = work.appendingPathComponent("Separate chart cache")
        let separated = try await open(fixtures.appendingPathComponent("separate-legend.pptx"), store: separatedStore,
                                       cache: separateCache, model: separate)
        let separateProject = try await verify(separated, model: separate, cache: separateCache, full: true, output: output)

        let contained = ImageRecorder()
        let containedStore = DeckStore(rootURL: work.appendingPathComponent("Contained"))
        let containedCache = work.appendingPathComponent("Contained chart cache")
        let ordinary = try await open(fixtures.appendingPathComponent("self-contained-chart.pptx"), store: containedStore,
                                     cache: containedCache, model: contained)
        _ = try await verify(ordinary, model: contained, cache: containedCache, full: false, output: output)
        try await verifyOverlappingCharts(fixtures.appendingPathComponent("overlapping-charts.pptx"), root: work)
        try await verifyLegacy(separated, project: separateProject, store: separatedStore, cache: separateCache,
                               root: work, output: output)
    }

    private static func open(_ file: URL, store: DeckStore, cache: URL, model: ImageRecorder) async throws -> StudioWorkspace {
        let ws = StudioWorkspace(store: store, model: model, chartCacheDirectory: cache)
        ws.openURL(file)
        try await until("PPT import or initial local chart preparation did not complete") {
            ws.project != nil && ws.importing == nil && !ws.preparingCharts
        }
        try check(ws.project?.onlineImageReadingEnabled == false && ws.slides.count == 2, "The test PPT did not open offline with both pages")
        let requests = await model.requests
        try check(requests.isEmpty, "Opening a PPT with online read disabled sent an image")
        return ws
    }

    private static func verify(_ ws: StudioWorkspace, model: ImageRecorder, cache: URL,
                               full: Bool, output: URL) async throws -> DeckProject {
        guard let imported = ws.project, let slide = imported.activeRevision.slides.first,
              let chart = slide.visuals.first, let image = slide.image, let region = chart.region else {
            throw Failure(description: "Missing native chart or page image")
        }
        try check(!(chart.externalChartRegions ?? []).isEmpty == full, "Import misclassified the external chart context: \(chart)")
        ws.setOnlineImages(true)
        try await until("Online chart preparation did not finish") { !ws.preparingCharts }
        let requests = await model.requests
        try check(requests.count == 1, "Expected precisely one target image, got \(requests.count)")
        guard let request = requests.first, let bytes = request.image?.bytes else { throw Failure(description: "Missing chart request") }
        let transmitted = try inspect(bytes)
        if full {
            try check(transmitted.width == image.pixelWidth && transmitted.height == image.pixelHeight,
                      "External legend did not result in the relevant full page")
            for label in ["Legend", "Units", "Chart title", "99%"] {
                try check(transmitted.text.contains(label), "Full-page dispatch is missing \(label): \(transmitted.text)")
            }
        } else {
            try check(abs(transmitted.width - Int(region.width * Double(image.pixelWidth))) <= 2 &&
                      abs(transmitted.height - Int(region.height * Double(image.pixelHeight))) <= 2,
                      "Self-contained chart did not dispatch an exact chart crop")
            for label in ["Pilot adoption", "North", "South", "37%", "31%"] {
                try check(transmitted.text.contains(label), "Chart crop lost \(label): \(transmitted.text)")
            }
            try check(!transmitted.text.contains("99%"), "Unrelated page content entered the minimal crop")
        }
        try check(!transmitted.text.contains("77%") && !transmitted.text.contains("OTHER SLIDE"), "A different slide leaked into the request")
        try bytes.write(to: output.appendingPathComponent(full ? "dispersed-chart-full-page.png" : "self-contained-chart-crop.png"))
        let cacheReader = QAChartReader(cacheDirectory: cache, modelID: ws.provider.cacheIdentifier)
        let online = await cacheReader.cachedEvidence(projectID: imported.id, revisionID: imported.activeRevisionID,
                                                      pageIndex: 0, onlineImageReadingEnabled: true)
        let figures = online.filter(\.exactNumericClaimsAllowed).map(\.text)
        try check(figures.count == 2 && figures.contains { $0.contains("North") && $0.contains("37%") } &&
                  figures.contains { $0.contains("South") && $0.contains("31%") } && !figures.contains { $0.contains("99%") },
                  "Exact output included an unrelated number or lost a bound series: \(figures)")
        ws.setOnlineImages(false)
        try await until("Turning image reading off did not settle") { !ws.preparingCharts }
        let local = await cacheReader.cachedEvidence(projectID: imported.id, revisionID: imported.activeRevisionID,
                                                     pageIndex: 0, onlineImageReadingEnabled: false)
        let offRequests = await model.requests
        try check(offRequests.count == 1 && local.allSatisfy { !$0.exactNumericClaimsAllowed }, "Turning off disclosed images or retained online readings")
        ws.setOnlineImages(true)
        try await until("Restoring image reading did not settle") { !ws.preparingCharts }
        let cachedRequests = await model.requests
        try check(await ws.flushSave(), "Online setting did not save")
        try check(cachedRequests.count == 1, "Enabling again re-sent an unchanged image")
        print("PASS \(full ? "detached labels / one page" : "ordinary chart / minimal crop"): \(transmitted.width) × \(transmitted.height), 37%/31%, no 99% evidence, off/on cache")
        return try await ws.store.openProject(id: imported.id)
    }

    private static func verifyOverlappingCharts(_ fixture: URL, root: URL) async throws {
        let model = ImageRecorder()
        let store = DeckStore(rootURL: root.appendingPathComponent("Overlapping"))
        let cache = root.appendingPathComponent("Overlapping chart cache")
        let ws = try await open(fixture, store: store, cache: cache, model: model)
        guard let project = ws.project, let slide = ws.slides.first else { throw Failure(description: "No overlapping chart fixture") }
        try check(slide.visuals.count == 2 && slide.visuals.allSatisfy { $0.externalChartRegions?.isEmpty != false },
                  "A shared label was assigned to one of two competing charts")
        ws.setOnlineImages(true)
        try await until("Overlapping chart preparation did not finish") { !ws.preparingCharts }
        let requests = await model.requests
        let reader = QAChartReader(cacheDirectory: cache, modelID: ws.provider.cacheIdentifier)
        let cached = await reader.cachedEvidence(projectID: project.id, revisionID: project.activeRevisionID,
                                                  pageIndex: 0, onlineImageReadingEnabled: true)
        try check(requests.isEmpty && !cached.isEmpty && cached.allSatisfy { !$0.exactNumericClaimsAllowed },
                  "Overlapping charts were uploaded or treated as precise numeric evidence")
        try check(await ws.flushSave(), "Overlapping chart project did not save")
        print("PASS overlapping native charts: no upload or exact readings, local preview remains")
    }

    private static func verifyLegacy(_ workspace: StudioWorkspace, project: DeckProject, store: DeckStore,
                                     cache: URL, root: URL, output: URL) async throws {
        workspace.closeProject()
        var old = project
        old.updateActiveRevision { revision in
            revision.chartContextVersion = nil
            for index in revision.slides.indices {
                for visual in revision.slides[index].visuals.indices {
                    revision.slides[index].visuals[visual].externalChartRegions = nil
                }
            }
            revision.slides[0].script.edit("Keep my legacy preparation.")
            revision.setAppendix(true, at: 2)
        }
        try await store.save(old)
        let files = FileManager.default
        let newCache = cache.appendingPathComponent("4")
        let formerCache = cache.appendingPathComponent("3")
        try files.moveItem(at: newCache, to: formerCache)
        let obsolete = files.enumerator(at: formerCache, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        try check(!obsolete.isEmpty, "Legacy cache fixture not created")
        for file in obsolete {
            let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "37%", with: "99%")
            try Data(text.utf8).write(to: file)
        }
        let model = ImageRecorder()
        let reopened = StudioWorkspace(store: store, model: model, chartCacheDirectory: cache)
        reopened.openProject(old)
        try await until("Legacy deck did not reopen and prepare its chart") { reopened.project != nil && !reopened.preparingCharts }
        let recovered = await model.requests
        guard let full = recovered.first?.image?.bytes else { throw Failure(description: "Legacy deck was not re-routed from its stored source") }
        let dimensions = try inspect(full)
        try check(recovered.count == 1 && dimensions.width == old.activeRevision.slides[0].image?.pixelWidth,
                  "Legacy deck reused obsolete cache or did not recover the external legend")
        try check(reopened.project?.activeRevision.slides[0].script.text == "Keep my legacy preparation." &&
                  reopened.project?.activeRevision.slides[1].isAppendix == true,
                  "Rebuilding context disturbed existing preparation")
        try full.write(to: output.appendingPathComponent("legacy-reopened-page.png"))

        guard let managed = await store.sourceURL(projectID: old.id, revisionID: old.activeRevisionID) else {
            throw Failure(description: "Synthetic project source was unavailable before the fallback case")
        }
        try files.moveItem(at: managed, to: root.appendingPathComponent("temporarily removed synthetic source.pptx"))
        let fallbackModel = ImageRecorder()
        let missingSource = StudioWorkspace(store: store, model: fallbackModel, chartCacheDirectory: cache)
        guard let missingSlide = old.activeRevision.slides.first, let visual = missingSlide.visuals.first,
              let fingerprint = missingSlide.image?.fingerprint else { throw Failure(description: "No legacy chart preview") }
        let reader = QAChartReader(cacheDirectory: cache, modelID: missingSource.provider.cacheIdentifier)
        let cropCandidate = QAVisualCandidate(id: visual.id, title: visual.title, region: visual.region.map(QARegion.init(deck:)))
        let prefill = await reader.cachedEvidence(projectID: old.id, revisionID: old.activeRevisionID, pageIndex: 0,
                                                  onlineImageReadingEnabled: true, imageFingerprint: fingerprint,
                                                  candidates: [cropCandidate])
        try check(prefill.isEmpty, "The previous full-page evidence escaped before re-reading the crop")
        missingSource.openProject(old)
        try await until("Legacy project with missing original did not settle") { missingSource.project != nil && !missingSource.preparingCharts }
        let fallback = await fallbackModel.requests
        guard let crop = fallback.first?.image?.bytes else { throw Failure(description: "Missing source did not safely fall back to a chart crop") }
        let cropped = try inspect(crop)
        try check(fallback.count == 1 && cropped.width < dimensions.width && !cropped.text.contains("Legend") && !cropped.text.contains("99%"),
                  "Missing source sent the full page or unrelated content")
        let cached = await reader.cachedEvidence(projectID: old.id, revisionID: old.activeRevisionID,
                                                  pageIndex: 0, onlineImageReadingEnabled: true)
        try check(cached.allSatisfy { !$0.exactNumericClaimsAllowed }, "The formerly full-page result survived crop-only fallback")
        try crop.write(to: output.appendingPathComponent("legacy-missing-source-crop.png"))
        print("PASS old manifest with stored PPT rebuilt chart context and bypassed obsolete cache; missing PPT used crop; existing script and appendix stayed")
    }

    private static func inspect(_ png: Data) throws -> (width: Int, height: Int, text: String) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(description: "Invalid PNG") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return (image.width, image.height, text)
    }

    private static func until(_ description: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while !predicate() {
            try check(ContinuousClock.now < deadline, description)
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
