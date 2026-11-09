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
                    CaptureMeterView(indicators: model.indicators, finalizing: model.finalizingRecording)
                    Spacer()
                    Button("Остановить") { Task { await model.stopRecording() } }.buttonStyle(.borderedProminent).disabled(model.finalizingRecording).help("Остановить запись и сохранить аудио")
                }.padding().background(.red.opacity(0.05))
                Divider()
            }
            if let selected = model.selected {
                HStack {
                    RecordingTitleView(title: selected.displayTitle) { title in
                        Task { await model.renameRecording(selected.id, title: title) }
                    }
                    .id(selected.id)
                    Spacer()
                    Group {
                        if selected.state.processing {
                            ProgressView()
                            Button("Отменить") { Task { await model.cancel(selected.id) } }
                                .help("Отменить обработку выбранной записи")
                                .accessibilityIdentifier("recording.cancel")
                        } else if model.queuePosition(for: selected.id) != nil {
                            Button("Поднять на верх очереди") { model.moveToFrontOfQueue(selected.id) }
                                .help("Обработать выбранную запись следующей после текущего задания")
                                .accessibilityIdentifier("recording.moveToFront")
                            Button("Отменить") { Task { await model.cancel(selected.id) } }
                                .help("Убрать запись из очереди, сохранив аудио и результаты")
                                .accessibilityIdentifier("recording.cancel")
                        } else if [.interrupted,.failed,.cancelled,.recorded,.waitingForModels].contains(selected.state), selected.state != .failed || selected.sourceComplete {
                            Button("Продолжить") { model.resume(selected.id) }
                                .disabled(model.finalizingRecording || model.recordingID == selected.id || selected.pendingRunId == nil && selected.state == .waitingForModels && !model.modelsReady)
                                .help("Продолжить обработку выбранной записи с контрольной точки")
                                .accessibilityIdentifier("recording.resume")
                        }
                    }.controlSize(.small)
                    RecordingActionsView(
                        canRepeatAnalysis: !model.busy && model.recordingID == nil && selected.sourceComplete && model.modelsReady && !model.installing,
                        canRecreateSummary: model.transcript?.diarized == true && !model.busy && model.recordingID == nil && model.modelsReady && !model.installing,
                        canDelete: model.deletingGroupID == nil && !model.finalizingRecording && model.recordingID != selected.id,
                        showAudio: model.showAudio,
                        repeatAnalysis: { Task { await model.repeatAnalysis(summaryOnly: false) } },
                        recreateSummary: { language in Task { await model.repeatAnalysis(summaryOnly: true, language: language) } },
                        deleteRecording: { Task { await model.deleteSelected() } }
                    )
                }.padding(20)
                if let message = model.resourcePauseMessage {
                    Label(message, systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.bottom, 10)
                        .accessibilityIdentifier("queue.resourcePause")
                }
                if let message = selected.lastError {
                    Button("Показать сообщение об обработке", systemImage: "exclamationmark.bubble") {
                        model.errorHandler.report(message: message)
                    }
                    .help("Открыть подробности последней ошибки или прерывания в отдельном окне")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 10)
                }
                if selected.activeRunId != nil && selected.pendingRunId != nil { Text("Показан предыдущий успешный результат. Новая версия ещё обрабатывается.").font(.caption).foregroundStyle(.secondary).padding(.horizontal,20) }
                HStack {
                    Picker(selection: Binding(get: { model.tab }, set: { part in
                        // Updating the prepared text also publishes changes; wait
                        // until SwiftUI finishes the picker's own view update.
                        Task { @MainActor in model.tab = part }
                    })) {
                        ForEach(model.resultTabs, id: \.self) { part in
                            Text(part.rawValue).tag(part)
                        }
                    } label: {
                        Text("Результат")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: model.resultTabs.contains(.warnings) ? 410 : 270)
                    .accessibilityIdentifier("result.section")
                    Spacer()
                    Button("Редактировать", systemImage: "pencil", action: model.beginResultEditing)
                        .disabled(!model.canEditResult)
                        .help("Изменить текст расшифровки и итогов")
                        .accessibilityIdentifier("result.edit")
                    Menu {
                        ForEach(model.exportParts, id: \.self) { part in Button(part.rawValue) { model.copy(part) }.help("Копировать: \(part.rawValue)") }
                    } label: { Label("Копировать", systemImage: "doc.on.doc") } primaryAction: { model.copy(model.tab) }
                    .help("Копировать открытый результат; меню позволяет выбрать раздел")
                    Menu {
                        ForEach(model.exportParts, id: \.self) { part in
                            Menu(part.rawValue) { Button("Markdown (.md)") { model.export(markdown: true, part: part) }.help("Сохранить раздел «\(part.rawValue)» в Markdown"); Button("Текст (.txt)") { model.export(markdown: false, part: part) }.help("Сохранить раздел «\(part.rawValue)» в текстовый файл") }
                        }
                    } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }
                    .help("Сохранить выбранный раздел результата или всё вместе в файл")
                }.padding(.horizontal,20).padding(.bottom,12)
                Divider()
                if model.tab == .summary, model.summary == nil, !model.automaticSummaries {
                    Text("Автоматическое создание итогов отключено")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("result.automaticSummariesDisabled")
                } else {
                    PresentedResultView(presentation: model.resultPresentation, jumpRequest: model.tab == .transcript ? model.jumpTo : nil, onJump: { id in model.jumpTo = ResultJumpRequest(segmentID: id); model.tab = .transcript })
                }
            } else {
                ContentUnavailableView {
                    Label("Разговор останется на вашем Mac", systemImage: "waveform")
                } description: { Text("Запишите встроенный микрофон или импортируйте аудио.\nРаспознавание можно начать вместе с записью.\nУчастники и итоги — после сохранения звука.") } actions: {
                    Button("Новая запись") { recordingSheet = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStartRecording)
                        .help("Настроить и начать запись встроенного микрофона")
                        .accessibilityIdentifier("recordings.start.new")
                    Button("Импортировать аудио", action: model.chooseImport).help("Выбрать аудиофайлы для расшифровки")
                }
            }
            ActivityStatusView(indicators: model.indicators)
        }.background(Color(nsColor: .textBackgroundColor))
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                model.importProviders(providers); return true
            }
            .sheet(isPresented: $recordingSheet) {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Новая запись", systemImage: "mic.fill").font(.title2)
                    Text("Встроенный микрофон MacBook")
                    Text("Группа: \(model.defaultGroup.name) ✓").accessibilityIdentifier("recording.destination")
                    Text("Убедитесь, что участники знают о записи.").foregroundStyle(.secondary)
                    Text("Голоса в наушниках не записываются. Запись можно сохранить и без установленных моделей.").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Отмена") { recordingSheet = false }
                            .keyboardShortcut(.cancelAction)
                            .help("Закрыть окно без начала записи")
                        Button("Начать") {
                            guard model.canStartRecording else { return }
                            let destination = model.defaultGroup.id
                            recordingSheet = false
                            Task { await model.startRecording(groupID: destination) }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canStartRecording)
                        .help("Начать запись встроенного микрофона")
                    }
                }.padding(28).frame(width: 440)
            }
            .sheet(item: $model.resultEdit) { draft in
                ResultEditorView(initial: draft, initialPart: model.tab, save: model.saveResultEdits,
                                 cancel: { model.resultEdit = nil }, reportError: model.errorHandler.report)
            }
    }
}

