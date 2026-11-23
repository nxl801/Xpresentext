import SwiftUI

struct StudioCuePreview: View {
    @ObservedObject var ws: StudioWorkspace
    @ObservedObject var tracking: CompanionTrackingController
    let project: DeckProject
    let slide: DeckSlide
    let height: CGFloat
    var compact = false
    @State private var indexRevision = ""
    @State private var oldTargets: [Int: [DeckCueTarget]] = [:]
    @State private var bulletKey = ""
    @State private var bulletTargets: [DeckCueTarget] = []
    private struct EditingCue: Identifiable {
        let cue: CompanionPointingCue
        let projectID: UUID
        let revisionID: String
        let page: Int
        let imageSetID: UUID?
        let color: Color
        let initialRegion: DeckRegion?
        var id: String { cue.id }
    }

    @State private var editing: EditingCue?

    private var cue: CompanionPointingCue? {
        guard let position = tracking.promptPosition, position.pageIndex == slide.pageNumber - 1,
              let index = position.sentenceIndex else { return nil }
        return CompanionPointingCue.active(in: tracking.sentences(on: position.pageIndex), sentence: index,
                                           read: tracking.readWords[position] ?? [])
    }

    private var textTargets: [DeckCueTarget] {
        (indexRevision == project.activeRevisionID ? oldTargets[slide.pageNumber] : nil) ?? slide.cueTargets ?? []
    }

    private var pageKey: String {
        "\(project.activeRevisionID)/\(slide.pageNumber)/\(slide.image?.fingerprint ?? "")/\(textTargets.count)"
    }

    private func regions(for cue: CompanionPointingCue) -> [DeckRegion] {
        if let manual = slide.manualCueRegions?[cue.id] { return [manual] }
        let targets = textTargets + (bulletKey == pageKey ? bulletTargets : [])
        return DeckCueTarget.regions(for: cue.instruction, context: cue.context, nearbyText: cue.nearbyText, title: slide.title, among: targets)
    }

    private func image(regions: [DeckRegion]) -> StudioPageImage {
        StudioPageImage(store: ws.store, projectID: project.id, revisionID: project.activeRevisionID,
                        pageNumber: slide.pageNumber,
                        highlightRegions: regions.map { QARegion(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
                        imageSetID: project.activeRevision.imageSetID, outline: StudioColors.color(project.cueColorHex),
                        outlinePadding: 2.5)
    }

    var body: some View {
        let active = cue
        let targets = active.map(regions) ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(slide.pageNumber) / \(project.activeRevision.slides.count)")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(StudioColors.tint)
                Text(slide.title.isEmpty ? "胶片" : slide.title).font(.headline).lineLimit(1)
                Spacer()
                if let active, slide.image != nil {
                    Button {
                        editing = EditingCue(cue: active, projectID: project.id, revisionID: project.activeRevisionID,
                                             page: slide.pageNumber, imageSetID: project.activeRevision.imageSetID,
                                             color: StudioColors.color(project.cueColorHex), initialRegion: targets.count == 1 ? targets.first : nil)
                    } label: {
                        Label(targets.isEmpty ? "框选指向" : "校准指向", systemImage: "scope")
                            .foregroundStyle(StudioColors.color(project.cueColorHex))
                    }
                    .disabled(tracking.phase == .listeningQuestion)
                    .help(active.instruction)
                }
                if slide.isAppendix { Label("备查附录", systemImage: "bookmark").font(.callout).foregroundStyle(.secondary) }
            }.padding(.horizontal, 14).padding(.vertical, 7)
                .modifier(StudioGlass(radius: 10))
            image(regions: targets)
                .frame(maxWidth: .infinity).frame(height: height)
                .padding(.trailing, compact ? 0 : 80).padding(.vertical, 5)
        }
        .task(id: project.activeRevisionID) {
            guard project.activeRevision.slides.contains(where: { !$0.hasIndexedCueTargets }) else { return }
            let revision = project.activeRevision
            let targets = try? await ws.store.cueTargets(projectID: project.id, revision: revision)
            guard !Task.isCancelled else { return }
            oldTargets = targets ?? [:]
            indexRevision = revision.id
        }
        .task(id: pageKey) {
            guard textTargets.contains(where: { $0.bulletItems != nil }) else { return }
            let key = pageKey
            let items = try? await ws.store.bulletTargets(projectID: project.id, revisionID: project.activeRevisionID,
                                                           slide: slide, targets: textTargets)
            guard !Task.isCancelled else { return }
            bulletTargets = items ?? []
            bulletKey = key
        }
        .sheet(item: $editing) { item in
            RegionEditor(store: ws.store, item: item) { selection in
                ws.saveCueRegion(selection, cue: item.id, projectID: item.projectID, revisionID: item.revisionID, page: item.page)
            }
        }
    }

    private struct RegionEditor: View {
        let store: DeckStore
        let item: EditingCue
        let save: (DeckRegion) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var drawn: DeckRegion?
        private var selection: DeckRegion? { drawn ?? item.initialRegion }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("在胶片上拖出指向框").font(.title2.bold())
                Text("[\(item.cue.instruction)]").foregroundStyle(item.color)
                StudioPageImage(store: store, projectID: item.projectID, revisionID: item.revisionID, pageNumber: item.page,
                                region: selection.map { QARegion(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
                                imageSetID: item.imageSetID, outline: item.color, outlinePadding: 2.5, drawRegion: { drawn = $0 })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("保存指向") {
                        if let selection { save(selection) }
                        dismiss()
                    }.keyboardShortcut(.defaultAction)
                     .disabled((selection?.width ?? 0) < 0.01 || (selection?.height ?? 0) < 0.01)
                }
            }.padding(20).frame(width: 760, height: 510)
        }
    }
}
