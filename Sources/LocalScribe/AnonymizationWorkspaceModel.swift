import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

/// Mode state of the text-anonymization workspace: selection, reveal and the
/// sidebar projections. The archive, snapshots and group transactions stay in
/// AppModel/AnonymizationCoordinator; this model never touches files itself.
/// The section keeps its own context (selection, search, expansion) that
/// survives switching to the recordings and diagrams sections.
@MainActor final class AnonymizationWorkspaceModel: ObservableObject {
    let model: AppModel
    /// The card editor of the open text card (work 10): it follows the
    /// selection, flushing pending edits of the previous card into the archive
    /// before loading the next one.
    let cardEditor: AnonymizationCardEditor
    init(model: AppModel) {
        self.model = model
        self.cardEditor = AnonymizationCardEditor(model: model)
        // Work 12 (AC-19): the download menu acts through this handler.
        // Tests may replace it to observe the menu wiring.
        requestTextDownload = { [weak self] cardID, format in
            self?.downloadText(cardID, format: format)
        }
    }

    /// The download menu of the card calls this handler (work 12); the items
    /// stay disabled while it is nil.
    var requestTextDownload: ((String, AnonymizationTextDownloadFormat) -> Void)?

    @Published var selection: String? {
        didSet {
            sidebarSelection = SidebarSelection(selection)
            retainSearchSelection()
            if oldValue != selection {
                if !revealingProgrammatically {
                    // Any navigation outside the import reveal (a manual row
                    // pick, Esc, keyboard shortcuts) stops auto-opening.
                    importAutoRevealPermitted = false
                }
                let next = selection
                Task { await cardEditor.activate(next) }
            }
        }
    }
    @Published private(set) var sidebarSelection = SidebarSelection()
    @Published var sidebarRevealID: String?

    var search: RecordingSearch { model.anonymizationSearch }
    var selected: AnonymizationCardSummary? { selection.flatMap(model.textCard) }

    // MARK: - Sidebar projection

