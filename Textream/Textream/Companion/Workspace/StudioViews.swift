import SwiftUI
import AppKit

enum StudioColors {
    static let tint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.35, green: 0.83, blue: 0.73, alpha: 1)
            : NSColor(srgbRed: 0.04, green: 0.39, blue: 0.34, alpha: 1)
    })

    static func color(_ hex: String) -> Color {
        let raw = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x926AD7
        return Color(red: Double(raw >> 16 & 255) / 255, green: Double(raw >> 8 & 255) / 255,
                     blue: Double(raw & 255) / 255)
    }

    static func hex(_ color: Color) -> String {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "#926AD7" }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

struct StudioPageImage: View {
    let store: DeckStore
    let projectID: UUID
    let revisionID: String
    let pageNumber: Int
    var thumbnail = false
    var region: QARegion?
    var highlightRegions: [QARegion] = []
    var imageSetID: UUID?
    var cropToRegion = false
    var outline: Color = .orange
    var outlinePadding: CGFloat = 0
    var drawRegion: ((DeckRegion) -> Void)?
    @State private var image: NSImage?
    @State private var loadedID = ""
    private var crop: DeckRegion? {
        guard cropToRegion, let region, region.isValid else { return nil }
        return DeckRegion(x: region.x, y: region.y, width: region.width, height: region.height)
    }
    private var loadID: String { "\(projectID)-\(revisionID)-\(pageNumber)-\(thumbnail)-\(imageSetID?.uuidString ?? "")-\(String(describing: crop))" }
    var body: some View {
        Group {
            if let image, loadedID == loadID {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .overlay {
                        if !cropToRegion {
                            let regions = (highlightRegions + [region].compactMap { $0 }).filter(\.isValid)
                            GeometryReader { geo in
                                ForEach(regions.indices, id: \.self) { index in
                                    let region = regions[index]
                                    let left = max(0, geo.size.width * region.x - outlinePadding)
                                    let top = max(0, geo.size.height * region.y - outlinePadding)
                                    let right = min(geo.size.width, geo.size.width * (region.x + region.width) + outlinePadding)
                                    let bottom = min(geo.size.height, geo.size.height * (region.y + region.height) + outlinePadding)
                                    Rectangle().strokeBorder(outline, lineWidth: outlinePadding > 0 ? 2 : 3)
                                        .background(outline.opacity(0.12))
                                        .frame(width: right - left, height: bottom - top)
                                        .position(x: (left + right) / 2, y: (top + bottom) / 2)
                                }
                            }.allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if let drawRegion {
                            GeometryReader { geo in
                                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 2)
                                    .onChanged { gesture in
                                        guard geo.size.width > 0, geo.size.height > 0 else { return }
                                        let x1 = min(1, max(0, gesture.startLocation.x / geo.size.width))
                                        let x2 = min(1, max(0, gesture.location.x / geo.size.width))
                                        let y1 = min(1, max(0, gesture.startLocation.y / geo.size.height))
                                        let y2 = min(1, max(0, gesture.location.y / geo.size.height))
                                        drawRegion(DeckRegion(x: min(x1, x2), y: min(y1, y2),
                                                              width: abs(x2 - x1), height: abs(y2 - y1)))
                                    })
                            }
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: thumbnail ? 3 : 7)
                    .fill(.quaternary.opacity(0.55))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { Image(systemName: "rectangle.on.rectangle").foregroundStyle(.tertiary) }
            }
        }
        .accessibilityLabel("第 \(pageNumber) 页胶片")
        .task(id: loadID) {
            image = nil
            let data = try? await store.imageData(projectID: projectID, revisionID: revisionID,
                                                  pageNumber: pageNumber, kind: thumbnail ? .thumbnail : .page,
                                                  region: crop)
            if !Task.isCancelled {
                image = data.flatMap(NSImage.init(data:))
                loadedID = loadID
            }
        }
    }
}

struct StudioRoot: View {
    @ObservedObject var ws: StudioWorkspace
    @ObservedObject var tracking: CompanionTrackingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTarget = false
    @State private var showTrackingPreparation = false
    @State private var showFollowAudio = false
    @State private var trackingConsent: TrackingConsent?

