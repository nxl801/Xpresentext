import Foundation

actor DeckStore {
    static var defaultRootURL: URL {
        let manager = FileManager.default
        let appSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? manager.homeDirectoryForCurrentUser
        return appSupport.appendingPathComponent("Textream/PresentationCompanion", isDirectory: true)
    }

    let rootURL: URL
    private let renderer: DeckRenderer
    private let files = FileManager.default
    private var imageFolders: [UUID: [String: URL]] = [:]
    private var bulletCache: [String: [DeckCueTarget]] = [:]
    private var legacyCueTargets: [String: [Int: [DeckCueTarget]]] = [:]
    private var legacyChartRegions: [String: [String: [String: [DeckRegion]]]] = [:]

    init(rootURL: URL = DeckStore.defaultRootURL, officeURL: URL? = DeckRenderer.installedOffice()) {
        self.rootURL = rootURL
        renderer = DeckRenderer(officeURL: officeURL)
    }

    func listProjects() throws -> [DeckProject] {
        guard files.fileExists(atPath: rootURL.path) else { return [] }
        return try files.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? openProject(id: $0) }
            .sorted { $0.activeRevision.importedAt > $1.activeRevision.importedAt }
    }

    func openProject(id: UUID) throws -> DeckProject {
        let manifest = manifestURL(id)
        guard files.fileExists(atPath: manifest.path) else { throw DeckImportError.missingProject }
        guard let project = try? JSONDecoder().decode(DeckProject.self, from: Data(contentsOf: manifest)),
              project.id == id, Self.isValid(project) else { throw DeckImportError.invalidProject }
        rememberImageFolders(project)
        return project
    }

    func save(_ project: DeckProject) throws {
        let saved = try openProject(id: project.id)
        guard project.revisions.map(\.id) == saved.revisions.map(\.id),
              project.revisions.map(\.imageSetID) == saved.revisions.map(\.imageSetID) else {
            throw DeckImportError.saveConflict
        }
        try write(project)
    }

    func importDeck(from source: URL, replacing project: DeckProject? = nil,
                    renderedPDF: URL? = nil, expectedRevisionID: String? = nil) async throws -> DeckProject {
        guard source.pathExtension.lowercased() == "pptx" else { throw DeckImportError.unsupportedFormat }
        try Task.checkCancellation()
        let stage = rootURL.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        let package = stage.appendingPathComponent("package", isDirectory: true)
        let revisionStage = stage.appendingPathComponent("revision", isDirectory: true)
        try files.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: stage) }
        try files.createDirectory(at: revisionStage, withIntermediateDirectories: true)
        let archive = revisionStage.appendingPathComponent("source.pptx")
        try copyScopedFile(source, to: archive)
        let revisionID = try DeckPPTX.fileFingerprint(archive)
        if let expectedRevisionID, expectedRevisionID != revisionID { throw DeckImportError.imageSourceUnavailable }
        let startingProject = try lookupProject(revisionID: revisionID, replacing: project)
        if var existing = startingProject, let current = existing.revisions.first(where: { $0.id == revisionID }),
           current.renderWarning == nil, !current.hasLegacyImageGeometry, renderedPDF == nil {
            existing.selectRevision(id: revisionID)
            try write(existing)
            return existing
        }

        try await extractPackage(archive, into: package)
        let reader = DeckPPTX(folder: package)
        var revision = try reader.parse(revisionID: revisionID, sourceName: source.lastPathComponent)
        let imageSetID = UUID()
        let imageFolder = imageFolderName(for: imageSetID)
        let stagedImages = revisionStage.appendingPathComponent(imageFolder, isDirectory: true)
        do {
            let pdf: URL
            if let supplied = renderedPDF {
                pdf = stage.appendingPathComponent("supplied.pdf")
                try copyScopedFile(supplied, to: pdf)
            } else {
                let conversionArchive = try await archiveForRendering(archive, package: package, in: stage)
                pdf = try await renderer.convertToPDF(from: conversionArchive, workDirectory: stage)
            }
            revision = try renderer.render(pdf: pdf, to: stagedImages, slideAspectRatio: reader.slideWidth / reader.slideHeight,
                                           revision: revision, checkExternalOrder: renderedPDF != nil)
            revision.imageSetID = imageSetID
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? files.removeItem(at: stagedImages)
            revision.renderWarning = (error as? DeckImportError)?.localizedDescription ?? DeckImportError.renderFailed.localizedDescription
        }

        try Task.checkCancellation()
        // An import can suspend during conversion. Re-read the manifest before choosing a base.
        if var latest = try lookupProject(revisionID: revisionID, replacing: project, fallbackID: startingProject?.id) {
            if let expectedRevisionID, latest.activeRevisionID != expectedRevisionID {
                throw DeckImportError.imageRepairUnavailable
            }
            if startingProject == latest, let project, project.id == latest.id,
               project.revisions.map(\.id) == latest.revisions.map(\.id) {
                latest = project
            }
            if latest.selectRevision(id: revisionID) {
                if revision.renderWarning == nil,
                   latest.activeRevision.renderWarning != nil || latest.activeRevision.hasLegacyImageGeometry || renderedPDF != nil {
                    let oldImages = imagesURL(projectID: latest.id, revision: latest.activeRevision)
                    let images = imagesURL(projectID: latest.id, revision: revision)
                    try files.moveItem(at: stagedImages, to: images)
                    let slides = Dictionary(uniqueKeysWithValues: revision.slides.map { ($0.id, $0) })
                    latest.updateActiveRevision { existing in
                        existing.renderWarning = nil
                        existing.imageSetID = revision.imageSetID
                        existing.imageGeometryVersion = revision.imageGeometryVersion
                        existing.chartContextVersion = revision.chartContextVersion
                        existing.imageRepairSource = nil
                        for index in existing.slides.indices {
                            guard let refreshed = slides[existing.slides[index].id] else { continue }
                            existing.slides[index].image = refreshed.image
                            existing.slides[index].visuals = refreshed.visuals
                        }
                    }
                    do {
                        try write(latest)
                    } catch {
                        try? files.removeItem(at: images)
                        throw error
                    }
                    try? files.removeItem(at: oldImages)
                    return latest
                } else if renderedPDF != nil, let warning = revision.renderWarning {
                    // A failed optional replacement should surface the error while preserving a usable prior render.
                    throw DeckImportError.renderMessage(warning)
                }
                try write(latest)
                return latest
            }
            let base = project.flatMap { requested in latest.revisions.first { $0.id == requested.activeRevisionID } } ?? latest.activeRevision
            revision.carryPreparation(from: base)
            latest.addRevision(revision)
            try install(revisionStage, for: latest, revisionID: revisionID)
            return latest
        }
        let newProject = DeckProject(name: source.deletingPathExtension().lastPathComponent, revision: revision)
        try install(revisionStage, for: newProject, revisionID: revisionID)
        return newProject
    }

    func refreshImageGeometry(projectID: UUID) async throws -> DeckProject {
        let current = try openProject(id: projectID)
        guard current.activeRevision.hasLegacyImageGeometry else { return current }
        guard let original = sourceURL(projectID: projectID, revisionID: current.activeRevisionID) else {
            throw DeckImportError.imageSourceUnavailable
        }
        return try await importDeck(from: original, replacing: current, expectedRevisionID: current.activeRevisionID)
    }

    func repairImages(projectID: UUID, revisionID: String, fromPDF pdf: URL, replaceExisting: Bool = false) async throws -> DeckProject {
        let current = try openProject(id: projectID)
        guard current.activeRevisionID == revisionID, replaceExisting || current.activeRevision.needsImageRepair else {
            throw DeckImportError.imageRepairUnavailable
        }
        guard let original = sourceURL(projectID: projectID, revisionID: revisionID) else {
            throw DeckImportError.imageSourceUnavailable
        }
        let stage = rootURL.appendingPathComponent(".repair-\(UUID().uuidString)", isDirectory: true)
        let package = stage.appendingPathComponent("package", isDirectory: true)
        try files.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: stage) }
        let archive = stage.appendingPathComponent("source.pptx")
        try files.copyItem(at: original, to: archive)
        guard try DeckPPTX.fileFingerprint(archive) == revisionID else {
            throw DeckImportError.imageSourceUnavailable
        }
        let localPDF = stage.appendingPathComponent("source.pdf")
        try copyScopedFile(pdf, to: localPDF)
        let pdfFingerprint = try DeckPPTX.fileFingerprint(localPDF)
        try await extractPackage(archive, into: package)
        let reader = DeckPPTX(folder: package)
        let originalRevision = try reader.parse(revisionID: revisionID, sourceName: current.activeRevision.sourceName)

        // The file copy and extraction can outlive another save or a version switch.
        var latest = try openProject(id: projectID)
        let existing = latest.activeRevision
        guard latest.activeRevisionID == revisionID, replaceExisting || existing.needsImageRepair else {
            throw DeckImportError.imageRepairUnavailable
        }
        guard existing.slides.map(\.id) == originalRevision.slides.map(\.id) else {
            throw DeckImportError.imageSourceUnavailable
        }
        let previous = imagesURL(projectID: projectID, revision: existing)
        let stagedImages = stage.appendingPathComponent("images", isDirectory: true)
        var repaired = try renderer.render(pdf: localPDF, to: stagedImages,
                                           slideAspectRatio: reader.slideWidth / reader.slideHeight,
                                           revision: existing, checkExternalOrder: true,
                                           preservingImagesIn: replaceExisting || existing.hasLegacyImageGeometry ? nil : previous)
        repaired.renderWarning = nil
        repaired.imageSetID = UUID()
        repaired.imageRepairSource = DeckImageRepairSource(filename: pdf.lastPathComponent, fingerprint: pdfFingerprint,
                                                          repairedAt: Date())
        try Task.checkCancellation()
        let installed = imagesURL(projectID: projectID, revision: repaired)
        try files.moveItem(at: stagedImages, to: installed)
        latest.updateActiveRevision { $0 = repaired }
        do {
            try write(latest)
        } catch {
            try? files.removeItem(at: installed)
            throw error
        }
        try? files.removeItem(at: previous)
        return latest
    }

    func imageData(projectID: UUID, revisionID: String, pageNumber: Int,
                   kind: DeckImageKind = .page, region: DeckRegion? = nil) throws -> Data? {
        guard pageNumber > 0, Self.isRevisionID(revisionID) else { return nil }
        if imageFolders[projectID]?[revisionID] == nil { _ = try? openProject(id: projectID) }
        guard let folder = imageFolders[projectID]?[revisionID] else { return nil }
        let url = DeckRenderer.fileURL(in: folder, pageNumber: pageNumber, kind: kind)
        guard files.fileExists(atPath: url.path) else { return nil }
        let full = try Data(contentsOf: url)
        if let region { return DeckRenderer.cropData(full, region: region) }
        return full
    }

    func sourceURL(projectID: UUID, revisionID: String) -> URL? {
        guard Self.isRevisionID(revisionID) else { return nil }
        let source = revisionURL(projectID: projectID, revisionID: revisionID).appendingPathComponent("source.pptx")
        return files.fileExists(atPath: source.path) ? source : nil
    }

    func chartRegions(projectID: UUID, revision: DeckRevision) async throws -> [String: [String: [DeckRegion]]] {
        if revision.chartContextVersion == DeckPPTX.chartContextVersion { return revision.externalChartRegions }
        guard let source = sourceURL(projectID: projectID, revisionID: revision.id) else { return [:] }
        if let cached = legacyChartRegions[revision.id] { return cached }
        let parsed = try await geometryRevision(source, revision: revision)
        let regions = parsed.externalChartRegions
        legacyChartRegions[revision.id] = regions
        return regions
    }

    func cueTargets(projectID: UUID, revision: DeckRevision) async throws -> [Int: [DeckCueTarget]] {
        if revision.slides.allSatisfy({ $0.hasIndexedCueTargets }) {
            return Dictionary(uniqueKeysWithValues: revision.slides.map { ($0.pageNumber, $0.cueTargets ?? []) })
        }
        if let cached = legacyCueTargets[revision.id] { return cached }
        guard let source = sourceURL(projectID: projectID, revisionID: revision.id) else { return [:] }
        let parsed = try await geometryRevision(source, revision: revision)
        let targets = Dictionary(uniqueKeysWithValues: parsed.slides.map { ($0.pageNumber, $0.cueTargets ?? []) })
        legacyCueTargets[revision.id] = targets
        return targets
    }

    func bulletTargets(projectID: UUID, revisionID: String, slide: DeckSlide, targets: [DeckCueTarget]) throws -> [DeckCueTarget] {
        let lists = targets.filter { $0.bulletItems != nil }
        guard lists.count == 1, let list = lists.first, let image = slide.image else { return [] }
        let key = revisionID + ":" + slide.id + ":" + image.fingerprint
        if let cached = bulletCache[key] { return cached }
        guard let data = try imageData(projectID: projectID, revisionID: revisionID, pageNumber: slide.pageNumber,
                                       region: list.region) else { return [] }
        let result = DeckRenderer.bulletTargets(in: data, list: list)
        bulletCache[key] = result
        return result
    }

    private func geometryRevision(_ source: URL, revision: DeckRevision) async throws -> DeckRevision {
        let stage = rootURL.appendingPathComponent(".geometry-\(UUID().uuidString)", isDirectory: true)
        let package = stage.appendingPathComponent("package", isDirectory: true)
        try files.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: stage) }
        let archive = stage.appendingPathComponent("source.pptx")
        try files.copyItem(at: source, to: archive)
        guard try DeckPPTX.fileFingerprint(archive) == revision.id else { throw DeckImportError.invalidProject }
        try await extractPackage(archive, into: package)
        return try DeckPPTX(folder: package).parse(revisionID: revision.id, sourceName: revision.sourceName)
    }

    private func lookupProject(revisionID: String, replacing project: DeckProject?, fallbackID: UUID? = nil) throws -> DeckProject? {
        if let id = project?.id { return try openProject(id: id) }
        if let fallbackID, let found = try? openProject(id: fallbackID) { return found }
        return try listProjects().first { $0.revisions.contains { $0.id == revisionID } }
    }

    private func archiveForRendering(_ original: URL, package: URL, in stage: URL) async throws -> URL {
        // Linked images can reference network URLs. Strip external relationships from the
        // renderer's input only, and keep the original archive untouched for the user.
        guard try removeExternalRelationships(in: package) else { return original }
        let sanitized = stage.appendingPathComponent("slide-render.pptx")
        let status = try await DeckProcess.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                               arguments: ["-c", "-k", "--norsrc", package.path, sanitized.path],
                                               timeout: .seconds(30))
        guard status == 0 else { throw DeckImportError.renderFailed }
        return sanitized
    }

    private func removeExternalRelationships(in package: URL) throws -> Bool {
        guard let enumerator = files.enumerator(at: package, includingPropertiesForKeys: nil) else { return false }
        var changed = false
        for case let url as URL in enumerator where url.pathExtension == "rels" {
            try Task.checkCancellation()
            let relations = try XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever])
            let external = relations.rootElement()?.children?.filter { child in
                (child as? XMLElement)?.attribute(forName: "TargetMode")?.stringValue?.lowercased() == "external"
            } ?? []
            if external.isEmpty { continue }
            external.forEach { $0.detach() }
            try relations.xmlData.write(to: url, options: .atomic)
            changed = true
        }
        return changed
    }

    private func copyScopedFile(_ source: URL, to destination: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try files.copyItem(at: source.resolvingSymlinksInPath(), to: destination)
    }

    private func extractPackage(_ archive: URL, into package: URL) async throws {
        let status = try await DeckProcess.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                               arguments: ["-xf", archive.path, "-C", package.path],
                                               timeout: .seconds(30))
        guard status == 0 else { throw DeckImportError.invalidPackage("PPTX") }
        try validateExtractedParts(in: package)
    }

    private func validateExtractedParts(in package: URL) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = files.enumerator(at: package, includingPropertiesForKeys: Array(keys)) else {
            throw DeckImportError.invalidPackage("PPTX")
        }
        for case let entry as URL in enumerator {
            let metadata = try entry.resourceValues(forKeys: keys)
            guard metadata.isSymbolicLink != true, metadata.isDirectory == true || metadata.isRegularFile == true else {
                throw DeckImportError.invalidPackage("PPTX")
            }
        }
    }

    private func install(_ stage: URL, for project: DeckProject, revisionID: String) throws {
        let directory = revisionURL(projectID: project.id, revisionID: revisionID)
        try files.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A previous termination may have left an unreferenced directory behind.
        if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
        try files.moveItem(at: stage, to: directory)
        do {
            try write(project)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    private func write(_ project: DeckProject) throws {
        guard Self.isValid(project) else { throw DeckImportError.invalidProject }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(project).write(to: manifestURL(project.id), options: .atomic)
        rememberImageFolders(project)
    }

    private func projectURL(_ id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func manifestURL(_ id: UUID) -> URL { projectURL(id).appendingPathComponent("project.json") }

    private func revisionURL(projectID: UUID, revisionID: String) -> URL {
        projectURL(projectID).appendingPathComponent("revisions/\(revisionID)", isDirectory: true)
    }

    private func imagesURL(projectID: UUID, revision: DeckRevision) -> URL {
        revisionURL(projectID: projectID, revisionID: revision.id)
            .appendingPathComponent(imageFolderName(for: revision.imageSetID), isDirectory: true)
    }

    private func imageFolderName(for imageSetID: UUID?) -> String {
        imageSetID.map { "images-\($0.uuidString)" } ?? "images"
    }

    private func rememberImageFolders(_ project: DeckProject) {
        imageFolders[project.id] = Dictionary(uniqueKeysWithValues: project.revisions.map {
            ($0.id, imagesURL(projectID: project.id, revision: $0))
        })
    }

    private static func isRevisionID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isValid(_ project: DeckProject) -> Bool {
        Set(project.revisions.map(\.id)).count == project.revisions.count &&
            project.revisions.contains { $0.id == project.activeRevisionID } &&
            project.revisions.allSatisfy { revision in
                isRevisionID(revision.id) && Set(revision.slides.map(\.id)).count == revision.slides.count &&
                    !revision.slides.isEmpty && revision.slides.enumerated().allSatisfy { $0.offset + 1 == $0.element.pageNumber }
            }
    }
}
