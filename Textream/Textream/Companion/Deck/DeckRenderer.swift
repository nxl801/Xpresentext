import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

struct DeckRenderer: Sendable {
    static let imageGeometryVersion = 2
    let officeURL: URL?

    static func installedOffice() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let candidates = [
            URL(fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice"),
            home.appendingPathComponent("Applications/LibreOffice.app/Contents/MacOS/soffice"),
            home.appendingPathComponent(".local/bin/soffice"),
            URL(fileURLWithPath: "/opt/homebrew/bin/soffice"),
            URL(fileURLWithPath: "/usr/local/bin/soffice")
        ] + path.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("soffice") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func convertToPDF(from file: URL, workDirectory: URL) async throws -> URL {
        guard let officeURL, FileManager.default.isExecutableFile(atPath: officeURL.path) else {
            throw DeckImportError.missingRenderer
        }
        // The macOS bundle still initializes AppKit in --headless mode. In a
        // process without a WindowServer session it aborts during registration.
        let binary = officeURL.resolvingSymlinksInPath()
        let frameworks = binary.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Frameworks")
        if FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("libvclplug_osxlo.dylib").path),
           CGSessionCopyCurrentDictionary() == nil {
            throw DeckImportError.renderMessage("当前进程无法连接 macOS 图形会话。请在已登录的 Mac 桌面打开 Xpresentext 转换胶片，或导入同版 PDF。")
        }
        let profile = workDirectory.appendingPathComponent("office-profile", isDirectory: true)
        let userProfile = profile.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: userProfile, withIntermediateDirectories: true)
        let settings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <oor:items xmlns:oor="http://openoffice.org/2001/registry">
          <item oor:path="/org.openoffice.Office.Common/Security/Scripting">
            <prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop>
          </item>
        </oor:items>
        """
        try Data(settings.utf8).write(to: userProfile.appendingPathComponent("registrymodifications.xcu"))
        let filter = #"pdf:impress_pdf_Export:{"ExportHiddenSlides":{"type":"boolean","value":"true"},"ExportNotesPages":{"type":"boolean","value":"false"}}"#
        let status = try await DeckProcess.run(officeURL, arguments: [
            "-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore", "--nodefault", "--nolockcheck",
            "--convert-to", filter, "--outdir", workDirectory.path, file.path
        ], timeout: .seconds(120))
        let pdf = workDirectory.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".pdf")
        guard status == 0, FileManager.default.fileExists(atPath: pdf.path) else { throw DeckImportError.renderFailed }
        return pdf
    }

    func render(pdf source: URL, to directory: URL, slideAspectRatio: Double, revision: DeckRevision,
                checkExternalOrder: Bool = false, preservingImagesIn previous: URL? = nil) throws -> DeckRevision {
        guard let pdf = PDFDocument(url: source) else { throw DeckImportError.renderFailed }
        guard pdf.pageCount == revision.slides.count else {
            throw DeckImportError.imagePageCount(expected: revision.slides.count, actual: pdf.pageCount)
        }
        if checkExternalOrder { try Self.checkPDFOrder(pdf, against: revision.slides) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var result = revision
        result.imageGeometryVersion = Self.imageGeometryVersion
        for index in result.slides.indices {
            try Task.checkCancellation()
            let slide = result.slides[index]
            guard let page = pdf.page(at: index) else { throw DeckImportError.renderFailed }
            let size = page.bounds(for: .cropBox).size
            guard size.width > 0, size.height > 0,
                  abs(size.width / size.height / slideAspectRatio - 1) < 0.02 else {
                throw DeckImportError.imageAspectRatio(page: slide.pageNumber)
            }
            if let previous, slide.image != nil, try Self.copyExistingImages(from: previous, to: directory, page: slide.pageNumber) {
                continue
            }
            guard let full = Self.rasterized(page, longEdge: 2048),
                  let thumbnail = Self.rasterized(page, longEdge: 384),
                  let fullPNG = Self.png(full), let thumbnailPNG = Self.png(thumbnail) else {
                throw DeckImportError.renderFailed
            }
            try fullPNG.write(to: Self.fileURL(in: directory, pageNumber: slide.pageNumber, kind: .page))
            try thumbnailPNG.write(to: Self.fileURL(in: directory, pageNumber: slide.pageNumber, kind: .thumbnail))
            result.slides[index].image = DeckSlideImage(pixelWidth: full.width, pixelHeight: full.height,
                                                        fingerprint: SHA256.hex(SHA256.hash(data: fullPNG)))
            for visualIndex in slide.visuals.indices where slide.visuals[visualIndex].kind == .picture {
                try Task.checkCancellation()
                guard let region = slide.visuals[visualIndex].region, let crop = Self.crop(full, region: region) else { continue }
                result.slides[index].visuals[visualIndex].text = Self.recognizeText(crop)
            }
        }
        return result
    }

    static func fileURL(in directory: URL, pageNumber: Int, kind: DeckImageKind) -> URL {
        directory.appendingPathComponent("\(pageNumber)-\(kind.rawValue).png")
    }

    private static func copyExistingImages(from previous: URL, to destination: URL, page: Int) throws -> Bool {
        let manager = FileManager.default
        let full = fileURL(in: previous, pageNumber: page, kind: .page)
        let thumbnail = fileURL(in: previous, pageNumber: page, kind: .thumbnail)
        guard manager.fileExists(atPath: full.path) else { return false }
        try manager.copyItem(at: full, to: fileURL(in: destination, pageNumber: page, kind: .page))
        let target = fileURL(in: destination, pageNumber: page, kind: .thumbnail)
        if manager.fileExists(atPath: thumbnail.path) {
            try manager.copyItem(at: thumbnail, to: target)
        } else {
            guard let source = CGImageSourceCreateWithURL(full as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 384
                  ] as CFDictionary), let data = png(image) else { throw DeckImportError.renderFailed }
            try data.write(to: target)
        }
        return true
    }

    static func cropData(_ data: Data, region: DeckRegion) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cropped = crop(image, region: region) else { return nil }
        return png(cropped)
    }

    private static func checkPDFOrder(_ pdf: PDFDocument, against slides: [DeckSlide]) throws {
        func normalize(_ text: String) -> String {
            String(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber })
        }
        let sourcePages = slides.map { normalize($0.title + "\n" + $0.bodyText) }
        let rendered = (0..<pdf.pageCount).map { normalize(pdf.page(at: $0)?.string ?? "") }
        let anchors = slides.enumerated().map { index, slide in
            let lines = [slide.title] + slide.bodyText.components(separatedBy: .newlines)
            return Set(lines.map(normalize)).filter { line in
                line.count >= 6 && !sourcePages.enumerated().contains {
                    $0.offset != index && $0.element.contains(line)
                }
            }
        }
        func matchesRaster(pageIndex: Int, anchors: Set<String>) throws -> Bool {
            try Task.checkCancellation()
            guard let page = pdf.page(at: pageIndex), let image = rasterized(page, longEdge: 1200) else { return false }
            let text = normalize(recognizeText(image))
            return anchors.contains { text.contains($0) }
        }
        var matched = 0
        for (index, pageAnchors) in anchors.enumerated() where !pageAnchors.isEmpty {
            try Task.checkCancellation()
            if pageAnchors.contains(where: { rendered[index].contains($0) }) {
                matched += 1
                continue
            }
            // A heading can also occur in another slide's body. Only text unique to
            // its source slide can establish an order mismatch.
            let moved = pageAnchors.contains { anchor in
                rendered.filter { $0.contains(anchor) }.count == 1
            }
            if moved {
                guard try matchesRaster(pageIndex: index, anchors: pageAnchors) else {
                    throw DeckImportError.imageOrderMismatch(page: index + 1)
                }
                matched += 1
            }
        }
        // For outline- or image-only exports PDF text can be empty. Use local OCR to
        // confirm visible anchors before associating the export with this PPT.
        if matched == 0, anchors.contains(where: { !$0.isEmpty }) {
            for (index, pageAnchors) in anchors.enumerated() where !pageAnchors.isEmpty {
                if try matchesRaster(pageIndex: index, anchors: pageAnchors) { return }
            }
            throw DeckImportError.imageVersionUnverified
        }
    }

    private static func rasterized(_ page: PDFPage, longEdge: Double) -> CGImage? {
        guard let source = page.pageRef else { return nil }
        let size = page.bounds(for: .cropBox).size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let scale = longEdge / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        // Quartz caps the PDF drawing transform at native size. Apply output pixel
        // scaling explicitly so full-page assets and normalized crop regions agree.
        let nativeBounds = CGRect(origin: .zero, size: size)
        context.scaleBy(x: Double(width) / size.width, y: Double(height) / size.height)
        context.concatenate(source.getDrawingTransform(.cropBox, rect: nativeBounds, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(source)
        return context.makeImage()
    }

    private static func crop(_ image: CGImage, region: DeckRegion) -> CGImage? {
        guard region.x.isFinite, region.y.isFinite, region.width.isFinite, region.height.isFinite,
              region.width > 0, region.height > 0 else { return nil }
        let width = Double(image.width)
        let height = Double(image.height)
        let crop = CGRect(x: region.x * width, y: region.y * height,
                          width: region.width * width, height: region.height * height).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !crop.isNull, !crop.isEmpty else { return nil }
        return image.cropping(to: crop)
    }

    private static func png(_ image: CGImage) -> Data? {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? bytes as Data : nil
    }

    private static func recognizeText(_ image: CGImage) -> String {
        guard image.width >= 64, image.height >= 32 else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil else { return "" }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.65 }
            .map(\.string).joined(separator: "\n")
    }
}

nonisolated enum DeckProcess {
    static func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> Int32 {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            while process.isRunning {
                guard clock.now < deadline else { throw DeckImportError.renderFailed }
                try await Task.sleep(for: .milliseconds(70))
            }
            return process.terminationStatus
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }
}

extension DeckRenderer {
    /// OCR provides the displayed line bounds. PowerPoint supplies the bullet
    /// order and spelling, so ambiguous or clipped OCR cannot manufacture an item.
    static func bulletTargets(in crop: Data, list: DeckCueTarget) -> [DeckCueTarget] {
        guard let items = list.bulletItems else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(data: crop).perform([request])) != nil else { return [] }
        func letters(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let lines = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        return items.enumerated().compactMap { ordinal, text in
            let expected = letters(text)
            guard !expected.isEmpty, items.filter({ letters($0) == expected }).count == 1 else { return nil }
            var candidates: [CGRect] = []
            for start in lines.indices {
                var label = ""
                var bounds = CGRect.null
                for i in start..<min(start + 8, lines.count) {
                    guard let recognized = lines[i].topCandidates(1).first, recognized.confidence >= 0.65 else { break }
                    var part = recognized.string
                    if i == start {
                        part = part.replacingOccurrences(of: #"^\s*[（(]?[0-9]+[.)）、．]\s*"#,
                                                        with: "", options: .regularExpression)
                    }
                    if i == start && letters(part).isEmpty { break }
                    label += letters(part)
                    bounds = bounds.union(lines[i].boundingBox)
                    if label == expected { candidates.append(bounds); break }
                    if !expected.hasPrefix(label) { break }
                }
            }
            guard candidates.count == 1, let rect = candidates.first else { return nil }
            let r = list.region
            return DeckCueTarget(text: text, region: DeckRegion(x: r.x + r.width * rect.minX,
                y: r.y + r.height * (1 - rect.maxY), width: r.width * rect.width, height: r.height * rect.height),
                itemNumber: ordinal + 1)
        }
    }
}
