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
                        if !cropToRegion, let region, region.isValid {
                            GeometryReader { geo in
                                let left = max(0, geo.size.width * region.x - outlinePadding)
                                let top = max(0, geo.size.height * region.y - outlinePadding)
                                let right = min(geo.size.width, geo.size.width * (region.x + region.width) + outlinePadding)
                                let bottom = min(geo.size.height, geo.size.height * (region.y + region.height) + outlinePadding)
                                Rectangle().strokeBorder(outline, lineWidth: outlinePadding > 0 ? 2 : 3)
                                    .background(outline.opacity(0.12))
                                    .frame(width: right - left, height: bottom - top)
                                    .position(x: (left + right) / 2, y: (top + bottom) / 2)
                            }
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
    @State private var isDropTarget = false
    @State private var showTrackingPreparation = false
    @State private var trackingConsent: TrackingConsent?

    private struct TrackingConsent {
        let projectID: UUID
        let revisionID: String
        let provider: StudioModelProvider
    }
    @AppStorage("studio.upcomingSentences") private var upcomingSentences = 3
    @AppStorage("studio.slideHeightOffset") private var slideHeightOffset = 0.0
    @GestureState private var resizing = CGFloat.zero
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
                    header
                    Divider()
                    if let text = ws.importing {
                        Spacer()
                        ProgressView()
                        Text(ws.repairingImages ? "正在从 \(text) 生成胶片图" : "正在导入 \(text)").font(.headline).padding()
                        Spacer()
                    } else if let p = ws.project {
                        HSplitView {
                            sidebar(p).frame(minWidth: 155, idealWidth: 195, maxWidth: 265)
                            if let slide = ws.currentSlide {
                                readingView(p, slide)
                            } else { ContentUnavailableView("没有可显示的胶片", systemImage: "rectangle.dashed") }
                        }
                        Divider()
                        statusLine(p)
                    } else { library }
                    if let message = ws.notification ?? tracking.speechError {
                        HStack {
                            Image(systemName: "info.circle").foregroundStyle(StudioColors.tint)
                            Text(message).font(.callout).textSelection(.enabled)
                            Spacer()
                            if ws.notification != nil { Button("收起") { ws.notification = nil }.buttonStyle(.borderless) }
                        }.padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
                    }
                }
                .frame(minWidth: 880, minHeight: 560)
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
            Image(systemName: "rectangle.3.group").font(.title2.weight(.semibold)).foregroundStyle(StudioColors.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Textream Studio").font(.headline)
                if let p = ws.project { Text(p.activeRevision.sourceName).lineLimit(1).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { ws.chooseFile() } label: { Label("打开胶片", systemImage: "folder") }
            Button { StudioQuestionPanel.shared.show(ws) } label: { Label("现场问答", systemImage: "bubble.left.and.bubble.right") }
            if ws.project != nil && !ws.chineseKeyPoints {
                Button {
                    if tracking.isListening || tracking.isStarting { tracking.stopFollowing() } else { tracking.startFollowing() }
                } label: {
                    Label(tracking.isListening || tracking.isStarting ? "停止跟读" : "开始跟读",
                          systemImage: tracking.isListening ? "stop.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent)
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
                        }.disabled(!ws.canPrepareTracking)
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
                }
                ForEach(ws.library) { p in
                    Button { ws.openProject(p) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(p.name, systemImage: "rectangle.stack").fontWeight(.medium).lineLimit(2)
                            Text("\(p.activeRevision.slides.count) 页").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.frame(width: 180, alignment: .leading).padding(20).background(.bar)
            Divider()
            VStack(spacing: 17) {
                Spacer()
                Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 46, weight: .light))
                    .foregroundStyle(StudioColors.tint)
                Text("打开你的 PowerPoint").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("将 .pptx 拖到这里，按原始页码查看胶片和演讲者备注。")
                    .font(.body).foregroundStyle(.secondary)
                Button("选择胶片…") { ws.chooseFile() }.controlSize(.large).buttonStyle(.borderedProminent)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                        if slide.isAppendix { Image(systemName: "bookmark.fill").font(.caption2).help("备查附录") }
                                    }
                                }
                                .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                                .background(i == ws.pageIndex ? StudioColors.tint.opacity(0.12) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(i == ws.pageIndex ? StudioColors.tint : .clear))
                            }
                            .buttonStyle(.plain).id(i)
                            .accessibilityLabel("选中第 \(slide.pageNumber) 页 \(slide.title)")
                            .contextMenu { appendixMenu(slide) }
                        }
                    }.padding(.horizontal, 9).padding(.bottom, 8)
                }
                .onChange(of: tracking.position?.pageIndex) { _, page in
                    if let page { proxy.scrollTo(page, anchor: .center) }
                }
            }
        }.background(.bar)
    }

    @ViewBuilder private func appendixMenu(_ slide: DeckSlide) -> some View {
        Button("从本页起作为附录") { ws.updateAppendix(from: slide.pageNumber) }
        Button(slide.isAppendix ? "恢复为正文页" : "仅本页作为附录") { ws.updateAppendix(single: (slide.pageNumber, !slide.isAppendix)) }
        if ws.project?.activeRevision.canUndoAppendixChange == true {
            Button("撤销上次附录标记") { ws.updateAppendix(undo: true) }
        }
    }

    private func readingView(_ p: DeckProject, _ slide: DeckSlide) -> some View {
        GeometryReader { size in
            let base = 0.43 - Double(min(8, max(1, upcomingSentences))) * 0.021
            let ratio = min(0.65, max(0.12, base + slideHeightOffset + resizing / max(1, size.size.height)))
            VStack(alignment: .leading, spacing: 0) {
                StudioCuePreview(ws: ws, tracking: tracking, project: p, slide: slide,
                                 height: max(55, size.size.height * ratio))
                ZStack {
                    Divider()
                    Capsule().fill(.secondary.opacity(0.4)).frame(width: 34, height: 3)
                }
                .frame(maxWidth: .infinity).frame(height: 10).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($resizing) { value, state, _ in state = value.translation.height }
                    .onEnded { value in
                        let target = base + slideHeightOffset + value.translation.height / max(1, size.size.height)
                        slideHeightOffset = min(0.65, max(0.12, target)) - base
                    })
                .accessibilityLabel("胶片与讲稿分隔条")
                .accessibilityAdjustableAction { direction in
                    let target = base + slideHeightOffset + (direction == .increment ? -0.05 : 0.05)
                    slideHeightOffset = min(0.65, max(0.12, target)) - base
                }
                .help("上下拖动调整讲稿区域高度")
                StudioScriptView(ws: ws, tracking: tracking, project: p, slide: slide)
                    .id("\(p.id)-\(p.activeRevisionID)-\(slide.id)")
            }
        }
    }

    private func statusLine(_ p: DeckProject) -> some View {
        HStack(spacing: 12) {
            Label(tracking.phase == .listeningQuestion ? "听题中 · 位置已锁定" :
                    tracking.phase == .awaitingResume ? "等待接回讲稿" :
                    tracking.isListening ? "正在跟随" : "手动定位",
                  systemImage: tracking.isListening ? "waveform" : "cursorarrow")
            if let warning = p.activeRevision.renderWarning { Text(warning).lineLimit(1).help(warning) }
            if let source = p.activeRevision.imageRepairSource {
                Label("PDF 画面", systemImage: "doc.richtext").help(source.filename)
            }
            Spacer()
            if let status = ws.chartStatus { Text(status).lineLimit(1) }
            if let status = ws.trackingPreparationStatus {
                Text(status).lineLimit(1).help(status)
            } else if ws.preparedTrackingPageCount > 0 {
                Text(ws.usesPreparedTracking ? "等义跟读已准备 \(ws.preparedTrackingPageCount) 页" : "等义跟读已停用")
                    .lineLimit(1)
            }
            Text(ws.saving ? "正在保存…" : "本机备稿")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6)
    }
}
