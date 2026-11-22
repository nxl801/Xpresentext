import Foundation

/// Frames complete JSON objects without waiting for a line ending or array close.
struct QAAnswerObjectStream: Sendable {
    private enum Layout {
        case start, objects, firstArrayItem, nextArrayItem, afterArrayItem, arrayClosed
    }

    private enum Fence {
        case none, opening, open, firstCloseTick, secondCloseTick, closed
    }

    private var layout = Layout.start
    private var fence = Fence.none
    private var header: [UInt8] = []
    private var object = Data()
    private var braceDepth = 0
    private var inString = false
    private var escaped = false

    mutating func append(_ chunk: String, onObject: (Data) throws -> Void) throws {
        for byte in chunk.utf8 {
            if braceDepth > 0 {
                if let complete = appendToObject(byte) { try onObject(complete) }
            } else if try !consumeMarkup(byte) {
                try beginObjectOrArray(byte)
            }
        }
    }

    func finish() throws {
        guard braceDepth == 0, layout == .objects || layout == .arrayClosed,
              fence == .none || fence == .closed
        else { throw QAServiceError.invalidResponse }
    }

    private mutating func appendToObject(_ byte: UInt8) -> Data? {
        object.append(byte)
        if escaped {
            escaped = false
        } else if inString && byte == UInt8(ascii: "\\") {
            escaped = true
        } else if byte == UInt8(ascii: "\"") {
            inString.toggle()
        } else if !inString {
            if byte == UInt8(ascii: "{") { braceDepth += 1 }
            if byte == UInt8(ascii: "}") { braceDepth -= 1 }
        }
        guard braceDepth == 0 else { return nil }
        let complete = object
        object = Data()
        return complete
    }

    private mutating func consumeMarkup(_ byte: UInt8) throws -> Bool {
        let tick = UInt8(ascii: "`")
        switch fence {
        case .opening:
            if byte == UInt8(ascii: "\n") {
                let line = String(decoding: header, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard ["```", "```json", "```jsonl", "```ndjson"].contains(line)
                else { throw QAServiceError.invalidResponse }
                fence = .open
            } else {
                guard header.count < 20 else { throw QAServiceError.invalidResponse }
                header.append(byte)
            }
            return true
        case .firstCloseTick, .secondCloseTick:
            guard byte == tick else { throw QAServiceError.invalidResponse }
            fence = fence == .firstCloseTick ? .secondCloseTick : .closed
            return true
        case .none, .open, .closed:
            break
        }

        switch byte {
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"):
            return true
        default:
            break
        }
        guard fence != .closed else { throw QAServiceError.invalidResponse }
        guard byte == tick else { return false }
        if fence == .none && layout == .start {
            header = [tick]
            fence = .opening
        } else if fence == .open && (layout == .objects || layout == .arrayClosed) {
            fence = .firstCloseTick
        } else {
            throw QAServiceError.invalidResponse
        }
        return true
    }

    private mutating func beginObjectOrArray(_ byte: UInt8) throws {
        switch (layout, byte) {
        case (.start, UInt8(ascii: "[")):
            layout = .firstArrayItem
            return
        case (.firstArrayItem, UInt8(ascii: "]")), (.afterArrayItem, UInt8(ascii: "]")):
            layout = .arrayClosed
            return
        case (.afterArrayItem, UInt8(ascii: ",")):
            layout = .nextArrayItem
            return
        case (.start, UInt8(ascii: "{")), (.objects, UInt8(ascii: "{")):
            layout = .objects
        case (.firstArrayItem, UInt8(ascii: "{")), (.nextArrayItem, UInt8(ascii: "{")):
            layout = .afterArrayItem
        default:
            throw QAServiceError.invalidResponse
        }
        object.append(byte)
        braceDepth = 1
    }
}
