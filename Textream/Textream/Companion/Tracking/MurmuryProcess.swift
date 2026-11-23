import Foundation
import Darwin

/// One local helper with ordered JSON lines. No port, document upload or credential exchange.
@MainActor
final class MurmuryProcess {
    private static var executable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MurmuryPresenter.app/Contents/MacOS/MurmuryPresenter")
    }
    static var isInstalled: Bool {
        #if arch(arm64)
        return FileManager.default.isExecutableFile(atPath: executable.path)
        #else
        return false
        #endif
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writer = DispatchQueue(label: "studio.murmury.input")
    private var reader: Task<Void, Never>?
    private(set) var stopped = false

    init(script: String, arguments: [String] = [], executable: URL? = nil, receive: @escaping @MainActor ([String: Any]) -> Void,
         closed: @escaping @MainActor (Int32) -> Void) throws {
        let url = executable ?? Self.executable
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        process.executableURL = url
        process.arguments = [script] + arguments
        let allowed = ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
                       "https_proxy", "http_proxy", "all_proxy", "no_proxy", "QT_QPA_PLATFORM"]
        var env = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
        process.environment = env
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let handle = output.fileHandleForReading
        // AsyncBytes can wait for a large read on an open pipe. Each flushed JSON line must
        // reach the UI immediately, even when the other helper is idle for an entire talk.
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        DispatchQueue.global(qos: .userInitiated).async {
            var pending = Data()
            var bytes = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                pending.append(contentsOf: bytes.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                    continuation.yield(Data(pending[..<newline]))
                    pending.removeSubrange(...newline)
                }
            }
            continuation.finish()
        }
        reader = Task { [weak self, process] in
            for await line in lines {
                guard self?.stopped == false else { return }
                if let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    receive(event)
                }
            }
            guard let self, !self.stopped else { return }
            await Task.detached { process.waitUntilExit() }.value
            guard !self.stopped else { return }
            closed(process.terminationStatus)
        }
    }

    func send(_ message: [String: Any]) {
        guard !stopped, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(10)
        let bytes = data, handle = input.fileHandleForWriting
        writer.async { try? handle.write(contentsOf: bytes) }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        reader?.cancel()
        reader = nil
        let handle = input.fileHandleForWriting
        writer.async { try? handle.close() }
        if process.isRunning { process.terminate() }
    }
}
