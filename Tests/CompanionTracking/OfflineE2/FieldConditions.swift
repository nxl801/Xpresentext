import CoreAudio
import Foundation
import Network

/// Observe the Mac's default network and audio routes without changing them.
@MainActor
final class FieldConditions {
    private struct AudioRoute: Codable, Equatable {
        let id: UInt32
        let transport: String

        var isPhysical: Bool {
            ["bltn", "usb ", "1394", "blue", "blea", "pci ", "thun", "hdmi", "dprt"].contains(transport)
        }

        init(_ selector: AudioObjectPropertySelector) {
            id = Self.property(AudioObjectID(kAudioObjectSystemObject), selector)
            let code = Self.property(id, kAudioDevicePropertyTransportType)
            transport = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) },
                               encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) ?? ""
        }

        private static func property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
            guard object != kAudioObjectUnknown else { return 0 }
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout.size(ofValue: value))
            let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
            return status == noErr ? value : 0
        }
    }

    private struct Observation: Encodable {
        let date: Date
        let network: String
        let input: AudioRoute
        let output: AudioRoute
    }

    private let monitor = NWPathMonitor()
    private var observedStatus: NWPath.Status?
    private var observations: [Observation] = []
    private var polling: Task<Void, Never>?
    private var directory: URL?
    private var finished = false
    private var failureReason: String?

    func start(in directory: URL) async throws {
        self.directory = directory
        monitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            Task { @MainActor in
                guard let self, !self.finished else { return }
                self.observedStatus = status
                self.observe(status)
            }
        }
        monitor.start(queue: DispatchQueue(label: "textream.field.network"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while observedStatus == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if observedStatus == nil { reject("未能确认此 Mac 的网络状态。") }
        do {
            try check()
        } catch {
            stop()
            throw error
        }
        guard let initial = observations.first, initial.network == "unsatisfied",
              initial.input.isPhysical, initial.output.isPhysical else {
            stop()
            throw NSError(domain: "Textream.Field", code: 2, userInfo: [NSLocalizedDescriptionKey: "未能确认现场断网和物理音频设备。"])
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, let status = self.observedStatus else { return }
                self.observe(status)
            }
        }
    }

    func check() throws {
        // Audio routes are checked by the monitor timer. The 25 ms alignment
        // sampling loop only needs to catch a new network state or a failure.
        if let observedStatus, monitor.currentPath.status != observedStatus {
            observe(monitor.currentPath.status)
        }
        if let reason = failureReason {
            throw NSError(domain: "Textream.Field", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    func stop() {
        if !finished, let status = observedStatus { observe(status, final: true) }
        finished = true
        polling?.cancel()
        monitor.cancel()
    }

    private func observe(_ status: NWPath.Status, final: Bool = false) {
        guard let directory else { return }
        let entry = Observation(date: Date(), network: String(describing: status),
                                input: AudioRoute(kAudioHardwarePropertyDefaultInputDevice),
                                output: AudioRoute(kAudioHardwarePropertyDefaultOutputDevice))
        if !final, let last = observations.last, last.network == entry.network,
           last.input == entry.input, last.output == entry.output { return }
        observations.append(entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(observations).write(to: directory.appendingPathComponent("conditions.json"), options: .atomic)
        } catch {
            reject("无法保存网络和音频设备实测记录。")
            return
        }
        if status != .unsatisfied {
            reject("Mac 仍有可用网络连接。现场断网测试尚未满足条件。")
        } else if !entry.input.isPhysical || !entry.output.isPhysical {
            reject("请为此项声学测试选择物理麦克风和可外放的扬声器。")
        } else if let first = observations.first, first.input != entry.input || first.output != entry.output {
            reject("测试期间默认音频设备有变化，请用同一对设备复测。")
        }
    }

    private func reject(_ reason: String) {
        if failureReason == nil { failureReason = reason }
        guard let directory else { return }
        let abort = directory.appendingPathComponent("abort")
        if !FileManager.default.fileExists(atPath: abort.path) {
            try? reason.write(to: abort, atomically: true, encoding: .utf8)
        }
    }
}
