import AVFoundation
import Foundation

@MainActor
private final class TestSpeechInput: CompanionSpeechInput {
    var continuesFollowingAfterFinal = false
    private(set) var streams: [@MainActor (CompanionSpeechEvent) -> Void] = []
    private(set) var locales: [String] = []
    private(set) var finishCount = 0

    func start(
        localeIdentifier: String,
        reportLevel: Bool,
        onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void
    ) {
        locales.append(localeIdentifier)
        streams.append(onEvent)
        onEvent(.started)
    }

    func finish() { finishCount += 1 }
    func cancel() {}

    func emit(_ text: String, final: Bool = false, stream: Int? = nil) {
        streams[stream ?? streams.count - 1](.transcript(text, isFinal: final))
    }

    func level(_ value: CGFloat, at time: TimeInterval) {
        streams.last?(.level(value, at: time))
    }

    func fail(_ message: String) {
        streams.last?(.failure(message, canRestart: false))
    }
}

@MainActor
private final class TestTime {
    var time: TimeInterval = 0
}

@main
struct TrackingChecks {
    private static let first = "Our field team measures baseline energy consumption."
    private static let second = "Monthly comparisons reveal seasonal changes in demand."
    private static let third = "A separate pilot reduces cooling hours across warehouses."
    private static let fourth = "Temperature sensors confirm stable cold storage performance."
    private static let fifth = "The final rollout covers distribution centers nationwide."
    private static let sixth = "Regional managers verify installation costs against budget."

    private static let pages = [
        CompanionTrackingPage(sentences: [first, "[Point at metric. Wait for audience!]", second]),
        CompanionTrackingPage(sentences: ["Hidden backup slide contains archived vendor comparisons."], isAppendix: true),
        CompanionTrackingPage(sentences: [third, fourth]),
        CompanionTrackingPage(sentences: [fifth, sixth])
    ]

