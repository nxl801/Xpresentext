import SwiftUI
import AppKit

@MainActor
final class StudioQuestionPanel: NSObject, NSWindowDelegate {
    static let shared = StudioQuestionPanel()
    private var panel: NSPanel?
    private weak var workspace: StudioWorkspace?

    func show(_ ws: StudioWorkspace) {
        workspace = ws
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let host = NSHostingController(rootView: StudioQuestionView(ws: ws, tracking: ws.tracking))
        let newPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 478, height: 505),
                               styleMask: [.titled, .closable, .resizable, .utilityWindow],
                               backing: .buffered, defer: false)
        newPanel.title = "现场问答 · Textream Studio"
        newPanel.contentViewController = host
        newPanel.isReleasedWhenClosed = false
        newPanel.delegate = self
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.isOpaque = false
        newPanel.backgroundColor = .windowBackgroundColor
        newPanel.level = UserDefaults.standard.object(forKey: "studio.panelPinned") as? Bool == false ? .normal : .floating
        newPanel.alphaValue = UserDefaults.standard.object(forKey: "studio.panelOpacity") as? Double ?? 0.94
        newPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        newPanel.minSize = NSSize(width: 360, height: 320)
        if !newPanel.setFrameUsingName("StudioQuestionPanel") { newPanel.center() }
        newPanel.setFrameAutosaveName("StudioQuestionPanel")
        panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func appearance(pinned: Bool, opacity: Double) {
        panel?.level = pinned ? .floating : .normal
        panel?.alphaValue = opacity
    }
    func windowWillClose(_ notification: Notification) {
        workspace?.tracking.disarmQuestionCue()
        workspace?.tracking.cancelQuestion()
        workspace?.questions.clearSearch()
        panel = nil
    }
}

