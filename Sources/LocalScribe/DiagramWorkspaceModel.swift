import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import LocalScribeCore

enum DiagramExportFormat: String, Sendable {
    case markdown = "md", plainText = "txt", plantuml = "puml"
}

struct DiagramExportRequest: Sendable {
    let diagram: DiagramManifest
    let result: DiagramResult
    let part: DiagramExportPart
    let format: DiagramExportFormat

    var filename: String {
        diagram.displayTitle.replacingOccurrences(of: "/", with: "-") + "." + format.rawValue
    }

    func render() async -> String {
        await Task.detached(priority: .userInitiated) {
            switch format {
            case .markdown:
                DiagramExport.markdown(result, title: diagram.displayTitle, warnings: diagram.warnings, part: part)
            case .plainText:
                DiagramExport.plainText(result, title: diagram.displayTitle, warnings: diagram.warnings, part: part)
            case .plantuml:
                DiagramExport.plantuml(result, title: diagram.displayTitle).text
            }
        }.value
    }
}

/// Mode state of the diagrams workspace: selection, preview and the validated
/// result. Queue dispatch, archives and models stay in AppModel; this model
/// only prepares values for the UI and never starts a worker itself.
@MainActor final class DiagramWorkspaceModel: ObservableObject {
    private struct PresentedResult: Sendable {
        let result: DiagramResult
        let edgeLabels: [String: String]

        init(_ result: DiagramResult) {
            self.result = result
            edgeLabels = Dictionary(uniqueKeysWithValues: result.nodes.map { node in
                (node.id, node.label.split(whereSeparator: \.isNewline).joined(separator: " "))
            })
        }
    }

    let model: AppModel
    private var diagramsCancellable: AnyCancellable?
    init(model: AppModel) {
        self.model = model
        diagramsCancellable = model.$diagrams.sink { [weak self] diagrams in
            guard let self else { return }
            // @Published emits before model.diagrams changes. Use the incoming
            // snapshot so completion loads the newly published active run.
            self.loadResult(for: diagrams.first { $0.id == self.selection })
        }
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
    @Published private var presentation: PresentedResult?
    @Published private(set) var resultTab: DiagramExportPart = .nodes
    @Published private(set) var resultError: String?
    private var previewLoadID = UUID()
    private var resultLoadID = UUID()
    private var resultSignature = ""

    var search: RecordingSearch { model.diagramSearch }
    var selected: DiagramManifest? { model.diagrams.first { $0.id == selection } }
    var result: DiagramResult? { presentation?.result }
    var resultTabs: [DiagramExportPart] {
        DiagramExportPart.sections(includingWarnings: selected?.warnings.isEmpty == false)
    }

    func selectResultTab(_ part: DiagramExportPart) {
        guard resultTabs.contains(part) else { return }
        resultTab = part
    }

    func edgeLabel(_ id: String) -> String { presentation?.edgeLabels[id] ?? id }

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
        let url = repository.originalURL(selected)
        Task.detached(priority: .userInitiated) {
            let image = NSImage(contentsOf: url)
            await MainActor.run {
                guard self.previewLoadID == loadID, self.selection == id else { return }
                if let image { self.preview = image } else { self.previewError = "Не удалось открыть оригинальное изображение" }
            }
        }
    }

    func showImageInFinder(_ diagram: DiagramManifest) {
        guard let repository = model.diagramRepository else { return }
        NSWorkspace.shared.activateFileViewerSelecting([repository.originalURL(diagram)])
    }

    func loadResult() {
        loadResult(for: selected)
    }

    private func loadResult(for selected: DiagramManifest?) {
        if resultTab == .warnings, selected?.warnings.isEmpty != false { resultTab = .nodes }
        guard let selected else { presentation = nil; resultError = nil; resultSignature = ""; return }
        let signature = selected.id + (selected.activeRunId ?? "") + (selected.pendingRunId ?? "") + selected.state.rawValue
        guard resultSignature != signature else { return }
        resultSignature = signature
        presentation = nil; resultError = nil
        guard let runID = selected.activeRunId, let diagramArchive = model.diagramArchive else { return }
        let id = selected.id
        let loadID = UUID(); resultLoadID = loadID
        Task {
            do {
                let loaded = try await diagramArchive.perform { PresentedResult(try $0.results(id, runId: runID)) }
                guard self.selection == id, self.resultSignature == signature, self.resultLoadID == loadID else { return }
                self.presentation = loaded
            } catch {
                guard self.selection == id, self.resultSignature == signature, self.resultLoadID == loadID else { return }
                self.resultError = error.localizedDescription
            }
        }
    }

    // MARK: - Import

    var resolveDuplicateImport: (DuplicateDiagram) -> AppModel.DuplicateImportAction = { _ in
        AppModel.presentDuplicateImportAlert()
    }