    private struct TrackingConsent {
        let projectID: UUID
        let revisionID: String
        let provider: StudioModelProvider
    }
    @AppStorage("studio.upcomingSentences") private var upcomingSentences = 3
    private enum ReadingLayout: String { case single, double, automatic }
    @AppStorage("studio.readingLayout") private var readingLayout: ReadingLayout =
        UserDefaults.standard.bool(forKey: "studio.twoPageReading") ? .double : .single
    @AppStorage("studio.scriptFontSize") private var scriptFontSize = 17
    @AppStorage("studio.slideHeightOffset") private var slideHeightOffset = 0.0
    @GestureState private var resizing = CGFloat.zero
    private let appendixHelp = "供现场查阅的备用页，不参与自动跟读跳页。"
    private let equivalentTrackingHelp = "提前准备英文讲稿的同义表达，方便演讲时用不同措辞也能定位到原句。"
    init(_ ws: StudioWorkspace) { self.ws = ws; self.tracking = ws.tracking }

    var body: some View {
        Group {
            if ws.classic {
                ContentView()
                    .toolbar {
                        ToolbarItem { Button("胶片工作区") { ws.classic = false } }
                    }
            } else {
                VStack(spacing: 0) {
                    header.modifier(StudioGlass(radius: 13)).padding(.horizontal, 8).padding(.vertical, 5)
                    if let text = ws.importing {
                        Spacer()
                        ProgressView()
                        Text(ws.repairingImages ? "正在从 \(text) 生成胶片图" : "正在导入 \(text)").font(.headline).padding()
                        Spacer()
                    } else if let p = ws.project {
                        HSplitView {
                            sidebar(p).modifier(StudioGlass(radius: 13)).padding(.leading, 8)
                                .frame(minWidth: 155, idealWidth: 195, maxWidth: 265)
                            if let slide = ws.currentSlide {
                                readingView(p, slide)
                            } else { ContentUnavailableView("没有可显示的胶片", systemImage: "rectangle.dashed") }
                        }
                        Divider()
                        statusLine(p).modifier(StudioGlass(radius: 8)).padding(.horizontal, 8).padding(.vertical, 3)
                    } else { library }
                    if let message = tracking.speechError ?? ws.notification {
                        HStack {
                            Image(systemName: "info.circle").foregroundStyle(StudioColors.tint)
                            Text(message).font(.callout).textSelection(.enabled)
                            Spacer()
                            if ws.notification != nil && tracking.speechError == nil { Button("收起") { ws.notification = nil }.buttonStyle(.borderless) }
                        }.padding(.horizontal, 16).padding(.vertical, 8).modifier(StudioGlass(radius: 10))
                    }
                }
                .frame(minWidth: 880, minHeight: 560)
                .background {
                    if ws.project != nil || ws.importing != nil {
                        StudioLunarScene(kind: .workspace)
                    } else { Color(red: 0.024, green: 0.04, blue: 0.064) }
                }
                .environment(\.colorScheme, .dark)
                .overlay { if isDropTarget { RoundedRectangle(cornerRadius: 12).stroke(StudioColors.tint, lineWidth: 3).allowsHitTesting(false) } }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    ws.openURL(url)
                    return true
                } isTargeted: { isDropTarget = $0 }
            }
        }
        .tint(StudioColors.tint)
        .confirmationDialog("准备等义跟读？", isPresented: $showTrackingPreparation, presenting: trackingConsent) { consent in
            Button("发送英文讲稿") {
                guard ws.project?.id == consent.projectID, ws.project?.activeRevisionID == consent.revisionID,
                      ws.provider == consent.provider else { return }
                ws.prepareTrackingAlternatives()
            }
        } message: { consent in
            Text("将要准备的英文讲稿发送给 \(consent.provider.label)。等义表达保存在本机，供演讲时定位句子。")
        }
        .sheet(isPresented: $ws.settingsVisible) { StudioSettings(ws: ws) }
        .sheet(isPresented: $ws.reviewsVisible) { StudioReviews(ws: ws) }
        .task { ws.loadLibraryOnce() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Xpresentext").font(.headline)
                if let p = ws.project { Text(p.activeRevision.sourceName).lineLimit(1).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { ws.chooseFile() } label: { Label("打开胶片", systemImage: "folder") }
            Button { StudioQuestionPanel.shared.show(ws) } label: { Label("现场问答", systemImage: "bubble.left.and.bubble.right") }
            if ws.project != nil && ws.chineseKeyPoints {
                Button {
                    ws.chineseKeyPoints = false
                    tracking.startFollowing()
                } label: { Label("开始英文跟读", systemImage: "mic.fill") }
                .buttonStyle(.borderedProminent)
                .help("从中文关键点切换到英文讲稿并开始跟读")
                .disabled(tracking.phase == .listeningQuestion)
            } else if ws.project != nil {
                Button {
                    if tracking.displaysFollowCapture { tracking.stopFollowing() } else { tracking.startFollowing() }
                } label: {
                    Label(tracking.displaysFollowCapture ? (tracking.isStarting ? "取消启动" : "停止跟读") :
                          (tracking.phase == .awaitingResume ? "继续跟读" : "开始跟读"),
                          systemImage: tracking.displaysFollowCapture ? "stop.fill" : "mic.fill")
                }
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: tracking.isListening || tracking.isStarting)
                .buttonStyle(.borderedProminent)
                .help(tracking.displaysFollowCapture ? "停止使用麦克风跟读" : "用麦克风跟随讲稿，定位到正在讲的句子")
                .disabled(tracking.phase == .listeningQuestion)
            }
            Menu {
                Button("模型与显示设置…") { ws.settingsVisible = true }
                if let p = ws.project {
                    Button("准备图表依据") { ws.prepareCharts() }
                    if ws.preparingTracking {
                        Button("停止准备等义跟读") { ws.cancelTrackingPreparation() }
                    } else {
                        Button("准备等义跟读…") {
                            trackingConsent = TrackingConsent(projectID: p.id, revisionID: p.activeRevisionID, provider: ws.provider)
                            showTrackingPreparation = true
                        }.disabled(!ws.canPrepareTracking).help(equivalentTrackingHelp)
                    }
                    if ws.preparedTrackingPageCount > 0 {
                        Toggle("使用已准备的等义跟读", isOn: Binding(get: { ws.usesPreparedTracking }, set: ws.setPreparedTrackingEnabled))
                            .disabled(!ws.canSetPreparedTracking)
                    }
                    Button("导入这份胶片的新版…") { ws.chooseFile(replacing: true) }
                    if p.activeRevision.needsImageRepair {
                        Button("用同版 PDF 补图…") { ws.chooseImageRepairPDF() }.disabled(ws.importing != nil)
                    } else {
                        Button("用同版 PowerPoint PDF 更新画面…") { ws.chooseImageRepairPDF() }.disabled(ws.importing != nil)
                    }
                    if p.revisions.count > 1 {
                        Menu("备稿版本") {
                            ForEach(p.revisions.reversed()) { r in
                                Button { ws.chooseRevision(r.id) } label: {
                                    Text("\(r.sourceName) · \(r.importedAt.formatted()) \(r.id == p.activeRevisionID ? "✓" : "")")
                                }
                            }
                        }
                    }
                    if !p.activeRevision.revisionReviews.isEmpty {
                        Button("核对换版讲稿…") { ws.reviewsVisible = true }
                    }
                    Button("关闭这份备稿") { ws.closeProject() }
                        .disabled(ws.saving || ws.importing != nil || ws.hasSaveFailure)
                }
                if !ws.library.isEmpty {
                    Menu("已保存的备稿") {
                        ForEach(ws.library) { p in Button(p.name) { ws.openProject(p) } }
                    }
                }
                Divider()
                Button("打开原版提词器") { tracking.stopFollowing(); ws.classic = true }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().help("工作区选项")
        }.padding(.horizontal, 19).padding(.vertical, 12)
    }

