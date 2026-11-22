import AppKit
import Foundation
import ImageIO
import Vision

@main
struct InspectLocalDeck {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: inspect-local-deck /path/to/input.pptx")
            return
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DeckInspection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = DeckStore(rootURL: base)
        let project = try await store.importDeck(from: source)
        let revision = project.activeRevision
        let nonempty = revision.slides.filter { !$0.script.isEmpty }.map(\.pageNumber)
        let charts = revision.slides.filter { $0.visuals.contains { $0.kind == .chart } }.map(\.pageNumber)
        let tables = revision.slides.filter { $0.visuals.contains { $0.kind == .table } }.map(\.pageNumber)
        let scanned = revision.slides.filter { $0.visuals.contains { $0.kind == .picture && !$0.text.isEmpty } }.map(\.pageNumber)
        var rendered = 0
        var thumbnails = 0
        var chartsCropped = 0
        var anchoredPages: [Int] = []
        var inspectedTitles = 0
        var validatedPicturePages: [Int] = []
        for slide in revision.slides {
            if let image = try await store.imageData(projectID: project.id, revisionID: revision.id, pageNumber: slide.pageNumber),
               NSImage(data: image) != nil {
                rendered += 1
                let anchor = normalized(slide.title)
                if anchor.count >= 6, !slide.script.isEmpty || [1, 3, 8, 10, 20, revision.slides.count].contains(slide.pageNumber) {
                    inspectedTitles += 1
                    let imageText = normalized(recognize(image))
                    let words = slide.title.split { !$0.isLetter && !$0.isNumber }.map { normalized(String($0)) }
                    let distinctWords = Set(words.filter { $0.count > 3 })
                    let matchedWords = distinctWords.filter { imageText.contains($0) }
                    if imageText.contains(anchor) || (distinctWords.count >= 4 && matchedWords.count * 4 >= distinctWords.count * 3) {
                        anchoredPages.append(slide.pageNumber)
                    }
                }
            }
            if let image = try await store.imageData(projectID: project.id, revisionID: revision.id,
                                                     pageNumber: slide.pageNumber, kind: .thumbnail),
               NSImage(data: image) != nil { thumbnails += 1 }
            for chart in slide.visuals where chart.kind == .chart {
                if let region = chart.region,
                   let image = try await store.imageData(projectID: project.id, revisionID: revision.id,
                                                         pageNumber: slide.pageNumber, region: region),
                   NSImage(data: image) != nil { chartsCropped += 1 }
            }
            if validatedPicturePages.count < 2,
               let picture = slide.visuals.first(where: {
                   $0.kind == .picture && $0.region != nil && $0.text.count >= 20 && $0.text.filter(\.isNumber).count >= 2
               }), let region = picture.region,
               let photo = try await store.imageData(projectID: project.id, revisionID: revision.id,
                                                     pageNumber: slide.pageNumber, region: region),
               normalized(recognize(photo)) == normalized(picture.text) {
                validatedPicturePages.append(slide.pageNumber)
            }
        }
        print("Slides: \(revision.slides.count); page images: \(rendered); thumbnails: \(thumbnails)")
        print("Pages with notes: \(nonempty)")
        print("Native charts: \(charts); renderable chart crops: \(chartsCropped)")
        print("Native tables: \(tables); pages with locally read image text: \(scanned)")
        print("Sampled full page images with matching visible title: \(anchoredPages) (\(anchoredPages.count)/\(inspectedTitles))")
        print("Sampled number-bearing image regions with matching persisted local text: \(validatedPicturePages)")
        print("Rendering warning: \(revision.renderWarning ?? "none")")
        let reopened = try await DeckStore(rootURL: base).openProject(id: project.id)
        let snapshotMatches = reopened == project
        print("Persisted project reopened identically: \(snapshotMatches)")
        guard snapshotMatches, rendered == revision.slides.count, thumbnails == revision.slides.count else {
            throw DeckImportError.renderFailed
        }
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func recognize(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.65 }.map(\.string).joined(separator: "\n")
    }
}
