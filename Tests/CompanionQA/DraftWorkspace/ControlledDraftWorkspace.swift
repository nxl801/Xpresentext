import Foundation

private struct DraftCheck: Error, CustomStringConvertible {
    let description: String
}

private func expectDraft(_ condition: Bool, _ why: String) throws {
    if !condition { throw DraftCheck(description: why) }
}

private actor DeferredDrafts: QAModel {
    private var requests: [QAModelRequest] = []
    private var responses: [AsyncThrowingStream<String, Error>.Continuation] = []

    nonisolated func stream(_ request: QAModelRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { await register(request, continuation: continuation) }
        }
    }

    private func register(
        _ request: QAModelRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        guard request.purpose == .draft, request.image == nil else {
            continuation.finish(throwing: QAServiceError.rejectedConnection)
            return
        }
        requests.append(request)
        responses.append(continuation)
    }

    var count: Int { requests.count }

    func sent(_ index: Int) -> QAModelRequest { requests[index] }

    func resolve(_ index: Int, draft: String? = nil) {
        if let draft {
            responses[index].yield(draft)
            responses[index].finish()
        } else {
            responses[index].finish(throwing: QAServiceError.transport)
        }
    }
}

@MainActor
private final class DraftReplayNoSpeech: CompanionSpeechInput {
    func start(localeIdentifier: String, reportLevel: Bool, onEvent: @escaping @MainActor (CompanionSpeechEvent) -> Void) {
        fatalError("The draft workspace test must not call speech capture")
    }

    func finish() {}
    func cancel() {}
}

@main
@MainActor
struct ControlledDraftWorkspace {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else { throw DraftCheck(description: "Expected fixture and isolated storage directories") }
        let fixtures = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let storage = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let model = DeferredDrafts()
        let store = DeckStore(rootURL: storage.appendingPathComponent("drafts"), officeURL: nil)
        let workspace = StudioWorkspace(
            store: store, model: model, chartCacheDirectory: storage.appendingPathComponent("charts"),
            tracking: CompanionTrackingController(speech: DraftReplayNoSpeech()), modelLabel: "Controlled fixture model"
        )

