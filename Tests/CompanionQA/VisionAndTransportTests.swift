import AppKit
import CryptoKit
import Foundation
import ImageIO

private final class GeminiFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              url.host == "generativelanguage.googleapis.com", url.query == "alt=sse",
              request.value(forHTTPHeaderField: "x-goog-api-key") == "test-fixture-key",
              request.httpMethod == "POST"
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let code = url.path.contains("fixture-error") ? 429 : 200
        let response = HTTPURLResponse(
            url: url, statusCode: code, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let frames = [
            ": keepalive\n\n",
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"hidden fixture thought\"},{\"text\":\"Usable \"}]}}]}\n\n",
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"sentence.\"}]},\"finishReason\":\"STOP\"}]}\n\n"
        ]
        for frame in frames { client?.urlProtocol(self, didLoad: Data(frame.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor ChartRelease {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func hold() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

extension CompanionQATests {
    static func transport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let request = QAModelRequest(purpose: .answer, instructions: "Test only.", input: "Fixture question.", maxOutputTokens: 80)
        let model = GeminiQAModel(model: "gemini-fixture", apiKeyProvider: { "test-fixture-key" }, session: session)
        let response = try await model.complete(request)
        try expect(response == "Usable sentence.", "Wire stream did not join text parts or strip thought")
        do {
            let model = GeminiQAModel(model: "gemini-fixture-error", apiKeyProvider: { "test-fixture-key" }, session: session)
            _ = try await model.complete(request)
            throw TestFailure(description: "HTTP rate limit was ignored")
        } catch QAServiceError.httpStatus(429) {}
        do {
            _ = try await GeminiQAModel(apiKey: "").complete(request)
            throw TestFailure(description: "Missing credentials reached the transport")
        } catch QAServiceError.missingCredentials {}
        print("PASS transport: HTTPS endpoint, API-key header, SSE text chunks, thought removal, HTTP errors")
    }

    @MainActor
    static func chart(artifactDirectory: URL?) async throws {
        let image = try chartFixture(north: "37%", south: "31%")
        let revisedImage = try chartFixture(north: "31%", south: "31%")
        let faded = try chartFixture(north: nil, south: nil)
        let axisOnly = try chartFixture(north: nil, south: nil, axisTicks: true)
        if let artifactDirectory {
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
            try image.write(to: artifactDirectory.appendingPathComponent("regional-share-original.png"))
            try revisedImage.write(to: artifactDirectory.appendingPathComponent("regional-share-revised.png"))
            try faded.write(to: artifactDirectory.appendingPathComponent("regional-share-no-labels.png"))
            try axisOnly.write(to: artifactDirectory.appendingPathComponent("regional-share-axis-only.png"))
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let project = UUID()
        let region = QARegion(x: 0.16, y: 0.17, width: 0.68, height: 0.7)
        let candidate = QAVisualCandidate(id: "plot", title: "Regional share", region: region)

        let model = RecordedModel { _, continuation in
            continuation.yield("""
            {"readings":[{"series":"North","category":"","value":"37%","unit":""},
                         {"series":"South","category":"","value":"31%","unit":""}],"unresolved":false}
            """)
            continuation.finish()
        }
        let reader = QAChartReader(cacheDirectory: path, model: model)
        let ocrStart = ContinuousClock.now
        let offline = try await reader.prepare(
            projectID: project, revisionID: "original", pageIndex: 7, imageData: image, candidate: candidate,
            onlineImageReadingEnabled: false
        )
        let localOCRTime = ms(ocrStart.duration(to: .now))
        let requestsOffline = await model.requests
        try expect(offline.onlineStatus == .disabled && requestsOffline.isEmpty, "Image left the Mac with online reading off")
        try expect(
            offline.evidence.contains { $0.text.contains("37%") } && offline.evidence.contains { $0.text.contains("31%") },
            "Vision did not read both printed labels: " + offline.evidence.map(\.text).joined(separator: ", ")
        )
        try expect(offline.evidence.allSatisfy { !$0.exactNumericClaimsAllowed && $0.region == region }, "Unverified OCR was treated as a precise chart fact")
        try expect(!offline.evidence.contains { $0.text.contains("Outside scope") }, "Unrelated heading escaped the crop")

        let online = try await reader.prepare(
            projectID: project, revisionID: "original", pageIndex: 7, imageData: image, candidate: candidate,
            onlineImageReadingEnabled: true
        )
        let requestsOnline = await model.requests
        let exact = online.evidence.filter(\.exactNumericClaimsAllowed)
        try expect(online.onlineStatus == .read && Set(exact.map(\.text)) == [
            "Regional share · North · 37%", "Regional share · South · 31%"
        ], "Chart values or series mismatch: \(exact.map(\.text)), \(online.onlineStatus)")
        try expect(exact.allSatisfy { $0.region == region }, "Exact chart facts lost their original area")
        let crop = try decodeImage(requestsOnline.first?.image?.bytes)
        let full = try decodeImage(image)
        try expect(crop.width < full.width && crop.height < full.height && requestsOnline.count == 1, "Online model received the whole page instead of the region")
        if let artifactDirectory {
            try requestsOnline.first?.image?.bytes.write(to: artifactDirectory.appendingPathComponent("regional-share-sent-crop.png"))
        }

        let reopened = QAChartReader(cacheDirectory: path, model: model)
        let imageFingerprint = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        let persisted = await reopened.cachedEvidence(
            projectID: project, revisionID: "original", pageIndex: 7,
            onlineImageReadingEnabled: true, imageFingerprint: imageFingerprint
        )
        try expect(persisted == online.evidence, "Reopening lost the prepared evidence")
        _ = try await reopened.prepare(
            projectID: project, revisionID: "original", pageIndex: 7, imageData: image, candidate: candidate,
            onlineImageReadingEnabled: true
        )
        let requestCount = await model.requests.count
        try expect(requestCount == 1, "A cached chart was uploaded again")
        let differentImage = await reopened.cachedEvidence(
            projectID: project, revisionID: "original", pageIndex: 7,
            onlineImageReadingEnabled: true, imageFingerprint: "changed image"
        )
        let onlineOff = await reopened.cachedEvidence(
            projectID: project, revisionID: "original", pageIndex: 7, onlineImageReadingEnabled: false
        )
        let newPageBeforeReading = await reopened.cachedEvidence(
            projectID: project, revisionID: "revised", pageIndex: 9, onlineImageReadingEnabled: true
        )
        try expect(differentImage.isEmpty && newPageBeforeReading.isEmpty, "Prior chart was reused for changed image or revision")
        try expect(onlineOff.allSatisfy { !$0.exactNumericClaimsAllowed }, "Disabling online analysis returned online evidence")

        let revised = try await reopened.prepare(
            projectID: project, revisionID: "revised", pageIndex: 9, imageData: revisedImage, candidate: candidate,
            onlineImageReadingEnabled: true
        )
        try expect(revised.onlineStatus == .ambiguous && !revised.evidence.contains { $0.text.contains("37%") }, "Old model value survived a revised image")
        let ambiguous = try await reopened.prepare(
            projectID: project, revisionID: "unlabelled", pageIndex: 7, imageData: faded, candidate: candidate,
            onlineImageReadingEnabled: true
        )
        try expect(
            ambiguous.onlineStatus == .ambiguous && ambiguous.evidence.allSatisfy { !$0.exactNumericClaimsAllowed && $0.region == region },
            "Label-free bars produced a precise figure or lost the original preview"
        )

        let ticks = try await reopened.prepare(
            projectID: project, revisionID: "axis-only", pageIndex: 7, imageData: axisOnly, candidate: candidate,
            onlineImageReadingEnabled: true
        )
        try expect(ticks.evidence.contains { $0.text.contains("37%") } && ticks.evidence.contains { $0.text.contains("31%") },
                   "Expected visible axis tick text in the test fixture")
        try expect(ticks.onlineStatus == .ambiguous && ticks.evidence.allSatisfy { !$0.exactNumericClaimsAllowed },
                   "Axis ticks became exact series values")

        let swappedModel = RecordedModel { _, continuation in
            continuation.yield("""
            {"readings":[{"series":"North","category":"","value":"31%","unit":""},
                         {"series":"South","category":"","value":"37%","unit":""}],"unresolved":false}
            """)
            continuation.finish()
        }
        let swapped = try await QAChartReader(cacheDirectory: path, model: swappedModel, modelID: "fixture-swapped")
            .prepare(projectID: project, revisionID: "original", pageIndex: 7, imageData: image, candidate: candidate, onlineImageReadingEnabled: true)
        try expect(swapped.evidence.filter(\.exactNumericClaimsAllowed).isEmpty, "Swapped series readings passed local cross-check")
        let decoration = QAVisualCandidate(
            id: "decoration", title: "Picture", kind: .imageText, region: QARegion(x: 0.05, y: 0.35, width: 0.14, height: 0.3)
        )
        let skipped = try await reader.prepare(
            projectID: project, revisionID: "decoration", pageIndex: 0, imageData: image, candidate: decoration,
            onlineImageReadingEnabled: true
        )
        try expect(skipped.onlineStatus == .notNeeded, "Unrelated picture was sent for chart analysis")
        let fullCandidate = QAVisualCandidate(id: "full", title: "Regional share", region: region, needsFullPage: true)
        _ = try await reader.prepare(
            projectID: project, revisionID: "full-page", pageIndex: 7, imageData: image,
            candidate: fullCandidate, onlineImageReadingEnabled: true
        )
        let fullRequest = await model.requests.last
        let fullSize = try decodeImage(fullRequest?.image?.bytes)
        try expect(fullSize.width == full.width && fullSize.height == full.height, "Dispersed legend case did not use the necessary page")

        let release = ChartRelease()
        let racedModel = RecordedModel { request, continuation in
            let old = request.input.contains("Old plot")
            if old { await release.hold() }
            let value = old ? "37%" : "31%"
            continuation.yield("""
            {"readings":[{"series":"North","category":"","value":"\(value)","unit":""}],"unresolved":false}
            """)
            continuation.finish()
        }
        let racing = QAChartReader(cacheDirectory: path, model: racedModel)
        let oldTask = Task {
            try await racing.prepare(
                projectID: project, revisionID: "racing-old", pageIndex: 7, imageData: image,
                candidate: QAVisualCandidate(id: "racing", title: "Old plot", region: region), onlineImageReadingEnabled: true
            )
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while await racedModel.requests.isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let oldRequestInFlight = await racedModel.requests.count == 1
            try expect(oldRequestInFlight, "Old online read did not start")
            let newResult = try await racing.prepare(
                projectID: project, revisionID: "racing-new", pageIndex: 9, imageData: revisedImage,
                candidate: QAVisualCandidate(id: "racing", title: "New plot", region: region), onlineImageReadingEnabled: true
            )
            await release.release()
            let oldResult = try await oldTask.value
            let settledNew = await racing.cachedEvidence(projectID: project, revisionID: "racing-new", pageIndex: 9, onlineImageReadingEnabled: true)
            try expect(oldResult.evidence.contains(where: { $0.exactNumericClaimsAllowed && $0.text.contains("37%") }),
                       "Delayed prior revision did not preserve its own value")
            try expect(newResult.evidence == settledNew && !settledNew.contains(where: { $0.text.contains("37%") }),
                       "A delayed old chart contaminated the new revision")
        } catch {
            await release.release()
            oldTask.cancel()
            throw error
        }

        print("TIMING cold local Vision chart OCR and persistence: \(String(format: "%.2f", localOCRTime)) ms")
        print("PASS Vision: local 37% and 31%, online crop \(crop.width)×\(crop.height) of \(full.width)×\(full.height), no sends with off")
        print("PASS chart: persisted region, revision/fingerprint isolation, swapped-series, axis-only, unlabelled-value fallback, and late old-revision read")
    }

    private static func decodeImage(_ data: Data?) throws -> CGImage {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw TestFailure(description: "Expected image data") }
        return image
    }

    @MainActor
    static func chartFixture(north: String?, south: String?, axisTicks: Bool = false) throws -> Data {
        let width = 1_440
        let height = 900
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
        else { throw TestFailure(description: "Could not generate chart fixture") }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        NSColor.white.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: width, height: height))
        func caption(_ text: String, x: Double, y: Double, size: CGFloat) {
            text.draw(at: CGPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.black
            ])
        }
        caption("Outside scope · 99% · review only", x: 80, y: 800, size: 34)
        caption("Regional share", x: 330, y: 654, size: 64)
        caption("Share of coded submissions", x: 332, y: 601, size: 40)
        NSColor(calibratedRed: 0.17, green: 0.44, blue: 0.64, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 480, y: 414, width: 480, height: 86))
        NSColor(calibratedRed: 0.21, green: 0.51, blue: 0.65, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 480, y: 246, width: 402, height: 86))
        // The value is printed inline with each series. Removing labels leaves similar-color bars only.
        caption(north.map { "North  " + $0 } ?? "North", x: 500, y: 514, size: 57)
        caption(south.map { "South  " + $0 } ?? "South", x: 500, y: 346, size: 57)
        if axisTicks {
            for (index, percent) in ["25%", "31%", "37%", "43%"].enumerated() {
                caption(percent, x: 480 + Double(index * 130), y: 164, size: 37)
            }
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw TestFailure(description: "Chart fixture did not encode")
        }
        return png
    }
}
