import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

/// Returns only values actually present in the request, so a stale index cannot pass by coincidence.
private struct ChartReplay: QAModel {
    func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { output in
            do {
                switch request.purpose {
                case .draft:
                    output.yield("The chart shows pilot adoption. [Point to the chart]")
                case .answer:
                    struct Input: Decodable {
                        struct Row: Decodable { let id: String; let text: String }
                        let evidence: [Row]
                        let presentationAttached: Bool
                    }
                    let input = try JSONDecoder().decode(Input.self, from: Data(request.input.utf8))
                    if !input.presentationAttached {
                        output.yield(#"{"part":"short","kind":"supplemental","text":"Start with the main point.","sources":[]}"#)
                        output.finish()
                        return
                    }
                    guard let row = input.evidence.first(where: { $0.text.contains("North | Pilot |") }),
                          let percent = ["29%", "37%"].first(where: row.text.contains)
                    else { throw CheckFailure(description: "Question service did not receive the current chart") }
                    let line: [String: Any] = [
                        "part": "short", "kind": "grounded",
                        "text": "North pilot adoption reached \(percent).",
                        "sources": [["id": row.id, "quote": "North | Pilot | \(percent)"]]
                    ]
                    let bytes = try JSONSerialization.data(withJSONObject: line)
                    output.yield(String(decoding: bytes, as: UTF8.self))
                default:
                    throw CheckFailure(description: "Unexpected remote operation while online images are disabled")
                }
                output.finish()
            } catch { output.finish(throwing: error) }
        }
    }
}

@MainActor
private final class MeetingReplay: CompanionSpeechInput {
    var deliver: (@MainActor (CompanionSpeechEvent) -> Void)?
    func start(localeIdentifier: String, reportLevel: Bool, onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void) {
        deliver = onEvent
        onEvent(.started)
    }
    func finish() {}
    func cancel() {}
}