    var sidebarTextOrder: [String] {
        model.textGroups.groups.filter { search.expanded($0) }.flatMap { search.visible[$0.id] ?? [] }
    }
    func selectSidebarTextCard(_ id: String, command: Bool = false, shift: Bool = false) {
        importAutoRevealPermitted = false
        var next = sidebarSelection
        next.click(id, command: command, shift: shift, order: sidebarTextOrder)
        let primary = next.ids.contains(id) ? id : sidebarTextOrder.first { next.ids.contains($0) }
        if selection != primary { selection = primary }
        sidebarSelection = next
    }
    func selectSidebarContext(_ id: String) {
        importAutoRevealPermitted = false
        var next = sidebarSelection
        next.contextClick(id)
        if !next.ids.contains(selection ?? "") { selection = id }
        sidebarSelection = next
    }
    /// Up/Down arrows move the single selection through the currently visible
    /// sidebar order (collapsed groups are skipped); the chosen row is revealed.
    @discardableResult
    func moveSidebarSelection(down: Bool) -> Bool {
        guard let next = SidebarNeighbor.next(current: selection, in: sidebarTextOrder, down: down) else { return false }
        selectSidebarTextCard(next)
        sidebarRevealID = next
        return true
    }
    /// Mass actions operate on the current selection, narrowed to the current
    /// search results while a filter is active.
    func sidebarActionIDs(for id: String) -> Set<String> {
        let ids = sidebarSelection.ids.contains(id) ? sidebarSelection.ids : [id]
        return search.active && search.completed ? ids.intersection(search.matchingIDs) : ids
    }
    func visibleTextCards(in groupID: String) -> [AnonymizationCardSummary] {
        (search.visible[groupID] ?? []).compactMap(model.textCard)
    }
    func sidebarGroups(editing id: String?) -> [RecordingGroup] {
        model.textGroups.groups.filter {
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
        else { await model.changeTextGroups { try $0.setExpanded(group.id, !group.expanded) } }
    }
    func setAllSidebarExpanded(_ expanded: Bool) async {
        if search.active { search.setAllExpanded(expanded) }
        else { await model.changeTextGroups { $0.setAllExpanded(expanded) } }
    }
    // MARK: - Deletion (work 11)

    /// Confirmed card deletion through the archive transaction; afterwards the
    /// selection/sidebar keep only the cards that actually survive.
    func deleteCards(_ ids: Set<String>) async {
        await model.deleteTextCards(ids)
        reconcileSelectionAfterDeletion()
    }
    func deleteGroup(_ id: String, deleteFiles: Bool) async {
        await model.deleteTextGroup(id, deleteFiles: deleteFiles)
        if deleteFiles { reconcileSelectionAfterDeletion() }
    }
    private func reconcileSelectionAfterDeletion() {
        if let selection, model.textCard(selection) == nil { self.selection = nil }
        var retained = sidebarSelection
        retained.retain(Set(model.textCards.map(\.id)))
        if retained != sidebarSelection { sidebarSelection = retained }
    }
    func saveGroupName(_ name: String, id: String? = nil) async throws {
        guard let archive = model.textArchive else { throw ScribeError.message("Хранилище текстов недоступно") }
        try await archive.editGroups { catalog in
            if let id { try catalog.rename(id, name: name) }
            else { try catalog.create(name: name) }
        }
        await model.reloadTexts()
    }
    /// Select and reveal one card after an import or a duplicate resolution
    /// (used by work 6): expands its group, through the search filter when
    /// needed, and scrolls the row into view.
    func revealCard(_ id: String) async {
        await model.reloadTexts()
        guard !Task.isCancelled, !model.shuttingDown, model.textCard(id) != nil else { return }
        let groupID = model.textGroups.groupID(for: id)
        if search.active {
            await search.waitUntilIdle()
            if search.active, !search.matchingIDs.contains(id) { search.query = "" }
            search.setExpanded(groupID, true)
        } else if model.textGroups.groups.contains(where: { $0.id == groupID && !$0.expanded }) {
            await model.changeTextGroups { try $0.setExpanded(groupID, true) }
        }
        guard !Task.isCancelled, !model.shuttingDown, model.textCard(id) != nil else { return }
        revealingProgrammatically = true
        selection = id; sidebarRevealID = id
        revealingProgrammatically = false
    }

    // MARK: - Import (work 6)

    /// Auto-opening of imported cards runs sequentially while the user has
    /// not left the section or picked a card since the batch started
    /// (AC-36). Every new batch resets the permission; explicit navigation
    /// and section switching revoke it.
    @Published private(set) var importAutoRevealPermitted = true
    private var revealingProgrammatically = false
    func stopImportAutoReveal() { importAutoRevealPermitted = false }

    enum TextDuplicateAction { case openExisting, importSeparateCopy, cancel }
    /// The system file panel request: the message explains the accepted
    /// formats, `limitText` shows the effective import limit (AC-37).
    struct TextOpenPanelRequest: Sendable {
        let messageText: String
        let limitText: String
        var allowsMultipleSelection = true
    }

    /// Byte-identical duplicate resolution (AC-35); the test seam.
    var resolveDuplicateImport: (String) -> TextDuplicateAction = { _ in presentDuplicateImportAlert() }
    /// Ambiguous-encoding confirmation (AC-49); nil cancels this candidate.
    var resolveAmbiguousEncoding: ([TextDecodingOption], String) -> TextImportEncoding? = { options, _ in
        presentEncodingChoice(options)
    }
    /// The system open panel; tests inject delayed or cancelled outcomes.
    var chooseImportFiles: (TextOpenPanelRequest) async -> [URL]? = { request in
        await runOpenPanel(request)
    }

    /// The shown limit always mirrors the acting `AnonymizationInputLimit` of
    /// the assigned profile on this Mac; without an assignment the check is
    /// deferred and the text explains that (AC-37).
    var importLimitText: String {
        if let limit = model.anonymizationImportLimitBytes {
            return L10n.text("Предел размера файла: %1$@", Self.sizeText(limit))
        }
        return L10n.text("Предел размера файла станет известен после выбора модели")
    }
    static func sizeText(_ bytes: UInt) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(L10n.locale))
    }

    var canImportFiles: Bool { !model.preparingStorage && !model.shuttingDown && model.textArchive != nil }

    /// «Загрузить файл» in the section list and the empty workspace: the
    /// destination group is fixed before the panel opens, so a default-group
    /// change during the modal session cannot redirect the batch.
    func presentImportPanel() {
        guard canImportFiles else { return }
        let destination = model.defaultTextGroup.id
        let request = TextOpenPanelRequest(
            messageText: L10n.text("Выберите файлы TXT или Markdown. Обезличивание выполняется на этом Mac."),
            limitText: importLimitText)
        Task { [weak self] in
            guard let self, let urls = await self.chooseImportFiles(request), !urls.isEmpty else { return }
            self.importURLs(urls, groupID: destination)
        }
    }

    /// Panel results and Finder drops share one pipeline: the destination
    /// group and the batch order are fixed before any asynchronous loading.
    func importURLs(_ urls: [URL], groupID: String? = nil) {
        guard canImportFiles, !urls.isEmpty else { return }
        let destination = groupID ?? model.defaultTextGroup.id
        importAutoRevealPermitted = true
        for url in urls { enqueueCandidate(groupID: destination) { url } }
    }

    /// External file drops (Finder → group or workspace area) enter here.
    /// Provider loading starts synchronously in the drop callback; the queue
    /// still awaits and imports the resulting URLs in source order.
    @discardableResult
    func importProviders(_ providers: [NSItemProvider], groupID: String?) -> Bool {
        guard canImportFiles, !providers.isEmpty else { return false }
        let destination = groupID ?? model.defaultTextGroup.id
        importAutoRevealPermitted = true
        for provider in providers {
            let request = DroppedFileURL.start(provider)
            enqueueCandidate(groupID: destination, onDiscard: { request.cancel() }) { try await request.value() }
        }
        return true
    }

    private func enqueueCandidate(groupID: String, onDiscard: @escaping @MainActor () -> Void = {},
                                  _ loadURL: @escaping @MainActor () async throws -> URL?) {
        guard canImportFiles else { onDiscard(); return }
        do {
            try model.importQueue.enqueue(onDiscard: onDiscard) { [self] in
                await importCandidate(groupID: groupID, loadURL: loadURL)
            }
        } catch {
            onDiscard()
            model.errorHandler.report(error)
        }
    }

    /// One candidate of a batch. A rejection or cancellation skips only this
    /// file; the destination group is re-resolved by the coordinator, so a
    /// group deleted mid-batch lands the remainder in «Без темы».
    private func importCandidate(groupID: String, loadURL: @MainActor () async throws -> URL?) async {
        do {
            guard let url = try await loadURL() else {
                throw ScribeError.message("Не удалось получить файл для импорта")
            }
            try Task.checkCancellation()
            guard let format = AnonymizationSourceFormat.importFormat(pathExtension: url.pathExtension) else {
                throw ScribeError.message("Неподдерживаемый формат файла. Допустимы TXT и Markdown.")
            }
            let bytes = try await Self.readImportBytes(url)
            try Task.checkCancellation()
            if let limit = model.anonymizationImportLimitBytes, UInt(bytes.count) > limit {
                throw ScribeError.message("Файл больше предела для выбранной модели: размер \(Self.sizeText(UInt(bytes.count))) при пределе \(Self.sizeText(limit)).")
            }
            guard let text = try await decodeImportText(bytes, filename: url.lastPathComponent) else { return }
            try Task.checkCancellation()
            guard text.contains(where: { !$0.isWhitespace }) else {
                throw ScribeError.message("Файл пуст или состоит из одних пробелов.")
            }
            guard let archive = model.textArchive else { throw ScribeError.message("Хранилище текстов недоступно") }
            if let duplicate = await archive.findDuplicate(of: bytes) {
                try Task.checkCancellation()
                guard !model.shuttingDown else { return }
                switch resolveDuplicateImport(duplicate) {
                case .cancel:
                    return
                case .openExisting:
                    // Live duplicate search at decision time: a match deleted
                    // meanwhile resolves to the previous surviving card, and
                    // an emptied history imports a fresh card (AC-35).
                    if let surviving = await archive.findDuplicate(of: bytes) {
                        await revealCard(surviving)
                        return
                    }
                case .importSeparateCopy:
                    break
                }
            }
            let draft = AnonymizationCoordinator.ImportDraft(
                bytes: bytes,
                importedNameStem: url.deletingPathExtension().lastPathComponent,
                sourceFormat: format,
                source: TextRevision(id: UUID().uuidString, text: text))
            let summary = try await archive.importCard(draft, groupID: groupID)
            // A ready model starts the card's first attempt at once (AC-8);
            // otherwise the card stays outside the FIFO in «Ожидает модель»
            // until a readiness change wakes it (AC-30).
            await model.enqueueText(summary.id)
            if importAutoRevealPermitted, !Task.isCancelled, !model.shuttingDown {
                await revealCard(summary.id)
            } else {
                await model.reloadTexts()
            }
        } catch is CancellationError { }
        catch { model.errorHandler.report(error) }
    }

    private static func readImportBytes(_ url: URL, forRestoration: Bool = false) async throws -> Data {
        do {
            return try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let source = try ImportSource(url)
                defer { source.close() }
                if forRestoration, source.size > AnonymizationRestoration.maximumImportFileBytes {
                    throw ScribeError.message("Текст для обратного преобразования слишком большой для карточки")
                }
                return try source.readBytes()
            }.value
        } catch is POSIXError {
            throw ScribeError.message("Не удалось прочитать файл")
        }
    }

    private func decodeImportText(_ bytes: Data, filename: String) async throws -> String? {
        let decoding = await Task.detached(priority: .userInitiated) { TextImportDecoder.decode(bytes) }.value
        try Task.checkCancellation()
        guard !model.shuttingDown else { return nil }
        switch decoding {
        case .undecodable:
            throw ScribeError.message("Кодировка файла не поддерживается или повреждена. Допустимы UTF-8, UTF-16 с BOM и Windows-1251.")
        case .resolved(let option):
            return option.text
        case .ambiguous(let options):
            guard let encoding = resolveAmbiguousEncoding(options, filename) else { return nil }
            return options.first(where: { $0.encoding == encoding })?.text
        }
    }

    // MARK: - Restoration

    @Published private(set) var restorationBusyCardID: String?

    func canStartRestoration(_ cardID: String) -> Bool {
        canImportFiles && restorationBusyCardID == nil && selected?.id == cardID &&
            cardEditor.cardID == cardID && cardEditor.hasPublishedResult
    }

    func importRestoration(_ cardID: String) async {
        await updateRestoration(cardID) { archive in
            let expected = try await savedMappingRevisions(cardID)
            let request = TextOpenPanelRequest(
                messageText: L10n.text("Выберите файл TXT или Markdown для обратного преобразования."),
                limitText: "", allowsMultipleSelection: false)
            guard let url = await chooseImportFiles(request)?.first else { return false }
            try Task.checkCancellation()
            guard !model.shuttingDown else { return false }
            guard let format = AnonymizationSourceFormat.importFormat(pathExtension: url.pathExtension) else {
                throw ScribeError.message("Неподдерживаемый формат файла. Допустимы TXT и Markdown.")
            }
            let bytes = try await Self.readImportBytes(url, forRestoration: true)
            guard let text = try await decodeImportText(bytes, filename: url.lastPathComponent) else { return false }
            try Task.checkCancellation()
            guard !model.shuttingDown else { return false }
            try await archive.restoreText(cardID, text: text, sourceFormat: format,
                                          expectedResultID: expected.resultID, expectedSourceID: expected.sourceID)
            return true
        }
    }

    func pasteRestoration(_ cardID: String, pasteboard: NSPasteboard = .general) async {
        await updateRestoration(cardID) { archive in
            guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
                throw ScribeError.message("В буфере обмена нет текста.")
            }
            let expected = try await savedMappingRevisions(cardID)
            try await archive.restoreText(cardID, text: text, sourceFormat: .txt,
                                          expectedResultID: expected.resultID, expectedSourceID: expected.sourceID)
            return true
        }
    }

    func repeatRestoration(_ cardID: String) async {
        await updateRestoration(cardID) { archive in
            guard let expectedRestorationID = cardEditor.document?.restoration?.result.id else { return false }
            try await archive.repeatRestoration(cardID, expectedRestorationID: expectedRestorationID)
            return true
        }
    }

    private func savedMappingRevisions(_ cardID: String) async throws -> (resultID: String, sourceID: String) {
        await cardEditor.flushEdits()
        try Task.checkCancellation()
        guard !model.shuttingDown, cardEditor.cardID == cardID, let document = cardEditor.document,
              let result = document.publishedResult else { throw CancellationError() }
        return (result.text.id, document.source.id)
    }

    private func updateRestoration(_ cardID: String, operation: (AnonymizationCoordinator) async throws -> Bool) async {
        guard canStartRestoration(cardID), let archive = model.textArchive else { return }
        restorationBusyCardID = cardID
        defer { restorationBusyCardID = nil }
        do {
            try Task.checkCancellation()
            if try await operation(archive) { await model.reloadTexts(); await cardEditor.flushEdits() }
        } catch is CancellationError { }
        catch { model.errorHandler.report(error) }
    }

    // MARK: - Result export

    func copyText(_ cardID: String, to pasteboard: NSPasteboard = .general) {
        model.copyResult(to: pasteboard) { [weak self] in
            guard let snapshot = try await self?.exportSnapshot(cardID, format: .plainText) else {
                throw CancellationError()
            }
            return snapshot.resultText
        }
    }

    func copyRestoration(_ cardID: String, to pasteboard: NSPasteboard = .general) {
        model.copyResult(to: pasteboard) { [weak self] in
            guard let snapshot = try await self?.restorationSnapshot(cardID, format: .plainText) else {
                throw CancellationError()
            }
            return snapshot.resultText
        }
    }

    /// The system save panel of the download; it receives the frozen snapshot
    /// and returns the confirmed URL or nil on cancellation. Tests inject
    /// deterministic outcomes and never open a real panel (the import seam
    /// pattern of `chooseImportFiles`).
    var chooseDownloadURL: (AnonymizationExportSnapshot) async -> URL? = { snapshot in
        await runDownloadSavePanel(snapshot)
    }

    /// «Скачать» menu action (AC-19): the format choice flushes the pending
    /// right-panel edits, freezes the export snapshot and only then asks for
    /// the destination.
    func downloadText(_ cardID: String, format: AnonymizationTextDownloadFormat) {
        Task { [weak self] in await self?.performTextDownload(cardID, format: format) }
    }

    func downloadRestoration(_ cardID: String, format: AnonymizationTextDownloadFormat) {
        Task { [weak self] in await self?.performRestorationDownload(cardID, format: format) }
    }

    /// Flush → snapshot → panel → write. Everything after the snapshot works
    /// on the captured values: an edit saved later goes to the next export,
    /// and a cancelled panel creates no file (AC-19). Internal (not private)
    /// so tests await the whole flow deterministically.
    func performTextDownload(_ cardID: String, format: AnonymizationTextDownloadFormat) async {
        await performDownload { try await exportSnapshot(cardID, format: format) }
    }

    func performRestorationDownload(_ cardID: String, format: AnonymizationTextDownloadFormat) async {
        await performDownload { try await restorationSnapshot(cardID, format: format) }
    }

    private func performDownload(_ capture: () async throws -> AnonymizationExportSnapshot?) async {
        do {
            guard let snapshot = try await capture(), let url = await chooseDownloadURL(snapshot),
                  !model.shuttingDown else { return }
            // Save UTF-8 without BOM off the main actor, tracked for shutdown.
            model.saveResultExport(to: url) { await snapshot.renderedText() }
        } catch {
            model.errorHandler.report(error)
        }
    }

    private func restorationSnapshot(_ cardID: String, format: AnonymizationTextDownloadFormat) async throws
        -> AnonymizationExportSnapshot? {
        guard !model.shuttingDown, let archive = model.textArchive else { return nil }
        let document = try await archive.loadCard(cardID)
        try Task.checkCancellation()
        guard !model.shuttingDown, let result = document.restoration else { return nil }
        return AnonymizationExportSnapshot(resultText: result.result.text, sourceFormat: result.sourceFormat,
                                           outputFormat: format, suggestedNameStem: document.importedNameStem)
    }

    private func exportSnapshot(_ cardID: String, format: AnonymizationTextDownloadFormat) async throws
        -> AnonymizationExportSnapshot? {
        guard !model.shuttingDown, let archive = model.textArchive else { return nil }
        await cardEditor.flushEdits()
        try Task.checkCancellation()
        guard !model.shuttingDown else { return nil }
        let document = try await archive.loadCard(cardID)
        guard let result = document.publishedResult else { return nil }
        try AnonymizationCardDocument.validateFileStem(result.downloadNameStem)
        return AnonymizationExportSnapshot(
            resultText: result.text.text,
            sourceFormat: document.sourceFormat,
            outputFormat: format,
            suggestedNameStem: result.downloadNameStem)
    }

    // MARK: - System panels and dialogs

    private static func runOpenPanel(_ request: TextOpenPanelRequest) async -> [URL]? {
        guard let window = NSApp.keyWindow else { return nil }
        return await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = request.allowsMultipleSelection
            // `UTType.markdown` needs a newer SDK floor; the filename
            // extension covers both .md and .markdown on this target.
            panel.allowedContentTypes = [.plainText] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
            panel.message = request.limitText.isEmpty ? request.messageText : request.messageText + "\n" + request.limitText
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.urls : nil)
            }
        }
    }

    /// The save panel proposes the snapshot's filename with the chosen
    /// extension; the user may change the name freely; nil means cancellation.
    private static func runDownloadSavePanel(_ snapshot: AnonymizationExportSnapshot) async -> URL? {
        guard let window = NSApp.keyWindow else { return nil }
        return await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            // `UTType.markdown` needs a newer SDK floor; the filename
            // extension covers .md on this target (the import-panel pattern).
            panel.allowedContentTypes = [UTType(filenameExtension: snapshot.outputFormat.rawValue) ?? .plainText]
            panel.nameFieldStringValue = snapshot.suggestedFilename
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    @MainActor static func presentDuplicateImportAlert() -> TextDuplicateAction {
        let alert = NSAlert()
        alert.messageText = L10n.text("Такой текст уже есть в архиве")
        alert.informativeText = L10n.text("Можно открыть сохранённую карточку с правками или добавить независимую копию.")
        alert.addButton(withTitle: L10n.text("Открыть существующую"))
        alert.addButton(withTitle: L10n.text("Импортировать отдельной копией"))
        alert.addButton(withTitle: L10n.text("Отмена"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .openExisting
        case .alertSecondButtonReturn: return .importSeparateCopy
        default: return .cancel
        }
    }

    /// Encoding confirmation with a preview: switching the encoding switches
    /// the shown text; «Загрузить» saves exactly the shown variant, «Отмена»
    /// creates nothing (AC-49).
    @MainActor static func presentEncodingChoice(_ options: [TextDecodingOption]) -> TextImportEncoding? {
        final class PreviewController: NSObject {
            let options: [TextDecodingOption]
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
            init(options: [TextDecodingOption]) {
                self.options = options
                super.init()
                for option in options { popup.addItem(withTitle: option.encoding.displayName) }
                popup.target = self
                popup.action = #selector(popupChanged)
                textView.isEditable = false
                textView.isSelectable = true
                textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                show(at: 0)
            }
            @objc private func popupChanged() { show(at: popup.indexOfSelectedItem) }
            private func preview(_ text: String) -> String {
                let limit = 2000
                return text.count <= limit ? text : String(text.prefix(limit)) + "…"
            }
            func show(at index: Int) {
                guard options.indices.contains(index) else { return }
                textView.string = preview(options[index].text)
            }
            var selected: TextImportEncoding? {
                guard options.indices.contains(popup.indexOfSelectedItem) else { return nil }
                return options[popup.indexOfSelectedItem].encoding
            }
        }
        let controller = PreviewController(options: options)
        let scroll = NSScrollView()
        scroll.documentView = controller.textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        controller.popup.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [controller.popup, scroll])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 440),
            scroll.heightAnchor.constraint(equalToConstant: 160)
        ])
        let alert = NSAlert()
        alert.messageText = L10n.text("Выберите кодировку файла")
        alert.informativeText = L10n.text("Кодировка не определена однозначно. Выберите вариант и проверьте текст.")
        alert.accessoryView = stack
        alert.addButton(withTitle: L10n.text("Загрузить"))
        alert.addButton(withTitle: L10n.text("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return controller.selected
    }
}

