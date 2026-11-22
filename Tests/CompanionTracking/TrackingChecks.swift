import AVFoundation
import Foundation

@MainActor
private final class TestSpeechInput: CompanionSpeechInput {
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
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 3, arguments[0] == "--questions" {
            try replayQuestions(manifest: URL(fileURLWithPath: arguments[1]), audio: URL(fileURLWithPath: arguments[2]))
            return
        }
        wordProgressAndPointingCues()
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
