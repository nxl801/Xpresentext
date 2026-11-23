import Combine
import Foundation
import NaturalLanguage

enum CompanionFollowEngine: String { case apple, whisper }

@MainActor
final class CompanionTrackingController: ObservableObject {
    let coverage: EnglishPointCoverage
    private var coverageObserver: AnyCancellable?
    var freeSpeaking: Bool { coverage.enabled && mode == .english }

    func setFreeSpeaking(_ enabled: Bool) {
        if enabled, let page = displayedPageIndex, page != position?.pageIndex {
            matcher.select(pageIndex: page, sentenceIndex: nil)
            publishPosition()
        }
        coverage.setEnabled(enabled)
        (speech as? CompanionLocalSpeechInput)?.separateFollowSegments = enabled && mode == .english
        if phase != .listeningQuestion && followingRequested { restartFollowing() }
    }

    @Published private(set) var readWords: [CompanionTrackingPosition: IndexSet] = [:]
    @Published private(set) var position: CompanionTrackingPosition?
    @Published private(set) var displayedPageIndex: Int?
    @Published private(set) var previousPageAnchor: CompanionTrackingPosition?
    private var reviewingPage: Int?
    @Published private(set) var nextPosition: CompanionTrackingPosition?
    @Published private(set) var currentSentence: String?
    @Published private(set) var nextSentence: String?
    @Published private(set) var phase: CompanionTrackingPhase = .following
    @Published private(set) var mode: CompanionTrackingMode = .english
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published private(set) var isQuestionEnding = false
    @Published private(set) var speechError: String?
    @Published private(set) var questionTranscript = ""
    @Published private(set) var questionSpeechStatus: CompanionQuestionSpeechStatus = .local
    @Published private var capturedQuestionVoice = false
    var canFinishQuestion: Bool {
        !questionTranscript.isEmpty || (questionCloud != nil && capturedQuestionVoice)
    }
    private(set) var lastQuestionSpeechEndedAt: ContinuousClock.Instant?

    @Published private(set) var followEngine: CompanionFollowEngine = .apple
    @Published private(set) var followEngineStatus = ""
    @Published private(set) var lastHeard = ""
    @Published private(set) var inputLevel = 0
    @Published private(set) var whisperInstalled: Bool?
    @Published private(set) var whisperStage: MurmurySpeechInput.ModelStage?
    private var inventory: MurmuryProcess?
    private var lastLevelAt = -Double.infinity
    var displaysFollowCapture: Bool {
        followingRequested && phase == .following && (isListening || isStarting)
    }
    var engineName: String { followEngine == .whisper && !cueArmed ? "Whisper Turbo" : "Apple 听写" }
    var whisperStateLabel: String {
        switch whisperStage {
        case .downloading: return "下载中"
        case .loading: return "加载中"
        case .loaded: return "已加载"
        case nil:
            if let installed = whisperInstalled { return installed ? "已下载 · 未加载" : "未下载" }
            return "待检查"
        }
    }

    func checkWhisperFiles() {
        guard MurmuryProcess.isInstalled, inventory == nil else { return }
        inventory = try? MurmuryProcess(script: "speech", arguments: ["inventory"], receive: { [weak self] event in
            if let present = event["installed"] as? Bool { self?.whisperInstalled = present }
        }, closed: { [weak self] _ in self?.inventory = nil })
    }
    private var whisperActive = false
    private var meetingVoiceActive = false
    private let whisper: (any CompanionSpeechInput)?
    private let speech: any CompanionSpeechInput
    private let questionPause: TimeInterval
    private let now: () -> TimeInterval
    private var matcher = CompanionTrackingMatcher()
    @Published private(set) var cueArmed = false
    private var cueLocale = "en-US"
    private var onQuestionCue: ((String) -> Void)?
    private var lastStandbyText = ""
    private var lastStandbyUpdate: TimeInterval?
    private var followingRequested = false

    var standbyLanguage: String {
        followingRequested && mode == .english && position != nil ? followingLocale : cueLocale
    }

    func armQuestionCue(localeIdentifier: String, onCue: @escaping (String) -> Void) {
        cueLocale = localeIdentifier
        onQuestionCue = onCue
        cueArmed = true
        if phase != .listeningQuestion { restartFollowing() }
    }

