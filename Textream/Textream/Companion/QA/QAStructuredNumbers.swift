import Foundation

struct QANumericBinding: Sendable, Hashable {
    let label: String
    let values: Set<String>

    init?(excerpt: String, kind: QACitation.Kind) {
        let columns: [String]
        if (kind == .chart || kind == .table) && excerpt.contains(" | ") {
            columns = excerpt.components(separatedBy: " | ")
        } else if [.chart, .table, .imageText].contains(kind) && excerpt.contains(" · ") {
            // Online evidence starts with the chart title, then the printed series or row.
            let parts = excerpt.components(separatedBy: " · ")
            columns = parts.count > 2 ? Array(parts.dropFirst()) : parts
        } else {
            return nil
        }
        guard columns.count >= 2,
              let label = columns.first.map(QASearchText.normalized), !label.isEmpty else { return nil }
        let cells = kind == .chart ? Array(columns.suffix(1)) : Array(columns.dropFirst())
        let values = Set(cells.flatMap(QASearchText.numericLiterals))
        guard !values.isEmpty else { return nil }
        self.label = label
        self.values = values
    }

    func numbers(in quote: String) -> Set<String> {
        values.intersection(QASearchText.numericLiterals(quote))
    }

    func isNamed(in text: String) -> Bool {
        Self.labelRange(label, in: QASearchText.normalized(text)) != nil
    }

    static func accepts(
        _ answer: String,
        labels: Set<String>,
        quoted: [QANumericBinding: Set<String>],
        quotedValues: Set<String>
    ) -> Bool {
        guard !quotedValues.isEmpty else { return true }
        let normalized = QASearchText.normalized(answer)
        let boundaries = #/;|\b(?:while|whereas|versus|vs\.?|compared (?:with|to)|compares (?:with|to))\b/#
        let clauses = normalized.replacing(boundaries, with: "\u{1F}").components(separatedBy: "\u{1F}")
        for clause in clauses {
            let numbers = QASearchText.numericLiterals(clause).filter { quotedValues.contains($0) }
            if numbers.isEmpty { continue }
            let mentioned = labels.compactMap { label in
                labelRange(label, in: clause).map { (label: label, range: $0) }
            }.sorted { $0.label.count > $1.label.count }
            var distinct: [(label: String, range: Range<String.Index>)] = []
            for mention in mentioned where !distinct.contains(where: { $0.range.overlaps(mention.range) }) {
                distinct.append(mention)
            }
            let names = distinct.sorted { $0.range.lowerBound < $1.range.lowerBound }.map(\.label)
            guard !names.isEmpty else { return false }

            func supports(_ name: String, _ number: String) -> Bool {
                quoted.contains { $0.key.label == name && $0.value.contains(number) }
            }

            if names.count == 1 {
                guard numbers.allSatisfy({ supports(names[0], $0) }) else { return false }
            } else if numbers.count == 1 {
                guard names.allSatisfy({ supports($0, numbers[0]) }) else { return false }
            } else {
                guard names.count == numbers.count, zip(names, numbers).allSatisfy(supports) else { return false }
            }
        }
        return true
    }

    private static func labelRange(_ label: String, in text: String) -> Range<String.Index>? {
        if QASearchText.containsHan(label) { return text.range(of: label) }
        let name = NSRegularExpression.escapedPattern(for: label)
        return text.range(of: #"(?<![\p{L}\p{N}])"# + name + #"(?![\p{L}\p{N}])"#, options: .regularExpression)
    }
}