struct StudioQuestionView: View {
    @ObservedObject var ws: StudioWorkspace
    @ObservedObject var tracking: CompanionTrackingController
    @State private var input = ""
    @State private var editingTranscript: UUID?
    @FocusState private var inputFocused: Bool
    @State private var followUp = false
    @State private var expanded = false
    @State private var preview: QACitation?
    @State private var settings = false
    @State private var showControls = false
    @State private var sendQuestionAudio = false
    @AppStorage("studio.questionLanguage") private var speechLanguage = "zh-CN"
    @AppStorage("studio.panelPinned") private var pinned = true
    @AppStorage("studio.panelOpacity") private var opacity = 0.94
    private var session: CompanionQASession { ws.questions }
    private var listening: Bool { tracking.phase == .listeningQuestion }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
            answers
            Divider()
            questionControls
        }
        .frame(minWidth: 345, minHeight: 285)
        .background(.regularMaterial)
        .onChange(of: tracking.phase) { old, new in
            if new != .listeningQuestion { session.clearSearch() }
            if old == .listeningQuestion, new == .awaitingResume,
               tracking.speechError != nil, input.isEmpty {
                input = tracking.questionTranscript
            }
        }
        .onChange(of: tracking.questionTranscript) { _, text in
            if listening { session.prepareSources(for: text, currentPageIndex: ws.project == nil ? nil : ws.pageIndex, followUp: followUp) }
        }
        .onChange(of: ws.pageIndex) { _, page in
            if listening { session.prepareSources(for: tracking.questionTranscript, currentPageIndex: page, followUp: followUp) }
        }
        .onChange(of: ws.provider) { _, _ in tracking.disarmQuestionCue(); tracking.cancelQuestion() }
        .onChange(of: sendQuestionAudio) { _, _ in tracking.disarmQuestionCue() }
        .onChange(of: speechLanguage) { _, _ in tracking.disarmQuestionCue() }
        .onChange(of: pinned) { _, _ in StudioQuestionPanel.shared.appearance(pinned: pinned, opacity: opacity) }
        .onChange(of: opacity) { _, _ in StudioQuestionPanel.shared.appearance(pinned: pinned, opacity: opacity) }
        .onChange(of: ws.project?.activeRevisionID) { _, _ in resetQuestionView() }
        .onChange(of: ws.project?.id) { _, _ in resetQuestionView() }
        .onChange(of: session.editableTranscriptID) { _, id in
            if let editingTranscript, editingTranscript != id { cancelCorrection() }
        }
        .sheet(item: $preview) { citation in
            StudioCitationPreview(ws: ws, citation: citation)
        }
        .sheet(isPresented: $settings) { StudioSettings(ws: ws) }
    }

    private var panelHeader: some View {
        HStack {
            Label("现场问答", systemImage: "bubble.left.and.bubble.right.fill").font(.headline)
                .foregroundStyle(StudioColors.tint)
            Spacer()
            if let p = ws.project { Text(p.name).font(.caption).lineLimit(1).foregroundStyle(.secondary) }
            Button { showControls.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless).accessibilityLabel("问答显示设置")
                .popover(isPresented: $showControls) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("窗口置顶", isOn: $pinned)
                        Text("窗口不透明度").font(.caption)
                        Slider(value: $opacity, in: 0.55...1)
                        OfflineAnswerSettings()
                        Button("模型设置…") { showControls = false; settings = true }
                    }.padding(16).frame(width: 215)
                }
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var answers: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if listening, !session.suggestedSources.isEmpty {
                    Text("正在听 · 可能相关的页面").font(.caption).foregroundStyle(.secondary)
                    ForEach(session.suggestedSources) { cite in
                        Button("第 \(cite.pageNumber) 页 · \(cite.pageTitle)") { preview = cite }
                            .buttonStyle(.borderless)
                    }
                }
                if !session.question.isEmpty {
                    if listening { Text("上一题").font(.caption).foregroundStyle(.secondary) }
                    Text(session.question).font(.headline).textSelection(.enabled)
                    if session.editableTranscriptID != nil, !listening {
                        Text(tracking.questionSpeechStatus.label).font(.caption).foregroundStyle(.secondary)
                    }
                    if let id = session.editableTranscriptID, !listening, input.isEmpty, editingTranscript == nil {
                        Button("修改转写") {
                            editingTranscript = id
                            input = session.question
                            inputFocused = true
                        }.buttonStyle(.borderless).font(.caption)
                    }
                }
                if session.usingLocalModel { Label("本机 oMLX 回答", systemImage: "desktopcomputer").font(.caption) }
                if let short = session.answer.shortAnswerPoint {
                    Text(short.text).font(.system(size: 19, weight: .medium)).textSelection(.enabled)
                    if short.kind != .grounded { Text(short.kind.label).font(.caption).foregroundStyle(.secondary) }
                }
                if !session.answer.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.answer.shortAnswer == nil ? "本机找到的相关原文" : "回答出处")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(session.answer.citations) { citation in
                            Button { preview = citation } label: {
                                Label("第 \(citation.pageNumber) 页 · \(citation.pageTitle) · \(citation.kind.label)",
                                      systemImage: "doc.text.magnifyingglass")
                                    .lineLimit(1)
                            }.buttonStyle(.borderless).font(.caption).foregroundStyle(StudioColors.tint)
                            Text(citation.excerpt).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(session.answer.bullets) { point in pointView(point) }
                if !session.answer.details.isEmpty {
                    DisclosureGroup("深入解答", isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 9) { ForEach(session.answer.details) { point in pointView(point) } }
                            .padding(.top, 6)
                    }
                }
                if case .failed(let error) = session.state {
                    Text(session.usingLocalModel ? "本机回答未完成。请检查 oMLX 是否运行，以及模型名称和端口。" : error.localizedDescription)
                        .foregroundStyle(.secondary)
                    Button("重试本题") { session.retry() }.buttonStyle(.borderless)
                    if let last = session.previousDisplay, let text = last.answer.shortAnswer {
                        DisclosureGroup("查看上一题的回答") { Text(last.question).bold(); Text(text).textSelection(.enabled) }
                    }
                    if error == .missingCredentials || error == .missingBigmodelStandardCredentials
                        || error == .httpStatus(401) || error == .httpStatus(403) {
                        Button("模型设置…") { settings = true }
                    }
                }
                if session.state == .answering {
                    HStack { ProgressView().controlSize(.small); Text("正在回答…").font(.caption); Button("取消") { session.cancel() }.buttonStyle(.borderless) }
                } else if session.question.isEmpty && !listening {
                    Text("输入问题，或点「听题」复述观众的提问。").foregroundStyle(.secondary).font(.body)
                }
                if let err = tracking.speechError { Text(err).font(.callout).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
    }

    private var questionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if listening {
                Text(tracking.questionSpeechStatus.label).font(.caption).foregroundStyle(.secondary)
                Text(tracking.questionTranscript.isEmpty ? "请复述一道题…" : tracking.questionTranscript)
                    .textSelection(.enabled)
                HStack { Button("取消听题") { tracking.disarmQuestionCue(); tracking.cancelQuestion() }
                    Button("立即提交") { tracking.submitQuestion() }.disabled(tracking.isQuestionEnding || !tracking.canFinishQuestion) }
            } else {
                HStack {
                    TextField(editingTranscript == nil ? "输入问题，回车提交" : "修改转写，回车重问", text: $input)
                        .textFieldStyle(.roundedBorder).focused($inputFocused)
                        .onSubmit(submit)
                    Button { submit() } label: { Image(systemName: "arrow.up.circle.fill") }
                        .accessibilityLabel("提交问题").disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if editingTranscript != nil {
                    Button("取消修改") { cancelCorrection() }.buttonStyle(.borderless).font(.caption)
                } else {
                    HStack {
                        Button { listen() } label: { Label("听题", systemImage: "mic") }
                        Picker("复述语言", selection: $speechLanguage) {
                            Text("中文").tag("zh-CN"); Text("English").tag("en-US")
                        }.labelsHidden().frame(maxWidth: 95)
                        Spacer()
                        if session.canFollowUp { Toggle("追问上一题", isOn: $followUp).toggleStyle(.checkbox).font(.caption) }
                    }
                    HStack {
                        Toggle("在线听题", isOn: $sendQuestionAudio).toggleStyle(.checkbox)
                        Button(tracking.cueArmed ? "结束连续听题" : "连续听题") {
                            if tracking.cueArmed { tracking.disarmQuestionCue() }
                            else {
                                listen()
                                if listening {
                                    tracking.armQuestionCue(localeIdentifier: speechLanguage) { seed in listen(seed) }
                                }
                            }
                        }.buttonStyle(.borderless)
                    }.font(.caption)
                    if sendQuestionAudio { Text("点「听题」或说下一题口令后，仅发送这道题的录音。待听在本机运行。").font(.caption).foregroundStyle(.secondary) }
                    if tracking.cueArmed {
                        Text(tracking.standbyLanguage.hasPrefix("zh") ? "本机待听。说「下一道问题是」，看到收题提示后复述。" : "本机待听。说 “Next question”，看到收题提示后复述。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(12)
    }

    private func listen(_ seed: String = "") {
        let continued = followUp
        ws.startSpokenQuestion(localeIdentifier: speechLanguage, onlineSpeech: sendQuestionAudio, initialText: seed) { question in
            expanded = false
            session.submit(question, currentPageIndex: ws.project == nil ? nil : ws.pageIndex,
                           followUp: continued, submittedAt: tracking.lastQuestionSpeechEndedAt ?? .now, fromSpeech: true)
            followUp = false
        }
    }

    private func resetQuestionView() {
        tracking.disarmQuestionCue()
        tracking.cancelQuestion()
        session.clearSearch()
        input = ""
        editingTranscript = nil
        preview = nil
        expanded = false
        followUp = false
        sendQuestionAudio = false
    }

    private func submit() {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        expanded = false
        if let id = editingTranscript {
            tracking.holdForTypedAnswer()
            session.submitCorrection(input, for: id)
            editingTranscript = nil
        } else {
            ws.submitQuestion(input, followUp: followUp)
        }
        input = ""
        followUp = false
    }

    private func cancelCorrection() {
        editingTranscript = nil
        input = ""
    }

    private func pointView(_ point: QAAnswerPoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("•  " + point.text).textSelection(.enabled)
            if ws.project != nil, point.kind != .grounded {
                Text(point.kind.label).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(point.citations) { cite in
                Button("第 \(cite.pageNumber) 页 · \(cite.kind.label)") { preview = cite }.buttonStyle(.borderless).font(.caption)
            }
        }
    }
}

private struct StudioCitationPreview: View {
    @ObservedObject var ws: StudioWorkspace
    let citation: QACitation
    @Environment(\.dismiss) var dismiss
    @State private var showsRegion = false
    private var hasRegion: Bool { citation.region?.isValid == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("第 \(citation.pageNumber) 页 · \(citation.kind.label)", systemImage: "doc.text.magnifyingglass")
                    .foregroundStyle(StudioColors.tint).font(.headline)
                Spacer(); Button("返回问答") { dismiss() }
            }
            if let p = ws.project, p.activeRevisionID == citation.revisionID {
                HStack {
                    Text(citation.pageTitle).font(.title3.bold())
                    Spacer()
                    if hasRegion {
                        Button(showsRegion ? "查看整页" : "放大区域") { showsRegion.toggle() }
                    }
                }
                StudioPageImage(store: ws.store, projectID: p.id, revisionID: p.activeRevisionID,
                                pageNumber: citation.pageNumber, region: citation.region,
                                imageSetID: p.activeRevision.imageSetID, cropToRegion: showsRegion)
                    .frame(maxWidth: .infinity)
                    .frame(height: hasRegion ? (showsRegion ? 235 : 190) : nil)
                    .frame(maxHeight: 300)
                ScrollView { Text(citation.excerpt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minHeight: hasRegion ? 24 : nil)
                Button("从本页讲稿继续") {
                    ws.tracking.select(pageIndex: citation.pageIndex)
                    dismiss()
                }
            }
        }.padding(16).frame(minWidth: 420, idealWidth: 490, minHeight: 370, idealHeight: 440)
    }
}

private struct OfflineAnswerSettings: View {
    @AppStorage("studio.offlineAnswerEnabled") private var enabled = false
    @AppStorage("studio.offlineAnswerModel") private var model = ""
    @AppStorage("studio.offlineAnswerPort") private var port = "8000"

    var body: some View {
        DisclosureGroup("断网备用") {
            VStack(alignment: .leading, spacing: 7) {
                Toggle("用本机 oMLX 回答", isOn: $enabled)
                if enabled {
                    TextField("oMLX 模型名称", text: $model)
                    TextField("本机端口", text: $port)
                    if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (UInt16(port) ?? 0) == 0 {
                        Text("填好名称和端口后即可启用。").font(.caption)
                    }
                }
            }.padding(.top, 5)
        }
    }
}
