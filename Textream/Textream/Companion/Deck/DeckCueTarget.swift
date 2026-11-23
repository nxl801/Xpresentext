import Foundation

struct DeckCueTarget: Codable, Hashable, Sendable {
    let text: String
    let region: DeckRegion
    var bulletItems: [String]?
    var itemNumber: Int?
    var isSlideTitle: Bool?

    static func regions(for cue: String, context: String, nearbyText: String, title: String, among targets: [Self]) -> [DeckRegion] {
        let shapes = targets.filter { $0.itemNumber == nil }
        func phrase(_ text: String) -> String {
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        }
        let spoken = " " + phrase(nearbyText) + " "
        if cue.range(of: #"["“「]"#, options: .regularExpression) != nil {
            return resolve(cue, context: context, among: targets).map { [$0] } ?? []
        }
        let command = phrase(cue)
        let subject = command.replacingOccurrences(of: #"^(?:point|gesture|look)(?: to| at)?(?: the)? |^(?:指向|请看|指着)"#,
                                                    with: "", options: .regularExpression)
        // A direction on its own refers to a part of the slide. A named object
        // such as "the left chart" still needs object evidence or a manual frame.
        switch subject {
        case "left", "左侧", "左边": return [DeckRegion(x: 0.015, y: 0.015, width: 0.48, height: 0.97)]
        case "right", "右侧", "右边": return [DeckRegion(x: 0.505, y: 0.015, width: 0.48, height: 0.97)]
        case "middle", "中部": return [DeckRegion(x: 0.015, y: 0.34, width: 0.97, height: 0.32)]
        case "bottom", "底部": return [DeckRegion(x: 0.015, y: 0.67, width: 0.97, height: 0.315)]
        case "top", "顶部": return [DeckRegion(x: 0.015, y: 0.015, width: 0.97, height: 0.315)]
        default: break
        }
        if Int(subject) != nil {
            let numbered = shapes.filter { phrase($0.text) == subject }
            return numbered.count == 1 ? [numbered[0].region] : []
        }
        if cue.range(of: #"\b(headline|title)\b|标题|標題"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let titles = shapes.filter { $0.isSlideTitle == true || phrase($0.text) == phrase(title) }
            guard titles.count == 1, let heading = titles.first else { return [] }
            let r = heading.region
            // Some decks draw a single headline as two consecutive text boxes.
            let continuation = shapes.filter { candidate in
                let c = candidate.region, gap = c.y - (r.y + r.height)
                return abs(c.x - r.x) < 0.012 && abs(c.height - r.height) < 0.25 * r.height
                    && gap >= -0.004 && gap < r.height * 0.4
                    && spoken.contains(" " + phrase(heading.text + " " + candidate.text) + " ")
            }
            guard continuation.count == 1, let c = continuation.first?.region else { return [r] }
            let x = min(r.x, c.x), y = min(r.y, c.y)
            return [DeckRegion(x: x, y: y, width: max(r.x + r.width, c.x + c.width) - x,
                               height: max(r.y + r.height, c.y + c.height) - y)]
        }
        if let count = groupSize(in: cue) {
            let matches = shapes.filter { target in
                let label = phrase(target.text)
                return !label.isEmpty && label.split(separator: " ").count <= 6 && spoken.contains(" " + label + " ")
            }
            // Require all labels and a single row or column with distinct bounds.
            var groups = Set<Set<DeckRegion>>()
            for match in matches {
                for horizontal in [true, false] {
                    let peers = matches.filter {
                        let r = $0.region, m = match.region
                        return horizontal ? abs(r.y - m.y) < min(r.height, m.height) * 0.25
                            : abs(r.x - m.x) < 0.012 && abs(r.height - m.height) < 0.20 * m.height
                    }.sorted { horizontal ? $0.region.x < $1.region.x : $0.region.y < $1.region.y }
                    if peers.count == count, Set(peers.map { phrase($0.text) }).count == count,
                       zip(peers, peers.dropFirst()).allSatisfy({ a, b in
                           horizontal ? a.region.x + a.region.width <= b.region.x + 0.003 :
                               a.region.y + a.region.height <= b.region.y + 0.003
                       }) { groups.insert(Set(peers.map(\.region))) }
                }
            }
            guard groups.count == 1, let selected = groups.first else { return [] }
            return matches.map(\.region).filter(selected.contains)
        }
        return resolve(cue, context: context, among: targets).map { [$0] } ?? []
    }

    private static func groupSize(in cue: String) -> Int? {
        for (count, names) in [(2, "two|2|两|兩|二"), (3, "three|3|三"), (4, "four|4|四"), (5, "five|5|五")] {
            if cue.range(of: "(?:\(names))\\s*(?:words?\\b|labels?\\b|boxes\\b|items?\\b|个词|個詞|个标签|個標籤|个框|個框)",
                         options: [.caseInsensitive, .regularExpression]) != nil { return count }
        }
        return nil
    }

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
        let shapes = targets.filter { $0.itemNumber == nil && (ordinal == nil || $0.isSlideTitle != true) }
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
