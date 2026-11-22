import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit
import Vision

private struct CheckFailure: Error, CustomStringConvertible {
    var description: String
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

@main
struct DeckAcceptance {
    private static func checkCueTargets() throws {
        let upper = DeckCueTarget(text: "Bright orchard gate", region: DeckRegion(x: 0.53, y: 0.28, width: 0.35, height: 0.075))
        let lower = DeckCueTarget(text: "Narrow garden path", region: DeckRegion(x: 0.53, y: 0.52, width: 0.35, height: 0.075))
        let targets = [lower, upper]
        func resolve(_ cue: String, _ context: String) -> DeckRegion? { DeckCueTarget.resolve(cue, context: context, among: targets) }
        try expect(resolve("point to the first box", "The bright gate opens here.") == upper.region &&
                   resolve("指向第二个方框", "We follow this narrow garden path.") == lower.region, "Reading order followed XML order")
        try expect(resolve("point to the first box", "We follow this narrow garden path.") == nil &&
                   resolve("point to the second box", "Look here.") == nil, "Ambiguous or conflicting action produced a box")
        try expect(resolve("指向“orchard gate”", "") == upper.region, "Unique quoted label did not resolve")
        let duplicate = DeckCueTarget(text: upper.text, region: lower.region)
        try expect(DeckCueTarget.resolve("point to the first box", context: upper.text, among: [upper, duplicate]) == nil &&
                   DeckCueTarget.resolve("指向“orchard gate”", context: "", among: [upper, duplicate]) == nil,
                   "Tied candidates or duplicate quoted labels selected an arbitrary object")
        let col1 = DeckCueTarget(text: "Alpha", region: upper.region, bulletItems: ["Alpha"])
        let col2 = DeckCueTarget(text: "Beta", region: lower.region, bulletItems: ["Beta"])
        let recovered = DeckCueTarget(text: "Alpha", region: upper.region, itemNumber: 1)
        try expect(DeckCueTarget.resolve("第一个点", context: "", among: [col1, col2, recovered]) == nil,
                   "Only recognizing one of two lists resolved an ambiguous ordinal")
        let list = DeckCueTarget(text: "1. Bright orchard gate\n2. Narrow garden path", region: upper.region)
        try expect(DeckCueTarget.resolve("指向第一个点", context: "Bright orchard gate", among: [list]) == nil,
                   "A single paragraph action outlined an entire list")
        let first = DeckCueTarget(text: "1. Bright orchard gate", region: upper.region)
        try expect(DeckCueTarget.resolve("指向第一个点", context: "", among: [first, lower]) == upper.region,
                   "A unique numbered text object did not resolve")
    }

    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("DeckAcceptance-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try checkCueTargets()
        let store = DeckStore(rootURL: work)
        let slideNotes = try await store.importDeck(from: folder.appendingPathComponent("notes.pptx"))
        let notes = slideNotes.activeRevision
        try expect(notes.slides.map(\.title) == ["Title 1", "Title 2 - hidden", "Title 3", "Title 4"], "PPT relationship order changed")
        try expect(notes.slides.map(\.pageNumber) == [1, 2, 3, 4], "Original slide numbering lost")
        try expect(notes.slides[1].originalNotes.isEmpty && notes.slides[1].script.origin == .empty, "Missing notes collapsed slide order")
        try expect(notes.slides[2].originalNotes == "关键点一\n\n关键点二\n[指向图表]\nKeep going.", "Newlines or Chinese notes changed")
        try expect(notes.slides[3].originalNotes == "0", "Numeric speaker note lost, or system page number retained")
        try expect(notes.slides[2].bodyText.contains("Local rendering fixture link"), "Visible body text missing")
        try expect(notes.renderWarning == nil, notes.renderWarning ?? "Missing slide render")
        try expect(Set(notes.slides.compactMap { $0.image?.fingerprint }).count == 4, "Images are missing or duplicated")
        for slide in notes.slides {
            let page = try await store.imageData(projectID: slideNotes.id, revisionID: notes.id, pageNumber: slide.pageNumber)
            let thumb = try await store.imageData(projectID: slideNotes.id, revisionID: notes.id,
                                                  pageNumber: slide.pageNumber, kind: .thumbnail)
            let fullImage = page.flatMap(cgImage)
            let thumbImage = thumb.flatMap(cgImage)
            try expect(fullImage?.width == 2048 && thumbImage?.width == 384, "Rendered page or thumbnail could not be opened")
            let pageTitle = "Title \(slide.pageNumber)"
            try expect(fullImage.map(recognize).map { $0.contains(pageTitle) } == true, "Rendered page does not match its PPT page")
            if slide.pageNumber == 1 {
                try expect(fullImage.map(cornerIsGreen) == true && thumbImage.map(cornerIsGreen) == true,
                           "Full-page or thumbnail raster did not fill its canvas")
            }
        }
        let itemSlide = notes.slides[3]
        let shapes = itemSlide.cueTargets ?? []
        let items = try await store.bulletTargets(projectID: slideNotes.id, revisionID: notes.id, slide: itemSlide, targets: shapes)
        let firstItem = DeckCueTarget.resolve("第一个点", context: "", among: shapes + items)
        let secondItem = DeckCueTarget.resolve("point to the second bullet", context: "", among: shapes + items)
        try expect(items.count == 2 && firstItem != nil && secondItem != nil &&
                   firstItem!.y + firstItem!.height <= secondItem!.y + 0.002, "Native bullet OCR failed to locate two separate rows")
        print("PASS pointing cues: unique native bullet rows in the rendered slide")
        var legacy = slideNotes
        legacy.updateActiveRevision {
            $0.imageGeometryVersion = nil
            $0.slides[0].script.edit("Keep the existing preparation after image refresh.")
        }
        try await store.save(legacy)
        let migrated = try await store.refreshImageGeometry(projectID: legacy.id)
        try expect(migrated.activeRevisionID == legacy.activeRevisionID && !migrated.activeRevision.hasLegacyImageGeometry &&
                   migrated.activeRevision.imageSetID != legacy.activeRevision.imageSetID &&
                   migrated.activeRevision.slides[0].script == legacy.activeRevision.slides[0].script,
                   "Geometry refresh changed the deck version or removed speaker edits")

        var blank = try await store.importDeck(from: folder.appendingPathComponent("no-notes.pptx"))
        try expect(blank.activeRevision.slides.allSatisfy { $0.originalNotes.isEmpty && $0.image != nil }, "All-empty deck not usable")
        try expect(blank.activeRevision.appendixSuggestion == nil && blank.activeRevision.bodySlides.count == 3,
                   "Trailing empty notes inferred as appendix")
        blank.updateActiveRevision { rev in rev.setAppendixStarting(at: 2); rev.setAppendix(false, at: 3) }
        try expect(blank.activeRevision.bodySlides.map(\.pageNumber) == [1, 3], "Single-page appendix override failed")
        try expect(blank.activeRevision.nextBodySlide(after: 1)?.pageNumber == 3 && blank.activeRevision.nextBodySlide(after: 3) == nil,
                   "Body navigation did not skip appendix or stop on last body page")
        try await store.save(blank)
        blank = try await DeckStore(rootURL: work).openProject(id: blank.id)
        try expect(blank.activeRevision.slides[1].isAppendix, "Appendix mark did not survive reopening")
        blank.updateActiveRevision { rev in _ = rev.undoAppendixChange(); _ = rev.undoAppendixChange() }
        try expect(blank.activeRevision.bodySlides.count == 3, "Appendix undo did not return the original order")
        try await store.save(blank)
        let explicitSection = try await store.importDeck(from: folder.appendingPathComponent("section.pptx"))
        try expect(explicitSection.activeRevision.appendixSuggestion == 2 && explicitSection.activeRevision.bodySlides.count == 3,
                   "PowerPoint section did not suggest appendix without enabling it")
        try await checkPDFFallback(folder: folder, work: work)
        try await checkRepeatedTitlePDFReplacement(folder: folder, work: work, store: store)

        let originalURL = folder.appendingPathComponent("original.pptx")
        var original = try await store.importDeck(from: originalURL)
        let originalID = original.activeRevisionID
        try expect(original.activeRevision.appendixSuggestion == 9 && original.activeRevision.bodySlides.count == 10,
                   "Explicit divider did not suggest appendix without enabling it")
        guard let chart = original.activeRevision.slides[7].visuals.first(where: { $0.kind == .chart }),
              let region = chart.region else { throw CheckFailure(description: "Native chart not extracted") }
        try expect(chart.series.map(\.name) == ["North", "South"], "Chart series order and labels missing")
        try expect(chart.text.contains("North | Pilot | 37%") && chart.text.contains("South | Pilot | 31%"),
                   "Visible values not paired with the correct chart data series")
        let chartPixels = try await store.imageData(projectID: original.id, revisionID: originalID, pageNumber: 8, region: region)
        let crop = chartPixels.flatMap(cgImage)
        try expect(crop.map { $0.width < 2048 && $0.height > 750 } == true, "Chart crop is not correctly sized")
        let chartWords = crop.map(recognize) ?? ""
        try expect(chartWords.contains("North") && chartWords.contains("South") && chartWords.contains("37%") && chartWords.contains("31%"),
                   "Rendered chart crop lost series, legend or visible values")
        let visuals = original.activeRevision.slides[9].visuals
        try expect(visuals.first(where: { $0.kind == .table })?.rows == [["Series", "Verified units"], ["Delta", "42"]],
                   "Native table rows not extracted")
        try expect(visuals.first(where: { $0.kind == .picture })?.text.contains("SCREENSHOT DATA") == true,
                   "Local image text not recognized")
        let source = DeckDraftSource(revisionID: originalID, pageNumber: 8, evidenceIDs: [chart.id], provider: "Fixture")
        original.updateActiveRevision { revision in
            _ = revision.slides[7].script.setAIDraft("Open the chart. [Point left]", source: source)
            revision.slides[7].script.edit("Look at the pilot. [Point left]")
            revision.slides[7].script.confirmAI()
            revision.slides[2].script.edit("Edited speaker note")
            revision.setAppendix(true, at: 8)
            revision.setAppendixStarting(at: 9)
        }
        original.onlineImageReadingEnabled = true
        original.cueColorHex = "#9344CC"
        original.draftColorHex = "#CD0220"
        try await store.save(original)
        let beforeRevision = try await store.openProject(id: original.id)
        try expect(beforeRevision == original, "Draft metadata, user settings or script edits did not persist")
        let copied = await store.sourceURL(projectID: original.id, revisionID: originalID)
        try expect(copied.flatMap { try? Data(contentsOf: $0) } == (try Data(contentsOf: originalURL)), "Stored original source differs")
        let malformed = folder.appendingPathComponent("corrupt.pptx")
        try Data("not a pptx".utf8).write(to: malformed)
        defer { try? FileManager.default.removeItem(at: malformed) }
        do {
            _ = try await store.importDeck(from: malformed, replacing: original)
            throw CheckFailure(description: "Invalid replacement was accepted")
        } catch is DeckImportError {}
        let afterFailed = try await store.openProject(id: original.id)
        try expect(afterFailed == original, "Invalid replacement modified accepted project")

        let reorderURL = folder.appendingPathComponent("reordered.pptx")
        var moved = try await store.importDeck(from: reorderURL, replacing: original)
        let movedID = moved.activeRevisionID
        let movedSlide = moved.activeRevision.slides[9]
        try expect(movedSlide.id == original.activeRevision.slides[7].id && movedSlide.pageNumber == 10,
                   "Content and its page did not move together")
        try expect(movedSlide.isAppendix && movedSlide.script.text == "Look at the pilot. [Point left]" &&
                   movedSlide.script.aiConfirmed && movedSlide.script.origin == .ai && movedSlide.script.aiSource == source,
                   "Preparation or AI provenance lost on clearly matched repagination")
        try expect(moved.activeRevision.slides[2].script.text == "Edited speaker note", "Speaker edit not preserved")
        try expect(moved.onlineImageReadingEnabled, "Project image preference not carried forward")
        moved.updateActiveRevision { $0.slides[9].script.edit("Reviewed next revision. [Point left]") }
        try await store.save(moved)
        let reopened = try await store.importDeck(from: reorderURL, replacing: moved)
        try expect(reopened == moved, "Repeated import overwrote verified revision edits")
        let newChart = reopened.activeRevision.slides[9].visuals.first { $0.kind == .chart }
        let newImage = try await store.imageData(projectID: original.id, revisionID: movedID, pageNumber: 10,
                                                  region: newChart?.region)
        try expect(newImage == chartPixels, "Matched visual not found at its new page")

        let changed = try await store.importDeck(from: folder.appendingPathComponent("changed.pptx"), replacing: moved)
        try expect(changed.activeRevision.slides[9].script.isEmpty && !changed.activeRevision.slides[9].isAppendix,
                   "Old draft or mark transferred across a chart content change")
        try expect(changed.activeRevision.slides[9].visuals.first?.text.contains("North | Pilot | 29%") == true &&
                   changed.activeRevision.slides[9].visuals.first?.text.contains("37%") == false,
                   "Revision visual evidence used old chart values")
        let changedChart = try await store.imageData(projectID: original.id, revisionID: changed.activeRevisionID,
                                                      pageNumber: 10, region: region)
        let changedChartWords = changedChart.flatMap(cgImage).map(recognize) ?? ""
        try expect(changedChartWords.contains("29%") && !changedChartWords.contains("37%"),
                   "Rerendered chart still displays the old value")
        try expect(changed.activeRevision.revisionReviews.contains { $0.oldSlide.pageNumber == 10 && $0.reason == .changed && $0.candidatePageNumbers == [10] },
                   "Changed chart preparation was not retained for review")
        try expect(changed.activeRevision.revisionReviews.contains { $0.oldSlide.pageNumber == 11 && $0.reason == .removed },
                   "Removed slide was not retained for review")
        let unchangedChart = try await store.imageData(projectID: original.id, revisionID: originalID, pageNumber: 8, region: region)
        try expect(unchangedChart == chartPixels, "Historical source image lost across revision")
        var comparison = changed
        _ = comparison.selectRevision(id: movedID)
        try await store.save(comparison)
        let ambiguous = try await store.importDeck(from: folder.appendingPathComponent("ambiguous.pptx"), replacing: comparison)
        try expect(ambiguous.activeRevision.slides[9].script.isEmpty && ambiguous.activeRevision.slides[12].script.isEmpty,
                   "Ambiguous copy inherited speaker preparation")
        try expect(ambiguous.activeRevision.revisionReviews.contains {
            $0.reason == .ambiguous && $0.oldSlide.pageNumber == 10 && $0.candidatePageNumbers == [10, 13]
        }, "Ambiguous candidates not available for review")
        try expect(ambiguous.revisions.count == 4, "Historical versions not retained")
        do {
            try await store.save(moved)
            throw CheckFailure(description: "Stale historical snapshot overwrote new revisions")
        } catch DeckImportError.saveConflict {}
        print("PASS • real PPTX relationship order, notes, hidden slide render, appendix, visual crops, persistence, and revision review")
    }

