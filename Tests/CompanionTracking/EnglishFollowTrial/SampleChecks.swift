import Foundation

private struct ControlledSpeech: CompanionCloudSpeech {
    let name = "controlled fixture"
    let sendsWhileListening: Bool
    let expected: Data
    let transcript: String
    let returnsEarly: Bool

    func recognize(_ audio: AsyncStream<CompanionCloudAudio>) -> AsyncThrowingStream<CompanionCloudSpeechEvent, Error> {
        AsyncThrowingStream { events in
            let worker = Task {
                events.yield(.ready)
                if returnsEarly {
                    events.yield(.complete(transcript))
                    events.finish()
                    return
                }
                var delivered = Data()
                for await item in audio {
                    switch item {
                    case .packet(let data):
                        delivered.append(data)
                        if sendsWhileListening && delivered.count == data.count {
                            events.yield(.preview(transcript, atSentenceBoundary: false))
                        }
                    case .finish:
                        guard delivered == expected else {
                            events.finish(throwing: CompanionCloudSpeechError.invalidResponse)
                            return
                        }
                        events.yield(.complete(transcript))
                        events.finish()
                        return
                    }
                }
                events.finish(throwing: CompanionCloudSpeechError.noSpeech)
            }
            events.onTermination = { _ in worker.cancel() }
        }
    }
}

@main
private enum SampleChecks {
    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let clips = try CompanionEnglishFollowSample.load(directory: directory)
        let texts = [
            "Throw away any event we have already handled so it never gets recorded twice.",
            "Do not discard duplicate deliveries before writing the ledger. Keep every event.",
            "If we were to discard duplicate deliveries before writing the ledger, how would the retry counter change?",
            "For the answer, I quoted the line: discard duplicate deliveries before writing the ledger.",
        ]
        precondition(clips.count == texts.count && clips.allSatisfy { $0.durationMs > 4_000 })
        for grouped in [true, false] {
            let bundle = try sampleBundle(from: directory, grouped: grouped)
            let packaged = try CompanionEnglishFollowSample.load(bundle: bundle)
            precondition(packaged.map(\.pcm) == clips.map(\.pcm))
        }
        for (clip, transcript) in zip(clips, texts) {
            let service = ControlledSpeech(sendsWhileListening: false, expected: clip.pcm, transcript: transcript, returnsEarly: false)
            let batch = await CompanionEnglishFollowSample.online(clip, provider: service)
            precondition(batch.passed && batch.error == nil && batch.decisions == (clip.expected.map { [$0] } ?? []))
            precondition(batch.firstCorrectAtMs == nil && batch.wholeRecordingResponseMs != nil)
        }
        let positive = clips[0]
        let streamed = await CompanionEnglishFollowSample.online(positive, provider:
            ControlledSpeech(sendsWhileListening: true, expected: positive.pcm, transcript: texts[0], returnsEarly: false))
        precondition(streamed.passed && streamed.firstCorrectAtMs != nil && streamed.wholeRecordingResponseMs == nil)
        let early = await CompanionEnglishFollowSample.online(positive, provider:
            ControlledSpeech(sendsWhileListening: true, expected: positive.pcm, transcript: texts[0], returnsEarly: true))
        precondition(!early.passed && early.error != nil)

        let asset = directory.appendingPathComponent("strong-paraphrase.wav")
        let wav = try Data(contentsOf: asset)
        do {
            try (wav + Data([0])).write(to: asset)
            do {
                _ = try CompanionEnglishFollowSample.load(directory: directory)
                fatalError("Tampered audio can be loaded")
            } catch CompanionCloudSpeechError.invalidResponse {
                try wav.write(to: asset)
            }
        }
        print("PASS grouped/flat bundles, audio hashes and payloads, matcher, batch/stream timing, premature completion, and tamper refusal")
    }

    private static func sampleBundle(from directory: URL, grouped: Bool) throws -> Bundle {
        let fixtures = ["cases.json", "strong-paraphrase.wav", "negation.wav", "hypothetical.wav", "quoted-in-answer.wav"]
        let name = grouped ? "grouped" : "flat"
        let app = directory.appendingPathComponent(name + ".app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        let destination = grouped ? resources.appendingPathComponent("EnglishFollowSamples") : resources
        let files = FileManager.default
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "local.xpresentext.sample.\(name)", "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        for file in fixtures {
            try files.copyItem(at: directory.appendingPathComponent(file), to: destination.appendingPathComponent(file))
        }
        guard let bundle = Bundle(url: app) else { throw CocoaError(.fileReadCorruptFile) }
        return bundle
    }
}
