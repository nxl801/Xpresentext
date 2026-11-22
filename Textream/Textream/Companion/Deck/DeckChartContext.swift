import Foundation

extension DeckPPTX {
    static let chartContextVersion = 1

    func associateExternalChartLabels(_ visuals: inout [DeckVisual], blocks: [TextBlock]) {
        let potentialTargets = visuals.indices.filter { index in
            let visual = visuals[index]
            if visual.kind != .picture { return true }
            // Ignore small decorative artwork when deciding if a label has only one target.
            return visual.region.map { $0.width * $0.height >= 0.05 } ?? true
        }
        guard potentialTargets.count == 1, let index = potentialTargets.first,
              let chart = visuals[index].region, visuals[index].kind != .table else { return }
        let candidate = visuals[index]
        let outside = blocks.filter { block in
            block.region.map { isNearOutside($0, chart: chart) } == true
        }
        let isNativeChart = candidate.kind == .chart
        let hasFigureName = normalizeChartText(candidate.title).range(
            of: #"\b(?:chart|plot|graph|figure)\b|图表|图示"#, options: .regularExpression
        ) != nil
        let legends = isNativeChart
            ? externalNativeLegend(candidate, outside: outside)
            : outside.filter { isLegend($0) }
        guard isNativeChart || hasFigureName || !legends.isEmpty else { return }
        let hasTitle = isNativeChart && candidate.title != "Chart"
        let hasUnits = normalizeChartText(candidate.text).range(
            of: #"%|‰|\b(?:kwh|mw|kg|gwh|ms|usd|eur|percentage points)\b|千克|毫秒|美元"#,
            options: .regularExpression
        ) != nil
        let captions = hasTitle ? [] : outside.filter(isChartCaption)
        let units = hasUnits ? [] : outside.filter(isChartUnit)
        var seen = Set<DeckRegion>()
        let regions = (legends + captions + units).compactMap(\.region).filter { seen.insert($0).inserted }
        if !regions.isEmpty { visuals[index].externalChartRegions = regions }
    }

    private func externalNativeLegend(_ chart: DeckVisual, outside: [TextBlock]) -> [TextBlock] {
        let names = chart.series.map { normalizeChartText($0.name) }
        let unique = Set(names.filter { !$0.isEmpty })
        guard unique.count >= 2, unique.count == names.count else { return [] }
        let inside = Set(chart.text.split(whereSeparator: \.isNewline).compactMap {
            $0.split(separator: "|").first.map { normalizeChartText(String($0)) }
        })
        guard !unique.isSubset(of: inside) else { return [] }
        let matches = outside.map { label in
            let lines = Set(label.text.split(whereSeparator: \.isNewline).map { normalizeChartText(String($0)) })
            let names = unique.filter { name in
                lines.contains(name) || (isLegend(label) && containsSeriesName(name, in: label.text))
            }
            return (label, names)
        }
        guard unique.isSubset(of: inside.union(matches.flatMap(\.1))) else { return [] }
        return matches.filter { !$0.1.isEmpty }.map(\.0)
    }

    private func isLegend(_ block: TextBlock) -> Bool {
        normalizeChartText(block.shapeName).range(of: #"\blegend\b|图例"#, options: .regularExpression) != nil
            || normalizeChartText(block.text).range(of: #"^(?:legend|图例)\s*[:：]"#, options: .regularExpression) != nil
    }

    private func isChartCaption(_ block: TextBlock) -> Bool {
        normalizeChartText(block.shapeName).range(
            of: #"\b(?:chart|figure|graph|plot)\s+(?:title|caption)\b|图表标题"#, options: .regularExpression
        ) != nil || normalizeChartText(block.text).range(
            of: #"^(?:chart|figure|graph|plot)(?: title| \d+[a-z]?)?\s*[:：]|^(?:图表标题|图题)\s*[:：]"#,
            options: .regularExpression
        ) != nil
    }

    private func isChartUnit(_ block: TextBlock) -> Bool {
        normalizeChartText(block.text).range(
            of: #"^(?:(?:chart\s+)?units?|单位)\s*[:：]\s*(?:[%‰]|percent(?:age points)?|kg|kwh|mw|gwh|ms|usd|eur|千克|毫秒|美元)$"#,
            options: .regularExpression
        ) != nil
    }

    private func containsSeriesName(_ name: String, in text: String) -> Bool {
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}])"#
        return normalizeChartText(text).range(of: pattern, options: .regularExpression) != nil
    }

    private func normalizeChartText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isNearOutside(_ label: DeckRegion, chart: DeckRegion) -> Bool {
        let horizontalOverlap = min(label.x + label.width, chart.x + chart.width) - max(label.x, chart.x)
        let verticalOverlap = min(label.y + label.height, chart.y + chart.height) - max(label.y, chart.y)
        let horizontalGap = max(label.x - chart.x - chart.width, chart.x - label.x - label.width)
        let verticalGap = max(label.y - chart.y - chart.height, chart.y - label.y - label.height)
        return (verticalOverlap > 0 && horizontalGap >= 0 && horizontalGap <= 0.18)
            || (horizontalOverlap > 0 && verticalGap >= 0 && verticalGap <= 0.16)
    }
}
