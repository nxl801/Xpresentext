import Foundation

struct DeckCueTarget: Codable, Hashable, Sendable {
    let text: String
    let region: DeckRegion
    var bulletItems: [String]?
    var itemNumber: Int?

    /// Use surrounding speech to disambiguate repeated shapes. An ordinal also
    /// has to agree with visual order among same-sized peers in a row or column.
    static func resolve(_ cue: String, context: String, among targets: [Self]) -> DeckRegion? {
        let words = { (s: String) in
            s.lowercased().split { !$0.isNumber && !$0.isLetter }.map(String.init)
        }
        let ignored = Set("the a an is are it to with of and for at in this that point box first second third fourth text bullet item".split(separator: " ").map(String.init))
        let quoted = cue.range(of: #"[\"“「][^\"”」]+[\"”」]"#, options: .regularExpression)
        if let quoted {
            let label = String(cue[quoted].dropFirst().dropLast()).lowercased()
            let matches = targets.filter { $0.bulletItems == nil && $0.text.lowercased().contains(label) }
            return matches.count == 1 ? matches[0].region : nil
        }
        let ordinals = ["first", "second", "third", "fourth", "fifth"]
        let chinese = ["一", "二", "三", "四", "五"]
        let cueWords = words(cue)
        let ordinal = ordinals.indices.first { i in
            cueWords.contains(ordinals[i]) || cue.contains("第" + chinese[i]) ||
                cue.range(of: "第" + String(i + 1) + "(?![0-9])", options: .regularExpression) != nil
        }
        if let ordinal, cue.range(of: #"bullet|item|point\s*$|个点|項|项|要点"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let nativeLists = targets.filter { $0.bulletItems != nil }
            if !nativeLists.isEmpty {
                let items = targets.filter { $0.itemNumber == ordinal + 1 }
                return nativeLists.count == 1 && items.count == 1 ? items[0].region : nil
            }
            // A separately numbered text object can identify an item directly.
            // A multi-paragraph text box has only one bound, never a bullet bound.
            let numbered = targets.filter {
                !$0.text.contains("\n") && $0.text.range(of: "^\\s*[（(]?" + String(ordinal + 1) + "[.)）、．]\\s*",
                                                       options: .regularExpression) != nil
            }
            if numbered.count == 1 { return numbered[0].region }
        }
        let hints = Set(words(ordinal == nil ? cue : cue + " " + context)).subtracting(ignored)
        let shapes = targets.filter { $0.itemNumber == nil }
        let scored = shapes.compactMap { target -> (Self, Int)? in
            if ordinal != nil && target.text.contains("\n") { return nil }
            let tokens = Set(words(target.text)).subtracting(ignored)
            let common = tokens.intersection(hints).count
            guard common >= 2, 2 * common >= tokens.count else { return nil }
            return (target, common)
        }.sorted { $0.1 > $1.1 }
        guard let (best, score) = scored.first, scored.dropFirst().first?.1 != score else { return nil }
        if let ordinal {
            let b = best.region
            let peers = shapes.filter {
                let r = $0.region
                return abs(r.width - b.width) <= b.width * 0.12 && abs(r.height - b.height) <= b.height * 0.18
            }
            let column = peers.filter { abs($0.region.x - b.x) < b.width * 0.08 }.sorted { $0.region.y < $1.region.y }
            let row = peers.filter { abs($0.region.y - b.y) < b.height * 0.18 }.sorted { $0.region.x < $1.region.x }
            func confirms(_ group: [Self], horizontal: Bool) -> Bool {
                guard group.count >= 2, group.indices.contains(ordinal), group[ordinal] == best else { return false }
                return zip(group, group.dropFirst()).allSatisfy { a, b in
                    horizontal ? a.region.x + a.region.width <= b.region.x + 0.002 :
                                 a.region.y + a.region.height <= b.region.y + 0.002
                }
            }
            guard (column.count == 1 && confirms(row, horizontal: true)) ||
                  (row.count == 1 && confirms(column, horizontal: false)) else { return nil }
        }
        return best.region
    }
}