    func presentImportPanel() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg]
        panel.message = "Выберите изображения PNG или JPEG. Распознавание выполняется на этом Mac."
        let destination = model.diagramGroups.defaultID
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.importURLs(panel.urls, groupID: destination)
        }
    }

    func importURLs(_ urls: [URL], groupID: String? = nil) {
        let destination = groupID ?? model.diagramGroups.defaultID
        for url in urls { enqueueImport(groupID: destination) { url } }
    }

    @discardableResult
    func importProviders(_ providers: [NSItemProvider], groupID: String? = nil) -> Bool {
        guard !model.preparingStorage, !model.shuttingDown, !providers.isEmpty else { return false }
        let destination = groupID ?? model.diagramGroups.defaultID
        for provider in providers {
            let request = DroppedFileURL.start(provider)
            enqueueImport(groupID: destination, onDiscard: { request.cancel() }) { try await request.value() }
        }
        return true
    }

    private func enqueueImport(groupID: String, onDiscard: @escaping @MainActor () -> Void = {},
                               _ loadURL: @escaping @MainActor () async throws -> URL?) {
        guard !model.preparingStorage, !model.shuttingDown else { onDiscard(); return }
        do {
            try model.importQueue.enqueue(onDiscard: onDiscard) { [self] in
                do {
                    guard let url = try await loadURL() else {
                        throw ScribeError.message("Не удалось получить файл изображения")
                    }
                    try Task.checkCancellation()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let manifest = try await model.importDiagramImage(at: url, groupID: groupID)
                        await revealDiagram(manifest.id)
                    } catch let duplicate as DuplicateDiagram {
                        try Task.checkCancellation()
                        guard !model.shuttingDown else { return }
                        switch resolveDuplicateImport(duplicate) {
                        case .openExisting:
                            await revealDiagram(duplicate.id, revealThroughSearch: true)
                        case .importAgain:
                            let manifest = try await model.importDiagramImage(at: url, groupID: groupID, allowDuplicate: true)
                            await revealDiagram(manifest.id)
                        case .cancel:
                            break
                        }
                    }
                } catch { model.errorHandler.report(error) }
            }
        } catch {
            onDiscard()
            model.errorHandler.report(error)
        }
    }

    // MARK: - Export

    func exportRequest(part: DiagramExportPart, format: DiagramExportFormat) -> DiagramExportRequest? {
        guard let selected, let result, part == .all || resultTabs.contains(part) else { return nil }
        return DiagramExportRequest(diagram: selected, result: result, part: part, format: format)
    }

    func copy(_ part: DiagramExportPart) {
        guard let request = exportRequest(part: part, format: .plainText) else { return }
        model.copyResult { await request.render() }
    }

    func presentExportPanel(part: DiagramExportPart, format: DiagramExportFormat) {
        // Capture the entire request before AppKit starts the modal loop.
        guard let request = exportRequest(part: part, format: format) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .data]
        panel.nameFieldStringValue = request.filename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveExport(request, to: url)
    }

    @discardableResult
    func saveExport(_ request: DiagramExportRequest, to url: URL) -> Task<Void, Never> {
        model.saveResultExport(to: url) { await request.render() }
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
    func revealDiagram(_ id: String, revealThroughSearch: Bool = false) async {
        await model.reloadDiagrams()
        guard !Task.isCancelled, !model.shuttingDown, model.diagram(id) != nil else { return }
        if revealThroughSearch, search.active {
            await search.waitUntilIdle()
            if search.active, !search.matchingIDs.contains(id) { search.query = "" }
        }
        let groupID = model.diagramGroups.groupID(for: id)
        if search.active {
            search.setExpanded(groupID, true)
        } else if !model.deletingDiagramJobs,
                  model.diagramGroups.groups.contains(where: { $0.id == groupID && !$0.expanded }) {
            await model.changeDiagramGroups { try $0.setExpanded(groupID, true) }
        }
        guard !Task.isCancelled, !model.shuttingDown, model.diagram(id) != nil else { return }
        selection = id; sidebarRevealID = id
    }
    func deleteSelected(_ ids: Set<String>) async {
        // Another window may have deleted some of the confirmed diagrams.
        await model.deleteDiagrams(ids.filter { model.diagram($0) != nil })
        reconcileSelectionAfterDeletion()
    }
    func deleteGroup(_ id: String, deleteDiagrams: Bool) async {
        await model.deleteDiagramGroup(id, deleteDiagrams: deleteDiagrams)
        if deleteDiagrams { reconcileSelectionAfterDeletion() }
    }
    private func reconcileSelectionAfterDeletion() {
        if let selection, model.diagram(selection) == nil { self.selection = nil }
        var retained = sidebarSelection
        retained.retain(Set(model.diagrams.map(\.id)))
        if retained != sidebarSelection { sidebarSelection = retained }
    }
}

/// Internal drag types of the diagram archive; cross-mode drags are impossible
/// because the identifiers differ from the recording types.
enum DiagramTransferTypes {
    static let diagram = UTType(exportedAs: "app.localscribe.diagram", conformingTo: .data)
    static let group = UTType(exportedAs: "app.localscribe.diagram.group", conformingTo: .data)
}
