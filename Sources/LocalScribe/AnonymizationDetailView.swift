import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

/// The selected text card with comparison, warnings and reverse transformation tabs.
struct AnonymizationDetailColumn: View {
    private enum Tab { case text, warnings, restoration }

    @ObservedObject var model: AppModel
    @ObservedObject var workspace: AnonymizationWorkspaceModel
    @ObservedObject private var editor: AnonymizationCardEditor
    @State private var tab = Tab.text
    @StateObject private var textScrollSync = AnonymizationScrollSync()
    @StateObject private var restorationScrollSync = AnonymizationScrollSync()
    /// Mount point of work 11: the trash button appears only when the host
    /// provides the deletion-confirmation handler.
    var requestDeletion: ((String) -> Void)?

    init(workspace: AnonymizationWorkspaceModel, requestDeletion: ((String) -> Void)? = nil) {
        _model = ObservedObject(wrappedValue: workspace.model)
        _workspace = ObservedObject(wrappedValue: workspace)
        _editor = ObservedObject(wrappedValue: workspace.cardEditor)
        self.requestDeletion = requestDeletion
    }

    var body: some View {
        Group {
            if let card = workspace.selected {
                cardBody(card)
            } else {
                ContentUnavailableView {
                    Label(L10n.text("Тексты"), systemImage: "doc.text")
                } description: {
                    Text(L10n.text("Выберите текст слева или перетащите файл TXT или Markdown"))
                } actions: {
                    VStack(spacing: 10) {
                        Button(L10n.text("Загрузить файл"), action: workspace.presentImportPanel)
                            .accessibilityIdentifier("texts.emptyImport")
                        Text(workspace.importLimitText)
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("texts.importLimit")
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil) {
            guard tab != .restoration else { return false }
            return workspace.importProviders($0, groupID: nil)
        }
        .onChange(of: workspace.selected?.id) { tab = .text }
        .onChange(of: workspace.selected?.resultWarningCount) {
            if tab == .warnings, workspace.selected?.resultWarningCount == 0 { tab = .text }
        }
        .background(WorkspaceKeyboardShortcut { action in
            switch action {
            case .command(.importFile):
                if tab == .restoration {
                    guard let card = workspace.selected, workspace.canStartRestoration(card.id) else { return false }
                    importRestoration(card)
                } else {
                    guard workspace.canImportFiles else { return false }
                    workspace.presentImportPanel()
                }
                return true
            case .command(.copyResult):
                guard let card = workspace.selected, canCopyResult(card) else { return false }
                copyResult(card)
                return true
            default: return false
            }
        })
    }

    // MARK: - Card

    private func cardBody(_ card: AnonymizationCardSummary) -> some View {
        VStack(spacing: 0) {
            let showsResultActions = tab == .restoration || (editor.cardID == card.id && editor.hasPublishedResult)
            ArchiveDetailHeader {
                RecordingTitleView(title: card.displayName, itemName: L10n.text("текста"), reservesTwoLines: true) { title in
                    Task { await model.renameTextCard(card.id, to: title) }
                }
                .id(card.id)
                .accessibilityIdentifier("texts.detail.title")
            } actions: {
                cardActions(card, showsRestorationSwitch: showsResultActions)
            } result: {
                statusLine(card)
            } resultActions: {
                if showsResultActions { resultActions(card) }
            }
            Divider()
            cardNotices(card)
            Group {
                switch tab {
                case .text:
                    panels
                case .warnings:
                    warningsSection(card.id)
                case .restoration:
                    AnonymizationRestorationView(editor: editor, cardID: card.id,
                                                 scrollSync: restorationScrollSync)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func statusLine(_ card: AnonymizationCardSummary) -> some View {
        HStack(spacing: 8) {
            Label(card.statusTitle, systemImage: card.statusIcon)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("texts.detail.status")
            if card.resultWarningCount > 0 {
                Button {
                    openTab(tab == .warnings ? .text : .warnings)
                } label: {
                    Label(L10n.text(tab == .warnings ? "К тексту" : "Предупреждения"),
                          systemImage: tab == .warnings ? "arrow.left" : "exclamationmark.triangle")
                }
                .controlSize(.small)
                .accessibilityIdentifier("texts.detail.warningsTab")
            }
            if card.attemptState == .queued, let position = model.textQueuePosition(for: card.id) {
                Text(L10n.text("Позиция в очереди: %1$@", String(position)))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("texts.detail.queuePosition")
            }
        }
    }

    @ViewBuilder private func cardNotices(_ card: AnonymizationCardSummary) -> some View {
        let failure = editor.failureText
        let loadFailure = editor.loadFailure
        let showsModelSettings = card.attemptState == .waitingModel && !editor.pendingRetryWaitsForModel
        if failure != nil || loadFailure != nil || showsModelSettings {
            VStack(alignment: .leading, spacing: 4) {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("texts.detail.failure")
                    if editor.failureIsSizeLimit {
                        // AC-42: the sizes are shown with the failure, the model
                        // settings and the left editor (still editable) resolve it.
                        HStack(spacing: 8) {
                            Button(L10n.text("Настроить модель")) { model.settingsWindow.show(tab: .anonymization) }
                                .controlSize(.small)
                                .accessibilityIdentifier("texts.detail.failure.settings")
                            Text(L10n.text("Можно сократить текст слева и повторить обработку"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let loadFailure {
                    Label(loadFailure, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("texts.detail.loadFailure")
                }
                if showsModelSettings {
                    Button {
                        model.settingsWindow.show(tab: .anonymization)
                    } label: {
                        Label(L10n.text("Настроить модель"), systemImage: "gear")
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("texts.openSettings")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private func cardActions(_ card: AnonymizationCardSummary, showsRestorationSwitch: Bool) -> some View {
        let regular = cardActionRow(card, showsRestorationSwitch: showsRestorationSwitch, spacing: 8)
            .controlSize(.small)
        if tab == .restoration {
            ViewThatFits(in: .horizontal) {
                regular
                cardActionRow(card, showsRestorationSwitch: showsRestorationSwitch, spacing: 4)
                    .controlSize(.mini)
                cardActionRow(card, showsRestorationSwitch: showsRestorationSwitch, spacing: 4, compact: true)
                    .controlSize(.small)
            }
        } else {
            regular
        }
    }

    private func cardActionRow(_ card: AnonymizationCardSummary, showsRestorationSwitch: Bool,
                               spacing: CGFloat, compact: Bool = false) -> some View {
        HStack(spacing: spacing) {
            if tab == .restoration {
                if workspace.restorationBusyCardID == card.id {
                    ProgressView()
                }
                if compact {
                    restorationInputActions(card).labelStyle(.iconOnly)
                } else {
                    restorationInputActions(card)
                }
            }
            if showsRestorationSwitch {
                let title = L10n.text(tab == .restoration ? "К обезличиванию" : "Обратное преобразование")
                Button(title) { openTab(tab == .restoration ? .text : .restoration) }
                    .help(title)
                    .accessibilityIdentifier("texts.detail.restorationTab")
            }
            if tab == .restoration {
                Button(L10n.text("Преобразовать снова")) {
                    Task { await workspace.repeatRestoration(card.id) }
                }
                .disabled(!hasRestoration(card) || !workspace.canStartRestoration(card.id))
                .help(L10n.text("Преобразовать снова"))
                .accessibilityIdentifier("texts.detail.restoration.retry")
            } else {
                switch card.attemptState {
                case .queued, .running:
                    Button(L10n.text("Отменить"), role: .destructive) {
                        Task { await model.cancelTextCard(card.id) }
                    }
                    .accessibilityIdentifier("texts.detail.cancel")
                case .waitingModel:
                    EmptyView()
                default:
                    retryButton(card)
                }
            }
            if let requestDeletion {
                Button(role: .destructive) {
                    requestDeletion(card.id)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Удалить открытый текст"))
                .accessibilityLabel(L10n.text("Удалить текст"))
                .disabled(model.deletingTextJobs)
                .accessibilityIdentifier("texts.detail.delete")
            }
        }
        .fixedSize()
    }

    private func restorationInputActions(_ card: AnonymizationCardSummary) -> some View {
        Group {
            Button(L10n.text("Импортировать"), systemImage: "square.and.arrow.down") {
                importRestoration(card)
            }
            .help(L10n.text("Импортировать"))
            .accessibilityIdentifier("texts.restoration.import")
            Button(L10n.text("Вставить"), systemImage: "document.on.clipboard") {
                Task { await workspace.pasteRestoration(card.id) }
            }
            .help(L10n.text("Вставить"))
            .accessibilityIdentifier("texts.restoration.paste")
        }
        .disabled(!workspace.canStartRestoration(card.id))
    }

    private func hasRestoration(_ card: AnonymizationCardSummary) -> Bool {
        editor.cardID == card.id && editor.document?.restoration != nil
    }

    private func importRestoration(_ card: AnonymizationCardSummary) {
        Task { await workspace.importRestoration(card.id) }
    }

    private func canCopyResult(_ card: AnonymizationCardSummary) -> Bool {
        if tab == .restoration { return hasRestoration(card) }
        return editor.cardID == card.id && editor.hasPublishedResult
    }

    private func copyResult(_ card: AnonymizationCardSummary) {
        if tab == .restoration { workspace.copyRestoration(card.id) }
        else { workspace.copyText(card.id) }
    }

    private func openTab(_ tab: Tab) {
        if tab != .text { editor.clearWarningJump() }
        self.tab = tab
    }

    @ViewBuilder private func resultActions(_ card: AnonymizationCardSummary) -> some View {
        let restoring = tab == .restoration
        let resultAvailable = canCopyResult(card)
        Group {
            Button {
                copyResult(card)
            } label: {
                // Match the icon inset of the borderless result menus.
                ArchiveActionIcon(icon: "doc.on.doc", horizontalOffset: -3)
            }
            .buttonStyle(.borderless)
            .tint(resultAvailable ? Color.primary : nil)
            .accessibilityLabel(L10n.text("Копировать"))
            .accessibilityIdentifier("texts.detail.copy")
            .help(L10n.text("Копировать результат"))

            downloadMenu(card, restoration: restoring)
        }
        .disabled(!resultAvailable)
    }

    /// Retry (AC-17/18): «Обезличить заново» in the card's top-right. Before
    /// the first success the button starts the processing; with no ready model
    /// it stays disabled with an explanation and the settings link is shown in
    /// the status line instead.
    private func retryButton(_ card: AnonymizationCardSummary) -> some View {
        let ready = model.anonymizationModelsReady
        return Button(card.hasPublishedResult || editor.hasPublishedResult
                      ? L10n.text("Обезличить заново") : L10n.text("Обезличить")) {
            Task { await editor.retry() }
        }
        .disabled(!ready)
        .help(ready
              ? L10n.text("Обработать заново текущий текст слева")
              : L10n.text("Сначала выберите и установите модель обезличивания"))
        .accessibilityIdentifier("texts.detail.retry")
    }

    /// The download menu (AC-19, work 12): it appears with the first
    /// published result; the items act through the workspace handler (the
    /// export implementation attaches it; tests may observe or replace it).
    private func downloadMenu(_ card: AnonymizationCardSummary, restoration: Bool) -> some View {
        let handler: ((String, AnonymizationTextDownloadFormat) -> Void)? = restoration
            ? workspace.downloadRestoration(_:format:) : workspace.requestTextDownload
        return ArchiveResultMenu(icon: "square.and.arrow.up", title: L10n.text("Экспорт"),
                                 help: L10n.text("Экспорт"), identifier: "texts.detail.download") {
            Button(L10n.text("Markdown (.md)")) { handler?(card.id, .markdown) }
                .disabled(handler == nil)
            Button(L10n.text("Текст (.txt)")) { handler?(card.id, .plainText) }
                .disabled(handler == nil)
        }
    }

    // MARK: - Panels

    private var panels: some View {
        AnonymizationComparisonView(scrollSync: textScrollSync) { sync in
            leftColumn(sync)
        } right: { sync in
            rightColumn(sync)
        }
    }

    private func leftColumn(_ sync: AnonymizationScrollSync) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.text("Исходный текст")).font(.headline)
                    .accessibilityIdentifier("texts.detail.source")
                if editor.panelsLocked { readOnlyBadge }
                Spacer()
            }
            AnonymizationTextEditor(
                value: editor.sourcePanel.map { AnonymizationTextEditor.Value($0) },
                editable: editor.sourceEditable,
                jump: nil,
                scrollSync: sync,
                onEdit: { edit in Task { await editor.applySourceEdit(edit) } })
                .accessibilityIdentifier("texts.detail.sourceEditor")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rightColumn(_ sync: AnonymizationScrollSync) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.text("Обезличенный текст")).font(.headline)
                    .accessibilityIdentifier("texts.detail.result")
                if editor.resultBuiltFromEarlierSource {
                    Label(L10n.text("по прежнему исходнику"), systemImage: "clock.arrow.circlepath")
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("texts.detail.earlierSource")
                }
                if editor.resultManuallyEdited {
                    Label(L10n.text("изменён вручную"), systemImage: "pencil")
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("texts.detail.manuallyEdited")
                }
                if editor.panelsLocked || editor.pendingRetryWaitsForModel { readOnlyBadge }
                Spacer()
            }
            if editor.showsPreviousResultDuringRun {
                Label(L10n.text("Идёт повторная обработка: показан предыдущий результат"), systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("texts.detail.previousResult")
            }
            if editor.showsNoMatchesMessage {
                Label(L10n.text("В тексте данные выбранных типов не найдены"), systemImage: "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("texts.detail.noMatches")
            }
            if editor.hasPublishedResult {
                AnonymizationTextEditor(
                    value: editor.resultPanel.map { AnonymizationTextEditor.Value($0) },
                    editable: editor.resultEditable,
                    jump: editor.jumpRequest,
                    scrollSync: sync,
                    scrollSide: .right,
                    onEdit: { edit in Task { await editor.applyResultEdit(edit) } })
                    .accessibilityIdentifier("texts.detail.resultEditor")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let card = workspace.selected {
                resultPlaceholder(card)
            }
        }
    }

    private var readOnlyBadge: some View {
        Text(L10n.text("Только чтение и копирование"))
            .font(.caption2).foregroundStyle(.secondary)
            .accessibilityIdentifier("texts.detail.readonly")
    }

    /// Warnings of the published result (AC-46/47): the row status shows
    /// «Готово с предупреждениями», here every item names the place to review.
    /// A doubtful body fragment jumps to its review position in the right
    /// text; an uninterpreted type is quoted verbatim with a link into the
    /// anonymization settings tab.
    private func warningsSection(_ cardID: String) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(editor.cardID == cardID ? editor.warnings : []) { warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(warning.title)
                            if let detail = warning.uninterpretedType ?? warning.fragment {
                                Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if warning.jump != nil {
                                Button(L10n.text("Показать в тексте")) {
                                    openTab(.text)
                                    editor.requestWarningJump(warning)
                                }
                                .controlSize(.small)
                                .accessibilityIdentifier("texts.detail.warning.jump.\(warning.id)")
                            }
                            if warning.uninterpretedType != nil {
                                Button(L10n.text("Открыть настройки типов")) {
                                    model.settingsWindow.show(tab: .anonymization)
                                }
                                .controlSize(.small)
                                .accessibilityIdentifier("texts.detail.warning.settings.\(warning.id)")
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("texts.detail.warning.\(warning.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("texts.detail.warnings")
    }

    /// The right panel before the first successful publication (AC-15).
    @ViewBuilder private func resultPlaceholder(_ card: AnonymizationCardSummary) -> some View {
        Group {
            switch card.attemptState {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Обезличивание выполняется"))
                }
            case .queued:
                Label(L10n.text("Обезличивание в очереди"), systemImage: "hourglass")
            case .waitingModel:
                Label(L10n.text("Обезличивание начнётся после выбора и установки модели"), systemImage: "arrow.down.circle")
            default:
                Label(L10n.text("Обезличенный текст появится после успешной обработки"), systemImage: "sparkles")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("texts.detail.resultPlaceholder")
    }
}