@main
@MainActor
struct WorkspaceAcceptance {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 5, args[1] == "--local-voice" {
            try await VoiceWorkspaceAcceptance.run(ppt: URL(fileURLWithPath: args[2]), manifest: URL(fileURLWithPath: args[3]), scratch: URL(fileURLWithPath: args[4]))
            return
        }
        guard args.count == 3 else { throw CheckFailure(description: "Expected fixture directory and temporary storage") }
        let fixtures = URL(fileURLWithPath: args[1])
        let storage = URL(fileURLWithPath: args[2])
        let store = DeckStore(rootURL: storage.appendingPathComponent("Library"))
        let ws = StudioWorkspace(store: store, model: ChartReplay(), chartCacheDirectory: storage.appendingPathComponent("Charts"))
        func ready(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            while !predicate() {
                guard ContinuousClock.now < deadline else {
                    throw CheckFailure(description: "Timed out. \(ws.notification ?? "") \(ws.chartStatus ?? "")")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        func open(_ name: String, replacing: Bool = false) async throws {
            ws.openURL(fixtures.appendingPathComponent(name), replacing: replacing)
            try await ready { ws.importing == nil && !ws.preparingCharts }
            try check(ws.notification == nil && ws.project?.activeRevision.sourceName == name, "Failed to open \(name): \(ws.notification ?? "")")
        }
        func askNorth(page: Int, number: String) async throws {
            let position = ws.tracking.position
            ws.submitQuestion("What was the North pilot adoption percentage?", followUp: false)
            try await ready { ws.questions.state != .answering }
            let answer = ws.questions.answer
            try check(ws.questions.state == .completed && answer.shortAnswer?.contains(number) == true,
                      "Expected \(number), received \(answer.shortAnswer ?? String(describing: ws.questions.state))")
            try check(answer.shortAnswerPoint?.citations.first?.pageNumber == page &&
                      answer.shortAnswerPoint?.citations.first?.kind == .chart &&
                      answer.shortAnswerPoint?.citations.first?.region != nil, "Wrong chart or page reference")
            try check(ws.tracking.position == position && ws.tracking.phase == .awaitingResume, "Reading position changed during Q&A")
        }

        try await open("original.pptx")
        guard let original = ws.project else { throw CheckFailure(description: "Missing project") }
        try check(ws.slides.count == 10 && ws.slides.allSatisfy { $0.image != nil } && ws.pageIndex == 0, "Thumbnails or slide order missing")
        ws.tracking.select(pageIndex: 7)
        ws.generateDraft()
        try await ready { ws.generatingPage == nil }
        try check(ws.currentSlide?.script.origin == .ai && ws.currentSlide?.script.aiConfirmed == false, "New draft lost provenance")
        ws.editCurrentSlide { $0.script.edit("The chart shows pilot adoption. [Point to North]") }
        ws.updateColors(cue: "#6B31C5", draft: "#1A786C")
        ws.updateAppendix(single: (8, true))
        ws.tracking.select(pageIndex: 2)
        try await askNorth(page: 8, number: "37%")

        let meeting = MeetingReplay()
        let presenter = MurmuryPresenter(makeMeetingInput: { meeting })
        var displayed: [String: Any] = [:]
        presenter.bind(ws) { displayed = $0 }
        presenter.receive(["action": "ready"])
        let oldContext = displayed["context"] as? String ?? ""
        let anchor = ws.tracking.position
        presenter.receive(["action": "ask", "context": oldContext, "text": "What was North pilot adoption?", "follow": true])
        try await ready { displayed["short"] as? String == "North pilot adoption reached 37%." && ws.questions.state == .completed }
        let labels = (displayed["sources"] as? [[String: String]] ?? []).compactMap { $0["label"] }
        try check(!oldContext.isEmpty && labels.contains(where: { $0.contains("第 8 页") }) && ws.tracking.position == anchor,
                  "Murmury did not display the deck source or moved the anchor")
        try check(MurmuryPresenter.isMeetingQuestion("Could you explain the calculation?") &&
                  !MurmuryPresenter.isMeetingQuestion("What we measured was the total.") &&
                  !MurmuryPresenter.isMeetingQuestion("Thanks for the update."), "Meeting question detection")
        presenter.receive(["action": "meeting", "context": oldContext])
        let beforeRemote = ws.questions.question
        meeting.deliver?(.transcript("What we measured was the total.", isFinal: true))
        try check(ws.questions.question == beforeRemote, "A remote statement submitted a question")
        meeting.deliver?(.transcript("Can you explain North", isFinal: false))
        try check(ws.questions.question == beforeRemote && ws.tracking.position == anchor, "A partial triggered an answer or moved the anchor")
        let remote = "Can you explain North pilot adoption?"
        meeting.deliver?(.transcript(remote, isFinal: true))
        try await ready { ws.questions.question == remote && ws.questions.state == .completed }
        presenter.receive(["action": "stop", "context": oldContext])
        meeting.deliver?(.transcript("Could you explain something else?", isFinal: true))
        try check(ws.questions.question == remote && ws.tracking.position == anchor, "A stopped source submitted a question")
        print("PASS meeting source routes a final question once, holds the anchor and drops stale audio")
        print("PASS Murmury host card, active deck chart citation, anchor, and meeting question detection")
        ws.updateAppendix(undo: true)
        try check(ws.tracking.phase == .awaitingResume, "An edit released the Q&A hold")
        ws.updateAppendix(single: (8, true))
        ws.tracking.select(pageIndex: 7)
        ws.editCurrentSlide { $0.script.confirmAI() }
        try check(await ws.flushSave(), "Failed to save preparation")
        print("PASS import, private draft edits, colors, appendix, Q&A hold and citation")

        try await open("reordered.pptx", replacing: true)
        guard let reordered = ws.project else { throw CheckFailure(description: "Missing second version") }
        let moved = ws.slides[9]
        try check(ws.slides.count == 12 && reordered.id == original.id && moved.isAppendix &&
                  moved.script.aiConfirmed && moved.script.text.contains("[Point to North]"), "Moved page lost preparation")
        try check(reordered.cueColorHex == "#6B31C5" && reordered.draftColorHex == "#1A786C", "Colors changed")
        try check(ws.questions.question.isEmpty && ws.questions.answer.citations.isEmpty, "Old answer crossed into next revision")
        presenter.receive(["action": "ask", "context": oldContext, "text": "Stale question"])
        try check(ws.questions.question.isEmpty, "Late Murmury question crossed deck revision")
        presenter.close()
        print("PASS Murmury late action dropped after revision")
        ws.tracking.select(pageIndex: 11)
        try await askNorth(page: 10, number: "37%")
        print("PASS old page 8 became page 10; new source and preserved edits")

        try await open("changed.pptx", replacing: true)
        try check(ws.project?.activeRevision.revisionReviews.isEmpty == false && ws.slides[9].script.isEmpty, "Changed chart silently inherited old preparation")
        try await askNorth(page: 10, number: "29%")
        ws.chooseRevision(original.activeRevisionID)
        try await ready { !ws.preparingCharts }
        try await askNorth(page: 8, number: "37%")
        try check(await ws.flushSave(), "Failed to persist selected version")
        let disk = try await store.openProject(id: original.id)
        try check(disk.activeRevisionID == original.activeRevisionID && disk.revisions.count == 3 &&
                  disk.activeRevision.slides[7].script.aiConfirmed && disk.activeRevision.slides[7].isAppendix,
                  "Reopened library lost version, draft provenance or appendix")
        print("PASS changed chart reports 29%, original still reports 37%, disk reopen preserves all three versions")

        let repairStore = DeckStore(rootURL: storage.appendingPathComponent("Missing Images"), officeURL: nil)
        let repairWorkspace = StudioWorkspace(store: repairStore, model: ChartReplay(),
                                               chartCacheDirectory: storage.appendingPathComponent("Repair Charts"))
        let repairSource = fixtures.appendingPathComponent("no-notes.pptx")
        repairWorkspace.openURL(repairSource)
        try await ready { repairWorkspace.project != nil && repairWorkspace.importing == nil }
        guard let missing = repairWorkspace.project, missing.activeRevision.needsImageRepair else {
            throw CheckFailure(description: "Missing images did not expose repair")
        }
        repairWorkspace.tracking.select(pageIndex: 1)
        repairWorkspace.editCurrentSlide { $0.script.edit("This prepared line survives PDF repair.") }
        let renderer = DeckRenderer(officeURL: DeckRenderer.installedOffice())
        let pdf = try await renderer.convertToPDF(from: repairSource, workDirectory: storage.appendingPathComponent("PDF Export"))
        await repairWorkspace.repairCurrentImages(from: pdf)
        try check(repairWorkspace.project?.activeRevisionID == missing.activeRevisionID &&
                  repairWorkspace.project?.activeRevision.needsImageRepair == false &&
                  repairWorkspace.currentSlide?.script.text == "This prepared line survives PDF repair." &&
                  repairWorkspace.pageIndex == 1, "Workspace PDF repair lost the current version, page or draft")
        print("PASS same-version PDF repair through workspace preserves the current slide and prepared line")

        ws.closeProject()
        try check(ws.project == nil && ws.tracking.position == nil && ws.questions.answer.citations.isEmpty,
                  "Closing the presentation retained its context")
        ws.submitQuestion("How should I begin?", followUp: false)
        try await ready { ws.questions.state != .answering }
        try check(ws.questions.answer.shortAnswer == "Start with the main point." && ws.questions.answer.citations.isEmpty,
                  "Standalone questions still used the closed presentation")
        print("PASS close presentation and answer a standalone question without slide citations")

        let legacy = storage.appendingPathComponent("legacy.textream")
        let lines = ["A previously saved script.", "[Pause] Continue."]
        try JSONEncoder().encode(lines).write(to: legacy)
        ws.openURL(legacy)
        try check(ws.classic && TextreamService.shared.pages == lines && TextreamService.shared.currentFileURL == legacy,
                  "Opening an existing Textream file did not restore the classic prompter")
        print("PASS existing .textream script opens in the classic prompter")

        if ProcessInfo.processInfo.environment["COMPANION_OFFLINE_CHECK"] == "1" {
            let offline = StudioWorkspace(store: store, model: GeminiQAModel(apiKey: "offline-fixture"),
                                          chartCacheDirectory: storage.appendingPathComponent("Charts"))
            offline.openProject(original)
            try await ready { offline.project?.id == original.id && !offline.preparingCharts }
            offline.submitQuestion("What was the North pilot adoption percentage?", followUp: false)
            try await ready { offline.questions.state != .answering }
            try check(offline.questions.state == .failed(.transport) || offline.questions.state == .failed(.timeout),
                      "Expected an offline error, got \(offline.questions.state)")
            offline.tracking.select(pageIndex: 4, sentenceIndex: 0)
            try check(offline.pageIndex == 4 && offline.currentSlide?.image != nil && offline.tracking.currentSentence != nil,
                      "An offline answer failure blocked access to script, image or manual selection")
            print("PASS outbound IP denied: actual cloud transport failed and the local slide, script and manual anchor remained usable")
        }
    }
}