        func wait(_ label: String, condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while await !condition() {
                if ContinuousClock.now > deadline { throw DraftCheck(description: "Timed out: " + label) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func open(_ file: String) async throws {
            workspace.openURL(fixtures.appendingPathComponent(file))
            try await wait("open " + file) {
                workspace.importing == nil && !workspace.preparingCharts
                    && workspace.project?.activeRevision.sourceName == file
            }
        }

        func start(_ count: Int) async throws {
            workspace.generateDraft()
            try await wait("draft request \(count)") { await model.count == count }
        }

        func done() async throws {
            try await wait("draft request to finish") { workspace.generatingPage == nil }
        }

        let output = "Start with the intended outcomes. [Point at the overview] Then turn to the detail."
        try await open("no-notes.pptx")
        try expectDraft(workspace.slides.count == 3 && workspace.slides.allSatisfy(\.script.isEmpty), "All-empty source did not import cleanly")
        workspace.updateAppendix(single: (3, true))
        workspace.tracking.select(pageIndex: 0)
        try await start(1)
        let first = await model.sent(0)
        try expectDraft(first.input.contains("Initial") && !first.input.contains("Planned outcomes"),
                        "Draft request was not confined to the selected page")
        workspace.tracking.select(pageIndex: 1)
        await model.resolve(0, draft: output)
        try await done()
        try expectDraft(workspace.slides[0].script.text == output && workspace.slides[0].script.origin == .ai
                        && workspace.slides[0].script.aiSource?.pageNumber == 1 && workspace.pageIndex == 1,
                        "Late draft did not land on the requested page or changed the current page")
        try expectDraft(workspace.slides[1].script.isEmpty && workspace.slides[2].script.isEmpty && workspace.slides[2].isAppendix,
                        "All-empty import wrote to an unselected body page or the appendix")
        workspace.tracking.select(pageIndex: 2)
        workspace.generateDraft()
        try expectDraft(workspace.generatingPage == nil, "The appendix accepted a generation request")
        try expectDraft(await workspace.flushSave(), "Could not save the first controlled project")
        print("PASS all-empty PPT: generated only selected page, even after changing current page; appendix skipped")

        try await open("notes.pptx")
        guard let current = workspace.project,
              let gap = workspace.slides.firstIndex(where: { $0.script.isEmpty && !$0.isAppendix }),
              let authored = workspace.slides.firstIndex(where: { !$0.originalNotes.isEmpty })
        else { throw DraftCheck(description: "Mixed-notes fixture lacks a blank and a note page") }
        let original = workspace.slides.map(\.originalNotes)
        let notes = workspace.slides.map(\.script)
        workspace.tracking.select(pageIndex: authored)
        workspace.generateDraft()
        try expectDraft(workspace.generatingPage == nil, "An existing note was sent for regeneration")
        workspace.tracking.select(pageIndex: gap)
        try await start(2)
        await model.resolve(1)
        try await done()
        try expectDraft(workspace.slides[gap].script.isEmpty && workspace.notification == QAServiceError.transport.localizedDescription,
                        "A model failure changed the blank page or hid the error")

        try await start(3)
        let personal = "This is my hand-edited line."
        workspace.editCurrentSlide { $0.script.edit(personal) }
        await model.resolve(2, draft: output)
        try await done()
        try expectDraft(workspace.slides[gap].script.text == personal && workspace.slides[gap].script.origin == .speaker,
                        "The late model result replaced a manual edit")
        workspace.generateDraft()
        try expectDraft(workspace.generatingPage == nil, "A manual script could be regenerated over")

        workspace.editCurrentSlide { $0.script.edit("") }
        try await start(4)
        workspace.updateAppendix(single: (gap + 1, true))
        await model.resolve(3, draft: output)
        try await done()
        try expectDraft(workspace.slides[gap].isAppendix && workspace.slides[gap].script.isEmpty,
                        "A draft was saved to a page moved to the appendix mid-request")
        workspace.updateAppendix(single: (gap + 1, false))
        print("PASS failure, retry, late response after manual edit, and marking an in-flight page as appendix")

        try await start(5)
        workspace.editCurrentSlide { $0.script.edit("A temporary manual line.") }
        workspace.editCurrentSlide { $0.script.edit("") }
        await model.resolve(4, draft: output)
        try await done()
        try expectDraft(workspace.slides[gap].script.isEmpty,
                        "The late result refilled a blank the speaker had deliberately restored")

        try await start(6)
        await model.resolve(5, draft: output)
        try await done()
        guard let source = workspace.slides[gap].script.aiSource else { throw DraftCheck(description: "Retry did not produce a sourced draft") }
        try expectDraft(workspace.notification == nil, "A successful retry retained the previous failure message")
        try expectDraft(source.revisionID == current.activeRevisionID && source.pageNumber == gap + 1
                        && source.evidenceIDs.contains(workspace.slides[gap].id)
                        && source.provider == "Controlled fixture model"
                        && !workspace.slides[gap].script.aiConfirmed,
                        "Retry lost original page/version evidence or changed the confirmation state")

        let edited = "Here is the point to remember. [Point at the overview] Continue with the next idea."
        workspace.editCurrentSlide { $0.script.edit(edited) }
        workspace.updateColors(cue: "#7040B8", draft: "#1A7968")
        try expectDraft(await workspace.flushSave(), "Could not save the edited draft")
        let saved = try await store.openProject(id: current.id)
        workspace.closeProject()
        try expectDraft(workspace.project == nil, "The fixture workspace did not close before reopening")
        workspace.openProject(saved)
        try await wait("reopen unconfirmed draft") { workspace.project?.id == current.id && !workspace.saving && !workspace.preparingCharts }
        let savedSlide = workspace.slides[gap]
        try expectDraft(savedSlide.script.text == edited && savedSlide.script.origin == .ai
                        && savedSlide.script.aiSource == source && !savedSlide.script.aiConfirmed
                        && workspace.project?.cueColorHex == "#7040B8" && workspace.project?.draftColorHex == "#1A7968",
                        "Reopening changed the draft, its provenance, or the cue/draft colors")
        workspace.tracking.select(pageIndex: gap)
        workspace.editCurrentSlide { $0.script.confirmAI() }
        try expectDraft(await workspace.flushSave(), "Could not persist the explicit draft confirmation")
        let reopened = try await store.openProject(id: current.id)
        let confirmed = reopened.activeRevision.slides[gap]
        try expectDraft(confirmed.script.aiConfirmed && confirmed.script.aiSource == source && confirmed.script.text == edited
                        && confirmed.script.text.contains("[Point at the overview]"), "Confirmed draft lost its source or cue")
        try expectDraft(reopened.activeRevision.slides.map(\.originalNotes) == original
                        && reopened.activeRevision.slides.enumerated().allSatisfy { $0.offset == gap || $0.element.script == notes[$0.offset] },
                        "Generation or retry changed another page's original notes or key points")
        try expectDraft(await model.count == 6, "Protected pages triggered unexpected model calls")
        print("PASS partial PPT: preserved original notes/key points, intentional empty edit, independent colors, adopted draft provenance")
    }
}