    private static func checkPDFFallback(folder: URL, work: URL) async throws {
        let path = folder.appendingPathComponent("no-notes.pptx")
        let separateStore = DeckStore(rootURL: work.appendingPathComponent("no-office"), officeURL: nil)
        var missing = try await separateStore.importDeck(from: path)
        try expect(missing.activeRevision.renderWarning != nil && missing.activeRevision.slides.count == 3,
                   "Missing optional renderer blocked original slide import")
        missing.updateActiveRevision { $0.slides[0].script.edit("Keep this prepared line.") }
        try await separateStore.save(missing)
        let workDirectory = work.appendingPathComponent("manual-pdf")
        let renderer = DeckRenderer(officeURL: DeckRenderer.installedOffice())
        let pdfURL = try await renderer.convertToPDF(from: path, workDirectory: workDirectory)
        guard let pdf = PDFDocument(url: pdfURL), let firstPage = pdf.page(at: 0) else {
            throw CheckFailure(description: "Generated reference PDF invalid")
        }
        pdf.removePage(at: 0)
        pdf.insert(firstPage, at: pdf.pageCount)
        let shuffledURL = workDirectory.appendingPathComponent("shuffled.pdf")
        try expect(pdf.write(to: shuffledURL), "Could not create reordered PDF fixture")
        do {
            _ = try await separateStore.repairImages(projectID: missing.id, revisionID: missing.activeRevisionID, fromPDF: shuffledURL)
            throw CheckFailure(description: "A visibly reordered companion PDF was accepted")
        } catch DeckImportError.imageOrderMismatch {}
        let unchanged = try await separateStore.openProject(id: missing.id)
        try expect(unchanged == missing, "A failed repair changed the existing preparation")
        let refreshed = try await separateStore.repairImages(projectID: missing.id, revisionID: missing.activeRevisionID, fromPDF: pdfURL)
        try expect(refreshed.activeRevision.renderWarning == nil && !refreshed.activeRevision.needsImageRepair,
                   "Supplied full-slide PDF did not repair missing render")
        try expect(refreshed.revisions.count == 1 && refreshed.activeRevisionID == missing.activeRevisionID &&
                   refreshed.activeRevision.slides[0].script.text == "Keep this prepared line.",
                   "PDF rendering created another revision or overwrote existing speaker edits")
        let fingerprint = try DeckPPTX.fileFingerprint(pdfURL)
        try expect(refreshed.activeRevision.imageRepairSource?.fingerprint == fingerprint &&
                   refreshed.activeRevision.imageRepairSource?.filename == pdfURL.lastPathComponent,
                   "The repaired PDF source identity was not recorded")
        do {
            _ = try await separateStore.repairImages(projectID: refreshed.id, revisionID: refreshed.activeRevisionID, fromPDF: pdfURL)
            throw CheckFailure(description: "A complete saved image set could be overwritten through repair")
        } catch DeckImportError.imageRepairUnavailable {}
        let reopened = try await DeckStore(rootURL: work.appendingPathComponent("no-office")).openProject(id: refreshed.id)
        try expect(reopened == refreshed, "Repaired images or provenance did not survive reopening")
        let oldFirstImage = try await separateStore.imageData(projectID: reopened.id, revisionID: reopened.activeRevisionID, pageNumber: 1)
        var incomplete = reopened
        incomplete.updateActiveRevision { $0.slides[2].image = nil }
        try await separateStore.save(incomplete)
        let partialRepair = try await separateStore.repairImages(projectID: reopened.id, revisionID: reopened.activeRevisionID, fromPDF: pdfURL)
        let sameFirstImage = try await separateStore.imageData(projectID: reopened.id, revisionID: reopened.activeRevisionID, pageNumber: 1)
        try expect(oldFirstImage != nil && oldFirstImage == sameFirstImage && !partialRepair.activeRevision.needsImageRepair,
                   "Partial repair changed an already-preserved page image")
    }

