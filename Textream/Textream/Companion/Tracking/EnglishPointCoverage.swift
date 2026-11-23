import Combine
import Foundation

/// Coverage belongs to a rehearsal, independent of the reading cursor.
/// All callbacks and page changes are serialized by the tracking controller.
@MainActor
final class EnglishPointCoverage: ObservableObject {
    enum ModelState { case idle, loading, missing, ready, failed }
    @Published private(set) var enabled = false
    @Published private(set) var covered = Set<CompanionTrackingPosition>()
    @Published private(set) var state: ModelState = .idle
    @Published private(set) var status = ""
    var modelLabel: String {
        switch state {
        case .idle: return "未启用"
        case .loading: return "准备中"
        case .missing: return "未安装"
        case .ready: return "已加载"
        case .failed: return "加载失败"
        }
    }
    struct LiveWord: Equatable {
        let position: CompanionTrackingPosition
        let index: Int
    }
    @Published private(set) var liveWord: LiveWord?
    @Published private(set) var isMatching = false
    private var utteranceNumber = 0
    private var lastLocatedNumber = 0
    var matched: ((CompanionTrackingPosition) -> Void)?
    private let helper: URL?

    init(helper: URL? = nil) { self.helper = helper }

    private var worker: MurmuryProcess?
    private var workerID = UUID()
    private var scope = UUID()
    private var document = ""
    private var pages: [CompanionTrackingPage] = []
    private var titles: [String] = []
    private var pending: [Job] = []
    private var busy: Job?
    private var previous: (page: Int, text: String, time: TimeInterval)?
    private struct Candidates {
        let page: Int
        let title: String
        let indices: [Int]
        let claims: [String]
    }
    private struct Job {
        let id = UUID()
        let scope: UUID
        let page: Int
        let number: Int
        let text: String
        let groups: [Candidates]
    }

    func configure(_ pages: [CompanionTrackingPage], titles: [String], document: String) {
        invalidate()
        if document != self.document { covered = [] }
        else {
            let old = self.pages
            covered = covered.filter { p in
                old.indices.contains(p.pageIndex) && pages.indices.contains(p.pageIndex) &&
                    old[p.pageIndex].sentences == pages[p.pageIndex].sentences
            }
        }
        self.document = document
        self.pages = pages
        self.titles = titles
    }

    func setEnabled(_ flag: Bool) {
        guard enabled != flag else { return }
        enabled = flag
        invalidate()
        if flag { startModel(download: false) }
        else {
            workerID = UUID()
            worker?.stop()
            worker = nil
            busy = nil
            state = .idle
            status = ""
        }
    }

    func invalidate() {
        scope = UUID()
        clearLiveWord()
        isMatching = false
        pending.removeAll()
        previous = nil
    }

    func reset() {
        invalidate()
        covered = []
    }

    func startModel(download: Bool, directory: URL? = nil) {
        guard enabled else { return }
        invalidate()
        workerID = UUID()
        worker?.stop()
        worker = nil
        busy = nil
        guard helper != nil || MurmuryProcess.isInstalled else {
            state = .missing
            status = "本构建仅支持原句匹配。"
            return
        }
        state = .loading
        status = "正在检查本机 FineCat…"
        let token = workerID
        let savedKey = "studio.finecatDirectory"
        let path = directory?.path ?? (download ? nil : UserDefaults.standard.string(forKey: savedKey))
        do {
            worker = try MurmuryProcess(script: "coverage",
                arguments: [download ? "prepare" : "local"] + (path.map { [$0] } ?? []), executable: helper,
                receive: { [weak self] event in
                    guard let self, token == self.workerID else { return }
                    switch event["type"] as? String {
                    case "ready":
                        self.state = .ready
                        self.status = "FineCat 已就绪 · 本机识别"
                        if let path { UserDefaults.standard.set(path, forKey: savedKey) }
                        else { UserDefaults.standard.removeObject(forKey: savedKey) }
                        self.sendNext()
                    case "missing":
                        self.pending.removeAll()
                        self.state = .missing
                        self.status = "可按原句跟读。下载 FineCat 后即可用自己的话讲。"
                    case "status": self.status = event["message"] as? String ?? ""
                    case "error": self.failed(event["message"] as? String ?? "语义模型启动失败。")
                    case "result":
                        guard let job = self.busy, event["id"] as? String == job.id.uuidString else { return }
                        self.busy = nil
                        self.isMatching = false
                        if job.scope == self.scope, let scores = event["scores"] as? [[Double]] {
                            self.apply(scores, to: job)
                        }
                        self.sendNext()
                    default: break
                    }
                }, closed: { [weak self] _ in
                    guard let self, token == self.workerID else { return }
                    self.worker = nil
                    if self.state != .missing && self.state != .failed { self.failed("语义模型已停止，可重新准备。") }
                })
        } catch { failed("无法启动语义组件，可继续按原句匹配。") }
    }

    private func failed(_ message: String) {
        state = .failed
        isMatching = false
        status = message
        busy = nil
        pending.removeAll()
    }

