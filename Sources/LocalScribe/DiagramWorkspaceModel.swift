import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import LocalScribeCore

enum DiagramExportFormat: String, CaseIterable {
    case markdown = "md", plantuml = "puml"
    var title: String { self == .markdown ? "Markdown (.md)" : "PlantUML (.puml)" }
}

/// Mode state of the diagrams workspace: selection, preview and the validated
/// result. Queue dispatch, archives and models stay in AppModel; this model
/// only prepares values for the UI and never starts a worker itself.
@MainActor final class DiagramWorkspaceModel: ObservableObject {
    let model: AppModel
    private var diagramsCancellable: AnyCancellable?
    init(model: AppModel) {
        self.model = model
        diagramsCancellable = model.$diagrams.sink { [weak self] _ in self?.loadResult() }
    }

    @Published var selection: String? {
        didSet {
            sidebarSelection = SidebarSelection(selection)
            retainSearchSelection()
            if oldValue != selection { loadPreview(); loadResult() }
        }
    }
    @Published private(set) var sidebarSelection = SidebarSelection()
    @Published var sidebarRevealID: String?
    @Published private(set) var preview: NSImage?
    @Published private(set) var previewError: String?
    @Published private(set) var result: DiagramResult?
    @Published private(set) var resultError: String?
    @Published private(set) var exporting = false
    private var previewLoadID = UUID()
    private var resultLoadID = UUID()
    private var resultSignature = ""

    var search: RecordingSearch { model.diagramSearch }
    var selected: DiagramManifest? { model.diagrams.first { $0.id == selection } }
    /// A retry with an existing readable result keeps showing the previous
    /// version until the new one passes validation.
    var showsPreviousVersion: Bool {
        guard let selected else { return false }
        return selected.activeRunId != nil && selected.pendingRunId != nil
    }

    // MARK: - Preview and result loading

    func loadPreview() {
        guard let selected, let repository = model.diagramRepository else { preview = nil; previewError = nil; return }
        let id = selected.id
        preview = nil; previewError = nil
        let loadID = UUID(); previewLoadID = loadID
        let url = repository.folder(id).appendingPathComponent(selected.originalRelativePath)
        Task.detached(priority: .userInitiated) {
            let image = NSImage(contentsOf: url)
            await MainActor.run {
                guard self.previewLoadID == loadID, self.selection == id else { return }
                if let image { self.preview = image } else { self.previewError = "Не удалось открыть оригинальное изображение" }
            }
        }
    }

    func loadResult() {
        guard let selected else { result = nil; resultError = nil; resultSignature = ""; return }
        let signature = selected.id + (selected.activeRunId ?? "") + (selected.pendingRunId ?? "") + selected.state.rawValue
        guard resultSignature != signature else { return }
        resultSignature = signature
        result = nil; resultError = nil
        guard let runID = selected.activeRunId, let diagramArchive = model.diagramArchive else { return }
        let id = selected.id
        let loadID = UUID(); resultLoadID = loadID
        Task {
            do {
                let loaded = try await diagramArchive.perform { try $0.results(id, runId: runID) }
                guard self.selection == id, self.resultSignature == signature, self.resultLoadID == loadID else { return }
                self.result = loaded
            } catch {
                guard self.selection == id, self.resultSignature == signature, self.resultLoadID == loadID else { return }
                self.resultError = error.localizedDescription
            }
        }
    }

    // MARK: - Import

