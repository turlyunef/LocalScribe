import SwiftUI
import AppKit
import Combine
import LocalScribeCore

/// Prepared UTF-16 highlight range of one panel, built off the main actor from
/// the scalar archive coordinates. Plain values keep the presentation Sendable.
struct PanelHighlightRange: Equatable, Sendable {
    let location: Int
    let length: Int
    init(nsRange: NSRange) {
        location = nsRange.location
        length = nsRange.length
    }
    var nsRange: NSRange { NSRange(location: location, length: length) }
}

/// One jump request into a panel editor: a fresh identity makes repeated
/// clicks on the same warning target scroll and select again.
struct PanelJumpRequest: Equatable {
    let id = UUID()
    let range: PanelHighlightRange
}

/// Prepared content of one text panel: the current version text plus the
/// visible highlight ranges of the replacement pairs (AC-28). `revisionID`
/// keys the presentation against the archive; the text slices are kept for
/// warnings/tests and never re-derive the document.
struct AnonymizationPanelContent: Equatable, Sendable {
    let revisionID: String
    let text: String
    let highlights: [PanelHighlightRange]
    let highlightSlices: [String]
}

struct AnonymizationRestorationPanels: Sendable {
    let source: AnonymizationPanelContent
    let result: AnonymizationPanelContent
}

/// One warning of the published result prepared for display: the localized
/// title, the verbatim fragment (user text — never rephrased), the traceable
/// review position in the current right text and the exact uninterpreted type
/// wording (AC-46/47).
struct AnonymizationWarningItem: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let fragment: String?
    let jump: PanelHighlightRange?
    let uninterpretedType: String?
}

/// Mode state of one open anonymization card (work 10). It owns the loaded
/// document, the panel presentations and edit commits; the archive, queue and
/// publication stay in `AppModel`/`AnonymizationCoordinator`. Text and ranges
/// are prepared off the main actor like `ResultPresentation` does; an async
/// answer is applied only while the card identity and the exact content key
/// are still current, and switching cards clears the panels at once.
@MainActor final class AnonymizationCardEditor: ObservableObject {

    let model: AppModel
    private var summariesCancellable: AnyCancellable?

    @Published private(set) var cardID: String?
    @Published private(set) var document: AnonymizationCardDocument?
    @Published private(set) var loadFailure: String?
    @Published private(set) var sourcePanel: AnonymizationPanelContent?
    @Published private(set) var resultPanel: AnonymizationPanelContent?
    @Published private(set) var restorationPanels: AnonymizationRestorationPanels?
    @Published private(set) var warnings: [AnonymizationWarningItem] = []
    @Published private(set) var jumpRequest: PanelJumpRequest?

    /// Consent dialog seam (AC-18): replacing a manually edited right version
    /// asks the user; tests inject deterministic answers.
    var confirmReplaceEditedResult: (String) -> Bool = { _ in presentReplaceConfirmation() }

    init(model: AppModel) {
        self.model = model
        // @Published emits the incoming (new) array before assignment, so the
        // signature is read from the emitted value itself.
        summariesCancellable = model.$textCards.sink { [weak self] cards in
            guard let self, let id = self.cardID else { return }
            guard let summary = cards.first(where: { $0.id == id }) else {
                // The card left the archive (deleted or unreadable): clear at
                // once so no stale text stays interactive.
                self.clearForVanishedCard()
                return
            }
            let signature = SummarySignature(summary)
            guard signature != self.observedSummary else { return }
            self.observedSummary = signature
            _ = self.serialized { await self.reloadDocument() }
        }
    }

    // MARK: - Activation and loading

    /// Opens one card. Switching cards first clears the previous presentation
    /// and runs after every pending edit of the previous card has landed in
    /// the archive, so unsaved drafts cannot leak into the next card.
    func activate(_ id: String?) async {
        let task = serialized {
            guard self.cardID != id else { return }
            self.cardID = id
            self.observedSummary = nil
            self.clearPanels()
            guard id != nil else { return }
            await self.reloadDocument()
        }
        await task.value
    }

