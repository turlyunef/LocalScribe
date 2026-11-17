import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

enum RecordingResultTab: CaseIterable {
    case transcript, summary, live, warnings

    var exportPart: ExportPart? {
        switch self {
        case .transcript: return .transcript
        case .summary: return .summary
        case .live: return nil
        case .warnings: return .warnings
        }
    }

    var title: String { exportPart?.title ?? L10n.text("В эфире") }
}

/// Right column of the recording archive: live recording bar, result header,
/// result tabs, status line, recording sheets and the shared file-drop receiver.
struct RecordingDetailColumn: View {
    @ObservedObject var model: AppModel
    @Binding var recordingSheet: Bool
    @State private var playbackCardID = UUID()

    private var canStartFromSheet: Bool { model.canStartRecording && model.recordingSources.hasEnabledSource }

    var body: some View {
        VStack(spacing: 0) {
            if model.recordingID != nil {
                HStack(spacing: 14) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    CaptureMeterView(indicators: model.indicators, finalizing: model.finalizingRecording,
                                     enableFallback: model.enableFallbackMicrophone)
                    Spacer()
                    Button(L10n.text("Остановить")) { Task { await model.stopRecording() } }.buttonStyle(.borderedProminent).disabled(model.finalizingRecording).help(L10n.text("Остановить запись и сохранить аудио"))
                }.padding().background(.red.opacity(0.05))
                Divider()
            }
            if let selected = model.selected {
                resultHeader(selected)
                Divider()
                if model.playbackSource != nil || !model.isSavingAudio(for: selected.id) {
                    RecordingPlayerView(playback: model.playback, sourceAvailable: model.playbackSource != nil)
                    Divider()
                }
                if let message = model.resourcePauseMessage {
                    Label(L10n.message(message), systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.vertical, 6)
                        .accessibilityIdentifier("queue.resourcePause")
                }
                if let message = selected.lastError {
                    Button(L10n.text("Показать сообщение об обработке"), systemImage: "exclamationmark.bubble") {
                        Task {
                            await model.errorHandler.presentStored(
                                DiagnosticJobReference(.recording, item: selected.id, run: selected.pendingRunId), message: message)
                        }
                    }
                    .help(L10n.text("Открыть подробности последней ошибки или прерывания в отдельном окне"))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 6)
                }
                if selected.activeRunId != nil && selected.pendingRunId != nil {
                    Text(L10n.text("Показан предыдущий успешный результат. Новая версия ещё обрабатывается."))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.vertical, 6)
                }
                if model.tab == .live, let captions = model.selectedCaptions {
                    LiveCaptionView(captions: captions).id(captions.recordingID)
                } else if model.tab == .summary, model.summary == nil, !model.automaticSummaries {
                    Text(L10n.text("Автоматическое создание итогов отключено"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("result.automaticSummariesDisabled")
                } else {
                    PresentedResultView(
                        presentation: model.resultPresentation,
                        jumpRequest: model.tab == .transcript ? model.jumpTo : nil,
                        playback: model.tab == .transcript ? model.playback : nil,
                        onJump: { [tab = model.tab] id in model.activateResultSegment(id, recordingID: selected.id, from: tab) }
                    )
                }
            } else {
                ContentUnavailableView {
                    Label(L10n.text("Разговор останется на вашем Mac"), systemImage: "waveform")
                } description: { Text(L10n.text("Запишите звук с выбранных источников или импортируйте аудио.\nРаспознавание можно начать вместе с записью.\nУчастники и итоги — после сохранения звука.")) } actions: {
                    Button(L10n.text("Новая запись")) { recordingSheet = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStartRecording)
                        .help(L10n.text("Настроить и начать запись"))
                        .accessibilityIdentifier("recordings.start.new")
                    Button(L10n.text("Импортировать аудио"), action: model.chooseImport).help(L10n.text("Выбрать аудиофайлы для расшифровки"))
                }
            }
            ActivityStatusView(indicators: model.indicators)
        }.background(Color(nsColor: .textBackgroundColor))
            .onAppear { model.playback.cardAppeared(playbackCardID, source: model.playbackSource) }
            .onChange(of: model.playbackSource) { _, source in model.playback.select(source) }
            .onDisappear { model.playback.cardDisappeared(playbackCardID) }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                model.importProviders(providers)
            }
            .sheet(isPresented: $recordingSheet) {
                VStack(alignment: .leading, spacing: 18) {
                    Label(L10n.text("Новая запись"), systemImage: "mic.fill").font(.title2)
                    VStack(alignment: .leading, spacing: 8) {
                        RecordingSourceControls(
                            preferences: Binding(get: { model.recordingSources }, set: model.setRecordingSources),
                            devices: model.microphoneDevices, identifierPrefix: "recording"
                        )
                        Text(L10n.text("Выбор источников сохраняется сразу для будущих записей."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(L10n.text("Группа: %1$@ ✓", model.defaultGroup.displayName)).accessibilityIdentifier("recording.destination")
                    Text(L10n.text("Убедитесь, что участники знают о записи.")).foregroundStyle(.secondary)
                    Text(L10n.text("Запись можно сохранить и без установленных моделей.")).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button(L10n.text("Отмена")) { recordingSheet = false }
                            .keyboardShortcut(.cancelAction)
                            .help(L10n.text("Закрыть окно без начала записи"))
                        Button(L10n.text("Начать")) {
                            guard canStartFromSheet else { return }
                            if model.requestRecording(groupID: model.defaultGroup.id) != nil {
                                recordingSheet = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canStartFromSheet)
                        .help(L10n.text("Начать запись с выбранных источников"))
                    }
                }.padding(28).frame(width: 440)
            }
            .sheet(item: $model.resultEdit) { draft in
                ResultEditorView(initial: draft, initialPart: model.tab.exportPart ?? .transcript, save: model.saveResultEdits,
                                 cancel: { model.resultEdit = nil }, reportError: { model.errorHandler.report($0, operation: .archive) })
            }
    }

    private func resultHeader(_ selected: Manifest) -> some View {
        ArchiveDetailHeader {
            HStack(spacing: 8) {
                RecordingTitleView(title: selected.displayTitle, reservesTwoLines: true) { title in
                    Task { await model.renameRecording(selected.id, title: title) }
                }
                .id(selected.id)
                Spacer(minLength: 0)
                statusActions(selected)
            }
        } actions: {
            recordingActions(selected)
        } result: {
            HStack(spacing: 8) {
                Text(L10n.text("Результат"))
                    .fixedSize()
                    .accessibilityIdentifier("result.label")
                RecordingResultPicker(parts: model.resultTabs, selection: $model.tab)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L10n.text("Результат"))
                    .accessibilityIdentifier("result.section")
                    // Keep the remaining controls in place when warnings appear.
                    .frame(width: RecordingResultPicker.reservedWidth(showsLive: model.selectedCaptions != nil), alignment: .leading)
            }
        } resultActions: {
            resultActions
        }
    }

    private func statusActions(_ selected: Manifest) -> some View {
        HStack(spacing: 8) {
            if selected.state.processing {
                ProgressView()
                Button(L10n.text("Отменить")) { Task { await model.cancel(selected.id) } }
                    .help(L10n.text("Отменить обработку выбранной записи"))
                    .accessibilityIdentifier("recording.cancel")
            } else if model.queuePosition(for: selected.id) != nil {
                Button(L10n.text("Поднять на верх очереди")) { model.moveToFrontOfQueue(selected.id) }
                    .help(L10n.text("Обработать выбранную запись следующей после текущего задания"))
                    .accessibilityIdentifier("recording.moveToFront")
                Button(L10n.text("Отменить")) { Task { await model.cancel(selected.id) } }
                    .help(L10n.text("Убрать запись из очереди, сохранив аудио и результаты"))
                    .accessibilityIdentifier("recording.cancel")
            } else if [.interrupted,.failed,.cancelled,.recorded,.waitingForModels].contains(selected.state), selected.state != .failed || selected.sourceComplete {
                Button(L10n.text("Продолжить")) { model.resume(selected.id) }
                    .disabled(model.finalizingRecording || model.recordingID == selected.id || selected.pendingRunId == nil && selected.state == .waitingForModels && !model.modelsReady)
                    .help(L10n.text("Продолжить обработку выбранной записи с контрольной точки"))
                    .accessibilityIdentifier("recording.resume")
            }
        }
        .controlSize(.small)
        .fixedSize()
    }

    private func recordingActions(_ selected: Manifest) -> some View {
        let canControlCaptions = model.recordingID == selected.id && !model.finalizingRecording
        return RecordingActionsView(
            canEdit: model.canEditResult,
            canRepeatAnalysis: !model.busy && model.recordingID == nil && selected.sourceComplete && model.modelsReady && !model.installing,
            canRecreateSummary: model.transcript?.diarized == true && !model.busy && model.recordingID == nil && model.modelsReady && !model.installing,
            canDelete: model.deletingGroupID == nil && !model.finalizingRecording && model.recordingID != selected.id,
            showAudio: model.showAudio,
            liveCaptionLanguageMenu: canControlCaptions
                ? LiveCaptionLanguageMenu(language: model.liveCaptionLanguage, select: { model.setLiveCaptionLanguage($0, for: selected.id) })
                : nil,
            liveCaptionControl: canControlCaptions
                ? LiveCaptionControl(captions: model.selectedCaptions, disabled: model.resourcePauseMessage != nil,
                                     start: { model.startLiveCaptions(selected.id) }, stop: { model.freezeLiveCaptions(selected.id) })
                : nil,
            editResult: model.beginResultEditing,
            repeatAnalysis: { Task { await model.repeatAnalysis(summaryOnly: false) } },
            recreateSummary: { language in Task { await model.repeatAnalysis(summaryOnly: true, language: language) } },
            deleteRecording: { Task { await model.deleteSelected() } }
        )
    }

    @ViewBuilder private var resultActions: some View {
        ArchiveResultMenu(icon: "doc.on.doc", title: L10n.text("Копировать"),
                          help: L10n.text("Копировать результат"), identifier: "result.copy") {
            ForEach(model.exportParts, id: \.self) { part in
                Button(part.title) { model.copy(part) }
                    .help(L10n.text("Копировать: %1$@", part.title))
            }
        }
        ArchiveResultMenu(icon: "square.and.arrow.up", title: L10n.text("Экспорт"),
                          help: L10n.text("Экспорт"), identifier: "result.export") {
            ForEach(model.exportParts, id: \.self) { part in
                Menu(part.title) {
                    Button("Markdown (.md)") { model.export(markdown: true, part: part) }
                        .help(L10n.text("Сохранить раздел «%1$@» в Markdown", part.title))
                    Button(L10n.text("Текст (.txt)")) { model.export(markdown: false, part: part) }
                        .help(L10n.text("Сохранить раздел «%1$@» в текстовый файл", part.title))
                }
            }
        }
    }
}