    @MainActor
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 2, arguments[0] == "--english-coverage-helper" {
            try await packagedCoverage(URL(fileURLWithPath: arguments[1]))
            return
        }
        if arguments.count == 3, arguments[0] == "--questions" {
            try replayQuestions(manifest: URL(fileURLWithPath: arguments[1]), audio: URL(fileURLWithPath: arguments[2]))
            return
        }
        let apple = TestSpeechInput(), whisper = TestSpeechInput()
        let switching = CompanionTrackingController(speech: apple, whisper: whisper)
        switching.configure(pages: pages)
        switching.startFollowing()
        precondition(apple.streams.count == 1 && whisper.streams.isEmpty)
        switching.selectFollowEngine(.whisper)
        precondition(whisper.streams.count == 1)
        let anchor = switching.position
        apple.emit(third + " " + fourth)
        precondition(switching.position == anchor)
        whisper.emit(first, final: true)
        precondition(whisper.streams.count == 1, "A pause must not reload Whisper")
        switching.startQuestion(localeIdentifier: "zh-CN") { _ in }
        precondition(apple.locales.last == "zh-CN" && switching.phase == .listeningQuestion)
        let held = switching.position
        whisper.emit(third + " " + fourth)
        precondition(switching.position == held)
        switching.cancelQuestion()
        precondition(whisper.streams.count == 2)
        switching.stopFollowing()
        print("PASS alternate follow engine, stale input, question isolation and resume")
        pageEndingChecks()
        followsSegmentedLongEnding()
        freeSpeakingChecks()
        liveFollowFeedback()
        wordProgressAndPointingCues()
        followsShortTransitionsAcrossFinals()
        followsAfterDroppedEndings()
        rollingPreviewAndPrompt()
        appleSegmentsKeepSuccessivePartialResults()
        continuousWordProgressAfterRecognitionCorrection()
        sentencesRetainActions()
        matcherAdvancesOnlyWithLocalEvidence()
        repairedPartialCanConfirmAnAdjacentPage()
        rebuildsSamePageProgressAfterRecognitionRestarts()
        preservesAssertionMeaning()
        usesLocalizedPreparedParaphrases()
        skipsOneMissedLineAndResumesOrderedSpeech()
        nextEmptyBodyPageDoesNotGetSkipped()
        explicitQuestionCueKeepsAnswersOutOfCapture()
        questionsLockAndSubmitOnlyOnce()
        lateCorrectionsKeepTheQuietInterval()
        questionRetainsSegmentsAcrossAnApplePartialReset()
        typedQuestionAndManualSelectionIgnoreLateRecognition()
        chineseKeyPointsAndLocalResourceFailureRemainSelectable()
        previewRangeKeepsPosition()
        print("PASS companion tracking, cue isolation and question lifecycle")
    }

    @MainActor
    private static func pageEndingChecks() {
        for engine in [CompanionFollowEngine.apple, .whisper] {
            let apple = TestSpeechInput(), whisper = TestSpeechInput()
            apple.continuesFollowingAfterFinal = true
            let voice = engine == .apple ? apple : whisper
            let tracker = CompanionTrackingController(speech: apple, whisper: whisper)
            let intro = "The sign points to the entrance."
            let last = "The blue marker shows our first stop."
            let next = "We cross the bridge to the garden."
            let deck = [CompanionTrackingPage(sentences: [intro, last, "[Pause.]"]),
                        .init(sentences: [], isAppendix: true),
                        .init(sentences: [next, fourth]), .init(sentences: []),
                        .init(sentences: [sixth], isAppendix: true)]
            tracker.configure(pages: deck)
            tracker.selectFollowEngine(engine)
            tracker.startFollowing()
            voice.emit(intro)
            require(tracker.displayedPageIndex == 0 && tracker.previousPageAnchor == nil, "Pre-reading the ending turned the slide")
            let opening = intro + " The blue marker shows"
            voice.emit(opening)
            require(tracker.position == location(0, 1) && tracker.displayedPageIndex == 2, "Distinctive ending did not turn the slide early")
            require(tracker.previousPageAnchor == location(0, 1) && tracker.promptPosition == location(2, 0) &&
                    tracker.previewPageIndex == 3 && tracker.readWords[location(2, 0)] == nil, "Wrong handoff panes or premature word marks")
            let current = intro + " " + last
            voice.emit(current)
            require(tracker.displayedPageIndex == 2 && tracker.readWords[location(0, 1)]?.count == 7, "Ending words lost during handoff")
            voice.emit(current + " " + next)
            require(tracker.position == location(2, 0) && tracker.displayedPageIndex == 2, "Continuous speech lost the opening of the new slide")
            tracker.returnToPreviousPage()
            voice.emit(last, final: true)
            require(tracker.displayedPageIndex == 0, "Review immediately bounced to the next slide")
            tracker.select(pageIndex: 2, sentenceIndex: 1)
            require(tracker.displayedPageIndex == 2, "Manual selection counted as speech")
            voice.emit(fourth, final: true)
            require(tracker.displayedPageIndex == 3 && tracker.promptPosition?.sentenceIndex == nil, "Empty body page skipped")
            voice.emit(sixth, final: true)
            require(tracker.displayedPageIndex == 3, "Entered an appendix from an empty body page")
            tracker.configure(pages: [.init(sentences: [intro, last]), .init(sentences: [next]),
                                      .init(sentences: [first, second, third, fourth, fifth, sixth]), .init(sentences: [intro])])
            tracker.select(pageIndex: 0)
            voice.emit(intro + " " + last + " " + next, final: true)
            require(tracker.previousPageAnchor == location(0, 1), "Coalesced speech lost the last spoken line on the old page")
            tracker.select(pageIndex: 0, sentenceIndex: 1)
            voice.emit(last, final: true)
            tracker.select(pageIndex: 2, fromPreview: true)
            require(tracker.displayedPageIndex == 2 && tracker.previewPageIndex == 3, "Clicking the right page during a handoff collapsed the rolling preview")
            tracker.configure(pages: [.init(sentences: ["The blue marker shows the pond.", last]),
                                      .init(sentences: [next])])
            tracker.select(pageIndex: 0, sentenceIndex: 1)
            voice.emit("The blue marker shows")
            require(tracker.displayedPageIndex == 0, "A shared opening moved the slide")
            voice.emit(last)
            require(tracker.displayedPageIndex == 1, "Unique ending failed to disambiguate")
            tracker.setFreeSpeaking(true)
            voice.emit(last, final: true)
            require(tracker.displayedPageIndex == 1 && tracker.position?.pageIndex == 1, "Mode switch restored the old slide")
            tracker.stopFollowing()
        }
        print("PASS early slide handoff: both engines, live tail, rolling preview, manual return, ambiguous prefix, blank and appendix")
    }

    @MainActor
    private static func followsSegmentedLongEnding() {
        let intro = "Forecast models are improving across regions."
        let chunks = ["When forecast models become mature enough", "and the local weather can be measured precisely",
                      "we may be able to close this gap"]
        let ending = chunks.joined(separator: ", ") + "."
        let deck: [CompanionTrackingPage] = [.init(sentences: [intro, ending]), .init(sentences: [first, second])]
        for engine in [CompanionFollowEngine.apple, .whisper] {
            for continuous in [false, true] {
                let apple = TestSpeechInput(), whisper = TestSpeechInput()
                apple.continuesFollowingAfterFinal = true
                let tracker = CompanionTrackingController(speech: apple, whisper: whisper)
                tracker.configure(pages: deck)
                tracker.selectFollowEngine(engine)
                tracker.startFollowing()
                let voice = engine == .apple ? apple : whisper
                var previous = ""
                func say(_ text: String) {
                    let transcript = previous + text
                    voice.emit(transcript, final: !continuous)
                    if continuous { previous = transcript + " " }
                }
                say(intro)
                say(chunks[0])
                require(tracker.position == location(0, 1) && tracker.displayedPageIndex == 1,
                        "A pause before a late qualifier blocked the distinctive opening of the ending")
                require(tracker.readWords[location(0, 1)] == IndexSet(0..<CompanionTrackingMatcher.words(in: chunks[0]).count)
                        && tracker.readWords[location(1, 0)] == nil,
                        "Partial ending marked words that were never spoken")
                say(chunks[1])
                say(chunks[2])
                require(tracker.readWords[location(0, 1)]?.count == CompanionTrackingMatcher.words(in: ending).count,
                        "Later fragments failed to finish the ending on the old page")
                say(first)
                require(tracker.position == location(1, 0), "Could not pick up the next page after a segmented ending")
                tracker.stopFollowing()
            }
        }
        var m = CompanionTrackingMatcher(pages: deck)
        m.process("When forecast models", awaitingResume: false)
        require(m.position == location(0, 0), "A short shared phrase moved a manually positioned cursor")
        m.process("When forecast models become mature enough", awaitingResume: true)
        require(m.position == location(0, 0), "An unfinished quotation released the question lock")
        m.process("When forecast models become mature enough we cannot proceed", awaitingResume: false)
        require(m.position == location(0, 0), "A contradictory ending counted as the printed opening")
        print("PASS paused long ending, continued word feedback and next-page pickup on both input routes")
    }

    @MainActor
    private static func freeSpeakingChecks() {
        for engine in [CompanionFollowEngine.apple, .whisper] {
            let apple = TestSpeechInput(), whisper = TestSpeechInput()
            apple.continuesFollowingAfterFinal = true
            let input = engine == .whisper ? whisper : apple
            let controller = CompanionTrackingController(speech: apple, whisper: whisper)
            controller.configure(pages: pages, document: "first deck")
            controller.selectFollowEngine(engine)
            controller.setFreeSpeaking(true)
            controller.startFollowing()
            let a = CompanionTrackingPosition(pageIndex: 0, sentenceIndex: 0)
            let b = CompanionTrackingPosition(pageIndex: 0, sentenceIndex: 2)
            let next = CompanionTrackingPosition(pageIndex: 2, sentenceIndex: 1)
            input.emit(second)
            input.emit(second.dropLast() + "?", final: true)
            precondition(controller.coverage.covered.isEmpty)
            input.emit(second, final: true)
            precondition(controller.coverage.covered == [b] && controller.position == b)
            controller.select(pageIndex: 0, sentenceIndex: 0)
            precondition(controller.coverage.covered == [b])
            input.emit(fourth, final: true)
            precondition(controller.position == a && controller.displayedPageIndex == 0 && controller.coverage.covered == [b, next])
            controller.select(pageIndex: 0, sentenceIndex: 0)
            controller.holdForTypedAnswer()
            input.emit(first, final: true)
            precondition(controller.coverage.covered == [b, next])
            controller.select(pageIndex: 0, sentenceIndex: 0)
            input.emit(first, final: true)
            precondition(controller.coverage.covered == [a, b, next] && controller.displayedPageIndex == 0)
            input.emit(third, final: true)
            input.emit(fourth, final: true)
            precondition(controller.position == a && controller.displayedPageIndex == 0)
            controller.holdForTypedAnswer()
            input.emit(third + " " + fourth, final: true)
            precondition(controller.phase == .awaitingResume && controller.displayedPageIndex == 0)
            controller.select(pageIndex: 2, sentenceIndex: 1, fromPreview: true)
            precondition(controller.position == next && controller.displayedPageIndex == 2)
            controller.configure(pages: pages, document: "second deck")
            precondition(controller.coverage.covered.isEmpty)
            controller.setFreeSpeaking(false)
            controller.stopFollowing()
        }
        print("PASS free speaking on both input routes: partials, skipped points, clicks, manual-only paging, Q&A and deck reset")
    }

    @MainActor
    private static func liveFollowFeedback() {
        let lines = ["We use three questions.", "Can AI do the digital work?",
                     "Does the task need physical evidence?", "Who approves the change?",
                     "The supplier approves the change."]
        for engine in [CompanionFollowEngine.apple, .whisper] {
            let apple = TestSpeechInput(), whisper = TestSpeechInput()
            apple.continuesFollowingAfterFinal = true
            let input = engine == .whisper ? whisper : apple
            let controller = CompanionTrackingController(speech: apple, whisper: whisper)
            controller.configure(pages: [CompanionTrackingPage(sentences: lines)])
            controller.selectFollowEngine(engine)
            controller.setFreeSpeaking(true)
            controller.startFollowing()
            input.level(0.08, at: 1)
            input.emit("Does the task need physical")
            let target = CompanionTrackingPosition(pageIndex: 0, sentenceIndex: 2)
            precondition(controller.inputLevel > 0 && controller.lastHeard == "Does the task need physical")
            precondition(controller.coverage.liveWord?.position == target && controller.coverage.covered.isEmpty)
            input.emit(lines[2], final: true)
            precondition(controller.position == target && controller.coverage.covered == [target])
            input.emit(lines[0] + " " + lines[1], final: true)
            precondition(controller.coverage.covered.count == 3)
            input.emit("The supplier approves the change?", final: true)
            precondition(controller.coverage.covered.count == 3)
            input.emit(lines[2], final: true)
            precondition(controller.position == target)
            controller.stopFollowing()
            precondition(controller.lastHeard.isEmpty && controller.inputLevel == 0 && !controller.displaysFollowCapture)
        }
        print("PASS Apple and Whisper routes: live level, interim cursor without grey, authored questions, combined final, repeated reading and stop")
    }

    @MainActor
    private static func packagedCoverage(_ helper: URL) async throws {
        let input = TestSpeechInput()
        input.continuesFollowingAfterFinal = true
        let coverage = EnglishPointCoverage(helper: helper)
        let controller = CompanionTrackingController(speech: input, pointCoverage: coverage)
        let air = ["The station measures humidity every minute.", "A technician approves each replacement sensor.",
                   "Readings are saved during a power cut."]
        let studio = ["Visitors must reserve a place online.", "A guide accompanies every group.",
                      "The studio plans to offer evening tours."]
        controller.configure(pages: [CompanionTrackingPage(sentences: air), CompanionTrackingPage(sentences: studio)],
                             titles: ["Air station", "Studio visits"], document: "coverage integration")
        controller.setFreeSpeaking(true)
        controller.startFollowing()
        defer { controller.stopFollowing(); controller.setFreeSpeaking(false) }
        func waitFor(_ description: String, _ predicate: () -> Bool) async throws {
            let end = ContinuousClock.now.advanced(by: .seconds(35))
            while !predicate(), .now < end {
                try await Task.sleep(for: .milliseconds(40))
            }
            precondition(predicate(), "\(description): \(coverage.status)")
        }
        try await waitFor("local model ready") { coverage.state == .ready }
        let a = CompanionTrackingPosition(pageIndex: 0, sentenceIndex: 0)
        let c = CompanionTrackingPosition(pageIndex: 0, sentenceIndex: 2)
        let book = CompanionTrackingPosition(pageIndex: 1, sentenceIndex: 0)
        let guide = CompanionTrackingPosition(pageIndex: 1, sentenceIndex: 1)
        input.emit("Every sixty seconds the station takes a humidity measurement.", final: true)
        controller.holdForTypedAnswer()
        controller.select(pageIndex: 0, sentenceIndex: 0)
        input.emit("Even if the power goes out, we keep the readings.", final: true)
        try await waitFor("late result discarded and shuffled point matched") { coverage.covered.contains(c) }
        precondition(coverage.covered == [c])
        input.emit("The station measures humidity once per minute.", final: true)
        try await waitFor("return to an earlier point") { coverage.covered.contains(a) }
        input.emit("Nobody can join a visit without booking a spot on the website first.", final: true)
        try await waitFor("single mention in the preview") { coverage.covered.contains(book) }
        precondition(controller.position?.pageIndex == 0)
        input.emit("Every group goes around with a guide.", final: true)
        try await waitFor("second preview point received") { coverage.covered.contains(guide) }
        precondition(controller.position == a && controller.displayedPageIndex == 0)
        precondition(coverage.covered == [a, c, book, guide])
        controller.select(pageIndex: 0, sentenceIndex: 1)
        precondition(coverage.covered == [a, c, book, guide])
        coverage.reset()
        precondition(coverage.covered.isEmpty)
        // A full 18-line page can have a semantic job in flight when the next
        // utterance is verbatim. Late results may fill omissions, never rewind.
        let dense = air + ["Does the sensor need calibration?"] + (1...14).map { "Checklist item \($0) covers fixture \($0)." }
        controller.configure(pages: [CompanionTrackingPage(sentences: dense), CompanionTrackingPage(sentences: studio)],
                             titles: ["Air station", "Studio visits"], document: "dense rehearsal")
        controller.select(pageIndex: 0)
        input.emit("Even if the power goes out, we keep the readings.", final: true)
        let question = CompanionTrackingPosition(pageIndex: 0, sentenceIndex: 3)
        input.emit("Does the sensor need calibration?", final: true)
        precondition(coverage.covered == [question] && controller.position == question)
        try await waitFor("earlier paraphrase completes without rewinding a newer reading") { coverage.covered.contains(c) }
        precondition(controller.position == question && coverage.covered == [question, c])
        print("PASS signed local model: late semantic result preserves new cursor on 18-line slide; scripted question marks immediately")
        print("PASS signed local model over real IPC: paraphrases out of order, omitted point, stale Q&A result, two-page evidence, review and reset")
    }

    @MainActor
    private static func explicitQuestionCueKeepsAnswersOutOfCapture() {
        let speech = TestSpeechInput()
        let timer = TestTime()
        let controller = CompanionTrackingController(speech: speech, now: { timer.time })
        var answers: [String] = []
        controller.armQuestionCue(localeIdentifier: "en-US") { seed in
            controller.startQuestion(localeIdentifier: "en-US", initialText: seed) { answers.append($0) }
        }
        let firstStream = speech.streams.count - 1
        speech.emit("That depends on the next question we ask.")
        speech.emit("How did we handle this in practice?")
        precondition(controller.phase != .listeningQuestion && answers.isEmpty)
        speech.emit("Next question, how does the meter work?")
        precondition(controller.phase == .listeningQuestion && controller.questionTranscript == "how does the meter work?")
        controller.submitQuestion()
        precondition(answers == ["how does the meter work?"] && controller.cueArmed)
        speech.emit("Next question, obsolete event", stream: firstStream)
        speech.emit("It uses an acoustic reading.")
        precondition(controller.phase == .awaitingResume && answers.count == 1)
        speech.emit("It uses an acoustic reading. Next question: how much energy")
        speech.emit("does the sensor use?")
        controller.submitQuestion()
        precondition(answers.last == "how much energy does the sensor use?" && answers.count == 2)
        controller.disarmQuestionCue()
        speech.emit("Next question: stop", stream: speech.streams.count - 1)
        precondition(!controller.isListening && !controller.cueArmed && answers.count == 2)

        controller.configure(pages: pages)
        controller.startFollowing()
        controller.armQuestionCue(localeIdentifier: "zh-CN") { _ in preconditionFailure("stale wake") }
        controller.select(pageIndex: 2)
        precondition(!controller.cueArmed && controller.isListening && speech.locales.last == "en-US")
    }

    private static func previewRangeKeepsPosition() {
        let slides = [
            CompanionTrackingPage(sentences: ["[Point here]", first, second, "[Pause]"]),
            CompanionTrackingPage(sentences: ["Backup appendix line."], isAppendix: true),
            CompanionTrackingPage(sentences: [third, fourth, fifth]),
            CompanionTrackingPage(sentences: []),
            CompanionTrackingPage(sentences: [sixth])
        ]
        var matcher = CompanionTrackingMatcher(pages: slides)
        let original = matcher.position
        func text(_ n: Int) -> [String] { matcher.readingWindow(upcoming: n).compactMap { matcher.sentence(at: $0) } }
        precondition(text(1) == ["[Point here]", first, second])
        precondition(text(3) == ["[Point here]", first, second, "[Pause]", third, fourth])
        precondition(text(8).last == fifth && !text(8).contains(sixth))
        precondition(matcher.position == original)
        matcher.select(pageIndex: 2, sentenceIndex: 2)
        precondition(text(3) == [fifth])
    }

    private struct Replay: Decodable {
        struct Clip: Decodable {
            struct Snapshot: Decodable {
                let referenceMs: Int
                let cutoffMs: Int
                let recognitionMs: Int
                let transcript: String
            }
            let id: String
            let phase: String
            let audioFile: String
            let events: [Snapshot]
        }
        let clips: [Clip]
    }

    private struct ReplayResult: Encodable {
        let clip: String
        let extraGapMs: Int
        let endOfLastPhraseMs: Int
        let submittedAtMs: Int?
        let submissionCount: Int
        let cutOffBeforeLastPhrase: Bool
        let unchangedPosition: Bool
        let keptAllRecognizedText: Bool
    }

    @MainActor
    private static func replayQuestions(manifest: URL, audio: URL) throws {
        let data = try Data(contentsOf: manifest)
        let replay = try JSONDecoder().decode(Replay.self, from: data)
        var results: [ReplayResult] = []
        for clip in replay.clips where clip.phase == "listeningQuestion" {
            let intervals = try levels(of: audio.appendingPathComponent(clip.audioFile))
            let stressGaps = clip.id.hasPrefix("slow-") ? [0, 950, 1_450] : [0]
            for extraGap in stressGaps {
                results.append(replayQuestion(clip, levels: intervals, extraGap: extraGap))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(results) + Data([10]))
    }

    private static func levels(of url: URL) throws -> [CGFloat] {
        let audio = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(audio.processingFormat.sampleRate / 50)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: frames),
              let samples = buffer.floatChannelData?.pointee else { throw CocoaError(.fileReadCorruptFile) }
        var levels: [CGFloat] = []
        while audio.framePosition < audio.length {
            try audio.read(into: buffer, frameCount: frames)
            let level = (0..<Int(buffer.frameLength)).reduce(Float.zero) { $0 + samples[$1] * samples[$1] }
            levels.append(CGFloat(sqrt(level / Float(buffer.frameLength))))
        }
        return levels
    }

    @MainActor
    private static func replayQuestion(_ clip: Replay.Clip, levels: [CGFloat], extraGap: Int) -> ReplayResult {
        let speech = TestSpeechInput()
        let clock = TestTime()
        let tracker = CompanionTrackingController(speech: speech, now: { clock.time })
        tracker.configure(pages: pages)
        tracker.select(pageIndex: 0, sentenceIndex: 0)
        var submissions: [String] = []
        var submittedAt: Int?
        tracker.startQuestion {
            submissions.append($0)
            submittedAt = Int((clock.time * 1000).rounded())
        }

        let split = (clip.events.first?.referenceMs ?? 0) / 20
        var samples = levels
        samples.insert(contentsOf: Array(repeating: 0, count: extraGap / 20), at: min(split, samples.count))
        var nextSnapshot = 0
        let deadline = (clip.events.last?.referenceMs ?? 0) + extraGap + 4_500
        for instant in stride(from: 0, through: deadline, by: 20) {
            clock.time = Double(instant) / 1000
            let index = instant / 20
            if speech.finishCount == 0 {
                speech.level(index < samples.count ? samples[index] : 0, at: clock.time)
                while nextSnapshot < clip.events.count {
                    let event = clip.events[nextSnapshot]
                    let scheduled = event.cutoffMs + event.recognitionMs + (nextSnapshot == 0 ? 0 : extraGap)
                    guard scheduled <= instant else { break }
                    speech.emit(event.transcript)
                    nextSnapshot += 1
                }
            }
            if instant.isMultiple(of: 200) { tracker.checkQuestionSilence() }
            if speech.finishCount > 0 && tracker.isQuestionEnding {
                // The same production controller consumes this final callback.
                speech.emit(tracker.questionTranscript, final: true)
                speech.emit(tracker.questionTranscript, final: true)
            }
        }
        let lastPhrase = (clip.events.last?.referenceMs ?? 0) + extraGap
        return ReplayResult(
            clip: clip.id, extraGapMs: extraGap, endOfLastPhraseMs: lastPhrase, submittedAtMs: submittedAt,
            submissionCount: submissions.count, cutOffBeforeLastPhrase: submittedAt.map { $0 < lastPhrase } ?? false,
            unchangedPosition: tracker.position == location(0, 0),
            keptAllRecognizedText: submissions.first == clip.events.last?.transcript
        )
    }

    private static func wordProgressAndPointingCues() {
        let sentence = "The team [point to the first box] builds the new green pump today."
        let line = location(0, 0)
        var matcher = CompanionTrackingMatcher(pages: [.init(sentences: [sentence, "[point to the second box]", "Pressure readings guide maintenance."])])
        func heard(_ value: String, _ indices: [Int], awaiting: Bool = false) {
            matcher.process(value, awaitingResume: awaiting)
            require(matcher.readWords[line] == IndexSet(indices), "Wrong word progress after " + value)
        }
        let ranges = CompanionTrackingPage.wordRanges(in: sentence)
        require(ranges.map { String(sentence[$0]) } == ["The","team","builds","the","new","green","pump","today"],
                "Action words entered lexical progress")
        let lines = matcher.sentences(on: 0)
        func cue(_ row: Int, _ read: [Int]) -> String? {
            CompanionPointingCue.active(in: lines, sentence: row, read: IndexSet(read))?.instruction
        }
        require(cue(0, [0]) == nil && cue(0, [0,1]) == "point to the first box", "Inline instruction fired early or late")
        require(cue(0, [0,1,7]) == "point to the second box" && cue(2, []) == "point to the second box",
                "Standalone instruction did not connect the surrounding speech")
        require(CompanionPointingCue.active(in: ["[pause]", "Keep going."], sentence: 1, read: []) == nil,
                "A performance direction requested a slide marker")
        heard("The", [0])
        heard("The team", [0,1])
        heard("The team builds", [0,1,2])
        heard("The team builds, could the audience wait", [0,1,2])
        heard("The team builds, could the audience wait, green", [0,1,2])
        heard("The team builds, could the audience wait, green pump", [0,1,2,5,6])
        heard("The team builds, could the audience wait, green pump", [0,1,2,5,6])
        matcher.resetTranscript()
        heard("today", [0,1,2,5,6], awaiting: true)
        matcher.resetTranscript()
        heard("today", [0,1,2,5,6,7])
        matcher.select(pageIndex: 0, sentenceIndex: 0)
        require(matcher.readWords[line] == nil, "Manual selection retained stale read words")
        var repeated = CompanionTrackingMatcher(pages: [.init(sentences: ["Try again again tomorrow."])])
        for partial in ["Try", "Try again", "Try again.", "Try again again"] { repeated.process(partial, awaitingResume: false) }
        require(repeated.readWords[line] == IndexSet([0,1,2]), "Repeated words or revised punctuation advanced incorrectly")
    }

    @MainActor
    private static func followsShortTransitionsAcrossFinals() {
        for engine in [CompanionFollowEngine.apple, .whisper] {
            let apple = TestSpeechInput(), whisper = TestSpeechInput()
            let tracker = CompanionTrackingController(speech: apple, whisper: whisper)
            tracker.configure(pages: [.init(sentences: [first, "Thank you."]),
                                      .init(sentences: ["Welcome back.", second]),
                                      .init(sentences: [third])])
            tracker.selectFollowEngine(engine)
            tracker.startFollowing()
            let input = engine == .apple ? apple : whisper
            input.emit(first, final: true)
            input.emit("Thank you.", final: true)
            require(tracker.position == location(0, 1), "A spoken two-word sentence stuck at the prior line")
            input.emit("Welcome back.", final: true)
            require(tracker.position == location(1, 0), "A pause at the page turn lost the new opening")
            input.emit(second, final: true)
            input.emit(third, final: true)
            require(tracker.position == location(2, 0), "The following page did not become current")
            tracker.stopFollowing()
        }
    }

    @MainActor
    private static func followsAfterDroppedEndings() {
        let clipped = "Our field team measures"
        let script = [first, "Shared context.", second, third, fourth, fifth, sixth]
        for engine in [CompanionFollowEngine.apple, .whisper] {
            for segmented in [true, false] {
                let apple = TestSpeechInput(), whisper = TestSpeechInput()
                let tracker = CompanionTrackingController(speech: apple, whisper: whisper)
                tracker.configure(pages: [.init(sentences: script), .init(sentences: [third, fourth, second]),
                                          .init(sentences: [first])])
                tracker.selectFollowEngine(engine)
                tracker.startFollowing()
                let voice = engine == .apple ? apple : whisper
                voice.emit(clipped, final: segmented)
                let prefix = segmented ? "" : clipped + " "
                voice.emit(prefix + "Shared")
                require(tracker.position == location(0, 0), "A single word after a clipped ending advanced")
                voice.emit(prefix + "Shared context.", final: segmented)
                require(tracker.position == location(0, 1), "Missing last words blocked a short following sentence")
                require(tracker.readWords[location(0, 0)] == IndexSet(0..<4), "Unheard ending was marked")
                tracker.select(pageIndex: 0, sentenceIndex: 0)
                voice.emit(clipped, final: segmented)
                voice.emit(prefix + fourth, final: segmented)
                require(tracker.position == location(0, 0), "A single distant quotation moved the prompt")
                voice.emit((segmented ? "" : prefix + fourth + " ") + fifth, final: segmented)
                require(tracker.position == location(0, 5), "Two ordered later lines could not recover the cursor")
                require(tracker.readingWindow(upcoming: 1).contains(location(0, 5)), "The last spoken sentence disappeared")
                voice.emit((segmented ? "" : prefix + fourth + " " + fifth + " ") + sixth)
                require(tracker.position == location(0, 6), "Tracking stopped after reacquiring the script")
                tracker.select(pageIndex: 1, sentenceIndex: 1, fromPreview: true)
                require(tracker.position == location(1, 1) && tracker.twoPagePreviewIndex == 2,
                        "Selecting a preview sentence did not roll the two pages")
                voice.emit(fourth)
                require(tracker.promptPosition == location(1, 2), "Tracking did not continue from the clicked preview sentence")
                tracker.stopFollowing()
            }
        }
        var m = CompanionTrackingMatcher(pages: [.init(sentences: [first]), .init(sentences: ["Shared context unites teams.", third])])
        m.process(clipped, awaitingResume: false)
        m.beginSpeechSegment()
        m.process("Shared context unites", awaitingResume: false)
        require(m.position == location(1, 0), "A clipped ending prevented a confirmed page opening")
        require(m.previousReadPosition == location(0, 0), "Page turn discarded the previous slide's read sentence")
        m = CompanionTrackingMatcher(pages: [.init(sentences: script)])
        for fragment in [clipped, fourth, "The", fifth] {
            m.process(fragment, awaitingResume: false)
        }
        require(m.position == location(0, 5) && m.readWords[location(0, 4)]?.count ?? 0 >= 4,
                "Untimed segment replacement discarded corroborating lines or their read history")
        require(m.readWords[location(0, 3)] == nil, "A skipped sentence was marked as read")
        for interrupted in [true, false] {
            m.select(pageIndex: 0, sentenceIndex: 0)
            m.process(fourth, awaitingResume: false)
            m.beginSpeechSegment()
            if interrupted {
                m.process("Let me look at the questions.", awaitingResume: false)
                m.beginSpeechSegment()
            } else {
                m.select(pageIndex: 0, sentenceIndex: 0)
            }
            m.process(fifth, awaitingResume: false)
            require(m.position == location(0, 0), "An old quotation survived an interruption or manual jump")
        }
        m.select(pageIndex: 0, sentenceIndex: 0)
        m.process("Do not " + fourth + " " + fifth, awaitingResume: false)
        require(m.position == location(0, 0), "An opposite assertion anchored a distant pair")
        for segmented in [false, true] {
            m = CompanionTrackingMatcher(pages: [.init(sentences: [first, second, third]),
                                                  .init(sentences: [fourth, fifth, sixth])])
            m.process(clipped, awaitingResume: false)
            if segmented { m.beginSpeechSegment() }
            m.process(fourth, awaitingResume: false)
            require(m.position == location(0, 0), "A lone quote flipped a slide with unread lines")
            if segmented { m.beginSpeechSegment() }
            m.process(segmented ? fifth : fourth + " " + fifth, awaitingResume: false)
            require(m.position == location(1, 1), "Missed lines at a slide boundary prevented reacquisition")
        }
        print("PASS clipped endings, short transitions, distant reacquisition, prompt history and preview selection on both engines")
    }

    @MainActor
    private static func rollingPreviewAndPrompt() {
        let apple = TestSpeechInput(), tracker = CompanionTrackingController(speech: apple)
        tracker.configure(pages: [
            .init(sentences: [first, second, "[pause]", third, fourth, "Thank you."]),
            .init(sentences: ["Backup figures."], isAppendix: true),
            .init(sentences: ["Welcome back.", first, second, third, fourth]),
            .init(sentences: [fifth]),
            .init(sentences: [])
        ])
        tracker.startFollowing()
        require(tracker.previewPageIndex == nil, "Long slides should open at full width")
        apple.emit(first)
        require(tracker.promptPosition == location(0, 1) && tracker.position == location(0, 0),
                "Finishing a line must immediately reveal the next prompt")
        require(tracker.previewPageIndex == nil, "Preview opened four sentences before the end")
        apple.emit(first + " " + second)
        require(tracker.promptPosition == location(0, 3) && tracker.previewPageIndex == 2,
                "Preview must open at three spoken sentences, skipping directions and appendix slides")
        let nearEnd = [first, second, third, fourth, "Thank you."].joined(separator: " ")
        apple.emit(nearEnd, final: true)
        require(tracker.position == location(0, 5) && tracker.displayedPageIndex == 2 && tracker.promptPosition == location(2, 0),
                "The last spoken line should bring up the next slide without consuming its first line")
        apple.emit("Welcome back.")
        require(tracker.position?.pageIndex == 2 && tracker.previewPageIndex == 3,
                "The new left page must bring the following page to the right immediately")
        require(tracker.sentences(on: 3) == [fifth], "Preview must use the following page's own notes")
        tracker.select(pageIndex: 2)
        require(tracker.previewPageIndex == nil, "Manual selection retained a stale rolling pair")
        tracker.select(pageIndex: 0, sentenceIndex: 5)
        tracker.select(pageIndex: 2, fromPreview: true)
        require(tracker.previewPageIndex == 3, "Choosing the right page should also promote the next preview")
        tracker.select(pageIndex: 3)
        require(tracker.previewPageIndex == 4 && tracker.sentences(on: 4).isEmpty, "Blank slide cannot be previewed")
        tracker.select(pageIndex: 4)
        require(tracker.previewPageIndex == nil, "Last page showed a phantom preview")
        tracker.select(pageIndex: 0)
        tracker.startQuestion { _ in }
        apple.emit(nearEnd)
        require(tracker.promptPosition == location(0, 0) && tracker.previewPageIndex == nil,
                "Hearing a question must not move the reading view")
        tracker.cancelQuestion()
        tracker.stopFollowing()
        print("PASS completed sentence, three-sentence preview, rolling pages, manual selection and Q&A hold")
    }

    private static func appleSegmentsKeepSuccessivePartialResults() {
        var segments = CompanionRecognitionSegments()
        var matcher = CompanionTrackingMatcher(pages: [.init(sentences: [first, "Thank you."]),
                                                        .init(sentences: ["Welcome back."])])
        func hear(_ text: String, _ range: Range<TimeInterval>) {
            matcher.process(segments.update(text, audio: range), awaitingResume: false)
        }
        hear("Our fleet", 0..<0.5)
        hear(first, 0..<2)
        hear("Thank", 3..<3.4)
        hear("Thank you.", 3..<3.8)
        require(matcher.position == location(0, 1), "A newer Apple partial segment stuck behind old word offsets")
        hear("Welcome back.", 5..<6)
        require(matcher.position == location(1, 0), "Apple segment replacement lost the page transition")
        matcher.select(pageIndex: 0, sentenceIndex: nil)
        for partial in [first, "Thank", "Thank you.", "", "Welcome back."] {
            matcher.process(partial, awaitingResume: false)
        }
        require(matcher.position == location(1, 0), "Untimed partials replaced after a pause broke the reading sequence")
    }

    @MainActor
    private static func continuousWordProgressAfterRecognitionCorrection() {
        let input = TestSpeechInput()
        input.continuesFollowingAfterFinal = true
        let tracker = CompanionTrackingController(speech: input)
        tracker.configure(pages: [.init(sentences: ["The route isn't fully clear.",
            "Morgan's answer was simple: walk along the coast.", "Our survey starts tomorrow.", fourth]),
            .init(sentences: [fifth])])
        tracker.startFollowing()
        require(tracker.twoPagePreviewIndex == 1 && tracker.previewPageIndex == nil,
                "An explicit two-page choice hid the next slide on a long page")
        input.emit("The route is not fully clear.")
        require(tracker.promptPosition == location(0, 1), "Second prompt was never displayed")
        for partial in ["More", "More answer", "More answer was"] { input.emit(partial) }
        require(tracker.position == location(0, 1) && tracker.readWords[location(0, 1)]?.last == 3,
                "The second line lost the live cursor when an untimed partial replaced a non-verbatim first line")
        input.emit("More answer was simple walk along the coast.", final: true)
        require(tracker.promptPosition == location(0, 2) && input.streams.count == 1 && tracker.isListening,
                "A sentence final interrupted a continuously running microphone")
        input.emit("Our survey")
        require(tracker.readWords[location(0, 2)]?.last == 1, "Third sentence lost its opening words")
        tracker.select(pageIndex: 1)
        require(tracker.twoPagePreviewIndex == nil, "The last slide acquired a nonexistent preview")
        tracker.stopFollowing()
        var revised = CompanionTrackingMatcher(pages: [.init(sentences: ["At the station check the lamps and turn them on."])])
        revised.process("Stage2 at the station check the lamps and turn", awaitingResume: false)
        revised.process("Stage two at the station check the lamps and turn them on", awaitingResume: false)
        require(revised.readWords[location(0, 0)]?.last == 9, "Re-tokenizing earlier audio froze the last two words")
        let cues = ["[point to the headline]", "First sentence.", "Second sentence.", "[pause]", "After the pause."]
        require(CompanionPointingCue.active(in: cues, sentence: 2, read: [])?.instruction == "point to the headline"
                && CompanionPointingCue.active(in: cues, sentence: 4, read: []) == nil, "A visible pointing cue expired early or survived a pause direction")
    }

    private static func sentencesRetainActions() {
        let input = "[Point to sample. Pause!] \(first) \(second)\n中文提纲：基线\n第二条关键点。"
        let result = CompanionTrackingPage.sentences(in: input)
        require(result == ["[Point to sample. Pause!] \(first)", second, "中文提纲：基线", "第二条关键点。"], "sentence splitting changed text: \(result)")
        let spanning = CompanionTrackingPage.sentences(in: "[Point here.\nPause!] \(first)\n\(second)")
        require(spanning == ["[Point here.\nPause!] \(first)", second], "multiline action was split")
        require(CompanionTrackingPage.sentences(in: "[Pause.]") == ["[Pause.]"], "action-only line disappeared")
    }

    private static func matcherAdvancesOnlyWithLocalEvidence() {
        var matcher = CompanionTrackingMatcher(pages: pages)
        require(matcher.nextPosition == location(0, 2), "actions are skipped in preview")
        matcher.process(first, awaitingResume: false)
        matcher.process(first + " Demand was on everyone's minds.", awaitingResume: false)
        require(matcher.position == location(0, 0), "single shared keyword advanced")
        matcher.process(first + " " + second, awaitingResume: false)
        require(matcher.position == location(0, 2), "did not advance to spoken sentence")
        require(matcher.nextPosition == location(2, 0), "preview did not skip the designated appendix")
        matcher.process(first + " " + second + " " + pages[1].sentences[0], awaitingResume: false)
        require(matcher.position == location(0, 2), "appendix was followed")
        let intervening = "The audience pointed to many unrelated examples involving production, weather, facilities, access, procurement, and revised accounting calendars."
        let cross = [first, second, intervening, third].joined(separator: " ")
        matcher.process(cross, awaitingResume: false)
        require(matcher.position == location(0, 2), "one isolated sentence of the next page flipped")
        matcher.process(cross + " " + fourth, awaitingResume: false)
        require(matcher.position == location(2, 1), "corroborated next page did not advance")
        require(matcher.nextPosition == location(3, 0), "next page opening was missing")
        let ending = [cross, fourth, fifth, sixth].joined(separator: " ")
        matcher.process(ending, awaitingResume: false)
        require(matcher.position == location(3, 1) && matcher.nextPosition == nil, "last page did not stop")
        matcher.process(ending, awaitingResume: false)
        require(matcher.position == location(3, 1), "a duplicate partial advanced after the final line")
    }

    private static func repairedPartialCanConfirmAnAdjacentPage() {
        let opening = "Our regional reviewers check"
        let corrected = "Our regional reviewers reviewed safety budgets."
        let appendix = "Hidden backup documentation tracks parking repairs."
        let slides = [
            CompanionTrackingPage(sentences: [opening + " safety budgets."]),
            CompanionTrackingPage(sentences: [appendix], isAppendix: true),
            CompanionTrackingPage(sentences: [third, fourth])
        ]
        var matcher = CompanionTrackingMatcher(pages: slides)
        matcher.process(opening, awaitingResume: false)
        matcher.process("Our regional reviewers reviewed", awaitingResume: false)
        matcher.process(corrected + " " + third, awaitingResume: false)
        require(matcher.position == location(2, 0), "the revised page ending was still valid but the opening was missed")

        for intervening in [
            "Our regional visitors discussed parking repairs.",
            "Our regional reviewers review receipts.",
            corrected + " The audience pointed to examples from regional procurement, facilities, production, weather, accounting, advertising and external hiring."
        ] {
            matcher.select(pageIndex: 0, sentenceIndex: nil)
            matcher.process(opening, awaitingResume: false)
            matcher.process(intervening + " " + third, awaitingResume: false)
            require(matcher.position == location(0, 0), "revised transcript falsely confirmed the next page: \(intervening)")
        }

        matcher.select(pageIndex: 0, sentenceIndex: nil)
        matcher.process(opening, awaitingResume: false)
        matcher.process(corrected + " " + appendix, awaitingResume: false)
        require(matcher.position == location(0, 0), "the repaired partial selected an appendix")
        matcher.resetTranscript()
        require(!matcher.process(third, awaitingResume: true), "a single answer sentence resumed tracking")
        require(!matcher.process(third, awaitingResume: true), "a repeated callback resumed tracking")
        require(matcher.process(third + " " + fourth, awaitingResume: true), "two ordered sentences did not resume tracking")
    }

    private static func skipsOneMissedLineAndResumesOrderedSpeech() {
        var matcher = CompanionTrackingMatcher(pages: [
            CompanionTrackingPage(sentences: [first, second, third]),
            CompanionTrackingPage(sentences: [fourth, fifth, sixth])
        ])
        matcher.process("Our field team measures consumption for the energy baseline.", awaitingResume: false)
        matcher.process("Our field team measures consumption for the energy baseline. A separate pilot reduces cooling hours in our warehouses.", awaitingResume: false)
        require(matcher.position == location(0, 2), "missed one sentence or lightly paraphrased sentence did not match")
        matcher.resetTranscript()
        require(!matcher.process(fourth, awaitingResume: true), "one adjacent line resumed during an answer")
        require(!matcher.process(fourth, awaitingResume: true), "a duplicate partial counted as new speech")
        require(!matcher.process(fourth + " " + sixth, awaitingResume: true), "nonadjacent answer sentences resumed")
        require(matcher.process(fourth + " " + fifth, awaitingResume: true), "adjacent return to the script did not resume")
        require(matcher.position == location(1, 1), "wrong page and sentence after resuming")
    }

    private static func rebuildsSamePageProgressAfterRecognitionRestarts() {
        let prefix = "Earlier examples discussed budgeting, contracts, approvals, maintenance scheduling, and summer staffing. "
        let oldTranscript = prefix + first
        let samePage = [CompanionTrackingPage(sentences: [first, second, third, fourth])]
        var matcher = CompanionTrackingMatcher(pages: samePage)
        matcher.process(oldTranscript, awaitingResume: false)
        matcher.process("Monthly", awaitingResume: false)
        matcher.process(second, awaitingResume: false)
        matcher.process(second + " " + second, awaitingResume: false)
        require(matcher.position == location(0, 0), "a repeated quotation confirmed a fresh segment")
        matcher.process(second + " " + third, awaitingResume: false)
        require(matcher.position == location(0, 2), "two new adjacent sentences were lost behind the old transcript index")

        matcher.select(pageIndex: 0, sentenceIndex: 0)
        matcher.process(oldTranscript, awaitingResume: false)
        matcher.process("Earlier", awaitingResume: false)
        matcher.process(oldTranscript, awaitingResume: false)
        require(matcher.position == location(0, 0), "a temporary truncated partial reprocessed old speech")
        matcher.process(oldTranscript + " " + second, awaitingResume: false)
        require(matcher.position == location(0, 1), "a restored cumulative transcript no longer followed normally")

        matcher.select(pageIndex: 0, sentenceIndex: 0)
        matcher.process(prefix + oldTranscript, awaitingResume: false)
        matcher.process("Earlier observers quoted " + second + " " + third + " " + first + " " + prefix,
                        awaitingResume: false)
        require(matcher.position == location(0, 0), "a historical correction moved the accepted position")
        matcher.process("Monthly", awaitingResume: false)
        matcher.process(second + " " + third, awaitingResume: false)
        require(matcher.position == location(0, 0), "a revised partial reused a pair from before the cursor")

        matcher.select(pageIndex: 0, sentenceIndex: 0)
        matcher.process(oldTranscript, awaitingResume: false)
        matcher.process("Monthly", awaitingResume: true)
        require(!matcher.process(second + " " + third, awaitingResume: true), "segment recovery bypassed the answer lock")

        var acrossPages = CompanionTrackingMatcher(pages: [
            CompanionTrackingPage(sentences: [first, second]),
            CompanionTrackingPage(sentences: [third], isAppendix: true),
            CompanionTrackingPage(sentences: [fourth, fifth])
        ])
        acrossPages.process(oldTranscript, awaitingResume: false)
        acrossPages.process("Temperature", awaitingResume: false)
        acrossPages.process(fourth + " " + fifth, awaitingResume: false)
        require(acrossPages.position == location(0, 0), "segment recovery moved to an appendix or a later body page")
    }

    private static func nextEmptyBodyPageDoesNotGetSkipped() {
        var matcher = CompanionTrackingMatcher(pages: [
            CompanionTrackingPage(sentences: [first]),
            CompanionTrackingPage(sentences: []),
            CompanionTrackingPage(sentences: [second, third])
        ])
        matcher.process([first, second, third].joined(separator: " "), awaitingResume: false)
        require(matcher.position == location(0, 0) && matcher.nextPosition == nil, "auto skipped blank body page")
        require(matcher.select(pageIndex: 1, sentenceIndex: nil), "blank page cannot be manually selected")
        require(matcher.position == CompanionTrackingPosition(pageIndex: 1, sentenceIndex: nil), "blank page acquired an invented sentence")
        require(matcher.nextPosition == location(2, 0), "blank page cannot preview next body page")
    }

    private static let queueScript = [
        "The queue starts empty.",
        "Discard duplicate deliveries before writing the ledger.",
        "Send the receipt only after the commit completes."
    ]
    private static let queueParaphrase = "Throw away any event we have already handled so it never gets recorded twice."

    private static func preservesAssertionMeaning() {
        func followed(_ transcript: String, target: String = queueScript[1], awaitingResume: Bool = false) -> Bool {
            let page = CompanionTrackingPage(sentences: [queueScript[0], target, queueScript[2]])
            var matcher = CompanionTrackingMatcher(pages: [page])
            matcher.process(transcript, awaitingResume: awaitingResume)
            return matcher.position == location(0, 1)
        }

        for transcript in [
            "Do not discard duplicate deliveries before writing the ledger. Keep every event.",
            "Don't discard duplicate deliveries before writing the ledger",
            "Well so do not discard duplicate deliveries before writing the ledger.",
            "Never discard duplicate deliveries before writing the ledger.",
            "If we were to discard duplicate deliveries before writing the ledger, how would the retry counter change?",
            "If the other implementation that was initially designed for a completely different production environment were to discard duplicate deliveries before writing the ledger, retry behavior could change.",
            "Suppose we discard duplicate deliveries before writing the ledger.",
            "Discard duplicate deliveries before writing the ledger only if the network is quiet.",
            "We might discard duplicate deliveries before writing the ledger."
        ] {
            require(!followed(transcript), "polarity or condition incorrectly advanced: \(transcript)")
        }
        require(!followed("For the answer, I quoted the line: discard duplicate deliveries before writing the ledger.",
                          awaitingResume: true), "one quotation bypassed the answer lock")
        require(followed("We did not see any anemometers. " + queueScript[1]), "a previous negative sentence held unrelated speech")
        require(followed("Don't discard duplicate deliveries before writing the ledger.", target: "Do not " + queueScript[1].lowercased()),
                "a scripted negation was treated as off-script")
        let conditional = "If the staging area fills up, discard duplicate deliveries before writing the ledger."
        require(followed(conditional, target: conditional), "a scripted condition was treated as off-script")
        require(!followed(queueScript[1], target: conditional), "missing a written condition still advanced")
        let unless = "Unless the staging area fills up, discard duplicate deliveries before writing the ledger."
        require(followed(unless, target: unless), "a scripted unless condition was treated as off-script")
        require(!followed(conditional, target: unless), "opposite conditional form still advanced")
    }

    @MainActor
    private static func usesLocalizedPreparedParaphrases() {
        func positionAfter(_ speech: String, alternatives: [Int: [String]], sentences: [String] = queueScript)
            -> CompanionTrackingPosition? {
            var matcher = CompanionTrackingMatcher(pages: [CompanionTrackingPage(sentences: sentences,
                                                                                 sentenceAlternatives: alternatives)])
            matcher.process(speech, awaitingResume: false)
            return matcher.position
        }

        require(positionAfter(queueParaphrase, alternatives: [:]) == location(0, 0), "an unknown reformulation moved the cursor")
        let alternatives = [1: [queueParaphrase]]
        require(positionAfter(queueParaphrase, alternatives: alternatives) == location(0, 1), "a prepared strong reformulation did not advance")
        require(positionAfter("If we " + queueParaphrase.lowercased(), alternatives: alternatives) == location(0, 0),
                "a prepared phrase embedded in a conditional still advanced")
        require(positionAfter("Do not " + queueParaphrase.lowercased(), alternatives: alternatives) == location(0, 0),
                "negating a prepared phrase still advanced")
        require(positionAfter(queueParaphrase, alternatives: [1: [queueParaphrase], 2: [queueParaphrase]]) == location(0, 0),
                "an expression assigned to two neighboring sentences should remain ambiguous")
        require(positionAfter(queueParaphrase, alternatives: [2: [queueParaphrase]]) == location(0, 0),
                "an alternative skipped a sentence")
        require(positionAfter(queueParaphrase, alternatives: [1: [queueParaphrase + " Keep the sheet open."]]) == location(0, 0),
                "a multi-sentence alternative became a tracking cue")
        let negative = "Never throw away events during an active recovery period."
        require(positionAfter(negative, alternatives: [1: [negative]],
                              sentences: [queueScript[0], "Do not discard messages while restoring service."]) == location(0, 1),
                "prepared alternatives could not preserve an intentional negation")
        let conditional = "If outdoor temperatures rise, assemble every patrol at the southern gate."
        require(positionAfter(conditional, alternatives: [1: [conditional]],
                              sentences: [queueScript[0], "If the weather warms up, bring all security crews to the south entrance."])
                == location(0, 1), "prepared alternatives could not preserve an intentional condition")
        let wrongFigure = "Keep 500 pieces aside for independent quality assurance."
        require(positionAfter(wrongFigure, alternatives: [1: [wrongFigure]],
                              sentences: [queueScript[0], "Reserve 50 units for external review."]) == location(0, 0),
                "a prepared expression changed a number")
        let firstPage = CompanionTrackingPage(sentences: Array(queueScript.prefix(2)), sentenceAlternatives: alternatives)
        let later = CompanionTrackingPage(sentences: [queueScript[2], fourth], sentenceAlternatives: [0: [queueParaphrase]])
        let backup = CompanionTrackingPage(sentences: [first], isAppendix: true)
        var matcher = CompanionTrackingMatcher(pages: [firstPage, backup, later])
        matcher.process(queueParaphrase, awaitingResume: true)
        require(matcher.position == location(0, 0), "a prepared phrase bypassed the two-sentence Q&A lock")
        matcher.resetTranscript()
        matcher.process(queueParaphrase, awaitingResume: false)
        let singleEntry = queueParaphrase + " " + queueScript[2]
        matcher.process(singleEntry, awaitingResume: false)
        require(matcher.position == location(0, 1), "a prepared page ending authorized an immediate page flip")
        matcher.process(singleEntry + " " + fourth, awaitingResume: false)
        require(matcher.position == location(2, 1), "prepared wording disabled a corroborated transition")

        let speech = TestSpeechInput()
        let controller = CompanionTrackingController(speech: speech)
        controller.configure(pages: [firstPage, backup, later])
        controller.startFollowing()
        controller.select(pageIndex: 2, sentenceIndex: 0)
        speech.emit(queueParaphrase, stream: 0)
        require(controller.position == location(2, 0), "a late prepared phrase moved a manually selected page")
    }

    @MainActor
    private static func questionsLockAndSubmitOnlyOnce() {
        let speech = TestSpeechInput()
        let clock = TestTime()
        let tracker = CompanionTrackingController(speech: speech, now: { clock.time })
        tracker.configure(pages: pages)
        tracker.startFollowing()
        var submitted: [String] = []
        tracker.startQuestion { submitted.append($0) }
        require(tracker.phase == .listeningQuestion, "the question did not lock immediately")
        speech.emit(first + " " + second, stream: 0)
        speech.emit("When you say that " + second)
        require(tracker.position == location(0, 0), "question shifts the prompt")

        clock.time = 2.0
        tracker.checkQuestionSilence()
        require(speech.finishCount == 0 && submitted.isEmpty, "natural pause truncated the question")
        speech.emit("When you say that " + second, final: true)
        clock.time = 2.4
        speech.level(0.1, at: clock.time)
        clock.time = 4.6
        tracker.checkQuestionSilence()
        require(speech.finishCount == 0 && submitted.isEmpty, "active audio was ignored before the next transcription")
        speech.emit("which months count?")
        clock.time = 7.4
        tracker.checkQuestionSilence()
        require(speech.finishCount == 1 && tracker.isQuestionEnding, "question did not finish after silence")
        let oldQuestion = speech.streams.count - 1
        speech.emit("which months count?", final: true)
        require(submitted == ["When you say that " + second + " which months count?"], "wrong question text or duplicate submission")
        require(tracker.lastQuestionSpeechEndedAt != nil, "last audible time was cleared on submission")
        speech.emit("repeat", final: true, stream: oldQuestion)
        tracker.submitQuestion()
        require(submitted.count == 1 && tracker.phase == .awaitingResume, "question did not end once")
        speech.emit(second)
        require(tracker.phase == .awaitingResume && tracker.position == location(0, 0), "oral answer advanced the prompt")
        speech.emit(second + " " + third)
        require(tracker.phase == .following && tracker.position == location(2, 0), "oral return to the script did not advance")
        require(submitted.count == 1, "spoken answer opened a new question")
        tracker.stopFollowing()
    }

    @MainActor
    private static func lateCorrectionsKeepTheQuietInterval() {
        let speech = TestSpeechInput()
        let clock = TestTime()
        let tracker = CompanionTrackingController(speech: speech, now: { clock.time })
        var submitted: [String] = []
        tracker.startQuestion { submitted.append($0) }
        clock.time = 0.5
        speech.level(0.1, at: clock.time)
        speech.emit("Which checks did the logger use")
        clock.time = 2.5
        speech.emit("Which checksum did the logger use?")
        clock.time = 3.3
        tracker.checkQuestionSilence()
        require(tracker.isQuestionEnding, "an earlier-word correction reset the full silence interval")
        speech.emit("", final: true)
        require(submitted == ["Which checksum did the logger use?"], "automatic submit lost the latest correction")

        tracker.startQuestion { submitted.append($0) }
        speech.level(0.1, at: clock.time)
        speech.emit("How does it work")
        clock.time += 2.3
        speech.emit("How does it work in winter")
        clock.time += 0.6
        tracker.checkQuestionSilence()
        require(!tracker.isQuestionEnding, "a quietly spoken new phrase did not extend the pause")
        tracker.cancelQuestion()
    }

    @MainActor
    private static func questionRetainsSegmentsAcrossAnApplePartialReset() {
        let speech = TestSpeechInput()
        let clock = TestTime()
        let tracker = CompanionTrackingController(speech: speech, now: { clock.time })
        let context = "Your next point is to standardize how teams work with documents."
        let question = "What does standardize mean here?"
        var submitted: [String] = []
        tracker.startQuestion { submitted.append($0) }
        clock.time = 0.1
        speech.level(0.1, at: clock.time)
        speech.emit(context)
        // Shrink and reissue part of the same phrase without an acoustic break.
        speech.emit("Your next point")
        speech.emit(context)
        require(tracker.questionTranscript == context, "a normal short revision duplicated the first clause")
        clock.time = 2.0
        speech.level(0.1, at: clock.time)
        speech.emit("What")
        require(tracker.questionTranscript == context, "a single new word replaced earlier audible speech")
        clock.time = 2.1
        speech.level(0.1, at: clock.time)
        speech.emit("What does")
        speech.emit(question)
        require(tracker.questionTranscript == context + " " + question, "new partial segment lost the question's first clause")
        speech.emit(context + " " + question)
        require(tracker.questionTranscript == context + " " + question, "a cumulative revision duplicated the retained clause")
        clock.time = 4.9
        tracker.checkQuestionSilence()
        speech.emit("", final: true)
        require(submitted == [context + " " + question], "empty final did not submit the complete question exactly once")

        let chineseContext = "请问为什么全需要建立AI基础"
        let chineseEnding = "工作有什么关系"
        submitted = []
        tracker.startQuestion(localeIdentifier: "zh-CN") { submitted.append($0) }
        clock.time = 5.0
        speech.level(0.1, at: clock.time)
        speech.emit(chineseContext)
        speech.emit("请问为什么")
        speech.emit(chineseContext)
        require(tracker.questionTranscript == chineseContext, "a continuous Chinese correction duplicated the clause")
        clock.time = 7.0
        speech.level(0.1, at: clock.time)
        speech.emit("有")
        require(tracker.questionTranscript == chineseContext, "an ambiguous Chinese partial removed the previous clause")
        speech.emit("有什么")
        speech.emit(chineseEnding)
        speech.emit(chineseContext + "，" + chineseEnding)
        let expected = chineseContext + " " + chineseEnding
        require(tracker.questionTranscript == expected, "a cumulative mixed-language revision lost or duplicated the first clause")
        clock.time = 9.9
        tracker.checkQuestionSilence()
        speech.emit("", final: true)
        require(submitted == [expected], "the mixed-language question did not auto-submit exactly once")
    }

    @MainActor
    private static func typedQuestionAndManualSelectionIgnoreLateRecognition() {
        let speech = TestSpeechInput()
        let tracker = CompanionTrackingController(speech: speech)
        tracker.configure(pages: pages)
        tracker.startFollowing()
        tracker.holdForTypedAnswer()
        require(tracker.phase == .awaitingResume, "typed question did not hold")
        speech.emit(second + " " + third, stream: 0)
        require(tracker.position == location(0, 0), "old voice moved typed-question position")
        tracker.select(pageIndex: 3, sentenceIndex: 1)
        require(tracker.position == location(3, 1) && tracker.phase == .following, "click did not resume immediately")
        speech.emit(first + " " + second + " " + third, stream: 1)
        require(tracker.position == location(3, 1), "old voice pulled the position back")
        tracker.stopFollowing()
    }

    @MainActor
    private static func chineseKeyPointsAndLocalResourceFailureRemainSelectable() {
        let speech = TestSpeechInput()
        let tracker = CompanionTrackingController(speech: speech)
        var text: String?
        tracker.startQuestion(localeIdentifier: "zh-CN") { text = $0 }
        speech.emit("这里的 baseline 怎么测？")
        tracker.submitQuestion()
        require(text == "这里的 baseline 怎么测？" && tracker.position == nil, "standalone bilingual question failed")
        tracker.configure(pages: [CompanionTrackingPage(sentences: ["基线 baseline", "结果 cooling hours", "问"])], mode: .chineseKeyPoints)
        tracker.startFollowing()
        require(!tracker.isListening && tracker.nextSentence == "结果 cooling hours", "key point mode did not show the next point")
        tracker.select(pageIndex: 0, sentenceIndex: 1)
        require(tracker.currentSentence == "结果 cooling hours", "key point click failed")
        require(tracker.nextSentence == "问", "single-character key point disappeared")
        tracker.startQuestion { _ in }
        require(speech.locales.last == "zh-CN", "key point language was ignored")
        speech.emit("识别到的半句")
        speech.fail("Local speech resources are unavailable")
        require(tracker.speechError != nil && !tracker.isListening && tracker.phase == .awaitingResume,
                "a failed recording left the panel in listening mode")
        require(tracker.questionTranscript == "识别到的半句", "speech failure discarded the editable partial question")
        tracker.select(pageIndex: 0, sentenceIndex: 0)
        require(tracker.position == location(0, 0), "speech resource failure blocked manual control")
        tracker.cancelQuestion()
    }

    private static func location(_ page: Int, _ sentence: Int) -> CompanionTrackingPosition {
        CompanionTrackingPosition(pageIndex: page, sentenceIndex: sentence)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