    private var library: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                Text("本机备稿").font(.headline).foregroundStyle(.secondary)
                if ws.library.isEmpty {
                    Text("还没有保存的备稿").font(.callout).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(ws.library) { p in
                                Button { ws.openProject(p) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(p.name, systemImage: "rectangle.stack").fontWeight(.medium).lineLimit(2)
                                        Text("\(p.activeRevision.slides.count) 页").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(StudioSelectionButtonStyle())
                                .accessibilityLabel("打开备稿 \(p.name)，\(p.activeRevision.slides.count) 页")
                            }
                        }.padding(2)
                    }
                }
            }.frame(width: 180, alignment: .leading).padding(20).modifier(StudioGlass(radius: 12))
            Divider()
            StudioLunarHome {
                VStack(alignment: .leading, spacing: 14) {
                    Label("演讲工作区", systemImage: "rectangle.on.rectangle.angled")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color(red: 0.54, green: 0.89, blue: 0.82))
                    Text("打开你的 PowerPoint")
                        .font(.system(size: 29, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("将 .pptx 拖到这里，按原始页码查看胶片和演讲者备注。")
                        .font(.body).foregroundStyle(.white.opacity(0.77))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("选择胶片…") { ws.chooseFile() }
                        .controlSize(.large).buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.06, green: 0.38, blue: 0.34))
                        .padding(.top, 4)
                }
                .frame(maxWidth: 306, alignment: .leading)
                .padding(.leading, 30).padding(.trailing, 8)
            }
        }
    }

    private func sidebar(_ p: DeckProject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("胶片").font(.headline); Spacer(); Text("\(p.activeRevision.slides.count)").monospacedDigit().foregroundStyle(.secondary) }.padding(12)
            if let start = p.activeRevision.appendixSuggestion,
               !p.activeRevision.slides.contains(where: \.isAppendix) {
                Button("将第 \(start) 页起标为附录") { ws.updateAppendix(from: start) }
                    .font(.caption).padding(.horizontal, 8).padding(.bottom, 7)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(Array(p.activeRevision.slides.enumerated()), id: \.element.id) { i, slide in
                            Button { tracking.select(pageIndex: i, sentenceIndex: nil) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    StudioPageImage(store: ws.store, projectID: p.id, revisionID: p.activeRevisionID,
                                                    pageNumber: slide.pageNumber, thumbnail: true,
                                                    imageSetID: p.activeRevision.imageSetID)
                                        .frame(maxWidth: .infinity, maxHeight: 86)
                                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                                        Text("\(slide.pageNumber)").font(.caption.monospacedDigit().bold()).foregroundStyle(StudioColors.tint)
                                        Text(slide.title.isEmpty ? "胶片" : slide.title).font(.caption).lineLimit(1)
                                        Spacer()
                                        if slide.isAppendix { Image(systemName: "bookmark.fill").font(.caption2).help(appendixHelp) }
                                    }
                                }
                            }
                            .buttonStyle(StudioSelectionButtonStyle(selected: i == ws.pageIndex)).id(i)
                            .accessibilityLabel("第 \(slide.pageNumber) 页 \(slide.title)\(slide.isAppendix ? "，备查附录" : "")")
                            .accessibilityAddTraits(i == ws.pageIndex ? .isSelected : [])
                            .contextMenu { appendixMenu(slide) }
                        }
                    }.padding(.horizontal, 9).padding(.bottom, 8)
                }
                .onChange(of: tracking.displayedPageIndex) { _, page in
                    if let page { proxy.scrollTo(page, anchor: .center) }
                }
            }
            if !tracking.freeSpeaking, let anchor = tracking.previousPageAnchor,
               p.activeRevision.slides.indices.contains(anchor.pageIndex), let line = tracking.text(at: anchor) {
                let slide = p.activeRevision.slides[anchor.pageIndex]
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Button { tracking.returnToPreviousPage() } label: {
                        HStack {
                            StudioPageImage(store: ws.store, projectID: p.id, revisionID: p.activeRevisionID,
                                            pageNumber: slide.pageNumber, thumbnail: true, imageSetID: p.activeRevision.imageSetID)
                                .frame(width: 56, height: 34)
                            Text("上一页 · \(slide.pageNumber)").font(.caption.weight(.semibold))
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.uturn.backward")
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("回到第 \(slide.pageNumber) 页继续讲")
                    ScrollView {
                        Text(StudioScriptView.styled(line, at: anchor, isDraft: slide.script.origin == .ai && !slide.script.aiConfirmed,
                                                     project: p, tracking: tracking, scale: CGFloat(scriptFontSize) / 17,
                                                     enlargeCurrentWord: false))
                            .font(.system(size: CGFloat(scriptFontSize)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 95)
                }.padding(9)
            }
        }
    }

    @ViewBuilder private func appendixMenu(_ slide: DeckSlide) -> some View {
        Button("从本页起作为附录") { ws.updateAppendix(from: slide.pageNumber) }
        Button(slide.isAppendix ? "恢复为正文页" : "仅本页作为附录") { ws.updateAppendix(single: (slide.pageNumber, !slide.isAppendix)) }
        if ws.project?.activeRevision.canUndoAppendixChange == true {
            Button("撤销上次附录标记") { ws.updateAppendix(undo: true) }
        }
    }

    private func readingView(_ p: DeckProject, _ slide: DeckSlide) -> some View {
        VStack(spacing: 3) {
            HStack {
                Picker("胶片布局", selection: $readingLayout) {
                    Text("单页胶片").tag(ReadingLayout.single)
                    Text("双页胶片").tag(ReadingLayout.double)
                    Text("自动分屏").tag(ReadingLayout.automatic)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("双页立即显示下一页。自动分屏在本页剩三句时展开。")
                Spacer()
                Button { tracking.select(pageIndex: ws.pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(ws.pageIndex == 0).accessibilityLabel("上一页")
                Button { tracking.select(pageIndex: ws.pageIndex + 1, fromPreview: readingLayout != .single) } label: { Image(systemName: "chevron.right") }
                    .disabled(ws.pageIndex + 1 >= p.activeRevision.slides.count).accessibilityLabel("下一页")
            }.padding(.horizontal, 12).padding(.vertical, 4)
            readingPanes(p, slide)
        }
    }

    private func readingPanes(_ p: DeckProject, _ slide: DeckSlide) -> some View {
        GeometryReader { size in
            let base = 0.43 - Double(min(8, max(1, upcomingSentences))) * 0.021
            let ratio = min(0.65, max(0.12, base + slideHeightOffset + resizing / max(1, size.size.height)))
            let previewHeight = max(55, size.size.height * ratio)

            let next: Int? = switch readingLayout {
            case .single: nil
            case .double: tracking.twoPagePreviewIndex
            case .automatic: tracking.previewPageIndex
            }
            let split = next != nil || readingLayout == .double
            HStack(alignment: .top, spacing: 8) {
                currentPage(p, slide, height: previewHeight, base: base, available: size.size.height, split: split)
                    .frame(minWidth: 0, maxWidth: .infinity)
                if let next, p.activeRevision.slides.indices.contains(next) {
                    nextPage(p, p.activeRevision.slides[next], index: next, height: previewHeight)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .id(p.activeRevision.slides[next].id)
                } else if split {
                    ContentUnavailableView("已到最后一页", systemImage: "rectangle.stack")
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(StudioGlass(radius: 15))
                }
            }.padding(.horizontal, 8).padding(.bottom, 4)
        }
    }

    private func currentPage(_ p: DeckProject, _ slide: DeckSlide, height: CGFloat,
                             base: Double, available: CGFloat, split: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioCuePreview(ws: ws, tracking: tracking, project: p, slide: slide,
                             height: height, compact: split)
            ZStack {
                Divider()
                Capsule().fill(.secondary.opacity(0.4)).frame(width: 34, height: 3)
            }
            .frame(maxWidth: .infinity).frame(height: 10).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($resizing) { value, state, _ in state = value.translation.height }
                .onEnded { value in
                    let target = base + slideHeightOffset + value.translation.height / max(1, available)
                    slideHeightOffset = min(0.65, max(0.12, target)) - base
                })
            .accessibilityLabel("胶片与讲稿分隔条")
            .accessibilityAdjustableAction { direction in
                let target = base + slideHeightOffset + (direction == .increment ? -0.05 : 0.05)
                slideHeightOffset = min(0.65, max(0.12, target)) - base
            }
            .help("上下拖动调整讲稿区域高度")
            StudioScriptView(ws: ws, tracking: tracking, project: p, slide: slide, fontSize: $scriptFontSize,
                             currentPageOnly: readingLayout != .single)
                .id("\(p.id)-\(p.activeRevisionID)-\(slide.id)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(StudioGlass(radius: 15))
        }
    }

    private func nextPage(_ p: DeckProject, _ slide: DeckSlide, index: Int, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("下一页 · \(slide.pageNumber)").font(.callout.monospacedDigit()).foregroundStyle(StudioColors.tint)
                Text(slide.title).font(.headline).lineLimit(1)
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 7).modifier(StudioGlass(radius: 10))
            StudioPageImage(store: ws.store, projectID: p.id, revisionID: p.activeRevisionID,
                            pageNumber: slide.pageNumber, imageSetID: p.activeRevision.imageSetID)
                .frame(maxWidth: .infinity).frame(height: height).padding(.vertical, 5)
            Divider().frame(height: 10)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("下一页讲稿").font(.headline)
                    Spacer()
                    Button("从此页继续") { tracking.select(pageIndex: index, fromPreview: true) }
                }.padding(.horizontal, 14).padding(.vertical, 11)
                let lines = tracking.sentences(on: index)
                if lines.isEmpty {
                    Text("本页尚无讲稿").foregroundStyle(.secondary).padding(.horizontal, 14)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: CGFloat(scriptFontSize) * 0.65) {
                            ForEach(lines.indices, id: \.self) { line in
                                Button {
                                    tracking.select(pageIndex: index, sentenceIndex: line, fromPreview: true)
                                } label: {
                                    Text(previewText(lines[line], project: p, page: index, line: line)).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("从第 \(slide.pageNumber) 页第 \(line + 1) 句继续")
                                .accessibilityLabel("从第 \(slide.pageNumber) 页第 \(line + 1) 句继续：\(lines[line])")
                            }
                        }.font(.system(size: CGFloat(scriptFontSize))).lineSpacing(CGFloat(scriptFontSize) / 4)
                         .padding(.horizontal, 14).padding(.bottom, 12)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
             .modifier(StudioGlass(radius: 15))
        }
    }

    private func previewText(_ text: String, project: DeckProject, page: Int, line: Int) -> AttributedString {
        var value = AttributedString(text)
        if tracking.freeSpeaking {
            let point = CompanionTrackingPosition(pageIndex: page, sentenceIndex: line)
            value.foregroundColor = tracking.coverage.covered.contains(point) ? .secondary.opacity(0.80) : .primary
        }
        for cue in text.matches(of: #/\[[^\]]*\]/#) {
            if let range = Range(cue.range, in: value) {
                value[range].foregroundColor = StudioColors.color(project.cueColorHex)
            }
        }
        return value
    }

    private func statusLine(_ p: DeckProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if tracking.displaysFollowCapture && tracking.isListening {
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(0..<5) { bar in
                            Capsule().fill(bar < tracking.inputLevel ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 3, height: CGFloat(5 + bar * 2))
                        }
                    }.accessibilityLabel("麦克风输入音量 \(tracking.inputLevel)/5")
                } else {
                    Image(systemName: tracking.isStarting ? "hourglass" : "mic")
                }
                Text(captureLabel).fontWeight(.medium)
                if tracking.mode == .english && tracking.phase != .listeningQuestion {
                    Divider().frame(height: 12)
                    if MurmuryProcess.isInstalled {
                        Button { showFollowAudio = true } label: {
                            Text(tracking.engineName == "Whisper Turbo"
                                 ? "Whisper Turbo · " + tracking.whisperStateLabel : "Apple 听写")
                        }.buttonStyle(.borderless).help("选择听写引擎或用样音测试")
                        .popover(isPresented: $showFollowAudio) {
                            VStack(alignment: .leading, spacing: 12) {
                                StudioFollowSettings(tracking: tracking)
                            }.padding(16).frame(width: 360)
                        }
                    } else { Text("Apple 听写") }
                }
                if tracking.coverage.isMatching && tracking.displaysFollowCapture {
                    Label("正在核对要点", systemImage: "text.magnifyingglass")
                }
                Spacer(minLength: 2)
                if let warning = p.activeRevision.renderWarning { Text(warning).lineLimit(1).help(warning) }
                if let source = p.activeRevision.imageRepairSource {
                    Label("PDF 画面", systemImage: "doc.richtext").help(source.filename)
                }
                if !tracking.displaysFollowCapture {
                    if let status = ws.chartStatus { Text(status).lineLimit(1) }
                    if let status = ws.trackingPreparationStatus { Text(status).lineLimit(1) }
                    else if ws.preparedTrackingPageCount > 0 {
                        Text(ws.usesPreparedTracking ? "等义跟读已准备 \(ws.preparedTrackingPageCount) 页" : "等义跟读已停用")
                            .lineLimit(1).help(equivalentTrackingHelp)
                    }
                }
                if ws.saving { Text("正在保存…") }
            }.font(.caption).foregroundStyle(.secondary)
            if tracking.displaysFollowCapture && !tracking.lastHeard.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("听到").font(.caption.weight(.semibold)).foregroundStyle(StudioColors.tint)
                    Text(tracking.lastHeard).font(.callout).lineLimit(2).truncationMode(.head)
                }.accessibilityElement(children: .combine)
            }
        }.padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var captureLabel: String {
        if tracking.phase == .listeningQuestion {
            if tracking.isQuestionEnding { return "正在完成听题 · 位置已锁定" }
            if tracking.isListening { return "听题中 · 位置已锁定" }
            return "麦克风正在启动 · 位置已锁定"
        }
        if tracking.phase == .awaitingResume { return "等待接回讲稿" }
        if tracking.displaysFollowCapture {
            if tracking.isStarting { return tracking.followEngineStatus.isEmpty ? "正在启动听写…" : tracking.followEngineStatus }
            if !tracking.lastHeard.isEmpty { return "正在跟读" }
            return tracking.inputLevel >= 2 ? "已收到声音 · 正在听写" : "麦克风已开启 · 等你开口"
        }
        if tracking.cueArmed { return "听题待命" }
        if tracking.speechError != nil { return "跟读已中断" }
        return "麦克风未开启 · 点击「开始跟读」"
    }

}