    private static func checkRepeatedTitlePDFReplacement(folder: URL, work: URL, store: DeckStore) async throws {
        let source = folder.appendingPathComponent("repeated-title.pptx")
        var prepared = try await store.importDeck(from: source)
        guard let first = prepared.activeRevision.slides.first, let initialImage = first.image else {
            throw CheckFailure(description: "Repeated-title fixture must start with rendered page images")
        }
        let revisionID = prepared.activeRevisionID
        let title = first.title
        let body = first.bodyText.components(separatedBy: "\n").last ?? ""
        try expect(!body.isEmpty && body != title && prepared.activeRevision.slides[1].bodyText.contains(title),
                   "Repeated-title fixture must have a unique body line and a title repeated in the other slide's body")
        prepared.updateActiveRevision {
            $0.slides[0].script.edit("Keep the pressure notes. [Point to gauge]")
            $0.setAppendix(true, at: 2)
        }
        try await store.save(prepared)

        let pdfURL = work.appendingPathComponent("repeated-title.pdf")
        try writeRepeatedTitlePDF(to: pdfURL, title: title, body: body)
        let pdf = PDFDocument(url: pdfURL)
        try expect(pdf?.page(at: 0)?.string?.contains(title) == false &&
                   pdf?.page(at: 0)?.string?.contains(body) == true &&
                   pdf?.page(at: 1)?.string?.contains(title) == true,
                   "PDF fixture must lack its first title in the text layer while keeping the unique line in order")
        let replaced = try await store.repairImages(projectID: prepared.id, revisionID: revisionID, fromPDF: pdfURL,
                                                     replaceExisting: true)
        try expect(replaced.activeRevisionID == revisionID &&
                   replaced.activeRevision.imageSetID != prepared.activeRevision.imageSetID &&
                   replaced.activeRevision.slides[0].image != initialImage &&
                   replaced.activeRevision.slides.allSatisfy { $0.image != nil },
                   "A valid PDF with a repeated title did not replace the complete image set")
        let pdfDigest = try DeckPPTX.fileFingerprint(pdfURL)
        try expect(replaced.activeRevision.imageRepairSource?.fingerprint == pdfDigest &&
                   replaced.activeRevision.slides.map(\.script) == prepared.activeRevision.slides.map(\.script) &&
                   replaced.activeRevision.slides.map(\.originalNotes) == prepared.activeRevision.slides.map(\.originalNotes) &&
                   replaced.activeRevision.slides.map(\.isAppendix) == prepared.activeRevision.slides.map(\.isAppendix),
                   "Explicit PDF replacement lost its source or preparation")
        let reopenedStore = DeckStore(rootURL: work)
        let reopened = try await reopenedStore.openProject(id: prepared.id)
        let reopenedPage = try await reopenedStore.imageData(projectID: prepared.id, revisionID: revisionID, pageNumber: 1)
        let reopenedThumbnail = try await reopenedStore.imageData(projectID: prepared.id, revisionID: revisionID,
                                                                  pageNumber: 1, kind: .thumbnail)
        try expect(reopened == replaced && reopenedPage.flatMap(cgImage).map(recognize)?.contains(title) == true &&
                   reopenedThumbnail.flatMap(cgImage) != nil,
                   "Reopening lost the selected PDF page image, thumbnail, or provenance")
        let reimported = try await reopenedStore.importDeck(from: source)
        try expect(reimported == replaced, "Reimporting the same PPT discarded the persisted native PDF replacement")
        print("PASS repeated title with missing PDF text layer and complete image replacement persistence")
    }