    func disarmQuestionCue() {
        guard cueArmed else { return }
        cueArmed = false
        onQuestionCue = nil
        if phase != .listeningQuestion { restartFollowing() }
    }

    private var followingLocale = "en-US"
    private var questionLocale = "en-US"
    private var captureGeneration = UUID()
    private var questionCallback: ((String) -> Void)?
    private var initialQuestionText = ""
    private var localQuestionTranscript = ""
    private var localFinishedQuestion = false
    private var localQuestionCanTranscribe = true
    private var questionPrefersFastEnding = false
    private var questionCloud: CloudQuestion?
    private var cloudPreview: String?
    private var cloudSentenceBoundary = false
    private var completedQuestionText = ""
    private var currentQuestionSegment = ""
    private var sameRequestPrefix = ""
    private var lastQuestionVoiceTime: TimeInterval?
    private var questionVoiceBurst = 0
    private var questionSegmentBurst = 0
    private var questionVoice = VoiceActivityDetector(hangoverDuration: 0.001)
    private var lastQuestionActivity: TimeInterval = 0
    private var followingRefresh: Task<Void, Never>?
    private var questionMonitor: Task<Void, Never>?
    private var questionFinalization: Task<Void, Never>?
    private var captureRecovery: Task<Void, Never>?
    private var followingRecovery = 0
    private var questionRecovery = 0

    convenience init() {
        let input = MurmurySpeechInput()
        self.init(speech: CompanionLocalSpeechInput(), whisper: input)
        if MurmuryProcess.isInstalled {
            followEngine = UserDefaults.standard.string(forKey: "studio.followEngine").flatMap(CompanionFollowEngine.init) ?? .apple
        }
        input.onStatus = { [weak self] message in self?.followEngineStatus = message }
        (speech as? CompanionLocalSpeechInput)?.onStatus = input.onStatus
        input.onStage = { [weak self] stage in
            self?.whisperStage = stage
            if stage != .downloading { self?.whisperInstalled = true }
        }
        checkWhisperFiles()
    }

    init(
        speech: any CompanionSpeechInput,
        whisper: (any CompanionSpeechInput)? = nil,
        pointCoverage: EnglishPointCoverage? = nil,
        questionPause: TimeInterval = 2.7,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        coverage = pointCoverage ?? EnglishPointCoverage()
        self.speech = speech
        self.whisper = whisper
        self.questionPause = questionPause
        self.now = now
        coverageObserver = coverage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        coverage.matched = { [weak self] location in
            guard let self, self.freeSpeaking, self.followingRequested, self.phase == .following else { return }
            guard self.displayedPageIndex == location.pageIndex else { return }
            if self.matcher.select(pageIndex: location.pageIndex, sentenceIndex: location.sentenceIndex) {
                self.publishPosition()
            }
        }
    }

    func selectFollowEngine(_ engine: CompanionFollowEngine) {
        guard engine != followEngine else { return }
        coverage.invalidate()
        followEngine = engine
        if phase != .listeningQuestion { restartFollowing() }
    }

    func configure(
        pages: [CompanionTrackingPage],
        mode: CompanionTrackingMode = .english,
        localeIdentifier: String? = nil,
        titles: [String] = [], document: String = ""
    ) {
        coverage.configure(pages, titles: titles, document: document)
        (speech as? CompanionLocalSpeechInput)?.separateFollowSegments = coverage.enabled && mode == .english
        let previous = promptPosition
        previousPageAnchor = nil
        reviewingPage = nil
        self.mode = mode
        followingLocale = localeIdentifier ?? (mode == .english ? "en-US" : "zh-CN")
        matcher = CompanionTrackingMatcher(pages: pages, mode: mode)
        if let previous {
            if !matcher.select(pageIndex: previous.pageIndex, sentenceIndex: previous.sentenceIndex) {
                matcher.select(pageIndex: previous.pageIndex, sentenceIndex: nil)
            }
        }
        displayedPageIndex = matcher.position?.pageIndex
        publishPosition()
        if phase != .listeningQuestion {
            stopCapture()
            startFollowCaptureIfNeeded()
        }
    }

