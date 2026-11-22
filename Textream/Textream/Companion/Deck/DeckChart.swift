import Foundation

extension DeckPPTX {
    func chartVisual(_ document: Node, id: String, region: DeckRegion?) -> DeckVisual {
        let chart = document["chart"]
        let plot = chart?["plotArea"]
        let title = chart?["title"].map(chartTitle) ?? ""
        let axes = plot?.children.filter { ["catAx", "valAx", "dateAx", "serAx"].contains($0.name) } ?? []
        let visibleAxes = axes.filter { !isTrue($0["delete"]?.attributes["val"]) }
        let axisTitles = visibleAxes.compactMap { $0["title"].map(chartTitle) }.compactMap(nonempty)
        let legend = chart?["legend"]
        let showLegend = legend != nil && !isTrue(legend?["delete"]?.attributes["val"])
        var evidence = [title] + axisTitles
        if visibleAxes.contains(where: {
            $0["tickLblPos"]?.attributes["val"] != "none" && $0["numFmt"]?.attributes["formatCode"]?.hasSuffix("%") == true
        }) { evidence.append("Unit: %") }
        var series: [DeckChartSeries] = []
        let plotTypes = plot?.children.filter { $0.name.hasSuffix("Chart") } ?? []
        let seriesCount = plotTypes.reduce(0) { $0 + $1.children(named: "ser").count }
        for plotType in plotTypes {
            let groupLabels = plotType["dLbls"]
            let showCategories = visibleAxes.contains {
                ($0.name == "catAx" || $0.name == "dateAx") && $0["tickLblPos"]?.attributes["val"] != "none"
            }
            for item in plotType.children(named: "ser") {
                let name = item["tx"]?["v"]?.text ?? item["tx"]?.firstDescendant("v")?.text ?? ""
                let values = item["val"] ?? item["yVal"]
                let categories = item["cat"] ?? item["xVal"]
                let categoryValues = points(in: categories)
                let categoryFormat = categories?.firstDescendant("formatCode")?.text
                let format = values?.firstDescendant("formatCode")?.text
                let labels = item["dLbls"]
                let index = item["idx"]?.attributes["val"]
                let legendEntry = legend?.children(named: "legendEntry").first { $0["idx"]?.attributes["val"] == index }
                let visibleSeriesName = showLegend && !isTrue(legendEntry?["delete"]?.attributes["val"])
                if visibleSeriesName, let name = nonempty(name) { evidence.append(name) }
                let valuesByIndex = points(in: values)
                let data = valuesByIndex.sorted { $0.key < $1.key }.map { point -> DeckChartPoint in
                    let category = categoryValues[point.key] ?? ""
                    let visibleCategory = categoryFormat.flatMap { displayedNumber(category, format: $0) }
                        ?? (categoryFormat == nil ? category : "")
                    let label = pointLabel(in: labels, index: point.key) ?? pointLabel(in: groupLabels, index: point.key)
                    let scopes = [label, labels, groupLabels].compactMap { $0 }
                    let isHidden = scopes.lazy.compactMap({ $0["delete"]?.attributes["val"] }).first.map(isTrue) == true
                    let customLabel = isHidden ? nil : label?["tx"].map(chartTitle).flatMap(nonempty)
                    let displayValue: String?
                    if !isHidden,
                       scopes.lazy.compactMap({ $0["showVal"]?.attributes["val"] }).first.map(isTrue) == true,
                       customLabel == nil {
                        let labelFormat = scopes.lazy.compactMap { $0["numFmt"]?.attributes["formatCode"] }.first ?? format
                        displayValue = displayedNumber(point.value, format: labelFormat)
                    } else {
                        displayValue = nil
                    }
                    let showCategoryLabel = !isHidden && scopes.lazy.compactMap {
                        $0["showCatName"]?.attributes["val"]
                    }.first.map(isTrue) == true
                    let showSeriesLabel = !isHidden && scopes.lazy.compactMap {
                        $0["showSerName"]?.attributes["val"]
                    }.first.map(isTrue) == true
                    if showCategories || showCategoryLabel, let visibleCategory = nonempty(visibleCategory) {
                        evidence.append(visibleCategory)
                    }
                    if let label = customLabel ?? displayValue {
                        let seriesLabel = (visibleSeriesName || showSeriesLabel) ? name : ""
                        let categoryLabel = (showCategories || showCategoryLabel) ? visibleCategory : ""
                        let labelledValue = [seriesLabel, categoryLabel, label].compactMap(nonempty).joined(separator: " | ")
                        let hasUnambiguousSeries = seriesCount == 1 || !seriesLabel.isEmpty
                        let hasUnambiguousCategory = valuesByIndex.count == 1 || !categoryLabel.isEmpty
                        if hasUnambiguousSeries, hasUnambiguousCategory,
                           !seriesLabel.isEmpty || !categoryLabel.isEmpty { evidence.append(labelledValue) }
                    }
                    return DeckChartPoint(category: category, value: point.value, displayValue: displayValue)
                }
                series.append(DeckChartSeries(name: name, points: data, numberFormat: format))
            }
        }
        var seen = Set<String>()
        let text = evidence.compactMap(nonempty).filter { seen.insert($0).inserted }.joined(separator: "\n")
        return DeckVisual(id: id, kind: .chart, title: nonempty(title) ?? "Chart", text: text,
                          region: region, series: series)
    }

    private func chartTitle(_ node: Node) -> String {
        if let rich = node.firstDescendant("rich") { return textParagraphs(rich).joined(separator: "\n") }
        return node.firstDescendant("v")?.text ?? ""
    }

    private func points(in source: Node?) -> [Int: String] {
        guard let source,
              let cache = source["strLit"] ?? source["numLit"] ?? source.firstDescendant("strCache") ??
                source.firstDescendant("numCache") ?? source.firstDescendant("multiLvlStrCache")?["lvl"] else { return [:] }
        var values: [Int: String] = [:]
        for entry in cache.children(named: "pt") {
            if let index = entry.attributes["idx"].flatMap(Int.init), let value = entry["v"]?.text { values[index] = value }
        }
        return values
    }

    private func pointLabel(in labels: Node?, index: Int) -> Node? {
        labels?.children(named: "dLbl").first { $0["idx"]?.attributes["val"].flatMap(Int.init) == index }
    }

    private func displayedNumber(_ value: String, format: String?) -> String? {
        guard let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else { return nil }
        let format = format ?? "General"
        if format.lowercased() == "general" { return value }
        // The format of a visible data label should be demonstrable from its cache. Excel's
        // currency, date and custom unit formats carry extra semantics we cannot infer here.
        guard format.range(of: #"^[#0,]+(?:\.[#0]+)?%?$"#, options: .regularExpression) != nil else { return nil }
        let isPercent = format.hasSuffix("%")
        let pattern = isPercent ? String(format.dropLast()) : format
        let parts = pattern.split(separator: ".")
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = pattern.contains(",")
        formatter.minimumIntegerDigits = max(1, parts[0].filter { $0 == "0" }.count)
        formatter.minimumFractionDigits = parts.count > 1 ? parts[1].filter { $0 == "0" }.count : 0
        formatter.maximumFractionDigits = parts.count > 1 ? parts[1].count : 0
        formatter.roundingMode = .halfUp
        let visibleNumber = NSDecimalNumber(decimal: number * (isPercent ? 100 : 1))
        return formatter.string(from: visibleNumber).map { $0 + (isPercent ? "%" : "") }
    }
}