/// Download formats of the text card (AC-19): the raw value is the filename
/// extension of the suggested download name.
enum AnonymizationTextDownloadFormat: String, Sendable {
    case markdown = "md"
    case plainText = "txt"
}

/// The frozen export snapshot of one download (the domain `ExportSnapshot`):
/// the right version at the format choice, the card's import format, the
/// chosen output format and the suggested name stem of the published result.
/// The snapshot lives within the single operation — later edits never reach
/// its file (AC-19).
struct AnonymizationExportSnapshot: Equatable, Sendable {
    let resultText: String
    let sourceFormat: AnonymizationSourceFormat
    let outputFormat: AnonymizationTextDownloadFormat
    let suggestedNameStem: String

    /// The panel proposal: the result's stem plus the chosen extension; the
    /// user may change the name (AC-34).
    var suggestedFilename: String { suggestedNameStem + "." + outputFormat.rawValue }

    /// Rendering runs off the main actor like `ResultPresentation`; the
    /// captured text is the only input, so the answer is deterministic.
    func renderedText() async -> String {
        let snapshot = self
        return await Task.detached(priority: .userInitiated) {
            AnonymizationTextExport.render(snapshot.resultText,
                                           sourceFormat: snapshot.sourceFormat,
                                           outputFormat: snapshot.outputFormat)
        }.value
    }
}