    func select(pageIndex: Int, sentenceIndex: Int? = nil, fromPreview: Bool = false) {
        let selectedPreview = fromPreview && twoPagePreviewIndex == pageIndex
        guard matcher.select(pageIndex: pageIndex, sentenceIndex: sentenceIndex, fromPreview: selectedPreview) else { return }
        if displayedPageIndex != pageIndex { previousPageAnchor = nil }
        reviewingPage = nil
        displayedPageIndex = pageIndex
        coverage.invalidate()
        cueArmed = false
        onQuestionCue = nil
        publishPosition()
        // Keep an explicitly opened question recording active. Results from it
        // are never fed into the matcher, before or after a manual click.
        guard phase != .listeningQuestion else { return }
        phase = .following
        stopCapture()
        startFollowCaptureIfNeeded()
    }

    func startFollowing() {
        guard phase != .listeningQuestion else { return }
        let wasStandby = cueArmed && !followingRequested
        followingRequested = true
        if phase == .awaitingResume { phase = .following }
        if wasStandby {
            restartFollowing()
            return
        }
        speechError = nil
        if !isStarting && !isListening {
            followingRecovery = 0
            startFollowCaptureIfNeeded()
        }
    }

    func stopFollowing() {
        coverage.invalidate()
        followingRequested = false
        cueArmed = false
        onQuestionCue = nil
        guard phase != .listeningQuestion else { return }
        stopCapture()
        matcher.resetTranscript()
    }

    func holdForMeetingVoice() {
        guard !meetingVoiceActive, phase != .listeningQuestion else { return }
        coverage.invalidate()
        meetingVoiceActive = true
        stopCapture()
        matcher.resetTranscript()
        phase = .awaitingResume
    }

    func endMeetingVoice() {
        guard meetingVoiceActive else { return }
        meetingVoiceActive = false
        startFollowCaptureIfNeeded()
    }

    func holdForTypedAnswer() {
        coverage.invalidate()
        if phase == .listeningQuestion { clearQuestion() }
        speechError = nil
        stopCapture()
        matcher.resetTranscript()
        phase = .awaitingResume
        startFollowCaptureIfNeeded()
    }