/// The SwiftUI segmented Picker redistributes space when the number of options changes.
/// AppKit lets each segment keep a width determined by its own label.
private struct RecordingResultPicker: NSViewRepresentable {
    var parts: [RecordingResultTab]
    @Binding var selection: RecordingResultTab

    static func reservedWidth(showsLive: Bool) -> CGFloat {
        width(for: RecordingResultTab.allCases.filter { showsLive || $0 != .live })
    }

    private static func width(for parts: [RecordingResultTab]) -> CGFloat {
        parts.reduce(0) { $0 + segmentWidth($1.title) }
    }

    private static func segmentWidth(_ label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + 16
    }

    func makeCoordinator() -> Coordinator { Coordinator(picker: self) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let control = context.coordinator.control
        control.segmentStyle = .rounded
        control.segmentDistribution = .fit
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.select(_:))
        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            context.coordinator.controlWidth
        ])
        return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: Self.reservedWidth(showsLive: parts.contains(.live)), height: context.coordinator.control.intrinsicContentSize.height)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.picker = self
        let control = context.coordinator.control
        if control.segmentCount != parts.count {
            control.segmentCount = parts.count
        }
        for (index, part) in parts.enumerated() {
            let label = part.title
            if control.label(forSegment: index) != label {
                control.setLabel(label, forSegment: index)
                control.setWidth(Self.segmentWidth(label), forSegment: index)
            }
        }
        // Fit the visible segments inside their native view and keep its leading edge fixed.
        context.coordinator.controlWidth.constant = Self.width(for: parts)
        control.selectedSegment = parts.firstIndex(of: selection) ?? -1
    }

    @MainActor
    final class Coordinator: NSObject {
        let control = NSSegmentedControl()
        lazy var controlWidth = control.widthAnchor.constraint(equalToConstant: 0)
        var picker: RecordingResultPicker

        init(picker: RecordingResultPicker) {
            self.picker = picker
        }

        @objc func select(_ control: NSSegmentedControl) {
            guard picker.parts.indices.contains(control.selectedSegment) else { return }
            picker.selection = picker.parts[control.selectedSegment]
        }
    }
}