    /// Waits until every queued edit/activation finished (used before a retry
    /// freezes the source snapshot).
    func flushEdits() async {
        if let chain { await chain.value }
    }

    private func reloadDocument() async {
        guard let id = cardID, let archive = model.textArchive else { clearPanels(); return }
        do {
            let loaded = try await archive.loadCard(id)
            guard cardID == id else { return }
            observedSummary = SummarySignature(AnonymizationCardSummary(document: loaded))
            applyDocument(loaded)
        } catch {
            guard cardID == id else { return }
            clearPanels()
            let reason = (error as? ScribeError)?.errorDescription ?? "Не удалось прочитать карточку обезличивания"
            loadFailure = L10n.message(reason ?? "Не удалось прочитать карточку обезличивания")
            model.errorHandler.report(error)
        }
    }

    private func applyDocument(_ doc: AnonymizationCardDocument) {
        let restorationChanged = document?.restoration?.result.id != doc.restoration?.result.id
        document = doc
        loadFailure = nil
        rebuildPanels()
        if restorationChanged { rebuildRestorationPanels(cardID: doc.id, restoration: doc.restoration) }
    }

    private func clearPanels() {
        document = nil
        loadFailure = nil
        presentationKey = nil
        sourcePanel = nil
        resultPanel = nil
        restorationPanels = nil
        warnings = []
        jumpRequest = nil
    }

    private func clearForVanishedCard() {
        cardID = nil
        observedSummary = nil
        clearPanels()
    }

    // MARK: - Editable state (domain invariant 7 / AC-38)

    /// QUEUED and RUNNING lock both panels to reading and copying.
    var panelsLocked: Bool {
        guard let attempt = document?.latestAttempt else { return false }
        return attempt.state == .queued || attempt.state == .running
    }
    var sourceEditable: Bool { document != nil && !panelsLocked }
    var resultEditable: Bool {
        guard let document, document.publishedResult != nil, !panelsLocked else { return false }
        // A retry that waits for the model keeps the right panel read-only
        // until it resolves; the consent stays bound to its version.
        if document.latestAttempt.state == .waitingModel,
           document.latestAttempt.expectedResultRevisionID != nil { return false }
        return true
    }
    /// An explicit retry is pending (queued, running or waiting for the model)
    /// while a previous result stays published.
    var pendingRetryWaitsForModel: Bool {
        guard let attempt = document?.latestAttempt else { return false }
        return attempt.state == .waitingModel && attempt.expectedResultRevisionID != nil
    }
    var showsPreviousResultDuringRun: Bool {
        document?.publishedResult != nil && (panelsLocked || pendingRetryWaitsForModel)
    }

    // MARK: - Result notices (AC-14/17/18/44)

    var hasPublishedResult: Bool { document?.publishedResult != nil }
    /// The result was built from an earlier left version (revision ids, never
    /// content comparison).
    var resultBuiltFromEarlierSource: Bool { document?.resultBuiltFromEarlierSource ?? false }
    /// The right panel carries manual edits after publication.
    var resultManuallyEdited: Bool { document?.resultManuallyEdited ?? false }
    /// No replacements in the body and no warnings: the right panel shows the
    /// full text plus the «not found» message, even when only the imported
    /// name was anonymized (AC-14).
    var showsNoMatchesMessage: Bool {
        guard let result = document?.publishedResult else { return false }
        return result.bodyReplacementCount == 0 && result.warnings.isEmpty
    }

    // MARK: - Failure of the latest attempt (AC-10/42)

