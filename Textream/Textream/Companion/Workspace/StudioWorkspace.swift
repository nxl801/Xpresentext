import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StudioWorkspace: ObservableObject {
    static let shared = StudioWorkspace()

    let store: DeckStore
    let tracking: CompanionTrackingController
    private(set) var qaService: CompanionQAService
    @Published private(set) var questions: CompanionQASession
    private(set) var chartReader: QAChartReader
    @Published private(set) var provider: StudioModelProvider
    private let chartCacheRoot: URL
    private let trackingPreparationCache: TrackingPreparationCache
    private var draftModelLabel: String

    @Published private(set) var project: DeckProject?
    @Published private(set) var library: [DeckProject] = []
    @Published var classic = false { didSet { if classic { cancelTrackingPreparation() } } }
    @Published var settingsVisible = false
    @Published var reviewsVisible = false
    @Published var notification: String?
    @Published private(set) var importing: String?
    @Published private(set) var repairingImages = false
    @Published private(set) var chartStatus: String?
    @Published private(set) var preparingCharts = false
    @Published private(set) var trackingPreparationStatus: String?
    @Published private(set) var preparingTracking = false
    @Published private var preparedTracking = TrackingPreparationCache.Entry()
    @Published private(set) var generatingPage: Int?
    @Published private(set) var saving = false
    @Published var chineseKeyPoints = false {
        didSet {
            guard oldValue != chineseKeyPoints else { return }
            if chineseKeyPoints { cancelTrackingPreparation() }
            refreshTracking()
        }
    }
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = UUID()
    private var saveFailure = false
    var hasSaveFailure: Bool { saveFailure }
    private var importToken = UUID()
    private var documentToken = UUID()
    private var draftEditedWhilePending = false
    private var draftTask: Task<Void, Never>?
    private var chartTask: Task<Void, Never>?
    private var chartGeneration = UUID()
    private var preparedEvidence: [Int: [QAVisualEvidence]] = [:]
    private var loadedLibrary = false
    private var trackingPreparationPages: [TrackingPreparationPage] = []
    private var trackingPreparationTask: Task<Void, Never>?
    private var trackingPreparationGeneration = UUID()
    private var trackingPreparationObserver: AnyCancellable?

    init(store: DeckStore = DeckStore(), model: (any QAModel)? = nil, chartCacheDirectory: URL? = nil,
         tracking: CompanionTrackingController? = nil, modelLabel: String? = nil) {
        self.store = store
        self.tracking = tracking ?? CompanionTrackingController()
        let selected = UserDefaults.standard.string(forKey: "studio.modelProvider").flatMap(StudioModelProvider.init(rawValue:)) ?? .deepseek
        self.provider = selected
        draftModelLabel = modelLabel ?? selected.label
        let client = model ?? selected.client()
        let service = CompanionQAService(model: client)
        qaService = service
        questions = CompanionQASession(service: service)
        let cacheRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextreamStudio/ChartEvidence", isDirectory: true)
        chartCacheRoot = chartCacheDirectory ?? cacheRoot
        chartReader = QAChartReader(cacheDirectory: chartCacheRoot, model: client, modelID: selected.cacheIdentifier)
        trackingPreparationCache = TrackingPreparationCache(directory: store.rootURL
            .appendingPathComponent("TrackingPreparation", isDirectory: true))
        trackingPreparationObserver = self.tracking.$isStarting.combineLatest(self.tracking.$isListening)
            .sink { [weak self] starting, listening in
                if starting || listening { self?.cancelTrackingPreparation() }
            }
    }

    func selectProvider(_ selected: StudioModelProvider) {
        guard provider != selected else { return }
        let previous = preparedTracking.enabled ? preparedTracking.pages : [:]
        documentToken = UUID()
        cancelDraft()
        cancelTrackingPreparation()
        chartTask?.cancel()
        tracking.cancelQuestion()
        questions.setDeck(nil)
        questions.cancel()
        provider = selected
        draftModelLabel = selected.label
        UserDefaults.standard.set(selected.rawValue, forKey: "studio.modelProvider")
        let client = selected.client()
        qaService = CompanionQAService(model: client)
        questions = CompanionQASession(service: qaService)
        chartReader = QAChartReader(cacheDirectory: chartCacheRoot, model: client, modelID: selected.cacheIdentifier)
        preparedEvidence.removeAll()
        reloadPreparedTracking()
        if previous != (preparedTracking.enabled ? preparedTracking.pages : [:]) { refreshTracking() }
        refreshQuestionMaterials()
        // Switching services can load their existing evidence without sending a new image.
        prepareCharts(allowRemoteRead: false)
    }

    var slides: [DeckSlide] { project?.activeRevision.slides ?? [] }
    var pageIndex: Int { tracking.displayedPageIndex ?? 0 }
    var currentSlide: DeckSlide? {
        let index = pageIndex
        return slides.indices.contains(index) ? slides[index] : nil
    }

    func loadLibraryOnce() {
        guard !loadedLibrary else { return }
        loadedLibrary = true
        Task {
            do { library = try await store.listProjects() }
            catch { notification = error.localizedDescription }
        }
    }

    func chooseFile(replacing: Bool = false) {
        guard importing == nil else { return }
        let panel = NSOpenPanel()
        panel.title = replacing ? "选择新版 PowerPoint" : "打开讲稿或 PowerPoint"
        panel.allowedContentTypes = replacing ? [UTType(filenameExtension: "pptx")!]
            : ["pptx", "textream"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { openURL(url, replacing: replacing) }
    }

    func chooseImageRepairPDF() {
        guard importing == nil, let project else { return }
        let panel = NSOpenPanel()
        panel.title = project.activeRevision.needsImageRepair ? "用同版 PDF 补图" : "用同版 PowerPoint PDF 更新画面"
        panel.message = "请选择从该版 PowerPoint 导出的完整 PDF，包含隐藏胶片且页序相同。"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await repairCurrentImages(from: url) }
    }

    func repairCurrentImages(from pdf: URL) async {
        guard importing == nil, let current = project else { return }
        let token = documentToken
        let replaceExisting = !current.activeRevision.needsImageRepair
        repairingImages = true
        importing = pdf.lastPathComponent
        notification = nil
        let scoped = pdf.startAccessingSecurityScopedResource()
        defer {
            if scoped { pdf.stopAccessingSecurityScopedResource() }
            repairingImages = false
            importing = nil
        }
        await saveTask?.value
        guard !saveFailure, token == documentToken else { return }
        do {
            let repaired = try await store.repairImages(projectID: current.id, revisionID: current.activeRevisionID, fromPDF: pdf,
                                                        replaceExisting: replaceExisting)
            guard token == documentToken else { return }
            chartGeneration = UUID()
            chartTask?.cancel()
            preparingCharts = false
            chartStatus = nil
            preparedEvidence.removeAll()
            project = repaired
            if let index = library.firstIndex(where: { $0.id == repaired.id }) { library[index] = repaired }
            if replaceExisting { questions.setDeck(nil) }
            refreshQuestionMaterials()
            notification = replaceExisting ? "已用同版 PDF 更新胶片画面。" : "已补齐这一版的胶片图。"
        } catch {
            if token == documentToken { notification = error.localizedDescription }
        }
    }

    func openURL(_ url: URL, replacing: Bool = false) {
        if url.pathExtension.lowercased() == "textream" {
            guard TextreamService.shared.confirmDiscardIfNeeded() else { return }
            classic = true
            tracking.stopFollowing()
            TextreamService.shared.openFileAtURL(url)
            return
        }
        guard url.pathExtension.lowercased() == "pptx" else {
            notification = "请选择 .pptx 胶片或 .textream 讲稿。"
            return
        }
        guard importing == nil else { return }
        cancelTrackingPreparation()
        let previous = replacing ? project : nil
        let openingProvider = provider
        let token = UUID()
        importToken = token
        classic = false
        importing = url.lastPathComponent
        notification = nil
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                if token == importToken { importing = nil }
            }
            await saveTask?.value
            if saveFailure { return }
            do {
                let next = try await store.importDeck(from: url, replacing: previous)
                guard token == importToken else { return }
                activate(next, allowRemoteRead: provider == openingProvider)
                library = try await store.listProjects()
            } catch { if token == importToken { notification = error.localizedDescription } }
        }
    }

    func openProject(_ item: DeckProject) {
        guard importing == nil else { return }
        cancelTrackingPreparation()
        let openingProvider = provider
        let token = UUID()
        importToken = token
        Task {
            await saveTask?.value
            guard !saveFailure else { return }
            do {
                var existing = try await store.openProject(id: item.id)
                guard importToken == token else { return }
                if existing.activeRevision.hasLegacyImageGeometry {
                    importing = existing.activeRevision.sourceName
                    defer { if importToken == token { importing = nil } }
                    do { existing = try await store.refreshImageGeometry(projectID: existing.id) }
                    catch { if importToken == token { notification = error.localizedDescription } }
                }
                if importToken == token { activate(existing, allowRemoteRead: provider == openingProvider) }
            } catch { if importToken == token { notification = error.localizedDescription } }
        }
    }

    private func activate(_ next: DeckProject, allowRemoteRead: Bool = true) {
        documentToken = UUID()
        cancelDraft()
        cancelTrackingPreparation()
        tracking.cancelQuestion()
        tracking.stopFollowing()
        chartTask?.cancel()
        questions.setDeck(nil)
        preparedEvidence.removeAll()
        project = next
        reloadPreparedTracking()
        classic = false
        reviewsVisible = false
        refreshTracking()
        tracking.select(pageIndex: next.activeRevision.slides.firstIndex(where: { !$0.isAppendix }) ?? 0)
        refreshQuestionMaterials()
        prepareCharts(allowRemoteRead: allowRemoteRead)
    }

    func chooseRevision(_ id: String) {
        guard importing == nil, var updated = project, updated.activeRevisionID != id,
              updated.selectRevision(id: id) else { return }
        activate(updated)
        persist(updated)
        if updated.activeRevision.hasLegacyImageGeometry { openProject(updated) }
    }

    func editCurrentSlide(_ edit: (inout DeckSlide) -> Void) {
        let index = pageIndex
        guard var next = project, next.activeRevision.slides.indices.contains(index) else { return }
        let previousScript = next.activeRevision.slides[index].script
        next.updateActiveRevision { edit(&$0.slides[index]) }
        if previousScript.text != next.activeRevision.slides[index].script.text {
            cancelTrackingPreparation()
            trackingPreparationStatus = nil
        }
        if generatingPage == index, next.activeRevision.slides[index].script != previousScript {
            draftEditedWhilePending = true
        }
        project = next
        refreshTracking()
        refreshQuestionMaterials()
        persist(next)
    }

    func saveCueRegion(_ region: DeckRegion, cue: String, projectID: UUID, revisionID: String, page: Int) {
        guard var next = project, next.id == projectID, next.activeRevisionID == revisionID,
              next.activeRevision.slides.indices.contains(page - 1) else { return }
        next.updateActiveRevision { revision in
            var overrides = revision.slides[page - 1].manualCueRegions ?? [:]
            overrides[cue] = region
            revision.slides[page - 1].manualCueRegions = overrides
        }
        project = next
        persist(next)
    }

    func updateAppendix(from page: Int? = nil, single: (Int, Bool)? = nil, undo: Bool = false) {
        guard var next = project else { return }
        cancelTrackingPreparation()
        trackingPreparationStatus = nil
        next.updateActiveRevision {
            if undo { $0.undoAppendixChange() }
            else if let page { $0.setAppendixStarting(at: page) }
            else if let (number, enabled) = single { $0.setAppendix(enabled, at: number) }
        }
        project = next
        refreshTracking()
        refreshQuestionMaterials()
        persist(next)
    }

    func finishReview(_ review: DeckRevisionReview, transferTo page: Int? = nil) {
        guard var next = project else { return }
        cancelTrackingPreparation()
        trackingPreparationStatus = nil
        next.updateActiveRevision { revision in
            guard revision.revisionReviews.contains(where: { $0.id == review.id }) else { return }
            if let page {
                guard let i = revision.slides.firstIndex(where: { $0.pageNumber == page }) else { return }
                revision.slides[i].script = review.oldSlide.script
                revision.slides[i].isAppendix = review.oldSlide.isAppendix
            }
            revision.revisionReviews.removeAll { $0.id == review.id }
        }
        project = next
        refreshTracking()
        refreshQuestionMaterials()
        persist(next)
    }

    func updateColors(cue: String? = nil, draft: String? = nil) {
        guard var next = project else { return }
        if let cue { next.cueColorHex = cue }
        if let draft { next.draftColorHex = draft }
        project = next
        persist(next)
    }

    func setOnlineImages(_ enabled: Bool) {
        guard provider.supportsOnlineImages, var next = project, next.onlineImageReadingEnabled != enabled else { return }
        next.onlineImageReadingEnabled = enabled
        project = next
        preparedEvidence.removeAll()
        refreshQuestionMaterials()
        persist(next)
        prepareCharts()
    }

    private func persist(_ snapshot: DeckProject) {
        let preceding = saveTask
        let generation = UUID()
        saveGeneration = generation
        saving = true
        saveTask = Task {
            await preceding?.value
            do {
                try await store.save(snapshot)
                if saveGeneration == generation {
                    saveFailure = false
                    if let index = library.firstIndex(where: { $0.id == snapshot.id }) {
                        library[index] = snapshot
                    }
                }
            } catch {
                if saveGeneration == generation {
                    saveFailure = true
                    notification = "备稿保存失败。\(error.localizedDescription)"
                }
            }
            if saveGeneration == generation { saving = false }
        }
    }

    func saveNow() { if let project { persist(project) } }
    func flushSave() async -> Bool { await saveTask?.value; return !saveFailure }

    private func refreshTracking() {
        var preparation: [TrackingPreparationPage] = []
        let pages = slides.map { slide in
            let sentences = CompanionTrackingPage.sentences(in: slide.script.text)
            guard !slide.isAppendix, !chineseKeyPoints, !sentences.isEmpty else {
                return CompanionTrackingPage(sentences: sentences, isAppendix: slide.isAppendix)
            }
            let input = TrackingPreparationPage(id: slide.id, script: slide.script.text, sentences: sentences)
            if !input.sentences.isEmpty { preparation.append(input) }
            let alternatives = preparedTracking.enabled ? preparedPage(for: input)?.alternatives ?? [:] : [:]
            return CompanionTrackingPage(sentences: sentences, sentenceAlternatives: alternatives)
        }
        trackingPreparationPages = preparation
        tracking.configure(pages: pages, mode: chineseKeyPoints ? .chineseKeyPoints : .english,
                           localeIdentifier: chineseKeyPoints ? "zh-CN" : "en-US", titles: slides.map(\.title),
                           document: [project?.id.uuidString, project?.activeRevisionID].compactMap { $0 }.joined(separator: "/"))
    }

    var preparedTrackingPageCount: Int { trackingPreparationPages.filter { preparedPage(for: $0) != nil }.count }
    var usesPreparedTracking: Bool { preparedTracking.enabled }
    var canSetPreparedTracking: Bool {
        !tracking.isStarting && !tracking.isListening && tracking.phase != .listeningQuestion && !preparingTracking
    }
    var canPrepareTracking: Bool {
        project != nil && !classic && importing == nil && !preparingTracking && !tracking.isStarting && !tracking.isListening &&
            tracking.phase != .listeningQuestion && preparedTrackingPageCount < trackingPreparationPages.count
    }

    func setPreparedTrackingEnabled(_ enabled: Bool) {
        guard canSetPreparedTracking, let key = trackingCacheKey, preparedTracking.enabled != enabled else { return }
        var updated = preparedTracking
        updated.enabled = enabled
        do {
            try trackingPreparationCache.save(updated, for: key)
            preparedTracking = updated
            trackingPreparationStatus = nil
            refreshTracking()
        } catch { trackingPreparationStatus = "无法保存等义跟读设置。" }
    }

    func prepareTrackingAlternatives() {
        guard canPrepareTracking, let key = trackingCacheKey else { return }
        let pending = trackingPreparationPages.filter { preparedPage(for: $0) == nil }
        let service = TrackingPreparation(model: qaService.model)
        let generation = UUID()
        trackingPreparationGeneration = generation
        preparingTracking = true
        trackingPreparationStatus = "正在准备等义跟读…"
        trackingPreparationTask = Task {
            defer {
                if trackingPreparationGeneration == generation {
                    preparingTracking = false
                    trackingPreparationTask = nil
                }
            }
            do {
                for (index, page) in pending.enumerated() {
                    try Task.checkCancellation()
                    let result = try await service.prepare(page)
                    guard !Task.isCancelled, trackingPreparationGeneration == generation,
                          !tracking.isStarting, !tracking.isListening else { return }
                    if !result.alternatives.isEmpty {
                        var updated = preparedTracking
                        updated.pages[page.id] = result
                        try trackingPreparationCache.save(updated, for: key)
                        preparedTracking = updated
                        refreshTracking()
                    }
                    trackingPreparationStatus = "已检查 \(index + 1)/\(pending.count) 页"
                }
                let count = preparedTrackingPageCount
                trackingPreparationStatus = count == 0 ? "未生成可用的等义表达。" : "等义跟读已准备 \(count) 页。"
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled, trackingPreparationGeneration == generation {
                    trackingPreparationStatus = "等义跟读准备中断。"
                    notification = "等义跟读准备中断。\(error.localizedDescription)"
                }
            }
        }
    }

    func cancelTrackingPreparation() {
        guard let task = trackingPreparationTask else { return }
        trackingPreparationGeneration = UUID()
        task.cancel()
        trackingPreparationTask = nil
        preparingTracking = false
        trackingPreparationStatus = "已停止准备等义跟读。"
    }

    private var trackingCacheKey: TrackingPreparationCache.Key? {
        project.map { TrackingPreparationCache.Key(projectID: $0.id, revisionID: $0.activeRevisionID,
                                                   modelID: provider.cacheIdentifier) }
    }

    private func reloadPreparedTracking() {
        preparedTracking = trackingCacheKey.map(trackingPreparationCache.load) ?? TrackingPreparationCache.Entry()
        trackingPreparationStatus = nil
    }

    private func preparedPage(for input: TrackingPreparationPage) -> TrackingPreparationCache.Page? {
        guard let page = preparedTracking.pages[input.id], page.fingerprint == input.fingerprint else { return nil }
        return page
    }

    private func pageMaterial(_ slide: DeckSlide, index: Int) -> QAPage {
        let direct = slide.visuals.compactMap { visual -> QAVisualEvidence? in
            guard !visual.text.isEmpty else { return nil }
            return QAVisualEvidence(id: visual.id, kind: visual.kind == .table ? .table : (visual.kind == .picture ? .imageText : .chart),
                                    region: visual.region.map(QARegion.init(deck:)), text: visual.text,
                                    exactNumericClaimsAllowed: visual.kind != .picture)
        }
        return QAPage(index: index, title: slide.title, bodyText: slide.bodyText,
                      originalNotes: slide.originalNotes, speakerScript: slide.script.origin == .speaker ? slide.script.text : nil,
                      aiDraft: slide.script.origin == .ai ? slide.script.text : nil, isAppendix: slide.isAppendix,
                      visualEvidence: direct + (preparedEvidence[index] ?? []))
    }

    private func refreshQuestionMaterials() {
        guard let project else { questions.setDeck(nil); return }
        let pages = project.activeRevision.slides.enumerated().map { pageMaterial($1, index: $0) }
        questions.setDeck(QADeckSnapshot(revisionID: project.activeRevisionID, pages: pages, projectID: project.id))
    }

    func generateDraft() {
        let index = pageIndex
        guard let p = project, p.activeRevision.slides.indices.contains(index), generatingPage == nil else { return }
        let slide = p.activeRevision.slides[index]
        guard slide.script.isEmpty, !slide.isAppendix else { return }
        let token = documentToken
        let service = qaService
        let modelLabel = draftModelLabel
        draftEditedWhilePending = false
        notification = nil
        generatingPage = index
        let material = pageMaterial(slide, index: index)
        draftTask = Task {
            defer {
                if token == documentToken {
                    draftTask = nil
                    generatingPage = nil
                }
            }
            guard token == documentToken, !Task.isCancelled else { return }
            do {
                let draft = try await service.generateDraft(for: material)
                guard token == documentToken, !Task.isCancelled, !draftEditedWhilePending, var next = project,
                      !next.activeRevision.slides[index].isAppendix,
                      next.activeRevision.slides[index].script == slide.script else { return }
                let source = DeckDraftSource(revisionID: p.activeRevisionID, pageNumber: slide.pageNumber,
                                             evidenceIDs: [slide.id] + slide.visuals.map(\.id), provider: modelLabel)
                var changed = false
                next.updateActiveRevision { rev in
                    changed = rev.slides[index].script.setAIDraft(draft, source: source)
                }
                if changed {
                    cancelTrackingPreparation()
                    trackingPreparationStatus = nil
                    project = next
                    refreshTracking()
                    refreshQuestionMaterials()
                    persist(next)
                }
            } catch { if token == documentToken, !Task.isCancelled { notification = error.localizedDescription } }
        }
    }

    private func cancelDraft() {
        draftTask?.cancel()
        draftTask = nil
        generatingPage = nil
    }

    func prepareCharts(allowRemoteRead: Bool = true) {
        chartTask?.cancel()
        let job = UUID()
        chartGeneration = job
        guard let p = project else { return }
        let allowsOnlineEvidence = provider.supportsOnlineImages && p.onlineImageReadingEnabled
        let canRequestOnlineReading = allowsOnlineEvidence && allowRemoteRead
        let rev = p.activeRevision
        let pages = rev.slides.enumerated().filter { !$0.element.visuals.isEmpty }
        let requiresReading: (DeckVisual, [DeckRegion]) -> Bool = { v, externalLabels in
            if !externalLabels.isEmpty { return true }
            // Structured, visible native labels are already part of the local evidence.
            if v.kind == .table && !v.rows.isEmpty { return false }
            if v.kind == .chart {
                let points = v.series.flatMap(\.points)
                return !v.text.contains(" | ") || points.isEmpty || points.contains { $0.displayValue?.isEmpty != false }
            }
            return allowsOnlineEvidence || v.text.isEmpty
        }
        guard !pages.isEmpty else { chartStatus = nil; preparingCharts = false; return }
        preparingCharts = true
        chartStatus = "正在准备图表…"
        chartTask = Task {
            let chartRegions = (try? await store.chartRegions(projectID: p.id, revision: rev)) ?? [:]
            let candidatesByPage = Dictionary(uniqueKeysWithValues: pages.map { index, slide in
                let externalLabels = chartRegions[slide.id] ?? [:]
                let pending = slide.visuals.filter { requiresReading($0, externalLabels[$0.id] ?? []) }
                return (index, pending.map { chartCandidate($0, on: slide, externalLabels: externalLabels[$0.id] ?? []) })
            })
            var problems = 0
            var done = 0
            defer {
                if chartGeneration == job {
                    preparingCharts = false
                    refreshQuestionMaterials()
                    chartStatus = problems == 0 ? "已准备 \(done) 页图表" : "已核对 \(done) 页，\(problems) 项需核对原图"
                }
            }
            for (index, slide) in pages {
                guard !Task.isCancelled, chartGeneration == job else { return }
                guard let fingerprint = slide.image?.fingerprint else { continue }
                let cached = await chartReader.cachedEvidence(projectID: p.id, revisionID: rev.id,
                                                               pageIndex: index, onlineImageReadingEnabled: allowsOnlineEvidence,
                                                               imageFingerprint: fingerprint,
                                                               candidates: candidatesByPage[index] ?? [])
                guard !Task.isCancelled, chartGeneration == job else { return }
                if !cached.isEmpty { preparedEvidence[index] = cached }
            }
            refreshQuestionMaterials()
            for (index, slide) in pages {
                guard !Task.isCancelled, chartGeneration == job else { return }
                do {
                    let pending = candidatesByPage[index] ?? []
                    guard !pending.isEmpty else { done += 1; continue }
                    guard let data = try await store.imageData(projectID: p.id, revisionID: rev.id,
                                                               pageNumber: slide.pageNumber) else { problems += 1; continue }
                    var evidence: [QAVisualEvidence] = canRequestOnlineReading ? [] : preparedEvidence[index] ?? []
                    for item in pending {
                        try Task.checkCancellation()
                        let result = try await chartReader.prepare(projectID: p.id, revisionID: rev.id, pageIndex: index,
                                                                   imageData: data, candidate: item,
                                                                   onlineImageReadingEnabled: canRequestOnlineReading)
                        switch result.onlineStatus {
                        case .unavailable, .failed, .ambiguous: problems += 1
                        default: break
                        }
                        let fresh = result.evidence.filter { !evidence.contains($0) }
                        evidence.append(contentsOf: fresh)
                    }
                    guard !Task.isCancelled, chartGeneration == job else { return }
                    preparedEvidence[index] = evidence
                    done += 1
                    chartStatus = "已准备 \(done) / \(pages.count) 页图表"
                } catch is CancellationError { return }
                catch { problems += 1 }
            }
        }
    }

    private func chartCandidate(_ visual: DeckVisual, on slide: DeckSlide, externalLabels: [DeckRegion]) -> QAVisualCandidate {
        let region = visual.region.map(QARegion.init(deck:))
        let competingFigure = slide.visuals.contains { other in
            guard other.id != visual.id, other.kind != .picture || visual.kind == .picture else { return false }
            guard let anchor = visual.region, let other = other.region else { return true }
            return min(anchor.x + anchor.width, other.x + other.width) > max(anchor.x, other.x)
                && min(anchor.y + anchor.height, other.y + other.height) > max(anchor.y, other.y)
        }
        let values = externalLabels.isEmpty ? [] : visual.series.flatMap { series in
            series.points.compactMap { point in
                point.displayValue.map {
                    QAChartValueBinding(series: series.name, category: point.category, visibleValue: $0)
                }
            }
        }
        return QAVisualCandidate(
            id: visual.id, title: visual.title.isEmpty ? slide.title : visual.title,
            kind: visual.kind == .table ? .table : (visual.kind == .chart ? .chart : .imageText),
            region: region, needsFullPage: !externalLabels.isEmpty,
            needsOnlineAnalysis: region != nil && !competingFigure,
            externalLabelRegions: externalLabels.map(QARegion.init(deck:)), nativeValues: values
        )
    }

    func submitQuestion(_ text: String, followUp: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        tracking.holdForTypedAnswer()
        questions.submit(text, currentPageIndex: project == nil ? nil : pageIndex, followUp: followUp)
    }

    func closeProject() {
        guard !saving, importing == nil, !saveFailure else { return }
        importToken = UUID()
        documentToken = UUID()
        chartGeneration = UUID()
        cancelDraft()
        cancelTrackingPreparation()
        chartTask?.cancel()
        tracking.cancelQuestion()
        tracking.stopFollowing()
        tracking.configure(pages: [])
        questions.setDeck(nil)
        preparedEvidence.removeAll()
        preparingCharts = false
        chartStatus = nil
        project = nil
        reloadPreparedTracking()
        trackingPreparationPages.removeAll()
        reviewsVisible = false
        notification = nil
    }
}

extension QARegion {
    init(deck: DeckRegion) {
        self.init(x: deck.x, y: deck.y, width: deck.width, height: deck.height)
    }
}