private struct CaptureMeterView: View {
    @ObservedObject var indicators: ActivityIndicators
    var finalizing: Bool
    var enableFallback: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            RecordingStatusText(indicators: indicators, finalizing: finalizing, prefix: L10n.text("Идёт запись"))
            CaptureStatusNotices(indicators: indicators, enableFallback: enableFallback)
        }
        ProgressView(value: indicators.level).frame(width: 100).accessibilityLabel(L10n.text("Уровень звука"))
    }
}

struct CaptureStatusNotices: View {
    @ObservedObject var indicators: ActivityIndicators
    var enableFallback: () -> Void

    var body: some View {
        switch indicators.microphoneStatus {
        case .active(let name):
            Text(L10n.text("Микрофон: %1$@", name)).font(.caption).foregroundStyle(.secondary)
        case .waiting:
            Text(L10n.text("Микрофон недоступен")).font(.caption).foregroundStyle(.orange)
        case .mutedFallback:
            Button(L10n.text("Включить запасной микрофон"), action: enableFallback)
                .accessibilityIdentifier("recording.microphone.enableFallback")
        case nil:
            EmptyView()
        }
        if indicators.waitingForSystemAudio {
            Text(L10n.text("Системный звук пока не поступает"))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("recording.systemAudio.waiting")
        }
        if let notice = indicators.soundNotice {
            Text(L10n.message(notice)).font(.caption).foregroundStyle(.orange)
        }
        ForEach(indicators.captureWarnings, id: \.self) { warning in
            Label(L10n.message(warning), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("recording.source.warning")
        }
    }
}

private struct ActivityStatusView: View {
    @ObservedObject var indicators: ActivityIndicators