/// Deterministic serializers of a frozen export snapshot (work 12). MARKDOWN
/// → `.md` and TXT → both keep the captured right version verbatim; MARKDOWN
/// → `.txt` degrades the markup into readable text (AC-32). Replacement pairs
/// and warnings are presentation-only and never reach the file (AC-28).
enum AnonymizationTextExport {

    static func render(_ text: String, sourceFormat: AnonymizationSourceFormat,
                       outputFormat: AnonymizationTextDownloadFormat) -> String {
        guard sourceFormat == .markdown, outputFormat == .plainText else { return text }
        return plainText(fromMarkdown: text)
    }

    /// Line structure and every character outside the recognized constructs
    /// pass through verbatim; ATX headings, emphasis/code delimiters and
    /// `[подпись](адрес)` links lose their service markers. A link degrades to
    /// the visible `подпись (адрес)` — hiding the address would hide
    /// anonymized data from the downloaded text.
    static func plainText(fromMarkdown text: String) -> String {
        var output = ""
        var line = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                output += Self.processLine(String(line))
                output.unicodeScalars.append(scalar)
                line = String.UnicodeScalarView()
            } else {
                line.append(scalar)
            }
        }
        if !line.isEmpty { output += Self.processLine(String(line)) }
        return output
    }

    private static func processLine(_ line: String) -> String {
        stripEmphasisAndCode(rewriteLinks(stripHeading(line)))
    }

    /// `# Заголовок` → `Заголовок`: an ATX marker (up to three leading spaces,
    /// 1–6 `#`, whitespace or end after it) disappears together with a single
    /// separating space.
    private static func stripHeading(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var index = 0
        while index < 3, index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
        var hashes = 0
        while hashes < 6, index + hashes < scalars.count, scalars[index + hashes] == "#" { hashes += 1 }
        guard hashes >= 1 else { return line }
        let after = index + hashes
        guard after == scalars.count || scalars[after] == " " || scalars[after] == "\t" else { return line }
        var content = after
        if content < scalars.count, scalars[content] == " " || scalars[content] == "\t" { content += 1 }
        return String(String.UnicodeScalarView(scalars[content...]))
    }

    /// `[подпись](адрес)` → `подпись (адрес)`; `![подпись](адрес)` drops the
    /// `!`. An empty side degrades to the other side alone; unmatched pieces
    /// stay verbatim.
    private static func rewriteLinks(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let isImage = scalars[index] == "!" && index + 1 < scalars.count && scalars[index + 1] == "["
            guard scalars[index] == "[" || isImage else {
                output.append(scalars[index])
                index += 1
                continue
            }
            let labelStart = index + (isImage ? 2 : 1)
            // A label with an inner `[` is not a link here.
            guard let labelEnd = (labelStart..<scalars.count).first(where: { scalars[$0] == "]" }),
                  labelEnd + 1 < scalars.count, scalars[labelEnd + 1] == "(",
                  let addressEnd = (labelEnd + 2..<scalars.count).first(where: { scalars[$0] == ")" }) else {
                output.append(scalars[index])
                index += 1
                continue
            }
            let label = String(String.UnicodeScalarView(scalars[labelStart..<labelEnd]))
            let address = String(String.UnicodeScalarView(scalars[labelEnd + 2..<addressEnd]))
            if !label.isEmpty && !address.isEmpty {
                output.append(contentsOf: (label + " (" + address + ")").unicodeScalars)
            } else {
                output.append(contentsOf: (label.isEmpty ? address : label).unicodeScalars)
            }
            index = addressEnd + 1
        }
        return String(output)
    }

    /// Paired `*`, `_` and backtick runs are delimiters: both sides of an
    /// emphasis/code span disappear. `*` and backticks pair anywhere; `_`
    /// never pairs inside a word, so identifiers like `snake_case` keep their
    /// underscores. An unmatched run stays verbatim.
    private static func stripEmphasisAndCode(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var output: [UnicodeScalar] = []
        var pending: [(marker: UnicodeScalar, length: Int, position: Int)] = []
        func isWord(_ scalar: UnicodeScalar?) -> Bool {
            guard let scalar else { return false }
            return scalar.properties.isAlphabetic || scalar.properties.numericType == .decimal
        }
        var index = 0
        while index < scalars.count {
            let marker = scalars[index]
            guard marker == "*" || marker == "_" || marker == "`" else {
                output.append(marker)
                index += 1
                continue
            }
            var length = 0
            while index + length < scalars.count, scalars[index + length] == marker { length += 1 }
            // Intraword `_` is a literal, never a delimiter (CommonMark rule).
            let canOpen = marker != "_" || !isWord(output.last)
            let canClose = marker != "_" || !isWord(index + length < scalars.count ? scalars[index + length] : nil)
            if canClose, let match = pending.lastIndex(where: { $0.marker == marker && $0.length == length }) {
                let opening = pending.remove(at: match)
                output.removeSubrange(opening.position..<(opening.position + length))
                // Later pending openings shift left by the removed run.
                for position in pending.indices where pending[position].position > opening.position {
                    pending[position].position -= length
                }
            } else if canOpen {
                pending.append((marker, length, output.count))
                output.append(contentsOf: scalars[index..<(index + length)])
            } else {
                output.append(contentsOf: scalars[index..<(index + length)])
            }
            index += length
        }
        return String(String.UnicodeScalarView(output))
    }
}