    func startQuestion(
        localeIdentifier: String? = nil,
        initialText: String = "",
        onlineSpeech: (any CompanionCloudSpeech)? = nil,
        preferFastEnding: Bool = false,
        onSubmit: @escaping (String) -> Void
    ) {
        coverage.invalidate()
        clearQuestion()
        stopCapture()
        matcher.resetTranscript()
        phase = .listeningQuestion
        initialQuestionText = initialText.trimmingCharacters(in: .whitespacesAndNewlines)
        localQuestionTranscript = initialQuestionText
        completedQuestionText = initialQuestionText
        sameRequestPrefix = initialQuestionText
        questionTranscript = initialQuestionText
        questionSpeechStatus = .local
        questionPrefersFastEnding = preferFastEnding
        questionLocale = localeIdentifier ?? followingLocale
        questionCallback = onSubmit
        questionVoice.reset()
        questionRecovery = 0
        lastQuestionActivity = now()
        lastQuestionSpeechEndedAt = nil
        if let onlineSpeech { connectQuestionCloud(onlineSpeech) }
        startCapture(localeIdentifier: questionLocale, forQuestion: true)
        guard phase == .listeningQuestion else { return }

        questionMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.phase == .listeningQuestion else { return }
                self.checkQuestionSilence()
            }
        }
    }

    func submitQuestion() {
        guard phase == .listeningQuestion, canFinishQuestion else { return }
        if questionCloud == nil { endQuestion(submitting: true) }
        else { finishQuestionCapture() }
    }

    func cancelQuestion() {
        guard phase == .listeningQuestion else { return }
        endQuestion(submitting: false)
    }

    // Also permits deterministic replay of the silence policy without a microphone.
    func checkQuestionSilence() {
        guard phase == .listeningQuestion, !isQuestionEnding, isListening,
              canFinishQuestion, now() - lastQuestionActivity >= questionSilence else { return }
        finishQuestionCapture()
    }

    private var questionSilence: TimeInterval {
        let text = questionTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let questionMark = text.hasSuffix("?") || text.hasSuffix("？")
        let openClause = text.lowercased().contains(
            #/(?:\b(?:and|or|because|if|when|such as|with|for|from|to|the|an?)|以及|因为|如果|然后|还有|比如|或者|怎么用|是否需要)[\s,.，。；;]*$/#
        )
        if openClause && !questionMark { return questionPause + min(1.5, questionPause * 0.65) }
        if questionPrefersFastEnding, !openClause, Self.isCompleteShortQuestion(text, providerBoundary: cloudSentenceBoundary) {
            return min(questionPause, 1.2)
        }
        // An actual final question plus a provider-confirmed boundary can
        // save time. Preserve a substantial pause for a second phrase.
        if cloudSentenceBoundary && questionMark { return questionPause * 0.85 }
        return questionPause
    }

    private static func isCompleteShortQuestion(_ text: String, providerBoundary: Bool) -> Bool {
        guard !text.isEmpty, text.count <= 145 else { return false }
        if providerBoundary && (text.hasSuffix("?") || text.hasSuffix("？")) {
            return questionWords(text).count >= 4
        }
        let words = questionWords(text)
        guard (4...18).contains(words.count),
              !text.unicodeScalars.contains(where: { $0.properties.isIdeographic })
        else { return false }
        let startsQuestion = ["how", "what", "which", "who", "when", "where", "why"].contains(words.first ?? "")
        let directRequest = ["explain", "describe", "show", "summarize", "compare"].contains(words.first ?? "")
            || words.starts(with: ["please", "explain"]) || words.starts(with: ["please", "show"])
        return startsQuestion || directRequest
    }

    private func finishQuestionCapture() {
        guard !isQuestionEnding else { return }
        isQuestionEnding = true
        isListening = false
        let cloud = questionCloud
        if let cloud { questionSpeechStatus = .finishingOnline(cloud.provider.name) }
        speech.finish()
        guard phase == .listeningQuestion, isQuestionEnding else { return }
        cloud?.input.continuation.yield(.finish)
        cloud?.input.continuation.finish()
        let wait: Duration = cloud.map { $0.provider.sendsWhileListening ? .milliseconds(1_450) : .seconds(3) }
            ?? .milliseconds(850)
        questionFinalization = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.isQuestionEnding else { return }
            if let cloud = self.questionCloud {
                self.fallBackFromCloud(cloud.id, reason: "在线语音完成超时。")
            }
            if self.phase == .listeningQuestion, self.isQuestionEnding { self.endQuestion(submitting: true) }
        }
    }

    private func clearQuestion() {
        questionMonitor?.cancel()
        questionMonitor = nil
        questionFinalization?.cancel()
        questionFinalization = nil
        questionCallback = nil
        isQuestionEnding = false
        stopQuestionCloud()
        initialQuestionText = ""
        localQuestionTranscript = ""
        localFinishedQuestion = false
        localQuestionCanTranscribe = true
        capturedQuestionVoice = false
        completedQuestionText = ""
        currentQuestionSegment = ""
        sameRequestPrefix = ""
        lastQuestionVoiceTime = nil
        questionVoiceBurst = 0
        questionSegmentBurst = 0
    }

    private func endQuestion(submitting: Bool) {
        let callback = questionCallback
        let text = questionTranscript
        let problem = speechError
        clearQuestion()
        stopCapture()
        matcher.resetTranscript()
        phase = .awaitingResume
        startFollowCaptureIfNeeded()
        if let problem { speechError = problem }
        if submitting, !text.isEmpty { callback?(text) }
    }

    private func publishPosition() {
        readWords = matcher.readWords
        position = matcher.position
        nextPosition = matcher.nextPosition
        currentSentence = matcher.sentence(at: position)
        nextSentence = matcher.sentence(at: nextPosition)
    }

    func returnToPreviousPage() {
        guard let anchor = previousPageAnchor else { return }
        select(pageIndex: anchor.pageIndex, sentenceIndex: anchor.sentenceIndex)
        reviewingPage = anchor.pageIndex
    }

    private var showingNextPage: Bool { displayedPageIndex != position?.pageIndex }

    var promptPosition: CompanionTrackingPosition? {
        if showingNextPage, let page = displayedPageIndex { return matcher.openingPosition(on: page) }
        return matcher.promptPosition
    }
    var previousReadPosition: CompanionTrackingPosition? { matcher.previousReadPosition }
    var twoPagePreviewIndex: Int? {
        if showingNextPage, let page = displayedPageIndex { return matcher.nextBodyPage(after: page) }
        return matcher.twoPagePreviewIndex
    }
    var previewPageIndex: Int? {
        if showingNextPage, let page = displayedPageIndex { return matcher.nextBodyPage(after: page) }
        return matcher.previewPageIndex
    }
    func readingWindow(upcoming count: Int) -> [CompanionTrackingPosition] {
        let upcoming = matcher.readingWindow(upcoming: count, startingAt: promptPosition)
        guard let previousReadPosition else { return upcoming }
        return [previousReadPosition] + upcoming
    }
    func sentences(on page: Int) -> [String] { matcher.sentences(on: page) }
    func text(at position: CompanionTrackingPosition) -> String? { matcher.sentence(at: position) }

    private func startFollowCaptureIfNeeded() {
        guard !meetingVoiceActive, phase != .listeningQuestion, cueArmed || (followingRequested && mode == .english && position != nil) else { return }
        lastStandbyText = ""
        lastStandbyUpdate = nil
        startCapture(localeIdentifier: cueArmed ? standbyLanguage : followingLocale, forQuestion: false)
        guard (isStarting || isListening), !whisperActive else { return }
        let token = captureGeneration
        // SFSpeech tasks in live capture can expire. Rotate requests without
        // discarding the visible position or the post-question lock.
        followingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(52))
            guard !Task.isCancelled, let self, token == self.captureGeneration else { return }
            self.restartFollowing(continuingSegment: true)
        }
    }

    private func questionAfterCue(in transcript: String) -> String? {
        let timestamp = now()
        var candidate = transcript[...]
        if let lastStandbyUpdate, timestamp - lastStandbyUpdate > 1.2,
           !lastStandbyText.isEmpty, transcript.hasPrefix(lastStandbyText) {
            candidate = transcript.dropFirst(lastStandbyText.count)
        }
        if lastStandbyText != transcript {
            lastStandbyText = transcript
            lastStandbyUpdate = timestamp
        }
        // Only a fresh utterance or a sentence boundary can introduce the next question.
        let cue = #/(?i)(?:^|[.!?。！？]\s*)(?:\s*)(?:next question\b|the audience question is\b|观众的问题是|下一个问题是|下一道问题是)[\s,:，：、.。?!！？—-]*/#
        guard let range = candidate.firstMatch(of: cue)?.range else { return nil }
        return String(candidate[range.upperBound...])
    }

    private func startCapture(localeIdentifier: String, forQuestion: Bool) {
        speechError = nil
        isStarting = true
        isListening = false
        let token = captureGeneration
        let receive: @MainActor (CompanionSpeechEvent) -> Void = { [weak self] event in
            guard let self, self.captureGeneration == token else { return }
            self.receive(event, forQuestion: forQuestion)
        }
        if !forQuestion, !cueArmed, followEngine == .whisper, let whisper {
            whisperActive = true
            whisper.start(localeIdentifier: localeIdentifier, reportLevel: false, onEvent: receive)
            return
        }
        if forQuestion, let cloud = questionCloud, let pcmSpeech = speech as? any CompanionQuestionPCMInput {
            let input = cloud.input.continuation
            let id = cloud.id
            pcmSpeech.start(localeIdentifier: localeIdentifier, reportLevel: true, onPCM: { [weak self] packet in
                guard case .dropped = input.yield(.packet(packet)) else { return }
                Task { @MainActor in self?.fallBackFromCloud(id, reason: "在线语音未能及时接收本题。") }
            }, onLocalAvailability: { [weak self] available in
                guard let self, self.captureGeneration == token else { return }
                self.localQuestionCanTranscribe = available
                if !available, self.questionCloud == nil {
                    self.endUnavailableQuestion()
                }
            }, onEvent: receive)
        } else {
            speech.start(localeIdentifier: localeIdentifier, reportLevel: forQuestion, onEvent: receive)
        }
    }

    private func stopCapture() {
        captureGeneration = UUID()
        followingRefresh?.cancel()
        followingRefresh = nil
        captureRecovery?.cancel()
        captureRecovery = nil
        if whisperActive { whisper?.cancel() } else { speech.cancel() }
        whisperActive = false
        whisperStage = nil
        lastHeard = ""
        inputLevel = 0
        lastLevelAt = -Double.infinity
        coverage.clearLiveWord()
        followEngineStatus = ""
        isStarting = false
        isListening = false
    }

    private func restartFollowing(continuingSegment: Bool = false) {
        stopCapture()
        if continuingSegment { matcher.beginSpeechSegment() } else { matcher.resetTranscript() }
        startFollowCaptureIfNeeded()
    }

    private func recoverCapture(forQuestion: Bool) {
        stopCapture()
        let token = captureGeneration
        isStarting = true
        captureRecovery = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.captureGeneration == token else { return }
            if forQuestion {
                self.startCapture(localeIdentifier: self.questionLocale, forQuestion: true)
            } else {
                self.matcher.beginSpeechSegment()
                self.startFollowCaptureIfNeeded()
            }
        }
    }

    private func receive(_ event: CompanionSpeechEvent, forQuestion: Bool) {
        switch event {
        case .started:
            isStarting = false
            isListening = true
            followEngineStatus = ""
        case .level(let level, let time):
            if !forQuestion {
                if followingRequested && time - lastLevelAt >= 0.12 {
                    let bucket = min(5, max(0, Int((log10(max(Double(level), 0.000001)) + 3.0) * 2.5)))
                    if bucket != inputLevel { inputLevel = bucket }
                    lastLevelAt = time
                }
                return
            }
            guard !isQuestionEnding else { return }
            questionVoice.process(level: level, at: time)
            if questionVoice.isActive(at: time) {
                capturedQuestionVoice = true
                if let lastQuestionVoiceTime, time - lastQuestionVoiceTime >= 1.2 {
                    questionVoiceBurst += 1
                }
                lastQuestionVoiceTime = max(lastQuestionVoiceTime ?? time, time)
                lastQuestionActivity = max(lastQuestionActivity, time)
                let estimatedEnd = ContinuousClock.now.advanced(by: .seconds(min(0, time - now())))
                if let previous = lastQuestionSpeechEndedAt {
                    lastQuestionSpeechEndedAt = max(previous, estimatedEnd)
                } else {
                    lastQuestionSpeechEndedAt = estimatedEnd
                }
            }
        case .transcript(let transcript, let isFinal):
            if forQuestion {
                if !transcript.isEmpty { questionRecovery = 0 }
                receiveQuestionTranscript(transcript, isFinal: isFinal)
            } else {
                followingRecovery = 0
                if cueArmed, let seed = questionAfterCue(in: transcript), let onQuestionCue {
                    onQuestionCue(seed)
                    return
                }
                guard followingRequested && mode == .english else {
                    if isFinal && !speech.continuesFollowingAfterFinal { restartFollowing() }
                    return
                }
                if phase == .following, !transcript.isEmpty { lastHeard = String(transcript.suffix(260)) }
                if freeSpeaking && phase == .following {
                    if !isFinal, let page = position?.pageIndex { coverage.preview(transcript, page: page) }
                    if isFinal, let page = position?.pageIndex {
                        coverage.hear(transcript, page: page, next: twoPagePreviewIndex, at: now())
                        if !whisperActive && !speech.continuesFollowingAfterFinal { restartFollowing() }
                    }
                    return
                }
                let previous = matcher.position
                let priorWords = matcher.readWords
                let resumed = matcher.process(transcript, awaitingResume: phase == .awaitingResume, resumeOnCurrentPageOnly: freeSpeaking)
                if matcher.position != previous { publishPosition() }
                else if readWords != matcher.readWords { readWords = matcher.readWords }
                if !freeSpeaking, phase == .following || resumed,
                   (previous != matcher.position || priorWords != matcher.readWords),
                   let spoken = matcher.position, let displayed = displayedPageIndex {
                    if spoken.pageIndex > displayed {
                        // A single final can span the old ending and the next opening.
                        // Keep the most recent old-page line with spoken evidence.
                        previousPageAnchor = matcher.readWords.keys
                            .filter { $0.pageIndex == displayed }
                            .max { ($0.sentenceIndex ?? -1) < ($1.sentenceIndex ?? -1) }
                            ?? previous.flatMap { $0.pageIndex == displayed ? $0 : nil }
                        displayedPageIndex = spoken.pageIndex
                        reviewingPage = nil
                    } else if spoken.pageIndex == displayed, reviewingPage != displayed,
                              let next = matcher.nextPageAfterSpokenEnding {
                        previousPageAnchor = spoken
                        displayedPageIndex = next
                    }
                }
                if resumed {
                    phase = .following
                    if cueArmed { disarmQuestionCue(); return }
                }
                if isFinal {
                    if whisperActive || speech.continuesFollowingAfterFinal { matcher.beginSpeechSegment() }
                    else { restartFollowing(continuingSegment: true) }
                }
            }
        case .failure(let message, let canRestart):
            if forQuestion, isQuestionEnding {
                localFinishedQuestion = true
                if questionCloud == nil { endQuestion(submitting: true) }
                return
            }
            if forQuestion, canRestart, questionRecovery < 2 {
                questionRecovery += 1
                beginFreshQuestionRequest()
                recoverCapture(forQuestion: true)
                return
            }
            if !forQuestion, canRestart, followingRecovery < 2 {
                followingRecovery += 1
                recoverCapture(forQuestion: false)
                return
            }
            if forQuestion {
                speechError = message
                endQuestion(submitting: false)
                return
            }
            cueArmed = false
            onQuestionCue = nil
            stopCapture()
            speechError = message
        }
    }

    private func receiveQuestionTranscript(_ transcript: String, isFinal: Bool) {
        updateQuestionText(transcript)

        guard isFinal else { return }
        if isQuestionEnding {
            localFinishedQuestion = true
            if questionCloud == nil { endQuestion(submitting: true) }
        } else {
            // A Speech task can end on its own during a natural pause. Keep any
            // text within the same question and wait for our own endpoint.
            beginFreshQuestionRequest()
            // The same tap continues streaming; rotate just the local Speech task.
            if questionCloud != nil { return }
            stopCapture()
            startCapture(localeIdentifier: questionLocale, forQuestion: true)
        }
    }

    private func beginFreshQuestionRequest() {
        completedQuestionText = localQuestionTranscript
        currentQuestionSegment = ""
        sameRequestPrefix = ""
        questionSegmentBurst = questionVoiceBurst
    }

    private func updateQuestionText(_ transcript: String) {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let segment = Self.removingRepeatedPrefix(sameRequestPrefix, from: raw)
        guard !segment.isEmpty, segment != currentQuestionSegment else { return }
        let oldWords = Self.questionWords(currentQuestionSegment)
        let newWords = Self.questionWords(segment)

        // Apple may resume its partial transcript at the start of the next
        // spoken phrase without sending a final for the earlier one.
        let couldBeNewSegment = questionVoiceBurst > questionSegmentBurst
            && newWords.count <= 3 && oldWords.count - newWords.count >= 4
        if couldBeNewSegment {
            // A one-word partial or a prefix of the prior result is ambiguous.
            // Keep the earlier text visible until the new phrase has two words.
            guard newWords.count >= 2, !oldWords.starts(with: newWords) else { return }
            sameRequestPrefix = [sameRequestPrefix, currentQuestionSegment].filter { !$0.isEmpty }.joined(separator: " ")
            completedQuestionText = localQuestionTranscript
        }

        let combined = [completedQuestionText, segment].filter { !$0.isEmpty }.joined(separator: " ")
        // A late spelling correction can arrive during silence. Keep the
        // corrected text, but only extend the pause for new speech.
        if lastQuestionSpeechEndedAt == nil || !Self.revisesEarlierWords(localQuestionTranscript, combined) {
            lastQuestionActivity = now()
        }
        if !Self.revisesEarlierWords(currentQuestionSegment, segment) {
            questionSegmentBurst = questionVoiceBurst
        }
        currentQuestionSegment = segment
        localQuestionTranscript = combined
        if cloudPreview == nil { questionTranscript = combined }
    }

    private final class CloudQuestion {
        let id = UUID()
        let provider: any CompanionCloudSpeech
        let input = AsyncStream<CompanionCloudAudio>.makeStream(bufferingPolicy: .bufferingOldest(220))
        var transcript: Task<Void, Never>?
        var startup: Task<Void, Never>?

        init(_ provider: any CompanionCloudSpeech) { self.provider = provider }
    }

    private func connectQuestionCloud(_ provider: any CompanionCloudSpeech) {
        guard speech is any CompanionQuestionPCMInput else {
            questionSpeechStatus = .fallback("当前语音输入无法发送音频。")
            return
        }
        let cloud = CloudQuestion(provider)
        questionCloud = cloud
        questionSpeechStatus = .connecting(provider.name)
        let id = cloud.id
        let audio = cloud.input.stream
        cloud.transcript = Task { [weak self] in
            do {
                for try await event in provider.recognize(audio) {
                    guard let self, !Task.isCancelled, self.questionCloud?.id == id else { return }
                    self.receiveCloudQuestion(event, id: id)
                }
                self?.fallBackFromCloud(id, reason: "在线语音提前结束。")
            } catch {
                let reason = (error as? CompanionCloudSpeechError)?.errorDescription ?? "在线语音连接中断。"
                self?.fallBackFromCloud(id, reason: reason)
            }
        }
        cloud.startup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.fallBackFromCloud(id, reason: "未能及时连接在线语音。")
        }
    }

    private func receiveCloudQuestion(_ event: CompanionCloudSpeechEvent, id: UUID) {
        guard let cloud = questionCloud, cloud.id == id else { return }
        switch event {
        case .ready:
            cloud.startup?.cancel()
            guard !isQuestionEnding else { return }
            questionSpeechStatus = cloud.provider.sendsWhileListening ? .streaming(cloud.provider.name)
                : .recordingForUpload(cloud.provider.name)
        case .preview(let text, let boundary):
            guard !text.isEmpty else { return }
            cloudPreview = text
            cloudSentenceBoundary = boundary
            questionTranscript = joinedCloudQuestion(text)
        case .complete(let text):
            guard isQuestionEnding, !text.isEmpty else {
                fallBackFromCloud(id, reason: "在线语音未完成本题。")
                return
            }
            questionTranscript = joinedCloudQuestion(text)
            questionSpeechStatus = .usedOnline(cloud.provider.name)
            endQuestion(submitting: true)
        }
    }

    private func joinedCloudQuestion(_ text: String) -> String {
        [initialQuestionText, Self.removingRepeatedPrefix(initialQuestionText, from: text)]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func fallBackFromCloud(_ id: UUID, reason: String) {
        guard questionCloud?.id == id else { return }
        stopQuestionCloud()
        questionSpeechStatus = .fallback(reason)
        questionTranscript = localQuestionTranscript
        if !localQuestionCanTranscribe {
            endUnavailableQuestion()
        } else if isQuestionEnding, localFinishedQuestion {
            endQuestion(submitting: true)
        }
    }

    private func endUnavailableQuestion() {
        speechError = "本题的在线转写未完成，本机语音识别也不可用。请在问题框输入或修改问题。"
        endQuestion(submitting: false)
    }

    private func stopQuestionCloud() {
        let cloud = questionCloud
        questionCloud = nil
        cloudPreview = nil
        cloudSentenceBoundary = false
        // Stop accepting audio without committing a clip.
        cloud?.transcript?.cancel()
        cloud?.startup?.cancel()
        cloud?.input.continuation.finish()
    }

    private static func removingRepeatedPrefix(_ prefix: String, from transcript: String) -> String {
        guard !prefix.isEmpty else { return transcript }
        let prefixWords = questionWords(prefix)
        let words = questionTokens(transcript)
        guard !prefixWords.isEmpty, words.map(foldQuestionWord).starts(with: prefixWords) else { return transcript }
        guard let suffix = words.dropFirst(prefixWords.count).first else { return "" }
        return String(transcript[suffix.startIndex...])
    }

    private static func revisesEarlierWords(_ previous: String, _ current: String) -> Bool {
        let oldWords = questionWords(previous)
        let newWords = questionWords(current)
        if oldWords == newWords { return true }
        return oldWords.count >= 3 && oldWords.count == newWords.count && oldWords.suffix(2) == newWords.suffix(2)
    }

    private static func questionWords(_ text: String) -> [String] {
        questionTokens(text).map(foldQuestionWord)
    }

    private static func foldQuestionWord(_ word: Substring) -> String {
        String(word).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en-US"))
    }

    private static func questionTokens(_ text: String) -> [Substring] {
        guard text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else {
            return text.split { !$0.isLetter && !$0.isNumber }
        }
        // Chinese partials can contain an entire preceding clause without any
        // spaces. Keep original ranges so a cumulative reissue can be trimmed.
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.simplifiedChinese)
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { text[$0] }
    }
}