    /// The destination group is frozen when the panel confirms the file, before
    /// any asynchronous import work starts.
    func presentImportPanel() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg]
        panel.message = "Один файл PNG или JPEG; распознавание выполняется на этом Mac"
        let destination = model.diagramGroups.defaultID
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                if let manifest = await self.model.importDiagramImage(at: url, groupID: destination) {
                    await self.revealDiagram(manifest.id)
                }
            }
        }
    }

    // MARK: - Export

    /// The frozen result and title are captured when the panel opens; a later
    /// selection change cannot swap the exported content.
    func presentExportPanel(format: DiagramExportFormat) {
        guard let selected, let frozen = result else { return }
        let title = selected.displayTitle, id = selected.id
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .data]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + "." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text: String
        switch format {
        case .markdown: text = DiagramExport.markdown(frozen, title: title, warnings: selected.warnings)
        case .plantuml: text = DiagramExport.plantuml(frozen, title: title).text
        }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                }.value
            } catch { model.errorHandler.report(message: "Не удалось сохранить файл: \(error.localizedDescription)") }
        }
    }

    // MARK: - Sidebar projection

    var sidebarDiagramOrder: [String] {
        model.diagramGroups.groups.filter { search.expanded($0) }.flatMap { search.visible[$0.id] ?? [] }
    }
    func selectSidebarDiagram(_ id: String, command: Bool = false, shift: Bool = false) {
        var next = sidebarSelection
        next.click(id, command: command, shift: shift, order: sidebarDiagramOrder)
        let primary = next.ids.contains(id) ? id : sidebarDiagramOrder.first { next.ids.contains($0) }
        if selection != primary { selection = primary }
        sidebarSelection = next
    }
    func selectSidebarContext(_ id: String) {
        var next = sidebarSelection
        next.contextClick(id)
        if !next.ids.contains(selection ?? "") { selection = id }
        sidebarSelection = next
    }
    func sidebarActionIDs(for id: String) -> Set<String> {
        let ids = sidebarSelection.ids.contains(id) ? sidebarSelection.ids : [id]
        return search.active && search.completed ? ids.intersection(search.matchingIDs) : ids
    }
    func visibleDiagrams(in groupID: String) -> [DiagramManifest] {
        (search.visible[groupID] ?? []).compactMap { model.diagram($0) }
    }
    func sidebarGroups(editing id: String?) -> [RecordingGroup] {
        model.diagramGroups.groups.filter {
            !search.active || !search.completed || !(search.visible[$0.id] ?? []).isEmpty || $0.id == id
        }
    }
    func sidebarGroupCount(_ id: String) -> String {
        let total = search.normal[id]?.count ?? 0
        return search.active ? "\(search.filtered[id]?.count ?? 0) / \(total)" : "\(total)"
    }
    private func retainSearchSelection() {
        guard search.active, search.completed else { return }
        var retained = sidebarSelection
        retained.retain(search.matchingIDs)
        sidebarSelection = retained
    }
    func setSidebarExpanded(_ group: RecordingGroup) async {
        if search.active { search.setExpanded(group.id, !search.expanded(group)) }
        else { await model.changeDiagramGroups { try $0.setExpanded(group.id, !group.expanded) } }
    }
    func setAllSidebarExpanded(_ expanded: Bool) async {
        if search.active { search.setAllExpanded(expanded) }
        else { await model.changeDiagramGroups { $0.setAllExpanded(expanded) } }
    }
    func saveGroupName(_ name: String, id: String? = nil) async throws {
        try await model.changeDiagramGroups { groups in
            if let id { try groups.rename(id, name: name) }
            else { try groups.create(name: name) }
        }
    }
    func revealDiagram(_ id: String) async {
        await model.reloadDiagrams()
        let groupID = model.diagramGroups.groupID(for: id)
        await model.changeDiagramGroups { try $0.setExpanded(groupID, true) }
        selection = id; sidebarRevealID = id
    }
    func deleteSelected(_ ids: Set<String>) async {
        await model.deleteDiagrams(ids)
        if let selection, model.diagram(selection) == nil { self.selection = nil }
    }
}

/// Internal drag types of the diagram archive; cross-mode drags are impossible
/// because the identifiers differ from the recording types.
enum DiagramTransferTypes {
    static let diagram = UTType(exportedAs: "app.localscribe.diagram", conformingTo: .data)
    static let group = UTType(exportedAs: "app.localscribe.diagram.group", conformingTo: .data)
}
