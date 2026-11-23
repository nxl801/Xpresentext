import AppKit
import SwiftUI
import Combine
import Observation

@MainActor
final class MurmuryPresenter {
    static let shared = MurmuryPresenter()
    private var helper: MurmuryProcess?
    private weak var ws: StudioWorkspace?
    private var send: (([String: Any]) -> Void)?
    private var subscriptions = Set<AnyCancellable>()
    private weak var observedSession: CompanionQASession?
    private var updateTask: Task<Void, Never>?
    private var meetingFollow = false
    private var lastState: Data?
    private var context = ""
    private var preview: NSWindow?
    private var ready = false
    private let makeMeetingInput: @MainActor () -> any CompanionSpeechInput
    private var meeting: (any CompanionSpeechInput)?
    private var meetingText = ""
    private var lastMeetingLine = ""
    private var meetingStatus = ""

    init(makeMeetingInput: @escaping @MainActor () -> any CompanionSpeechInput = { MurmurySpeechInput(source: "system") }) {
        self.makeMeetingInput = makeMeetingInput
    }

    func show(_ workspace: StudioWorkspace) {
        if let helper, ws === workspace { helper.send(["type": "focus"]); return }
        close()
        do {
            helper = try MurmuryProcess(script: "panel", receive: { [weak self] in self?.receive($0) },
               closed: { [weak self, weak workspace] status in
                   guard let self else { return }
                   let failed = !self.ready || status != 0
                   self.close()
                   if failed, let workspace { self.showFallback(workspace) }
               })
            workspace.notification = "正在打开 Murmury 问答浮窗…"
            bind(workspace) { [weak self] in self?.helper?.send($0) }
        } catch { showFallback(workspace) }
    }

    func bind(_ workspace: StudioWorkspace, send: @escaping ([String: Any]) -> Void) {
        ws = workspace
        self.send = send
        workspace.objectWillChange.merge(with: workspace.tracking.objectWillChange)
            .sink { [weak self] in self?.scheduleUpdate() }.store(in: &subscriptions)
    }

