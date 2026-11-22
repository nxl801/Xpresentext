import SwiftUI

struct StudioScriptView: View {
    @ObservedObject var ws: StudioWorkspace
    @ObservedObject var tracking: CompanionTrackingController
    let project: DeckProject
    let slide: DeckSlide
    @State private var editing = false
    @State private var editedText = ""
    private var isDraft: Bool { slide.script.origin == .ai && !slide.script.aiConfirmed }
    private var sentences: [String] { tracking.sentences(on: slide.pageNumber - 1) }
    @AppStorage("studio.upcomingSentences") private var upcoming = 3
    @AppStorage("studio.showFullScript") private var showFullScript = false
    @AppStorage("studio.enlargeCurrentWord") private var enlargeCurrentWord = false
    private var visiblePositions: [CompanionTrackingPosition] {
        if showFullScript || slide.isAppendix {
            return sentences.indices.map { CompanionTrackingPosition(pageIndex: slide.pageNumber - 1, sentenceIndex: $0) }
        }
        return tracking.readingWindow(upcoming: upcoming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("逐页讲稿").font(.headline)
                if isDraft {
                    Text("AI 补稿").font(.caption).foregroundStyle(StudioColors.color(project.draftColorHex))
                    Button("确认为我的讲稿") { ws.editCurrentSlide { $0.script.confirmAI() } }.font(.caption)
                }
                Spacer()
                if !sentences.isEmpty {
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
            }.padding(.horizontal, 20).padding(.vertical, 11)
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
                                    Label("预览第 \(position.pageIndex + 1) 页", systemImage: "arrow.turn.down.right")
                                        .font(.caption.weight(.semibold)).foregroundStyle(StudioColors.tint)
                                }
                                sentenceButton(position)
                            }
                        }.padding(.horizontal, 14).padding(.bottom, 12)
                    }
                    .onChange(of: tracking.position, initial: true) { _, position in
                        if let target = showFullScript ? position : visiblePositions.first { proxy.scrollTo(target, anchor: showFullScript ? .center : .top) }
                    }
                    .onChange(of: showFullScript) { _, full in
                        if let position = tracking.position { proxy.scrollTo(position, anchor: full ? .center : .top) }
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

    @ViewBuilder private func sentenceButton(_ position: CompanionTrackingPosition) -> some View {
        if let sentence = tracking.text(at: position), ws.slides.indices.contains(position.pageIndex) {
            let current = position == tracking.position
            let source = ws.slides[position.pageIndex].script
            Button { tracking.select(pageIndex: position.pageIndex, sentenceIndex: position.sentenceIndex) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle().fill(current ? StudioColors.tint : .clear).frame(width: 3)
                    Text(styled(sentence, at: position, isDraft: source.origin == .ai && !source.aiConfirmed))
                        .font(.system(size: current ? 20 : 17, weight: current ? .medium : .regular))
                        .lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 5).padding(.horizontal, 7)
                .background(current ? StudioColors.tint.opacity(0.085) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain).id(position)
            .accessibilityLabel("从第 \(position.pageIndex + 1) 页此句继续：\(sentence)")
        }
    }

    private func styled(_ text: String, at position: CompanionTrackingPosition, isDraft: Bool) -> AttributedString {
        var value = AttributedString(text)
        value.foregroundColor = isDraft ? StudioColors.color(project.draftColorHex) : Color.primary
        if let marked = tracking.readWords[position] {
            let last = position == tracking.position ? marked.last : nil
            let base = isDraft ? StudioColors.color(project.draftColorHex) : Color.secondary
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
                    value[lo..<hi].foregroundColor = isDraft ? base : StudioColors.tint
                    value[lo..<hi].underlineStyle = .single
                    value[lo..<hi].font = .system(size: enlargeCurrentWord ? 24 : 20, weight: .bold)
                } else {
                    value[lo..<hi].foregroundColor = isDraft ? base.opacity(0.70) : base
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