    var body: some View {
        if !indicators.status.isEmpty {
            Divider()
            Text(L10n.message(indicators.status)).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
}

private struct PresentedResultView: View {
    @ObservedObject var presentation: ResultPresentation
    var jumpRequest: ResultJumpRequest?
    var playback: RecordingPlayback?
    var onJump: (String) -> Void

    var body: some View {
        ZStack {
            ResultTextView(result: presentation.result, jumpRequest: jumpRequest, playback: playback,
                           playbackIndex: presentation.playbackIndex, onJump: onJump)
            if presentation.isRendering { ProgressView(L10n.text("Подготавливаем результат…")) }
        }
    }
}

struct RecordingTitleView: View {
    var title: String
    var itemName = L10n.text("записи")
    var reservesTwoLines = false
    var save: (String) -> Void
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if reservesTwoLines {
                Text(verbatim: " ").lineLimit(2, reservesSpace: true).hidden()
            }
            if editing {
                TextField(L10n.text("Название %1$@", itemName), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand {
                        editing = false
                        focused = false
                    }
                    .onChange(of: focused) { _, value in
                        if !value { commit() }
                    }
                    .onAppear { focused = true }
                    .accessibilityLabel(L10n.text("Название %1$@", itemName))
            } else {
                Button {
                    draft = title
                    editing = true
                } label: {
                    Text(title).multilineTextAlignment(.leading).lineLimit(2).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help(L10n.text("Нажмите, чтобы изменить название"))
                .accessibilityLabel(L10n.text("Изменить название %1$@: %2$@", itemName, title))
            }
        }
        .font(.title2).fontWeight(.semibold)
    }

    private func commit() {
        guard editing else { return }
        // End editing before clearing focus to avoid saving twice.
        editing = false
        focused = false
        if draft != title { save(draft) }
    }
}