    private func scheduleUpdate() {
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.updateTask = nil
            self.update()
        }
    }

    private func observe(_ session: CompanionQASession) {
        guard observedSession !== session else { return }
        observedSession = session
        withObservationTracking {
            _ = (session.answer, session.state, session.question, session.canFollowUp, session.editableTranscriptID)
        } onChange: { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session, self.observedSession === session else { return }
                self.observedSession = nil
                self.scheduleUpdate()
            }
        }
    }

    private func showFallback(_ workspace: StudioWorkspace) {
        workspace.notification = "Murmury 浮窗启动失败。可在本机问答窗口继续提问。"
        StudioQuestionPanel.shared.showNative(workspace)
    }

    private func stopMeeting() {
        meeting?.cancel()
        meeting = nil
        ws?.tracking.endMeetingVoice()
        meetingText = ""
        lastMeetingLine = ""
        meetingStatus = ""
    }

    func close() {
        subscriptions.removeAll()
        updateTask?.cancel()
        updateTask = nil
        observedSession = nil
        send = nil
        helper?.stop()
        helper = nil
        stopMeeting()
        ws?.tracking.disarmQuestionCue()
        ws?.tracking.cancelQuestion()
        ws?.questions.clearSearch()
        preview?.close()
        preview = nil
        ws = nil
        ready = false
        lastState = nil
        context = ""
    }

    private func key(_ workspace: StudioWorkspace) -> String {
        [workspace.project?.id.uuidString ?? "-", workspace.project?.activeRevisionID ?? "-", workspace.provider.rawValue].joined(separator: "/")
    }

    private func update() {
        guard let ws, ready else { return }
        let key = key(ws)
        if context != key {
            stopMeeting()
            preview?.close()
            preview = nil
            context = key
        }
        let session = ws.questions, tracking = ws.tracking, answer = session.answer
        observe(session)
        let listening = tracking.phase == .listeningQuestion
        var status = ""
        var failed = false
        switch session.state {
        case .idle: break
        case .answering: status = "正在回答…"
        case .completed: status = "已回答"
        case .failed(let error): status = error.localizedDescription; failed = true
        }
        if listening { status = tracking.isStarting ? "正在启动麦克风…" : "听题中 · 位置已锁定" }
        else if let error = tracking.speechError { status = error }
        if !meetingStatus.isEmpty { status = [meetingStatus, status].filter { !$0.isEmpty }.joined(separator: " · ") }
        let sources = answer.citations.map { ["id": $0.id, "label": "第 \($0.pageNumber) 页 · \($0.pageTitle) · \($0.kind.label)"] }
        let pointText: (QAAnswerPoint) -> String = { point in
            point.kind == .grounded ? point.text : "\(point.kind.label) · \(point.text)"
        }
        let state: [String: Any] = ["type": "state", "context": key, "title": ws.project?.name ?? "现场问答",
            "question": session.question, "short": answer.shortAnswer ?? "", "sources": sources,
            "kind": answer.shortAnswerPoint.flatMap { $0.kind == .grounded ? nil : $0.kind.label } ?? "",
            "bullets": answer.bullets.map(pointText), "details": answer.details.map(pointText),
            "status": status, "failed": failed, "canFollow": session.canFollowUp,
            "heard": listening ? tracking.questionTranscript : meetingText, "listening": listening || meeting != nil,
            "canUseHeard": meeting != nil && !lastMeetingLine.isEmpty, "transcriptID": session.editableTranscriptID?.uuidString ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys), data != lastState {
            lastState = data
            send?(state)
        }
    }

    func receive(_ event: [String: Any]) {
        guard let ws, let action = event["action"] as? String else { return }
        if action == "ready" {
            ready = true
            if ws.notification == "正在打开 Murmury 问答浮窗…" { ws.notification = nil }
            update()
            return
        }
        guard (event["context"] as? String) == key(ws), context == key(ws) else { return }
        let follow = event["follow"] as? Bool == true && ws.questions.canFollowUp
        let text = event["text"] as? String ?? ""
        switch action {
        case "ask": ws.submitQuestion(text, followUp: follow)
        case "microphone":
            stopMeeting()
            ws.startSpokenQuestion(localeIdentifier: event["language"] as? String ?? "zh-CN", onlineSpeech: false) { [weak ws] question in
                guard let ws else { return }
                ws.questions.submit(question, currentPageIndex: ws.project == nil ? nil : ws.pageIndex, followUp: follow,
                                    submittedAt: ws.tracking.lastQuestionSpeechEndedAt ?? .now, fromSpeech: true)
            }
        case "useHeard":
            guard meeting != nil, !lastMeetingLine.isEmpty else { return }
            submitMeetingLine(lastMeetingLine, in: ws, follow: follow)
        case "meeting": startMeeting(ws, follow: event["follow"] as? Bool == true)
        case "follow": meetingFollow = follow
        case "stop": stopMeeting(); ws.tracking.cancelQuestion()
        case "finish": ws.tracking.submitQuestion()
        case "correct":
            if let id = (event["id"] as? String).flatMap(UUID.init(uuidString:)), id == ws.questions.editableTranscriptID {
                ws.tracking.holdForTypedAnswer()
                ws.questions.submitCorrection(text, for: id)
            }
        case "retry": ws.questions.retry()
        case "preview":
            if let cite = ws.questions.answer.citations.first(where: { $0.id == event["id"] as? String }),
               ws.project?.activeRevisionID == cite.revisionID {
                preview?.close()
                let window = NSPanel(contentViewController: NSHostingController(rootView: StudioCitationPreview(ws: ws, citation: cite, onClose: { [weak self] in self?.preview?.close() })))
                window.title = "引用预览"
                window.level = .floating
                window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                window.isReleasedWhenClosed = false
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                preview = window
            }
        case "advanced":
            close()
            StudioQuestionPanel.shared.showNative(ws)
        default: break
        }
        update()
    }

    private func startMeeting(_ ws: StudioWorkspace, follow: Bool) {
        stopMeeting()
        ws.tracking.cancelQuestion()
        let input = makeMeetingInput()
        meeting = input
        meetingFollow = follow
        (input as? MurmurySpeechInput)?.onStatus = { [weak self, weak input] message in
            guard let self, let input, self.meeting === input else { return }
            self.meetingStatus = message
            self.scheduleUpdate()
        }
        let original = key(ws)
        meetingStatus = "正在准备会议声音…"
        input.start(localeIdentifier: "auto", reportLevel: false) { [weak self, weak input, weak ws] result in
            guard let self, let input, self.meeting === input, let ws, self.key(ws) == original else { return }
            switch result {
            case .started: self.meetingStatus = "正在听会议声音"
            case .transcript(let line, let final):
                self.meetingText = line
                if !final {
                    self.lastMeetingLine = ""
                    ws.tracking.holdForMeetingVoice()
                }
                if final {
                    self.lastMeetingLine = line
                    if Self.isMeetingQuestion(line) { self.submitMeetingLine(line, in: ws, follow: self.meetingFollow) }
                    ws.tracking.endMeetingVoice()
                }
            case .failure(let message, _): self.stopMeeting(); self.meetingStatus = message
            case .level: break
            }
            self.update()
        }
    }

    private func submitMeetingLine(_ line: String, in ws: StudioWorkspace, follow: Bool) {
        lastMeetingLine = ""
        ws.tracking.holdForTypedAnswer()
        ws.questions.submit(line, currentPageIndex: ws.project == nil ? nil : ws.pageIndex,
                            followUp: follow && ws.questions.canFollowUp, fromSpeech: true)
    }

    static func isMeetingQuestion(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count > 2 else { return false }
        return line.hasSuffix("?") || line.hasSuffix("？") ||
            line.range(of: #"(?i)^(?:(?:what|why|how|which|when|where|who)\s+(?:is|are|was|were|did|does|do|can|could|would|should|will|has|have)|(?:can|could|would) you|please (?:explain|show|compare)|tell me)\b|^(?:请问|请解释|请比较|为什么|怎么|如何)"#,
                       options: .regularExpression) != nil
    }
}