private struct CaptureMeterView: View {
    @ObservedObject var indicators: ActivityIndicators
    var finalizing: Bool

    var body: some View {
        VStack(alignment: .leading) {
            RecordingStatusText(indicators: indicators, finalizing: finalizing, prefix: "Встроенный микрофон")
            if let notice = indicators.soundNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
        }
        ProgressView(value: indicators.level).frame(width: 100).accessibilityLabel("Уровень микрофона")
    }
}

private struct ActivityStatusView: View {
    @ObservedObject var indicators: ActivityIndicators

    var body: some View {
        if !indicators.status.isEmpty {
            Divider()
            Text(indicators.status).font(.caption).foregroundStyle(.secondary)
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
            if presentation.isRendering { ProgressView("Подготавливаем результат…") }
        }
    }
}

struct RecordingTitleView: View {
    var title: String
    var itemName = "записи"
    var save: (String) -> Void
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Название \(itemName)", text: $draft)
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
                    .accessibilityLabel("Название \(itemName)")
            } else {
                Button {
                    draft = title
                    editing = true
                } label: {
                    Text(title).multilineTextAlignment(.leading).lineLimit(2)
                }
                .buttonStyle(.plain)
                .help("Нажмите, чтобы изменить название")
                .accessibilityLabel("Изменить название \(itemName): \(title)")
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
