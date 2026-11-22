import Foundation

@main
struct GLMLiveTrial {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            let detail = (error as? TestFailure)?.description ?? error.localizedDescription
            FileHandle.standardError.write(Data((detail + "\n").utf8))
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--verify"] {
            try await GLMTransportTests.run()
            return
        }

        guard (4...5).contains(arguments.count), arguments[0] == "--live",
              let provider = StudioModelProvider(rawValue: arguments[1]), provider != .gemini,
              arguments[3] == provider.liveTrialFlag,
              let repetitions = arguments.count == 5 ? Int(arguments[4]) : 2, (1...5).contains(repetitions)
        else {
            FileHandle.standardError.write(Data("""
            Usage: run.sh --verify
                   run.sh --live deepseek|bigmodel|zai OUTPUT_DIR --allow-keychain-access [REPETITIONS]
                   run.sh --live grok-cli OUTPUT_DIR --use-cli [REPETITIONS]
            The live test uses only project-authored fixtures. The explicit keychain option may open a macOS permission prompt.
            \n
            """.utf8))
            exit(2)
        }

        let makeModel = try provider.makeLiveTrialClients()
        let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try await CompanionQATests.liveTrial(
            output: output, modelID: provider.modelID, repetitions: repetitions,
            reportName: provider.evidenceTrialFilename, includeCharts: provider.supportsOnlineImages, makeModel: makeModel
        )
    }
}
