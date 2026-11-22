import CoreGraphics
import CryptoKit
import Foundation

nonisolated final class DeckXML: NSObject, XMLParserDelegate {
    nonisolated final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        var text = ""

        init(_ name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        subscript(child: String) -> Node? { children.first { $0.name == child } }
        func children(named name: String) -> [Node] { children.filter { $0.name == name } }

        func firstDescendant(_ name: String) -> Node? {
            for child in children {
                if child.name == name { return child }
                if let match = child.firstDescendant(name) { return match }
            }
            return nil
        }

        var relationshipID: String? { relatedAttribute("id") }

        func relatedAttribute(_ name: String) -> String? {
            attributes.first { $0.key.hasSuffix(":" + name) }?.value
        }

        func contentFingerprint(into hash: inout SHA256, relationships: [String: String]) {
            // PowerPoint generates these IDs on copy. They are not rendered content.
            guard name != "creationId", name != "modId" else { return }
            hash.append(name)
            for key in attributes.keys.sorted() {
                guard !(name == "cNvPr" && key == "id"), let value = attributes[key] else { continue }
                hash.append(key)
                hash.append(relationships[value] ?? value)
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == "t" || name == "v" {
                hash.append(text)
            }
            for child in children { child.contentFingerprint(into: &hash, relationships: relationships) }
            hash.append("/")
        }
    }

    private var root: Node?
    private var stack: [Node] = []

    static func read(at url: URL) throws -> Node {
        let delegate = DeckXML()
        let xml = XMLParser(data: try Data(contentsOf: url))
        xml.shouldProcessNamespaces = true
        xml.shouldResolveExternalEntities = false
        xml.externalEntityResolvingPolicy = .never
        xml.delegate = delegate
        guard xml.parse(), let root = delegate.root else {
            throw DeckImportError.invalidPackage(url.lastPathComponent)
        }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let node = Node(name, attributes: attributes)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let text = String(data: data, encoding: .utf8) { stack.last?.text += text }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) { _ = stack.popLast() }
}

extension SHA256 {
    nonisolated mutating func append(_ value: String) {
        var length = UInt64(value.utf8.count).bigEndian
        withUnsafeBytes(of: &length) { update(bufferPointer: $0) }
        update(data: Data(value.utf8))
    }

    nonisolated mutating func hex() -> String { Self.hex(finalize()) }

    nonisolated static func hex(_ digest: Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated final class DeckPPTX {
    typealias Node = DeckXML.Node

    struct TextBlock {
        let isTitle: Bool
        let text: String
        let region: DeckRegion?
        let fontSize: Double?
        let shapeName: String
        var bulletItems: [String]?
    }

    struct Relationship {
        let id: String
        let kind: String
        let path: String?
        let target: String
    }

    private let folder: URL
    private var xmlParts: [String: Node] = [:]
    private var relationParts: [String: [Relationship]] = [:]
    private var fingerprints: [String: String] = [:]
    private(set) var slideWidth = 9_144_000.0
    private(set) var slideHeight = 6_858_000.0

    init(folder: URL) { self.folder = folder }

    func parse(revisionID: String, sourceName: String) throws -> DeckRevision {
        guard let presentation = try relationships(in: "").first(where: { $0.kind == "officeDocument" })?.path
        else { throw DeckImportError.invalidPackage("presentation relationship") }
        let manifest = try xml(presentation)
        if let size = manifest["sldSz"], let width = number(size, "cx"), let height = number(size, "cy"),
           width > 0, height > 0 {
            slideWidth = width
            slideHeight = height
        }
        let presentationRelationships = try relationships(in: presentation)
        let slideReferences = manifest["sldIdLst"]?.children(named: "sldId") ?? []
        guard !slideReferences.isEmpty else { throw DeckImportError.emptyPresentation }
        var slides: [DeckSlide] = []
        var seenIDs = Set<String>()
        for (index, reference) in slideReferences.enumerated() {
            try Task.checkCancellation()
            guard let id = reference.attributes["id"], seenIDs.insert(id).inserted,
                  let path = presentationRelationships.first(where: {
                      $0.id == reference.relationshipID && $0.kind == "slide"
                  })?.path else { throw DeckImportError.invalidPackage("slide \(index + 1)") }
            slides.append(try slide(path, id: id, pageNumber: index + 1))
        }
        let suggestions = [sectionSuggestion(in: manifest, slides: slides), dividerSuggestion(in: slides)].compactMap { $0 }
        var revision = DeckRevision(id: revisionID, sourceName: sourceName, slides: slides,
                                    appendixSuggestion: suggestions.min())
        revision.chartContextVersion = Self.chartContextVersion
        return revision
    }

    func xml(_ path: String) throws -> Node {
        if let part = xmlParts[path] { return part }
        let part = try DeckXML.read(at: folder.appendingPathComponent(path))
        xmlParts[path] = part
        return part
    }

    func relationships(in path: String) throws -> [Relationship] {
        if let relations = relationParts[path] { return relations }
        let components = path.split(separator: "/").map(String.init)
        let relativeFolder = Array(components.dropLast())
        let relPath = (relativeFolder + ["_rels", (components.last ?? "") + ".rels"]).joined(separator: "/")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(relPath).path) else {
            relationParts[path] = []
            return []
        }
        let relations = try xml(relPath).children(named: "Relationship").compactMap { node -> Relationship? in
            guard let id = node.attributes["Id"], let target = node.attributes["Target"],
                  let kind = node.attributes["Type"]?.split(separator: "/").last else { return nil }
            let localPath = node.attributes["TargetMode"]?.lowercased() == "external" ? nil :
                resolvedPath(target, relativeTo: relativeFolder)
            return Relationship(id: id, kind: String(kind), path: localPath, target: target)
        }
        relationParts[path] = relations
        return relations
    }

    private func resolvedPath(_ target: String, relativeTo base: [String]) -> String? {
        guard let path = target.removingPercentEncoding, !path.contains(":"), !path.contains("\\"),
              !path.contains("\0"), !path.hasPrefix("//") else { return nil }
        var result = path.hasPrefix("/") ? [] : base
        for component in path.split(separator: "/").map(String.init) {
            guard component != "." else { continue }
            if component == ".." {
                guard !result.isEmpty else { return nil }
                result.removeLast()
            } else {
                result.append(component)
            }
        }
        return result.isEmpty ? nil : result.joined(separator: "/")
    }

    private func slide(_ path: String, id: String, pageNumber: Int) throws -> DeckSlide {
        let document = try xml(path)
        let relations = try relationships(in: path)
        let originalNotes = try relations.first(where: { $0.kind == "notesSlide" })?.path.map(notes) ?? ""
        let layoutPath = relations.first(where: { $0.kind == "slideLayout" })?.path
        let layout = try layoutPath.map(xml)
        let masterPath = try layoutPath.flatMap {
            try relationships(in: $0).first(where: { $0.kind == "slideMaster" })?.path
        }
        let master = try masterPath.map(xml)
        let placeholders = (master.map(placeholderTypes) ?? [:]).merging(layout.map(placeholderTypes) ?? [:]) { _, layoutType in layoutType }
        var blocks: [TextBlock] = []
        var visuals: [DeckVisual] = []
        if let shapeTree = document["cSld"]?["spTree"] {
            try readShapes(shapeTree, relations: relations, placeholders: placeholders, transform: .identity,
                           blocks: &blocks, visuals: &visuals)
        }
        associateExternalChartLabels(&visuals, blocks: blocks)
        let title = blocks.first(where: \.isTitle)?.text ?? prominentTitle(in: blocks) ??
            document["cSld"]?.attributes["name"].flatMap(nonempty) ?? blocks.first?.text ?? ""
        var hash = SHA256()
        hash.append(try fingerprint(path))
        hash.append(originalNotes)
        let fingerprint = hash.hex()
        let targets = blocks.compactMap { block -> DeckCueTarget? in
            guard !block.isTitle, let region = block.region else { return nil }
            return DeckCueTarget(text: block.text, region: region, bulletItems: block.bulletItems)
        }
        return DeckSlide(id: id, pageNumber: pageNumber, title: title,
                         bodyText: blocks.map(\.text).joined(separator: "\n"), originalNotes: originalNotes,
                         script: DeckScript(notes: originalNotes), visuals: visuals, cueTargets: targets, contentFingerprint: fingerprint)
    }

    private func notes(_ path: String) throws -> String {
        let document = try xml(path)
        guard let shapeTree = document["cSld"]?["spTree"] else { return "" }
        let masterPath = try relationships(in: path).first(where: { $0.kind == "notesMaster" })?.path
        let master = try masterPath.map(xml)
        let placeholders = master.map(placeholderTypes) ?? [:]
        var paragraphs: [String] = []
        for shape in shapes(in: shapeTree) where shape.name == "sp" {
            let type = placeholderType(in: shape, inherited: placeholders)
            if let type, type != "body", type != "obj" { continue }
            if let body = shape["txBody"] { paragraphs.append(contentsOf: textParagraphs(body)) }
        }
        return paragraphs.joined(separator: "\n")
    }

    private func readShapes(_ parent: Node, relations: [Relationship], placeholders: [String: String],
                            transform: CGAffineTransform, blocks: inout [TextBlock],
                            visuals: inout [DeckVisual]) throws {
        for shape in visibleChildren(in: parent) {
            let properties = shape.children.first { $0.name.hasPrefix("nv") }?["cNvPr"]
            if isTrue(properties?.attributes["hidden"]) { continue }
            if shape.name == "grpSp" {
                let group = groupTransform(shape["grpSpPr"]?["xfrm"]).concatenating(transform)
                try readShapes(shape, relations: relations, placeholders: placeholders, transform: group,
                               blocks: &blocks, visuals: &visuals)
                continue
            }
            let position = shape["xfrm"] ?? shape["spPr"]?["xfrm"]
            let region = region(position, parent: transform)
            if region == nil, let position, let width = number(position["ext"], "cx"),
               let height = number(position["ext"], "cy"), width > 0, height > 0 { continue }
            if let body = shape["txBody"], let text = nonempty(textParagraphs(body).joined(separator: "\n")) {
                let type = placeholderType(in: shape, inherited: placeholders)
                if type != "sldNum" && type != "sldImg" {
                    let isTitle = type == "title" || type == "ctrTitle" || type == "vertTitle"
                    let name = [properties?.attributes["name"], properties?.attributes["title"], properties?.attributes["descr"]]
                        .compactMap { $0 }.joined(separator: " ")
                    let items = zip(body.children(named: "p"), textParagraphs(body)).compactMap { paragraph, label -> String? in
                        guard let style = paragraph["pPr"], (style.attributes["lvl"] ?? "0") == "0",
                              style["buChar"] != nil || style["buAutoNum"] != nil else { return nil }
                        return nonempty(label)
                    }
                    blocks.append(TextBlock(isTitle: isTitle, text: text, region: region,
                                            fontSize: fontSize(in: body), shapeName: name, bulletItems: items.isEmpty ? nil : items))
                }
            }
            let id = properties?.attributes["id"] ?? String(visuals.count + 1)
            if shape.name == "graphicFrame", let graphic = shape["graphic"]?["graphicData"] {
                if let table = graphic["tbl"] {
                    let rows = table.children(named: "tr").map { row in
                        row.children(named: "tc").map { cell in
                            guard !isTrue(cell.attributes["hMerge"]), !isTrue(cell.attributes["vMerge"]),
                                  let body = cell["txBody"] else { return "" }
                            return textParagraphs(body).joined(separator: "\n")
                        }
                    }
                    let title = properties?.attributes["descr"] ?? properties?.attributes["name"] ?? "Table"
                    let text = rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
                    visuals.append(DeckVisual(id: id, kind: .table, title: title, text: text, region: region, rows: rows))
                } else if let chart = graphic["chart"], let link = relations.first(where: { $0.id == chart.relationshipID }),
                          let path = link.path, let document = try? xml(path) {
                    visuals.append(chartVisual(document, id: id, region: region))
                } else if graphic["chart"] != nil {
                    visuals.append(DeckVisual(id: id, kind: .chart, title: "Chart", text: "", region: region))
                }
            } else if shape.name == "pic" {
                let title = properties?.attributes["title"] ?? properties?.attributes["name"] ?? "Image"
                visuals.append(DeckVisual(id: id, kind: .picture, title: title,
                                          text: "", region: region))
            }
        }
    }

    private func visibleChildren(in node: Node) -> [Node] {
        node.children.flatMap { child -> [Node] in
            guard child.name == "AlternateContent" else { return [child] }
            return child["Fallback"]?.children ?? child["Choice"]?.children ?? []
        }
    }

    private func shapes(in parent: Node) -> [Node] {
        visibleChildren(in: parent).flatMap { $0.name == "grpSp" ? shapes(in: $0) : [$0] }
    }

    private func placeholderTypes(_ document: Node) -> [String: String] {
        guard let tree = document["cSld"]?["spTree"] else { return [:] }
        var result: [String: String] = [:]
        for shape in shapes(in: tree) {
            guard let placeholder = shape.children.first(where: { $0.name.hasPrefix("nv") })?["nvPr"]?["ph"],
                  let type = placeholder.attributes["type"] else { continue }
            result[placeholder.attributes["idx"] ?? "0"] = type
        }
        return result
    }

    private func placeholderType(in shape: Node, inherited: [String: String]) -> String? {
        guard let placeholder = shape.children.first(where: { $0.name.hasPrefix("nv") })?["nvPr"]?["ph"]
        else { return nil }
        return placeholder.attributes["type"] ?? inherited[placeholder.attributes["idx"] ?? "0"] ?? "obj"
    }

    func textParagraphs(_ container: Node) -> [String] {
        container.children(named: "p").map { paragraph in
            paragraph.children.map { part -> String in
                switch part.name {
                case "br": return "\n"
                case "tab": return "\t"
                case "r": return part["t"]?.text ?? ""
                case "fld":
                    return part.attributes["type"]?.lowercased() == "slidenum" ? "" : part["t"]?.text ?? ""
                default: return ""
                }
            }.joined()
        }
    }

    private func fontSize(in body: Node) -> Double? {
        for paragraph in body.children(named: "p") {
            if let run = paragraph.children(named: "r").first(where: { nonempty($0["t"]?.text ?? "") != nil }) {
                let defaultSize = paragraph["pPr"]?["defRPr"]?.attributes["sz"]
                    ?? body["lstStyle"]?["lvl1pPr"]?["defRPr"]?.attributes["sz"]
                let size = run["rPr"]?.attributes["sz"] ?? defaultSize ?? paragraph["endParaRPr"]?.attributes["sz"]
                return size.flatMap(Double.init).map { $0 / 100 }
            }
        }
        return nil
    }

    private func prominentTitle(in blocks: [TextBlock]) -> String? {
        let ranked = blocks.compactMap { block -> (String, Double)? in
            guard let region = block.region, region.y < 0.7 else { return nil }
            let lineCount = max(1, block.text.split(separator: "\n").count)
            let approximateFont = region.height * slideHeight / 12_700 * 0.7 / Double(lineCount)
            let size = min(48, block.fontSize ?? approximateFont)
            let aboveBody = region.x < 0.35 && region.y < 0.14 ? 10.0 : 0.0
            let length = block.text.count
            let longTextPenalty = length > 120 ? 8.0 : 0.0
            let score = size + 28 * (1 - region.y) + 12 * region.width + aboveBody - longTextPenalty
            return (block.text, score)
        }
        return ranked.max { $0.1 < $1.1 }?.0
    }

    private func fingerprint(_ path: String, visiting: Set<String> = []) throws -> String {
        if visiting.contains(path) { return "cycle" }
        if let cached = fingerprints[path] { return cached }
        let ext = (path as NSString).pathExtension.lowercased()
        let file = folder.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: file.path) else { return "missing" }
        let result: String
        if ext == "xml" || ext == "vml" {
            let document = try xml(path)
            let relations = try relationships(in: path).filter {
                // master <-> layout and slide <-> notes links are package navigation.
                $0.kind != "notesSlide" && $0.kind != "slide" &&
                    !(document.name == "sldMaster" && $0.kind == "slideLayout")
            }
            var hash = SHA256()
            var values: [String: String] = [:]
            for link in relations {
                if let relatedPath = link.path {
                    values[link.id] = link.kind + ":" + (try fingerprint(relatedPath, visiting: visiting.union([path])))
                } else {
                    values[link.id] = link.kind + ":" + link.target
                }
            }
            // Unreferenced relationship attributes can still affect inherited layout and themes.
            for value in values.values.sorted() { hash.append(value) }
            document.contentFingerprint(into: &hash, relationships: values)
            result = hash.hex()
        } else {
            result = try DeckPPTX.fileFingerprint(file)
        }
        fingerprints[path] = result
        return result
    }

    static func fileFingerprint(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.hex()
    }

    private func sectionSuggestion(in document: Node, slides: [DeckSlide]) -> Int? {
        guard let sectionList = document.firstDescendant("sectionLst") else { return nil }
        let candidates = sectionList.children(named: "section").filter { isDividerTitle($0.attributes["name"] ?? "") }
        let ids = Set(candidates.compactMap { $0["sldIdLst"]?["sldId"]?.attributes["id"] })
        return slides.first { ids.contains($0.id) }?.pageNumber
    }

    private func dividerSuggestion(in slides: [DeckSlide]) -> Int? {
        slides.first { isDividerTitle($0.title) }?.pageNumber
    }

    private func isDividerTitle(_ title: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let divider = #"^(?:appendix|appendices|backup(?: slides?)?|附录|附錄|備用頁|备用页)(?:\s+[a-z0-9]+)?(?:\s*[:：–—-].*)?$"#
        return value.range(of: divider, options: .regularExpression) != nil
    }

    func nonempty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func isTrue(_ value: String?) -> Bool { value == "1" || value == "true" }

    private func number(_ node: Node?, _ key: String) -> Double? {
        guard let value = node?.attributes[key].flatMap(Double.init), value.isFinite else { return nil }
        return value
    }

    private func groupTransform(_ node: Node?) -> CGAffineTransform {
        guard let node,
              let x = number(node["off"], "x"), let y = number(node["off"], "y"),
              let dx = number(node["ext"], "cx"), let dy = number(node["ext"], "cy"),
              let cx = number(node["chOff"], "x"), let cy = number(node["chOff"], "y"),
              let cdx = number(node["chExt"], "cx"), let cdy = number(node["chExt"], "cy"),
              cdx > 0, cdy > 0 else { return .identity }
        return CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(scaleX: dx / cdx, y: dy / cdy))
            .concatenating(CGAffineTransform(translationX: x, y: y))
            .concatenating(orientation(node, center: CGPoint(x: x + dx / 2, y: y + dy / 2)))
    }

    private func orientation(_ node: Node?, center: CGPoint) -> CGAffineTransform {
        let angle = (number(node, "rot") ?? 0) / 60_000 * .pi / 180
        let flipX = isTrue(node?.attributes["flipH"]) ? -1.0 : 1.0
        let flipY = isTrue(node?.attributes["flipV"]) ? -1.0 : 1.0
        return CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: flipX, y: flipY))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }

    private func region(_ node: Node?, parent: CGAffineTransform) -> DeckRegion? {
        guard let node, let x = number(node["off"], "x"), let y = number(node["off"], "y"),
              let width = number(node["ext"], "cx"), let height = number(node["ext"], "cy"),
              width > 0, height > 0 else { return nil }
        let source = CGRect(x: x, y: y, width: width, height: height)
        let transform = orientation(node, center: CGPoint(x: source.midX, y: source.midY)).concatenating(parent)
        let bounds = source.applying(transform).intersection(CGRect(x: 0, y: 0, width: slideWidth, height: slideHeight))
        guard !bounds.isEmpty, !bounds.isNull else { return nil }
        return DeckRegion(x: bounds.minX / slideWidth, y: bounds.minY / slideHeight,
                          width: bounds.width / slideWidth, height: bounds.height / slideHeight)
    }
}