/// Internal drag types of the text archive; identical UUIDs of the recording
/// and diagram archives can never mix because the identifiers differ.
enum TextTransferTypes {
    static let card = UTType(exportedAs: "app.localscribe.text", conformingTo: .data)
    static let group = UTType(exportedAs: "app.localscribe.text.group", conformingTo: .data)
}

/// Row-facing status of a text card: the latest attempt decides the label,
/// warnings of the published result refine the success state (AC-10 wording;
/// the full card status view belongs to work 10).
extension AnonymizationCardSummary {
    var statusTitle: String {
        switch attemptState {
        case .waitingModel: return L10n.text("Ожидает модель")
        case .queued: return L10n.text("В очереди")
        case .running: return L10n.text("Обезличивается")
        case .succeeded: return resultWarningCount > 0 ? L10n.text("Готово с предупреждениями") : L10n.text("Готово")
        case .failed: return L10n.text("Ошибка")
        case .cancelled: return L10n.text("Отменено")
        case .interrupted: return L10n.text("Прерван — можно повторить")
        }
    }
    var statusIcon: String {
        switch attemptState {
        case .waitingModel: return "arrow.down.circle"
        case .queued: return "hourglass"
        case .running: return "sparkles"
        case .succeeded: return resultWarningCount > 0 ? "exclamationmark.triangle" : "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled, .interrupted: return "clock.badge.exclamationmark"
        }
    }
}
