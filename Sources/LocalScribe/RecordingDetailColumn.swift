import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

/// Right column of the recording archive: live recording bar, result header,
/// result tabs, status line, recording sheets and the shared file-drop receiver.
struct RecordingDetailColumn: View {
    @ObservedObject var model: AppModel
    @Binding var recordingSheet: Bool

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
                if let message = model.resourcePauseMessage {
                    Label(L10n.message(message), systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.bottom, 10)
                        .accessibilityIdentifier("queue.resourcePause")
                }
                if let message = selected.lastError {
                    Button(L10n.text("Показать сообщение об обработке"), systemImage: "exclamationmark.bubble") {
                        model.errorHandler.report(message: message)
                    }
                    .help(L10n.text("Открыть подробности последней ошибки или прерывания в отдельном окне"))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 10)
                }
                if selected.activeRunId != nil && selected.pendingRunId != nil { Text(L10n.text("Показан предыдущий успешный результат. Новая версия ещё обрабатывается.")).font(.caption).foregroundStyle(.secondary).padding(.horizontal,20) }
                Divider()
                if model.tab == .summary, model.summary == nil, !model.automaticSummaries {
                    Text(L10n.text("Автоматическое создание итогов отключено"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("result.automaticSummariesDisabled")
                } else {
                    PresentedResultView(presentation: model.resultPresentation, jumpRequest: model.tab == .transcript ? model.jumpTo : nil, onJump: { id in model.jumpTo = ResultJumpRequest(segmentID: id); model.tab = .transcript })
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
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                model.importProviders(providers)
            }
            .sheet(isPresented: $recordingSheet) {
                VStack(alignment: .leading, spacing: 18) {
                    Label(L10n.text("Новая запись"), systemImage: "mic.fill").font(.title2)
                    RecordingSourceSummary(preferences: model.recordingSources, devices: model.microphoneDevices)
                    Text(L10n.text("Группа: %1$@ ✓", model.defaultGroup.displayName)).accessibilityIdentifier("recording.destination")
                    Text(L10n.text("Убедитесь, что участники знают о записи.")).foregroundStyle(.secondary)
                    Text(L10n.text("Запись можно сохранить и без установленных моделей.")).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button(L10n.text("Отмена")) { recordingSheet = false }
                            .keyboardShortcut(.cancelAction)
                            .help(L10n.text("Закрыть окно без начала записи"))
                        Button(L10n.text("Начать")) {
                            guard model.canStartRecording else { return }
                            if model.requestRecording(groupID: model.defaultGroup.id) != nil {
                                recordingSheet = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canStartRecording)
                        .help(L10n.text("Начать запись с выбранных источников"))
                    }
                }.padding(28).frame(width: 440)
            }
            .sheet(item: $model.resultEdit) { draft in
                ResultEditorView(initial: draft, initialPart: model.tab, save: model.saveResultEdits,
                                 cancel: { model.resultEdit = nil }, reportError: model.errorHandler.report)
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
                    .frame(width: RecordingResultPicker.reservedWidth, alignment: .leading)
                Spacer(minLength: 0)
                resultActions
            }
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
        RecordingActionsView(
            canEdit: model.canEditResult,
            canRepeatAnalysis: !model.busy && model.recordingID == nil && selected.sourceComplete && model.modelsReady && !model.installing,
            canRecreateSummary: model.transcript?.diarized == true && !model.busy && model.recordingID == nil && model.modelsReady && !model.installing,
            canDelete: model.deletingGroupID == nil && !model.finalizingRecording && model.recordingID != selected.id,
            showAudio: model.showAudio,
            editResult: model.beginResultEditing,
            repeatAnalysis: { Task { await model.repeatAnalysis(summaryOnly: false) } },
            recreateSummary: { language in Task { await model.repeatAnalysis(summaryOnly: true, language: language) } },
            deleteRecording: { Task { await model.deleteSelected() } }
        )
    }

    private var resultActions: some View {
        HStack(spacing: 4) {
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
        .fixedSize()
    }
}

/// The SwiftUI segmented Picker redistributes space when the number of options changes.
/// AppKit lets each segment keep a width determined by its own label.
private struct RecordingResultPicker: NSViewRepresentable {
    var parts: [ExportPart]
    @Binding var selection: ExportPart

    static var reservedWidth: CGFloat {
        width(for: ExportPart.allCases.filter { $0 != .all })
    }

    private static func width(for parts: [ExportPart]) -> CGFloat {
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
        CGSize(width: Self.reservedWidth, height: context.coordinator.control.intrinsicContentSize.height)
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

private struct RecordingSourceSummary: View {
    let preferences: RecordingSourcePreferences
    @ObservedObject var devices: MicrophoneDevices

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if preferences.microphoneEnabled {
                Label(microphoneTitle, systemImage: "mic")
                if case .device(let uid, let name) = preferences.microphone,
                   let actual = devices.snapshot.candidates(for: preferences.microphone).first, actual.uid != uid {
                    Text(L10n.text("%1$@ · Не подключён", name))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if preferences.systemAudioEnabled {
                Label(L10n.text("Системный звук"), systemImage: "speaker.wave.2")
            }
            if !preferences.microphoneEnabled && !preferences.systemAudioEnabled {
                Text(L10n.text("Источники записи не выбраны")).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("recording.sources")
    }

    private var microphoneTitle: String {
        if let device = devices.snapshot.candidates(for: preferences.microphone).first {
            return preferences.microphone == .builtIn ? L10n.text("Встроенный микрофон") : device.name
        }
        switch preferences.microphone {
        case .builtIn:
            return L10n.text("%1$@ · недоступен", L10n.text("Встроенный микрофон"))
        case .systemDefault:
            return L10n.text("%1$@ · недоступен", L10n.text("Как в настройках macOS"))
        case let .device(_, name):
            return L10n.text("%1$@ · Не подключён", name)
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
    var onJump: (String) -> Void

    var body: some View {
        ZStack {
            ResultTextView(result: presentation.result, jumpRequest: jumpRequest, onJump: onJump)
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
        ZStack(alignment: .topLeading) {
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
