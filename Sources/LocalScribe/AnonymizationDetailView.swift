import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

/// Right-hand area of the text-anonymization section. The card (work 10)
/// shows the two panels — «Исходный текст» and «Обезличенный текст» — with
/// pair highlighting, warnings, notices, status and retry; below the header
/// actions are the mount points of the deletion confirmation (work 11) and
/// the download menu (work 12). The empty state keeps the import entry points
/// of work 6.
struct AnonymizationDetailColumn: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: AnonymizationWorkspaceModel
    @ObservedObject private var editor: AnonymizationCardEditor
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
            if workspace.selected != nil {
                cardBody
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
        .onDrop(of: [.fileURL], isTargeted: nil) { workspace.importProviders($0, groupID: nil) }
    }

    // MARK: - Card

    private var cardBody: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let card = workspace.selected {
                            RecordingTitleView(title: card.displayName, itemName: L10n.text("текста")) { title in
                                Task { await model.renameTextCard(card.id, to: title) }
                            }
                            .id(card.id)
                            .accessibilityIdentifier("texts.detail.title")
                            statusLine(card)
                        }
                    }
                    Spacer()
                    if let card = workspace.selected { cardActions(card) }
                }
            }
            .padding(20)
            Divider()
            panels
                .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private func statusLine(_ card: AnonymizationCardSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(card.statusTitle, systemImage: card.statusIcon)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("texts.detail.status")
                if card.attemptState == .queued, let position = model.textQueuePosition(for: card.id) {
                    Text(L10n.text("Позиция в очереди: %1$@", String(position)))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("texts.detail.queuePosition")
                }
            }
            if let failure = editor.failureText {
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
            if let loadFailure = editor.loadFailure {
                Label(loadFailure, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("texts.detail.loadFailure")
            }
            if card.attemptState == .waitingModel, !editor.pendingRetryWaitsForModel {
                Button {
                    model.settingsWindow.show(tab: .anonymization)
                } label: {
                    Label(L10n.text("Настроить модель"), systemImage: "gear")
                }
                .controlSize(.small)
                .accessibilityIdentifier("texts.openSettings")
            }
        }
    }

    private func cardActions(_ card: AnonymizationCardSummary) -> some View {
        HStack(spacing: 8) {
            if editor.hasPublishedResult { downloadMenu(card) }
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
        .controlSize(.small)
        .fixedSize()
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
    private func downloadMenu(_ card: AnonymizationCardSummary) -> some View {
        let handler = workspace.requestTextDownload
        return Menu {
            Button(L10n.text("Markdown (.md)")) { handler?(card.id, .markdown) }
                .disabled(handler == nil)
            Button(L10n.text("Текст (.txt)")) { handler?(card.id, .plainText) }
                .disabled(handler == nil)
        } label: {
            Label(L10n.text("Скачать"), systemImage: "square.and.arrow.down")
        }
        .accessibilityIdentifier("texts.detail.download")
        .help(L10n.text("Скачать обезличенный текст"))
    }

    // MARK: - Panels

    private var panels: some View {
        HStack(alignment: .top, spacing: 16) {
            leftColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            rightColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var leftColumn: some View {
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
                onEdit: { edit in Task { await editor.applySourceEdit(edit) } })
                .accessibilityIdentifier("texts.detail.sourceEditor")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var rightColumn: some View {
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
            if !editor.warnings.isEmpty {
                warningsSection
            }
            if editor.hasPublishedResult {
                AnonymizationTextEditor(
                    value: editor.resultPanel.map { AnonymizationTextEditor.Value($0) },
                    editable: editor.resultEditable,
                    jump: editor.jumpRequest,
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
    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(editor.warnings) { warning in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning.title).font(.caption)
                        if let type = warning.uninterpretedType {
                            Text(type).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let fragment = warning.fragment {
                            Text(fragment).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 8) {
                            if warning.jump != nil {
                                Button(L10n.text("Показать в тексте")) { editor.requestWarningJump(warning) }
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
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("texts.detail.warning.\(warning.id)")
            }
        }
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
