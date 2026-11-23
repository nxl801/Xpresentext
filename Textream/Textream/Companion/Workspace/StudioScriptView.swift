import SwiftUI

struct StudioScriptView: View {
    @ObservedObject var ws: StudioWorkspace
    @ObservedObject var tracking: CompanionTrackingController
    let project: DeckProject
    let slide: DeckSlide
    @Binding var fontSize: Int
    private var scale: CGFloat { CGFloat(fontSize) / 17 }
    var currentPageOnly = false
    @State private var editing = false
    @State private var editedText = ""
    private var isDraft: Bool { slide.script.origin == .ai && !slide.script.aiConfirmed }
    private var sentences: [String] { tracking.sentences(on: slide.pageNumber - 1) }
    @AppStorage("studio.upcomingSentences") private var upcoming = 3
    @AppStorage("studio.showFullScript") private var showFullScript = false
    @AppStorage("studio.enlargeCurrentWord") private var enlargeCurrentWord = false
    private var visiblePositions: [CompanionTrackingPosition] {
        if tracking.freeSpeaking {
            return sentences.indices.map { CompanionTrackingPosition(pageIndex: slide.pageNumber - 1, sentenceIndex: $0) }
        }
        if showFullScript || slide.isAppendix {
            let page = slide.pageNumber - 1
            let rows = sentences.indices.map { CompanionTrackingPosition(pageIndex: page, sentenceIndex: $0) }
            if !slide.isAppendix, let previous = tracking.previousReadPosition, previous.pageIndex < page {
                return tracking.previousPageAnchor?.pageIndex == previous.pageIndex ? rows : [previous] + rows
            }
            return rows
        }
        let window = tracking.readingWindow(upcoming: upcoming).filter { $0.pageIndex != tracking.previousPageAnchor?.pageIndex }
        return currentPageOnly ? window.filter { $0.pageIndex <= slide.pageNumber - 1 } : window
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { scriptTitle; Spacer(); fontControls; scriptControls }
                VStack(alignment: .leading, spacing: 6) {
                    HStack { scriptTitle; Spacer(); fontControls }
                    scriptControls
                }
            }.padding(.horizontal, 14).padding(.vertical, 9)
            if tracking.mode == .english && !slide.isAppendix {
                HStack(spacing: 8) {
                    Picker("讲稿模式", selection: Binding(get: { tracking.freeSpeaking }, set: tracking.setFreeSpeaking)) {
                        Text("逐句跟读").tag(false)
                        Text("自由讲解").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer(minLength: 0)
                }.font(.caption).padding(.horizontal, 16).padding(.bottom, 5)
                if tracking.freeSpeaking {
                    HStack(spacing: 6) {
                        let page = slide.pageNumber - 1
                        let total = sentences.filter { !CompanionTrackingPage.wordRanges(in: $0).isEmpty }.count
                        let done = tracking.coverage.covered.filter { $0.pageIndex == page }.count
                        Text(done < total ? "本页还有 \(total - done) 项待讲" : total == 0 ? "本页暂无要点" : "本页已讲完 · 手动翻页")
                            .monospacedDigit()
                            .accessibilityValue("已讲 \(done)/\(total)")
                        Spacer(minLength: 0)
                        Menu {
                            if MurmuryProcess.isInstalled {
                                if tracking.coverage.state != .ready {
                                    Button("下载或修复 FineCat（1.5 GB）") { tracking.coverage.startModel(download: true) }
                                        .disabled(tracking.coverage.state == .loading)
                                }
                                Button("选择 FineCat 模型文件夹…") {
                                    let picker = NSOpenPanel()
                                    picker.canChooseFiles = false
                                    picker.canChooseDirectories = true
                                    if picker.runModal() == .OK, let url = picker.url { tracking.coverage.startModel(download: false, directory: url) }
                                }
                                Divider()
                            }
                            Button("清空本场已讲记录") { tracking.coverage.reset() }
                        } label: { Text("FineCat · " + tracking.coverage.modelLabel) }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("FineCat 负责判断讲过哪些要点。听写引擎显示在窗口底部。")
                    }.font(.caption).padding(.horizontal, 16).padding(.bottom, 5)
                }
                if tracking.freeSpeaking && tracking.coverage.state != .ready {
                    Text(tracking.coverage.status).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 4).textSelection(.enabled)
                }
            }
            if sentences.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(slide.isAppendix ? "备查附录" : "本页尚无讲稿").font(.title3.weight(.medium))
                    Text(slide.isAppendix ? "这页可供问答引用。" : "可粘贴自己的讲稿，或根据本页资料生成英文稿。")
                        .font(.body).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.vertical, 12)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            let positions = visiblePositions
                            ForEach(Array(positions.enumerated()), id: \.element) { offset, position in
                                if position.pageIndex != slide.pageNumber - 1,
                                   offset == 0 || positions[offset - 1].pageIndex != position.pageIndex {
                                    Divider()
                                    Text(position.pageIndex < slide.pageNumber - 1
                                         ? "第 \(position.pageIndex + 1) 页 · 已读"
                                         : "预览第 \(position.pageIndex + 1) 页")
                                        .font(.caption.weight(.semibold)).foregroundStyle(StudioColors.tint)
                                }
                                sentenceButton(position)
                            }
                        }.padding(.horizontal, 14).padding(.bottom, 12)
                    }
                    .onChange(of: tracking.coverage.liveWord?.position ?? tracking.promptPosition, initial: true) { _, position in
                        if tracking.freeSpeaking { if let position { proxy.scrollTo(position, anchor: .center) }; return }
                        if let target = showFullScript ? position : visiblePositions.first { proxy.scrollTo(target, anchor: showFullScript ? .center : .top) }
                    }
                    .onChange(of: showFullScript) { _, full in
                        if let target = full ? tracking.promptPosition : visiblePositions.first { proxy.scrollTo(target, anchor: full ? .center : .top) }
                    }
                }
            }
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 13) {
                Text("第 \(slide.pageNumber) 页 · 编辑讲稿").font(.title2.bold())
                TextEditor(text: $editedText).font(.system(size: 17)).padding(5)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                HStack {
                    Spacer(); Button("取消") { editing = false }.keyboardShortcut(.cancelAction)
                    Button("保存讲稿") {
                        if ws.project?.id == project.id, ws.project?.activeRevisionID == project.activeRevisionID,
                           ws.currentSlide?.id == slide.id { ws.editCurrentSlide { $0.script.edit(editedText) } }
                        editing = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(minWidth: 530, minHeight: 360)
        }
    }

    private var scriptTitle: some View {
        HStack(spacing: 8) {
            Text("本页讲稿").font(.headline)
            if isDraft {
                Text("AI 补稿").font(.caption).foregroundStyle(StudioColors.color(project.draftColorHex))
                Button("确认为我的讲稿") { ws.editCurrentSlide { $0.script.confirmAI() } }.font(.caption)
            }
        }
    }

    private var fontControls: some View {
        HStack(spacing: 4) {
            Button("A−") { fontSize = max(12, fontSize - 1) }
                .disabled(fontSize <= 12).help("缩小讲稿字号").accessibilityLabel("缩小讲稿字号")
            Text("\(fontSize)").monospacedDigit().font(.caption)
                .accessibilityLabel("讲稿字号 \(fontSize) 点")
            Button("A+") { fontSize = min(32, fontSize + 1) }
                .disabled(fontSize >= 32).help("放大讲稿字号").accessibilityLabel("放大讲稿字号")
        }.controlSize(.small).fixedSize()
    }

    private var scriptControls: some View {
        HStack(spacing: 8) {
            if !sentences.isEmpty && !tracking.freeSpeaking {
                Menu {
                    Picker("预读范围", selection: Binding(get: { upcoming }, set: { upcoming = $0; showFullScript = false })) {
                        ForEach(1...8, id: \.self) { n in Text("后面 \(n) 句").tag(n) }
                    }.pickerStyle(.inline)
                    Divider()
                    Toggle("查看本页全文", isOn: $showFullScript)
                    Toggle("放大当前词", isOn: $enlargeCurrentWord)
                } label: {
                    Text(showFullScript || slide.isAppendix ? "本页全文" : "预读 \(upcoming) 句")
                        .foregroundStyle(.primary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("调整讲稿显示范围")
            }
            if slide.script.isEmpty && !slide.isAppendix {
                Button {
                    ws.generateDraft()
                } label: {
                    Label(ws.generatingPage == slide.pageNumber - 1 ? "正在生成…" : "生成英文稿", systemImage: "sparkles")
                }
                .disabled(ws.generatingPage != nil)
            }
            Button {
                tracking.stopFollowing()
                editedText = slide.script.text
                editing = true
            } label: { Label("编辑", systemImage: "pencil") }
        }
    }

    @ViewBuilder private func sentenceButton(_ position: CompanionTrackingPosition) -> some View {
        if let sentence = tracking.text(at: position), ws.slides.indices.contains(position.pageIndex) {
            let current = position == (tracking.coverage.liveWord?.position ?? tracking.promptPosition)
            let done = tracking.freeSpeaking && tracking.coverage.covered.contains(position)
            let source = ws.slides[position.pageIndex].script
            Button { tracking.select(pageIndex: position.pageIndex, sentenceIndex: position.sentenceIndex) } label: {
                HStack(alignment: .top, spacing: 10) {
                    if tracking.freeSpeaking {
                        Image(systemName: done ? "checkmark.circle.fill" : current ? "arrowtriangle.right.fill" : "circle")
                            .font(.system(size: done || current ? 10 : 6))
                            .foregroundStyle(current ? StudioColors.tint : Color.secondary)
                            .frame(width: 12, height: 20 * scale)
                            .accessibilityHidden(true)
                    } else {
                        Rectangle().fill(current ? StudioColors.tint : .clear).frame(width: 3)
                    }
                    Text(Self.styled(sentence, at: position, isDraft: source.origin == .ai && !source.aiConfirmed, project: project, tracking: tracking, scale: scale, enlargeCurrentWord: enlargeCurrentWord))
                        .font(.system(size: (current ? 20 : 17) * scale, weight: current ? .medium : .regular))
                        .lineSpacing(4 * scale).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 5).padding(.horizontal, 7)
                .background(current ? StudioColors.tint.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain).id(position)
            .accessibilityLabel("从第 \(position.pageIndex + 1) 页此句继续：\(sentence)")
            .accessibilityValue(tracking.freeSpeaking ? (done ? "已讲" : "待讲") : "")
        }
    }

    static func styled(_ text: String, at position: CompanionTrackingPosition, isDraft: Bool,
                       project: DeckProject, tracking: CompanionTrackingController,
                       scale: CGFloat, enlargeCurrentWord: Bool) -> AttributedString {
        var value = AttributedString(text)
        value.foregroundColor = isDraft ? StudioColors.color(project.draftColorHex) : Color.primary
        let readColor = Color.secondary.opacity(0.80)
        if tracking.freeSpeaking {
            value.foregroundColor = tracking.coverage.covered.contains(position) ? readColor : Color.primary
            if let live = tracking.coverage.liveWord, live.position == position {
                let ranges = CompanionTrackingPage.wordRanges(in: text)
                if ranges.indices.contains(live.index), let range = Range(ranges[live.index], in: value) {
                    value[range].foregroundColor = StudioColors.tint
                    value[range].underlineStyle = .single
                }
            }
        } else if let marked = tracking.readWords[position] {
            let prompt = tracking.promptPosition
            let past = prompt.map { (position.pageIndex, position.sentenceIndex ?? -1) < ($0.pageIndex, $0.sentenceIndex ?? -1) } ?? false
            if past && position != tracking.position { value.foregroundColor = readColor }
            let last = position == tracking.position && (position == prompt || position == tracking.previousPageAnchor) ? marked.last : nil
            let words = CompanionTrackingPage.wordRanges(in: text)
            for index in marked where words.indices.contains(index) {
                var range = words[index]
                // Keep both parts of a spoken contraction together when the
                // recognizer sends "we" and "ve" as separate lexical tokens.
                if index > 0, marked.contains(index - 1), ["'", "’", "‘"].contains(String(text[words[index - 1].upperBound..<range.lowerBound])) {
                    range = words[index - 1].lowerBound..<range.upperBound
                }
                guard let lo = AttributedString.Index(range.lowerBound, within: value),
                      let hi = AttributedString.Index(range.upperBound, within: value) else { continue }
                if index == last {
                    value[lo..<hi].foregroundColor = isDraft ? StudioColors.color(project.draftColorHex) : StudioColors.tint
                    value[lo..<hi].underlineStyle = .single
                    value[lo..<hi].font = .system(size: (enlargeCurrentWord ? 24 : 20) * scale, weight: .bold)
                } else {
                    value[lo..<hi].foregroundColor = readColor
                }
            }
        }
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: #"\[[^\]]*\]"#, options: .regularExpression, range: start..<text.endIndex) {
            if let lo = AttributedString.Index(range.lowerBound, within: value),
               let hi = AttributedString.Index(range.upperBound, within: value) {
                value[lo..<hi].foregroundColor = StudioColors.color(project.cueColorHex)
            }
            start = range.upperBound
        }
        return value
    }
}

struct StudioSettings: View {
    @ObservedObject var ws: StudioWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var feedback = ""
    @State private var savedKey: Bool?
    @State private var testing: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("模型与显示设置").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("在线问答与补稿").font(.headline)
                    Picker("模型服务", selection: Binding(get: { ws.provider }, set: selectProvider)) {
                        ForEach(StudioModelProvider.allCases) { provider in Text(provider.label).tag(provider) }
                    }
                    providerDetails
                    if ws.provider.usesAPIKey {
                        SecureField(ws.provider == .bigmodel ? "标准 API 密钥" : "API 密钥", text: $key)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        if ws.provider.usesAPIKey { Text(keyStatus).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(testing == nil ? "用示例测试" : "正在测试…") { checkConnection() }
                            .disabled(testing != nil || (ws.provider.usesAPIKey && !key.isEmpty))
                            .help("用一条内置问题检查连接。只发送示例文字。")
                        if ws.provider.usesAPIKey {
                            Button("保存密钥") {
                                do {
                                    try StudioCredentials.update(key, for: ws.provider)
                                    key = ""
                                    feedback = savedKey == true ? "已更新密钥。" : ""
                                    savedKey = true
                                }
                                catch { feedback = error.localizedDescription }
                            }.disabled(key.isEmpty)
                        }
                    }
                    if !feedback.isEmpty { Text(feedback).font(.callout) }
                    if MurmuryProcess.isInstalled { StudioFollowSettings(tracking: ws.tracking) }
                    StudioSpeechSettings()
                    Toggle("中文关键点模式（点击定位）", isOn: $ws.chineseKeyPoints)
                    if let p = ws.project {
                        Divider()
                        if ws.provider.supportsOnlineImages {
                            Toggle("允许这份 PPT 在备稿时在线读图",
                                   isOn: Binding(get: { ws.project?.onlineImageReadingEnabled ?? false },
                                                 set: { ws.setOnlineImages($0) }))
                            Text("优先在本机读取图表。开启后，复杂图表的裁图或相关单页可交给当前选中的模型服务分析。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ColorPicker("动作提示", selection: Binding(get: { StudioColors.color(p.cueColorHex) },
                                                               set: { ws.updateColors(cue: StudioColors.hex($0)) }), supportsOpacity: false)
                        ColorPicker("AI 补稿", selection: Binding(get: { StudioColors.color(p.draftColorHex) },
                                                                set: { ws.updateColors(draft: StudioColors.hex($0)) }), supportsOpacity: false)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 230, idealHeight: 435, maxHeight: 550)
        }.padding(22).frame(width: 450)
        .onAppear { refreshKeyStatus() }
        .onChange(of: ws.provider) { _, _ in
            clearInputs()
            refreshKeyStatus()
        }
        .onDisappear { clearInputs() }
    }

    @ViewBuilder private var providerDetails: some View {
        switch ws.provider {
        case .grokCLI:
            VStack(alignment: .leading, spacing: 4) {
                Text(GrokCLIQAModel.isInstalled ? "Grok CLI 已安装" : "Grok CLI 未安装或不可执行")
                Text("使用这台 Mac 上的 Grok CLI 登录。用示例测试可检查连接。")
                Text("追问可能较慢，每题最多等待 \(GrokCLIQAModel.answerTimeoutSeconds) 秒。")
                if !ws.provider.supportsOnlineImages {
                    Text("图表问答使用本机读取的依据。")
                }
            }.font(.caption).foregroundStyle(.secondary)
        case .deepseek:
            VStack(alignment: .leading, spacing: 4) {
                Text("API 地址  \(DeepSeekQAModel.baseURL.absoluteString)").textSelection(.enabled)
                Text("模型  \(ws.provider.modelID)").textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
        case .bigmodel:
            VStack(alignment: .leading, spacing: 4) {
                Text(GLMQAModel.chinaEndpoint.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                Text("请使用智谱开放平台的标准 API 密钥。Coding Plan 套餐适用于智谱指定的工具。")
                if StudioCredentials.bigmodelLegacyIsCodingPlan {
                    Text("原 Coding Plan 密钥已单独保留。请另存标准 API 密钥。")
                }
            }.font(.caption).foregroundStyle(.secondary)
        case .zai, .gemini:
            EmptyView()
        }
    }

    private var keyStatus: String {
        guard let savedKey else { return "密钥保存到此 Mac 的钥匙串。" }
        return savedKey ? "已保存到本机钥匙串。" : "此服务尚未保存密钥。"
    }

    private func selectProvider(_ provider: StudioModelProvider) {
        guard ws.provider != provider else { return }
        clearInputs()
        savedKey = nil
        ws.selectProvider(provider)
    }

    private func clearInputs() {
        testing?.cancel()
        testing = nil
        key = ""
        feedback = ""
    }

    private func refreshKeyStatus() {
        savedKey = ws.provider.usesAPIKey ? StudioCredentials.hasSavedKey(for: ws.provider) : nil
    }

    private func checkConnection() {
        feedback = ""
        let provider = ws.provider
        let session = CompanionQASession(service: ws.qaService)
        testing = Task { @MainActor in
            defer { session.cancel() }
            session.submit("What is one simple way to start a presentation?")
            while session.state == .answering && session.answer.shortAnswer == nil {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard !Task.isCancelled, ws.provider == provider else { return }
            if let sentence = session.answer.shortAnswer, let elapsed = session.answer.firstSentenceElapsed {
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                feedback = String(format: "已连接，首句 %.1f 秒。", seconds) + "\n" + sentence
            } else if case .failed(let error) = session.state {
                feedback = error.localizedDescription
            }
            testing = nil
        }
    }
}

struct StudioReviews: View {
    @ObservedObject var ws: StudioWorkspace
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("核对换版讲稿").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            if let rev = ws.project?.activeRevision {
                if rev.revisionReviews.isEmpty { Text("本版待核对的页已处理完。") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(rev.revisionReviews) { review in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("旧第 \(review.oldSlide.pageNumber) 页 · \(review.oldSlide.title)").font(.headline)
                                Text(review.oldSlide.script.text.isEmpty ? "没有旧稿" : review.oldSlide.script.text)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                HStack {
                                    Button("保留新版内容") { ws.finishReview(review) }
                                    Menu("选择接收旧稿的页…") {
                                        ForEach(rev.slides) { slide in
                                            Button("用旧稿替换第 \(slide.pageNumber) 页 · \(slide.title)") {
                                                ws.finishReview(review, transferTo: slide.pageNumber)
                                            }
                                        }
                                    }
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
        }.padding(22).frame(width: 580, height: 425)
    }
}