    var failureIsSizeLimit: Bool {
        guard let attempt = document?.latestAttempt else { return false }
        return attempt.state == .failed && attempt.failure?.kind == .sizeLimit
    }
    var failureText: String? {
        guard let attempt = document?.latestAttempt,
              attempt.state == .failed, let failure = attempt.failure else { return nil }
        switch failure.kind {
        case .sizeLimit:
            if let actual = failure.actualBytes, let limit = failure.limitBytes {
                return L10n.text("Размер текста %1$@ превышает предел %2$@ для выбранной модели",
                                 Self.sizeText(actual), Self.sizeText(limit))
            }
            return L10n.text("Текст превышает предел размера для выбранной модели")
        case .processing:
            return L10n.message(failure.reason ?? "Ошибка обработки")
        }
    }
    static func sizeText(_ bytes: UInt) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(L10n.locale))
    }

    // MARK: - Edits (work 7 mechanism: edit → ScalarEdit → coordinator)

    /// One left-panel edit: it commits through the coordinator as an atomic
    /// document write and never starts an attempt by itself (AC-17).
    func applySourceEdit(_ edit: ScalarEdit) async {
        await performEdit { archive, id in try await archive.editSource(id, edit) }
    }
    /// One right-panel edit: requires a published result; pairs and warning
    /// review positions follow in the same transaction (AC-16/29).
    func applyResultEdit(_ edit: ScalarEdit) async {
        await performEdit { archive, id in try await archive.editResult(id, edit) }
    }
    private func performEdit(_ commit: @escaping @MainActor (AnonymizationCoordinator, String) async throws -> AnonymizationCardDocument) async {
        guard let id = cardID, let archive = model.textArchive, document != nil else { return }
        let task = serialized { [self] in
            guard self.cardID == id, self.document != nil else { return }
            do {
                let updated = try await commit(archive, id)
                guard self.cardID == id else { return }
                self.observedSummary = SummarySignature(AnonymizationCardSummary(document: updated))
                self.applyDocument(updated)
            } catch {
                // The local editor text may have diverged from the archive
                // (e.g. a stale range): report and resync from the document.
                self.model.errorHandler.report(error)
                await self.reloadDocument()
            }
        }
        await task.value
    }

    // MARK: - Retry (AC-17/18)

    /// «Обезличить заново»: the last local edits land first, then a manually
    /// edited right version asks for consent bound to its revision id. A
    /// refusal keeps the current text and starts nothing.
    func retry() async {
        guard let id = cardID else { return }
        await flushEdits()
        guard cardID == id else { return }
        switch await model.anonymizationRetryConsent(for: id) {
        case .notNeeded:
            await model.retryAnonymization(cardID: id)
        case .needed(let currentRevisionID):
            guard confirmReplaceEditedResult(currentRevisionID) else { return }
            await model.retryAnonymization(cardID: id, confirmingResultRevisionID: currentRevisionID)
        }
    }

    // MARK: - Warnings (AC-46/47)

    func requestWarningJump(_ warning: AnonymizationWarningItem) {
        guard let range = warning.jump else { return }
        jumpRequest = PanelJumpRequest(range: range)
    }

    func clearWarningJump() {
        jumpRequest = nil
    }

    // MARK: - Panel preparation (off the main actor, keyed by content)

    private struct PresentationKey: Equatable {
        let cardID: String
        let sourceRevision: String
        let resultTextRevision: String?
        let resultGeneratedRevision: String?
        let pairs: [ReplacementPair]
        let warnings: [AnonymizationWarning]
        init(_ document: AnonymizationCardDocument) {
            cardID = document.id
            sourceRevision = document.source.id
            resultTextRevision = document.publishedResult?.text.id
            resultGeneratedRevision = document.publishedResult?.generatedText.id
            pairs = document.publishedResult?.pairs ?? []
            warnings = document.publishedResult?.warnings ?? []
        }
    }
    private var presentationKey: PresentationKey?
    private var presentationLoad = UUID()

    private func rebuildPanels() {
        guard let document else { clearPanels(); return }
        let key = PresentationKey(document)
        guard key != presentationKey else { return }
        presentationKey = key
        let load = UUID()
        presentationLoad = load
        let snapshot = PanelSnapshot(document)
        let cardID = document.id
        Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                Self.preparePanels(snapshot)
            }.value
            // A late answer is dropped when the card, the load or the content
            // key has moved on; the previous presentation stays until the
            // current one is ready.
            guard let self, self.cardID == cardID, self.presentationLoad == load,
                  self.presentationKey == key else { return }
            self.sourcePanel = prepared.source
            self.resultPanel = prepared.result
            self.warnings = prepared.warnings
        }
    }

    private struct PanelSnapshot: Sendable {
        let source: TextRevision
        let result: AnonymizationResult?
        let importedNameStem: String
        init(_ document: AnonymizationCardDocument) {
            source = document.source
            result = document.publishedResult
            importedNameStem = document.importedNameStem
        }
    }

    private func rebuildRestorationPanels(cardID: String, restoration: AnonymizationRestoration?) {
        guard let restoration else { restorationPanels = nil; return }
        Task { [weak self] in
            let panels = await Task.detached(priority: .userInitiated) {
                AnonymizationRestorationPanels(
                    source: Self.restorationPanel(restoration.source, ranges: restoration.pairs.map(\.sourceRange)),
                    result: Self.restorationPanel(restoration.result, ranges: restoration.pairs.map(\.resultRange)))
            }.value
            guard let self, self.cardID == cardID,
                  self.document?.restoration?.result.id == restoration.result.id else { return }
            self.restorationPanels = panels
        }
    }

    nonisolated private static func restorationPanel(_ revision: TextRevision,
                                                     ranges: [LocalScribeCore.TextRange]) -> AnonymizationPanelContent {
        let bridge = TextUTF16Bridge(text: revision.text)
        let text = revision.text as NSString
        let converted = ranges.compactMap(bridge.nsRange)
        return AnonymizationPanelContent(revisionID: revision.id, text: revision.text,
                                         highlights: converted.map(PanelHighlightRange.init(nsRange:)),
                                         highlightSlices: converted.map(text.substring(with:)))
    }
    private struct PreparedPanels: Sendable {
        let source: AnonymizationPanelContent
        let result: AnonymizationPanelContent?
        let warnings: [AnonymizationWarningItem]
    }

    /// Scalar→UTF-16 conversion and text slices of every pair and warning,
    /// built away from the main actor over one document snapshot.
    nonisolated private static func preparePanels(_ snapshot: PanelSnapshot) -> PreparedPanels {
        let sourceText = snapshot.source.text
        let sourceBridge = TextUTF16Bridge(text: sourceText)
        var sourceHighlights: [PanelHighlightRange] = []
        var sourceSlices: [String] = []
        if let result = snapshot.result {
            for pair in result.pairs {
                if let range = sourceBridge.nsRange(from: pair.sourceRange) {
                    sourceHighlights.append(PanelHighlightRange(nsRange: range))
                    sourceSlices.append(scalarSlice(sourceText, pair.sourceRange))
                }
            }
        }
        let source = AnonymizationPanelContent(revisionID: snapshot.source.id, text: sourceText,
                                               highlights: sourceHighlights, highlightSlices: sourceSlices)
        guard let result = snapshot.result else {
            return PreparedPanels(source: source, result: nil, warnings: [])
        }
        let resultText = result.text.text
        let resultBridge = TextUTF16Bridge(text: resultText)
        var resultHighlights: [PanelHighlightRange] = []
        var resultSlices: [String] = []
        for pair in result.pairs {
            if let range = resultBridge.nsRange(from: pair.resultRange) {
                resultHighlights.append(PanelHighlightRange(nsRange: range))
                resultSlices.append(scalarSlice(resultText, pair.resultRange))
            }
        }
        let preparedResult = AnonymizationPanelContent(revisionID: result.text.id, text: resultText,
                                                       highlights: resultHighlights, highlightSlices: resultSlices)
        var items: [AnonymizationWarningItem] = []
        let generatedMatchesCurrent = resultText == result.generatedText.text
        for (index, warning) in result.warnings.enumerated() {
            switch warning.kind {
            case .doubtfulFragment:
                if warning.target == .importedName {
                    let fragment = warning.inputRange.map { scalarSlice(snapshot.importedNameStem, $0) }
                    items.append(AnonymizationWarningItem(
                        id: index,
                        title: L10n.text("Проверьте имя файла перед скачиванием"),
                        fragment: fragment, jump: nil, uninterpretedType: nil))
                } else {
                    var jump: PanelHighlightRange?
                    var fragment: String?
                    if let review = warning.reviewRange, let range = resultBridge.nsRange(from: review) {
                        jump = PanelHighlightRange(nsRange: range)
                        fragment = scalarSlice(resultText, review)
                    } else if generatedMatchesCurrent, let generated = warning.generatedRange,
                              let range = resultBridge.nsRange(from: generated) {
                        // The trace was lost, but the automatic version equals
                        // the current text, so its position is still exact.
                        jump = PanelHighlightRange(nsRange: range)
                        fragment = scalarSlice(resultText, generated)
                    } else if let generated = warning.generatedRange {
                        // Lost trace and an edited right text: show the place
                        // of the automatic version without a jump.
                        fragment = scalarSlice(result.generatedText.text, generated)
                    }
                    items.append(AnonymizationWarningItem(
                        id: index,
                        title: L10n.text("Проверьте перед скачиванием: сомнительный фрагмент"),
                        fragment: fragment, jump: jump, uninterpretedType: nil))
                }
            case .uninterpretedType:
                // The exact saved wording is shown verbatim (AC-47).
                items.append(AnonymizationWarningItem(
                    id: index,
                    title: L10n.text("Модель не поняла тип данных"),
                    fragment: nil, jump: nil, uninterpretedType: warning.dataType))
            }
        }
        return PreparedPanels(source: source, result: preparedResult, warnings: items)
    }

    nonisolated private static func scalarSlice(_ text: String, _ range: LocalScribeCore.TextRange) -> String {
        let scalars = text.unicodeScalars
        let startOffset = Int(range.start), endOffset = Int(range.end)
        guard startOffset >= 0, startOffset <= endOffset, endOffset <= scalars.count else { return "" }
        let start = scalars.index(scalars.startIndex, offsetBy: startOffset)
        let end = scalars.index(scalars.startIndex, offsetBy: endOffset)
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    // MARK: - Serialization

    /// All document mutations (edits, activations, reloads) run in one FIFO so
    /// the coordinator never sees interleaved read-modify-write cycles, and a
    /// card switch always happens after the previous card's last edit.
    private var chain: Task<Void, Never>?
    @discardableResult
    private func serialized(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = chain
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await operation()
        }
        chain = task
        return task
    }

    private struct SummarySignature: Equatable {
        let state: AnonymizationAttemptState
        let hasResult: Bool
        let warningCount: Int
        let bodyReplacements: UInt?
        let displayName: String
        let restorationResultRevisionID: String?
        init(_ summary: AnonymizationCardSummary) {
            state = summary.attemptState
            hasResult = summary.hasPublishedResult
            warningCount = summary.resultWarningCount
            bodyReplacements = summary.bodyReplacementCount
            displayName = summary.displayName
            restorationResultRevisionID = summary.restorationResultRevisionID
        }
    }
    private var observedSummary: SummarySignature?

    /// The AC-18 consent dialog for replacing a manually edited result.
    @MainActor static func presentReplaceConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.text("Заменить правленый результат?")
        alert.informativeText = L10n.text("Текущий текст справа останется в карточке, пока новая обработка не завершится успешно.")
        alert.addButton(withTitle: L10n.text("Обезличить заново"))
        alert.addButton(withTitle: L10n.text("Отмена"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The AppKit half of one panel editor: an NSTextView with the blue accent
/// background on the pair ranges (the shade is verified in the finished
/// `.app`, XCTest checks presence and ranges). Edits are applied optimistically
/// by the view itself for a responsive caret; the same `ScalarEdit` — computed
/// against the live text, which always matches the already-queued commits — is
/// forwarded to the editor, whose serialized commits keep the archive in step.
/// QUEUED/RUNNING switch the view to read-only while staying copyable.
struct AnonymizationTextEditor: NSViewRepresentable {
    struct Value: Equatable {
        let revisionID: String
        let text: String
        let highlights: [PanelHighlightRange]
        init(_ content: AnonymizationPanelContent) {
            revisionID = content.revisionID
            text = content.text
            highlights = content.highlights
        }
    }

    let value: Value?
    let editable: Bool
    let jump: PanelJumpRequest?
    var scrollSync: AnonymizationScrollSync? = nil
    var scrollSide: AnonymizationScrollSync.Side = .left
    let onEdit: (ScalarEdit) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isSelectable = true
        view.allowsUndo = false
        view.isRichText = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.font = NSFont.systemFont(ofSize: 13)
        view.textColor = NSColor.labelColor
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        context.coordinator.connect(scroll, to: scrollSync, side: scrollSide)
        context.coordinator.onEdit = onEdit
        view.isEditable = editable
        guard let value else {
            if context.coordinator.revision != nil {
                view.textStorage?.beginEditing()
                view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: view.textStorage?.length ?? 0), with: "")
                view.textStorage?.endEditing()
                context.coordinator.revision = nil
                context.coordinator.highlights = []
            }
            return
        }
        if context.coordinator.revision != value.revisionID || view.string != value.text {
            context.coordinator.revision = value.revisionID
            context.coordinator.highlights = value.highlights
            let storage = view.textStorage!
            let previousSelection = view.selectedRange()
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: value.text)
            Self.applyAttributes(to: storage, highlights: value.highlights)
            storage.endEditing()
            // A locally typed edit comes back with identical text, so this
            // branch only runs for external changes (publication, retry,
            // resync): keep the caret where the user left it, clamped.
            let utf16 = (value.text as NSString).length
            let location = min(previousSelection.location, utf16)
            view.setSelectedRange(NSRange(location: location, length: min(previousSelection.length, utf16 - location)))
        } else if context.coordinator.highlights != value.highlights {
            context.coordinator.highlights = value.highlights
            view.textStorage!.beginEditing()
            Self.applyAttributes(to: view.textStorage!, highlights: value.highlights)
            view.textStorage!.endEditing()
        }
        if let jump, context.coordinator.handledJump != jump.id {
            context.coordinator.handledJump = jump.id
            let range = jump.range.nsRange
            guard NSMaxRange(range) <= (view.textStorage?.length ?? 0) else { return }
            view.scrollRangeToVisible(range)
            view.setSelectedRange(range)
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.connect(scroll, to: nil, side: .left)
    }

    /// Rebuilds all attributes in place — never touching characters or
    /// selection, so refreshes of the same version are invisible to the user.
    private static func applyAttributes(to storage: NSTextStorage, highlights: [PanelHighlightRange]) {
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes([.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor], range: full)
        let tint = NSColor.controlAccentColor.withAlphaComponent(0.22)
        for highlight in highlights {
            let range = highlight.nsRange
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= full.length else { continue }
            storage.addAttribute(.backgroundColor, value: tint, range: range)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onEdit: (ScalarEdit) -> Void
        var revision: String?
        var highlights: [PanelHighlightRange] = []
        var handledJump: UUID?
        private weak var scrollSync: AnonymizationScrollSync?
        private var scrollSide: AnonymizationScrollSync.Side = .left
        init(onEdit: @escaping (ScalarEdit) -> Void) { self.onEdit = onEdit }

        @MainActor func connect(_ scroll: NSScrollView, to sync: AnonymizationScrollSync?, side: AnonymizationScrollSync.Side) {
            guard scrollSync !== sync || scrollSide != side else { return }
            scrollSync?.disconnect(scroll, side: scrollSide)
            scrollSync = sync
            scrollSide = side
            sync?.connect(scroll, side: side)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard textView.isEditable, let replacement = replacementString else { return textView.isEditable }
            // The live string equals every already-queued edit (optimistic
            // apply + serialized commits), so its bridge yields the exact
            // coordinates of this edit's archive commit.
            let bridge = TextUTF16Bridge(text: textView.string)
            guard let edit = bridge.edit(fromSelectedRange: affectedCharRange, replacement: replacement) else {
                return false
            }
            onEdit(edit)
            return true
        }
    }
}