/// Keep hover and selection independent; the Button retains its native
/// keyboard and accessibility behavior instead of using a gesture.
private struct StudioSelectionButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        Face(label: configuration.label, pressed: configuration.isPressed, selected: selected)
    }

    private struct Face<Label: View>: View {
        let label: Label
        let pressed: Bool
        let selected: Bool
        @State private var highlight: CGPoint?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7)
            let neutral: Color = colorScheme == .dark ? .white : .black
            let overlayOpacity = pressed ? 0.13 : highlight != nil ? 0.065 : 0
            label
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? StudioColors.tint.opacity(0.13) : .clear, in: shape)
                .background(neutral.opacity(overlayOpacity), in: shape)
                .overlay {
                    shape.strokeBorder(selected ? StudioColors.tint : .clear, lineWidth: 1.4)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                .overlay {
                    if let highlight {
                        shape.strokeBorder(.white.opacity(0.45), lineWidth: 1)
                            .mask { Canvas { ctx, bounds in
                                ctx.fill(Path(CGRect(origin: .zero, size: bounds)),
                                         with: .radialGradient(Gradient(colors: [.white, .clear]),
                                                               center: highlight, startRadius: 2, endRadius: 68))
                            } }
                            .allowsHitTesting(false)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): highlight = reduceMotion ? .zero : point
                    default: highlight = nil
                    }
                }
        }
    }
}
