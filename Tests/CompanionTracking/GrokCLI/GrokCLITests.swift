import Darwin
import Foundation

private struct FixtureFailure: LocalizedError {
    let errorDescription: String?
    init(_ detail: String) { errorDescription = detail }
}

@main
@MainActor
struct GrokCLITests {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--live-synthetic"] {
                try await realSynthetic()
            } else {
                guard arguments.count == 1 else { throw FixtureFailure("Fixture executable path is required.") }
                try await run(URL(fileURLWithPath: arguments[0]))
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func request(_ text: String) -> QAModelRequest {
        QAModelRequest(purpose: .answer, instructions: "Respond using complete sentences.", input: text, maxOutputTokens: 80)
    }

    private static func run(_ executable: URL) async throws {
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".textream-grok-test-" + UUID().uuidString)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tr-grok-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: marker) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let auth = folder.appendingPathComponent("auth.json")
        FileManager.default.createFile(atPath: auth.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o600])
        let protectedFile = marker.appendingPathComponent("protected")
        try Data("controlled host marker".utf8).write(to: protectedFile)
        setenv("TEXTREAM_GROK_FIXTURE_SECRET", "unrelated synthetic value", 1)
        defer { unsetenv("TEXTREAM_GROK_FIXTURE_SECRET") }

        let model = GrokCLIQAModel(testExecutable: executable, authFile: auth, timeout: 4)
        let output = try await model.complete(request("exclusively-in-stdin-1db5"))
        try expect(output == "The answer is complete.", "Text deltas were duplicated or thinking leaked.")
        let snapshot = try await model.complete(request("result-only fixture"))
        try expect(snapshot == "The final result supplies the answer.", "Result-only output was ignored.")
        let lingerStarted = ContinuousClock.now
        let lingered = try await model.complete(request("result-then-linger fixture"))
        try expect(lingerStarted.duration(to: .now) < .seconds(2), "Waiting for process exit delayed a successful result.")
        guard let lingerPID = Int32(lingered) else { throw FixtureFailure("The successful fixture did not report its PID.") }
        try await expectStopped(lingerPID)
        let isolation = try await model.complete(request("isolation-fixture:" + protectedFile.path))
        try expect(isolation == "The process isolation succeeded.", "Profile allowed host file access or subprocess creation.")

        let missing = GrokCLIQAModel(testExecutable: folder.appendingPathComponent("absent"), authFile: auth, timeout: 1)
        try await rejects(missing, request(""), .missingGrokCLI)
        let noAuth = GrokCLIQAModel(testExecutable: executable, authFile: folder.appendingPathComponent("absent"), timeout: 1)
        try await rejects(noAuth, request(""), .missingGrokLogin)
        try await rejects(model, request("missing sign-in fixture"), .missingGrokLogin)
        try await rejects(model, request("rate-limit fixture"), .httpStatus(429))
        try await rejects(model, request("unapproved model fixture"), .grokCLIIsolationUnavailable)
        try await rejects(model, request("enabled tool fixture"), .grokCLIIsolationUnavailable)
        try await rejects(model, request("unsupported tool output fixture"), .grokCLIIsolationUnavailable)
        try await rejects(model, request("malformed fixture"), .invalidResponse)
        let chart = QAModelRequest(purpose: .chart, instructions: "", input: "", maxOutputTokens: 40)
        try await rejects(model, chart, .grokCLIImagesUnsupported)

        let session = CompanionQASession(service: CompanionQAService(model: model), timeout: .seconds(4))
        session.submit("standalone early sentence fixture")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.answer.shortAnswer == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(session.answer.shortAnswer == "This short answer appears before the process ends." && session.state == .answering,
                   "A split first sentence did not appear while the process was running.")
        session.cancel()
        try await verifyStopped(model, timeLimited: false)
        let short = GrokCLIQAModel(testExecutable: executable, authFile: auth, timeout: 0.35)
        try await verifyStopped(short, timeLimited: true)
        print("PASS Grok CLI native fixture: stdin, independent instructions, no extra environment, host isolation, first sentence, results, errors, timeout and cancellation")
    }

    private static func verifyStopped(_ model: GrokCLIQAModel, timeLimited: Bool) async throws {
        var pid: Int32?
        let reader = Task {
            do {
                for try await chunk in model.stream(request("hold fixture")) {
                    if let child = Int32(chunk.trimmingCharacters(in: .whitespacesAndNewlines)) { pid = child }
                }
                return nil as QAServiceError?
            } catch {
                return error as? QAServiceError
            }
        }
        let seen = ContinuousClock.now.advanced(by: .seconds(2))
        while pid == nil && ContinuousClock.now < seen { try await Task.sleep(for: .milliseconds(10)) }
        guard let pid else {
            reader.cancel()
            throw FixtureFailure("Fixture process ID was not observed.")
        }
        if !timeLimited { reader.cancel() }
        let error = await reader.value
        if timeLimited { try expect(error == .timeout, "Timeout was not surfaced.") }
        try await expectStopped(pid)
    }

    private static func expectStopped(_ pid: Int32) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while kill(pid, 0) == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        try expect(kill(pid, 0) != 0 && errno == ESRCH, "The cancelled fixture process was still running.")
    }

    private static func realSynthetic() async throws {
        let pages = [QAPage(index: 0, title: "Orchid trial", bodyText: "Orchid coverage reached 83%.", originalNotes: "")]
        let deck = QADeckSnapshot(revisionID: "grok-textream-fixture", pages: pages)
        let session = CompanionQASession(service: CompanionQAService(model: GrokCLIQAModel()))
        session.setDeck(deck)
        let started = ContinuousClock.now
        session.submit("What was Orchid coverage?", currentPageIndex: 0)
        let deadline = started.advanced(by: .seconds(22))
        while session.state == .answering && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if case .failed(let error) = session.state {
            if let elapsed = session.answer.firstSentenceElapsed,
               let point = session.answer.shortAnswerPoint, point.kind == .grounded,
               point.text.contains("83%"), point.citations.map(\.pageNumber) == [1] {
                print("A validated first sentence was visible at \(elapsed) before the session failed.")
            }
            throw error
        }
        guard session.state == .completed, let first = session.answer.shortAnswerPoint,
              first.kind == .grounded, first.text.contains("83%"), first.citations.map(\.pageNumber) == [1] else {
            throw FixtureFailure("The synthetic live answer or its citation did not pass validation.")
        }
        print("PASS authenticated Grok synthetic: \(first.text), cited page 1.")
        print("First usable sentence \(session.answer.firstSentenceElapsed ?? .zero); completed \(started.duration(to: .now)).")
    }

    private static func rejects(_ model: GrokCLIQAModel, _ request: QAModelRequest, _ expected: QAServiceError) async throws {
        do { _ = try await model.complete(request) }
        catch let error as QAServiceError {
            try expect(error == expected, "Expected \(expected), observed \(error).")
            return
        }
        throw FixtureFailure("Expected \(expected) but the request succeeded.")
    }

    private static func expect(_ value: Bool, _ explanation: String) throws {
        if !value { throw FixtureFailure(explanation) }
    }
}