    private static func writeRepeatedTitlePDF(to url: URL, title: String, body: String) throws {
        var bounds = CGRect(x: 0, y: 0, width: 720, height: 540)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: &bounds, nil),
              let bitmap = CGContext(data: nil, width: 600, height: 56, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CheckFailure(description: "Could not create the synthetic PDF") }
        func write(_ text: String, into context: CGContext, at point: CGPoint, size: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            ))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.textPosition = point
            CTLineDraw(line, context)
        }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 600, height: 56))
        write(title, into: bitmap, at: CGPoint(x: 4, y: 14), size: 32)
        guard let titleImage = bitmap.makeImage() else { throw CheckFailure(description: "Could not rasterize the synthetic title") }
        pdf.beginPDFPage(nil)
        pdf.draw(titleImage, in: CGRect(x: 68, y: 426, width: 600, height: 56))
        write(body, into: pdf, at: CGPoint(x: 72, y: 345), size: 20)
        pdf.endPDFPage()
        pdf.beginPDFPage(nil)
        write("Pressure test procedure", into: pdf, at: CGPoint(x: 72, y: 440), size: 32)
        write(title, into: pdf, at: CGPoint(x: 72, y: 345), size: 20)
        write("The inlet stays isolated.", into: pdf, at: CGPoint(x: 72, y: 318), size: 20)
        pdf.endPDFPage()
        pdf.closePDF()
    }

    private static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func cornerIsGreen(_ image: CGImage) -> Bool {
        guard let corner = image.cropping(to: CGRect(x: 5, y: 5, width: 1, height: 1)) else { return false }
        var components = [UInt8](repeating: 0, count: 4)
        return components.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return buffer[0] < 45 && buffer[1] > 75 && buffer[1] < 105 && buffer[2] > 50 && buffer[2] < 79
        }
    }

    private static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
