import Foundation

/// Keep the overlay open while Whisper streams a prepared WAV through a second, independent pipe.
@main @MainActor struct PipeSmoke {
    static func main() async throws {
        var panelReady = false, decoded = "", failed = false
        let panel = try MurmuryProcess(script: "panel", receive: { event in
            panelReady = event["action"] as? String == "ready"
        }, closed: { _ in failed = true })
        defer { panel.stop() }
        let timeout = ContinuousClock.now.advanced(by: .seconds(45))
        while !panelReady && !failed && ContinuousClock.now < timeout { try await Task.sleep(for: .milliseconds(30)) }
        guard panelReady && !failed else { throw CocoaError(.executableLoad) }
        panel.send(["type": "state", "context": "pilot", "question": "North?", "short": "North reached 37%.",
                    "title":"Pilot", "status":"完成"])
        let speech = try MurmuryProcess(script: "speech", arguments: ["wav", "en-US", CommandLine.arguments[1]],
           receive: { event in
               if event["final"] as? Bool == true { decoded += " " + (event["text"] as? String ?? "") }
               if event["type"] as? String == "error" { failed = true }
           }, closed: { status in if status != 0 { failed = true } })
        defer { speech.stop() }
        while decoded.isEmpty && !failed && ContinuousClock.now < timeout { try await Task.sleep(for: .milliseconds(30)) }
        guard !failed && decoded.lowercased().contains("event") else { throw CocoaError(.fileReadCorruptFile) }
        print("PASS signed Murmury panel remains open while a second host pipe receives genuine Whisper transcription")
    }
}