    private func candidates(_ page: Int) -> Candidates? {
        guard pages.indices.contains(page), !pages[page].isAppendix else { return nil }
        let entries = pages[page].sentences.enumerated().compactMap { index, text -> (Int, String)? in
            let claim = CompanionTrackingPage.withoutActions(text).trimmingCharacters(in: .whitespacesAndNewlines)
            return claim.isEmpty ? nil : (index, claim)
        }
        guard !entries.isEmpty else { return nil }
        return Candidates(page: page, title: titles.indices.contains(page) ? titles[page] : "",
                          indices: entries.map { $0.0 }, claims: entries.map { $0.1 })
    }

    func clearLiveWord() {
        if liveWord != nil { liveWord = nil }
    }

    /// Follow a distinctive, consecutive run of words while ASR is revising it.
    /// This only draws a cursor. It never marks a point or promotes a slide.
    func preview(_ speech: String, page: Int) {
        guard enabled, let group = candidates(page) else { clearLiveWord(); return }
        let tail = Array(Self.words(speech).suffix(10))
        guard tail.count >= 2 else { clearLiveWord(); return }
        var best = 0
        var winner: LiveWord?
        for (row, claim) in group.claims.enumerated() {
            let words = Self.words(claim)
            for end in words.indices where words[end] == tail.last {
                var length = 1
                while length < min(end + 1, tail.count),
                      words[end - length] == tail[tail.count - 1 - length] { length += 1 }
                guard length >= 3 || (length == 2 && length == words.count) else { continue }
                if length > best {
                    best = length
                    winner = LiveWord(position: CompanionTrackingPosition(pageIndex: page, sentenceIndex: group.indices[row]), index: end)
                } else if length == best { winner = nil }
            }
        }
        if liveWord != winner { liveWord = winner }
    }

    private func verbatim(_ text: String, groups: [Candidates]) -> [[Double]]? {
        let units = CompanionTrackingPage.sentences(in: text)
        guard !units.isEmpty else { return nil }
        var scores = groups.map { Array(repeating: 0.0, count: $0.claims.count) }
        for unit in units {
            let spoken = Self.words(unit)
            let question = unit.hasSuffix("?") || unit.hasSuffix("？")
            guard !spoken.isEmpty else { return nil }
            var found = false
            for (slot, group) in groups.enumerated() {
                if let index = group.claims.firstIndex(where: {
                    (!question || $0.hasSuffix("?") || $0.hasSuffix("？")) && Self.words($0) == spoken
                }) {
                    scores[slot][index] = 1
                    found = true
                    break
                }
            }
            if !found { return nil }
        }
        // A mixed-page passage needs the usual page arbitration.
        return scores.filter { $0.contains(1) }.count == 1 ? scores : nil
    }

    func hear(_ speech: String, page: Int, next: Int?, at time: TimeInterval) {
        let text = speech.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !text.isEmpty, pages.indices.contains(page), !pages[page].isAppendix else { return }
        let groups = ([page] + (next.map { [$0] } ?? [])).compactMap(candidates)
        guard !groups.isEmpty else { return }
        utteranceNumber += 1
        let job = Job(scope: scope, page: page, number: utteranceNumber, text: text, groups: groups)
        clearLiveWord()
        if let exact = verbatim(text, groups: groups) {
            apply(exact, to: job)
            previous = (page, text, time)
            return
        }
        if state == .ready {
            pending.append(job)
            if let prior = previous, prior.page == page, time - prior.time < 5,
               prior.text != text, prior.text.count + text.count <= 650,
               text.range(of: #"^(from (?:that|those)|this (?:means|lets)|which (?:means|lets)|as a result|because of (?:that|this))\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil {
                pending.append(Job(scope: scope, page: page, number: utteranceNumber, text: prior.text + " " + text, groups: groups))
            }
            previous = (page, text, time)
            sendNext()
        } else if state == .loading {
            if pending.count == 6 { pending.removeFirst() }
            pending.append(job)
        }
    }

    private static func words(_ text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
    }

    private func sendNext() {
        guard state == .ready, busy == nil, !pending.isEmpty, let worker else { return }
        let job = pending.removeFirst()
        busy = job
        isMatching = true
        worker.send(["id": job.id.uuidString, "text": job.text, "preferCurrent": job.groups.first?.page == job.page, "pages": job.groups.map {
            ["title": $0.title, "points": $0.claims] as [String: Any]
        }])
    }

    private func apply(_ scores: [[Double]], to job: Job) {
        guard scores.count == job.groups.count,
              zip(scores, job.groups).allSatisfy({ values, group in
                  values.count == group.indices.count && values.allSatisfy { $0.isFinite && (0...1).contains($0) }
              }) else { return }
        for (slot, group) in job.groups.enumerated() {
            let threshold = group.page == job.page ? 0.50 : 0.85
            let matches = scores[slot].indices.filter { scores[slot][$0] >= threshold }
            guard !matches.isEmpty else { continue }
            let positions = matches.map { CompanionTrackingPosition(pageIndex: group.page, sentenceIndex: group.indices[$0]) }
            let new = positions.filter { !covered.contains($0) }
            if !new.isEmpty { covered.formUnion(new) }
            if group.page == job.page && job.number >= lastLocatedNumber {
                lastLocatedNumber = job.number
                matched?(new.first ?? positions[0])
            }
            // Prefer the current page when both slides contain the same claim.
            return
        }
    }
}
