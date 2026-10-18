import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var recordingSheet = false
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.recordings) { recording in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(recording.displayTitle).lineLimit(2).fontWeight(.medium)
                        Text("\(timecode(recording.durationMs)) · \(recording.createdAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        Label(recording.state.title, systemImage: recording.state == .recording ? "record.circle.fill" : recording.state == .completed ? "checkmark.circle" : "waveform").font(.caption).foregroundStyle(recording.state == .recording ? .red : .secondary)
                    }.padding(.vertical, 5).tag(recording.id)
                }
            }
            .navigationTitle("LocalScribe")
            .navigationSplitViewColumnWidth(min: 220, ideal: 270)
            VStack(spacing: 6) {
                Label("Всё обрабатывается на Mac", systemImage: "lock.shield").font(.caption)
                    .accessibilityIdentifier("sidebar.localProcessing")
                SettingsLink { Text(model.modelsReady ? "Модели готовы" : "Установить модели") }.font(.caption).help("Открыть настройки и управление моделями")
                    .accessibilityIdentifier("sidebar.models")
            }.foregroundStyle(.secondary).padding()
        } detail: {
            VStack(spacing: 0) {
                if model.recordingID != nil {
                    HStack(spacing: 14) {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        VStack(alignment: .leading) {
                            Text(model.finalizingRecording ? "Сохраняем аудио…" : "Встроенный микрофон · \(timecode(Int(model.elapsed*1000)))").monospacedDigit()
                            if let notice = model.soundNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
                        }
                        ProgressView(value: model.level).frame(width: 100).accessibilityLabel("Уровень микрофона")
                        Spacer()
                        Button("Остановить") { Task { await model.stopRecording() } }.buttonStyle(.borderedProminent).disabled(model.finalizingRecording).help("Остановить запись и сохранить аудио")
                    }.padding().background(.red.opacity(0.05))
                    Divider()
                }
                if let selected = model.selected {
                    HStack(alignment: .firstTextBaseline) {
                        RecordingTitleView(title: selected.displayTitle) { title in
                            model.renameRecording(selected.id, title: title)
                        }
                        .id(selected.id)
                        Spacer()
                        if selected.state.processing {
                            ProgressView().controlSize(.small)
                            Button("Отменить") { Task { await model.cancelSelected() } }.help("Отменить обработку выбранной записи")
                        } else if [.interrupted,.failed,.cancelled,.recorded,.waitingForModels].contains(selected.state), selected.state != .failed || selected.sourceComplete {
                            Button("Продолжить") { model.resume(selected.id) }.disabled(model.finalizingRecording || model.recordingID != nil || selected.state == .waitingForModels && !model.modelsReady).help("Продолжить обработку выбранной записи с контрольной точки")
                        }
                        RecordingActionsView(
                            canRepeatAnalysis: !model.busy && model.recordingID == nil && selected.sourceComplete && model.modelsReady && !model.installing,
                            canRecreateSummary: model.transcript?.diarized == true && !model.busy && model.recordingID == nil && model.modelsReady && !model.installing,
                            canDelete: !model.finalizingRecording && model.recordingID != selected.id,
                            showAudio: model.showAudio,
                            repeatAnalysis: { model.repeatAnalysis(summaryOnly: false) },
                            recreateSummary: { model.repeatAnalysis(summaryOnly: true, language: $0) },
                            deleteRecording: { Task { await model.deleteSelected() } }
                        )
                    }.padding(20)
                    if let message = selected.lastError {
                        Button("Показать сообщение об обработке", systemImage: "exclamationmark.bubble") {
                            model.errorHandler.report(message: message)
                        }
                        .help("Открыть подробности последней ошибки или прерывания в отдельном окне")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 10)
                    }
                    if selected.activeRunId != nil && selected.pendingRunId != nil { Text("Показан предыдущий успешный результат. Новая версия ещё обрабатывается.").font(.caption).foregroundStyle(.secondary).padding(.horizontal,20) }
                    HStack {
                        Picker(selection: $model.tab) {
                            Text("Расшифровка").tag(ExportPart.transcript)
                            Text("Итоги").tag(ExportPart.summary)
                        } label: {
                            Text("Результат")
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 270)
                        .accessibilityIdentifier("result.section")
                        Spacer()
                        Button("Редактировать", systemImage: "pencil", action: model.beginResultEditing)
                            .disabled(!model.canEditResult)
                            .help("Изменить текст расшифровки и итогов")
                            .accessibilityIdentifier("result.edit")
                        Menu {
                            ForEach(ExportPart.allCases, id: \.self) { part in Button(part.rawValue) { model.copy(part) }.help("Копировать: \(part.rawValue)") }
                        } label: { Label("Копировать", systemImage: "doc.on.doc") } primaryAction: { model.copy(model.tab) }
                        .help("Копировать открытый результат; меню позволяет выбрать раздел")
                        Menu {
                            ForEach(ExportPart.allCases, id: \.self) { part in
                                Menu(part.rawValue) { Button("Markdown (.md)") { model.export(markdown: true, part: part) }.help("Сохранить раздел «\(part.rawValue)» в Markdown"); Button("Текст (.txt)") { model.export(markdown: false, part: part) }.help("Сохранить раздел «\(part.rawValue)» в текстовый файл") }
                            }
                        } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }
                        .help("Сохранить расшифровку, итоги или всё вместе в файл")
                    }.padding(.horizontal,20).padding(.bottom,12)
                    Divider()
                    ResultTextView(result: model.renderedResult(model.tab), targetID: model.tab == .transcript ? model.jumpTo : nil, onJump: { id in model.jumpTo = id; model.tab = .transcript })
                } else {
                    ContentUnavailableView {
                        Label("Разговор останется на вашем Mac", systemImage: "waveform")
                    } description: { Text("Запишите встроенный микрофон или импортируйте аудио.\nРасшифровка, участники и итоги — после сохранения звука.") } actions: {
                        Button("Новая запись") { recordingSheet = true }.buttonStyle(.borderedProminent).disabled(model.startingRecording || model.finalizingRecording || model.installing).help("Настроить и начать запись встроенного микрофона")
                        Button("Импортировать аудио", action: model.chooseImport).help("Выбрать аудиофайлы для расшифровки")
                    }
                }
                if !model.status.isEmpty { Divider(); Text(model.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(10) }
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .toolbar {
            ToolbarItemGroup {
                Button { recordingSheet = true } label: { Label("Новая запись", systemImage: "mic") }.disabled(model.recordingID != nil || model.startingRecording || model.finalizingRecording || model.installing).help("Настроить и начать запись встроенного микрофона")
                Button(action: model.chooseImport) { Label("Импорт", systemImage: "square.and.arrow.down") }.help("Выбрать аудиофайлы для расшифровки")
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for provider in providers { _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.importURLs([url]) } } } }; return true
        }
        .sheet(isPresented: $recordingSheet) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Новая запись", systemImage: "mic.fill").font(.title2)
                Text("Встроенный микрофон MacBook")
                Text("Убедитесь, что участники знают о записи.").foregroundStyle(.secondary)
                Text("Голоса в наушниках не записываются. Запись можно сохранить и без установленных моделей.").font(.callout).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Отмена") { recordingSheet = false }.help("Закрыть окно без начала записи"); Button("Начать") { recordingSheet = false; Task { await model.startRecording() } }.buttonStyle(.borderedProminent).help("Начать запись встроенного микрофона") }
            }.padding(28).frame(width: 440)
        }
        .sheet(item: $model.resultEdit) { draft in
            ResultEditorView(initial: draft, initialPart: model.tab, save: model.saveResultEdits,
                             cancel: { model.resultEdit = nil }, reportError: model.errorHandler.report)
        }
        .disabled(model.preparingStorage || model.shuttingDown)
    }
}

struct RecordingTitleView: View {
    var title: String
    var save: (String) -> Void
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Название записи", text: $draft)
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
                    .accessibilityLabel("Название записи")
            } else {
                Button {
                    draft = title
                    editing = true
                } label: {
                    Text(title).multilineTextAlignment(.leading).lineLimit(2)
                }
                .buttonStyle(.plain)
                .help("Нажмите, чтобы изменить название")
                .accessibilityLabel("Изменить название записи: \(title)")
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

struct ResultTextView: NSViewRepresentable {
    var result: RenderedExport; var targetID: String?; var onJump: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView(); let view = scroll.documentView as! NSTextView
        view.isEditable = false; view.isSelectable = true; view.allowsUndo = false
        view.textContainerInset = NSSize(width: 20, height: 20); view.font = .systemFont(ofSize: 14); view.delegate = context.coordinator
        view.isAutomaticLinkDetectionEnabled = false; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView; context.coordinator.onJump = onJump
        if context.coordinator.current != result {
            context.coordinator.current = result
            context.coordinator.timestampRanges = [:]
            let value = NSMutableAttributedString(string: result.text, attributes: [.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.labelColor])
            for timestamp in result.timestamps {
                value.addAttribute(.link, value: "localscribe://segment/\(timestamp.segmentID)", range: timestamp.range)
                if timestamp.isTranscript { context.coordinator.timestampRanges[timestamp.segmentID] = timestamp.range }
            }
            view.textStorage?.setAttributedString(value)
            context.coordinator.target = nil
        }
        if let targetID, context.coordinator.target != targetID, let range = context.coordinator.timestampRanges[targetID] {
            view.scrollRangeToVisible(range); view.setSelectedRange(range); context.coordinator.target = targetID
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var current = RenderedExport(); var target: String?; var onJump: ((String)->Void)?
        var timestampRanges: [String: NSRange] = [:]
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string:$0) }
            if let url, url.scheme == "localscribe", url.host == "segment" { onJump?(url.lastPathComponent) }
            return true
        }
    }
}

struct ModelSettings: View {
    @ObservedObject var model: AppModel
    @State private var asrID = "asr"
    @State private var summaryID = "summary"
    @State private var showFiles = false
    private var profiles: [ModelProfile] { model.catalog?.models ?? [] }
    private var downloads: [ModelProfile] { model.profilesToInstall(asrID: asrID, summaryID: summaryID) }
    var body: some View {
        Form {
            Section("Модели для автономной работы") {
                Text(model.modelsStatus)
                Text("Выбранные модели применяются к новым заданиям. Сохранённые записи меняются только по команде «Продолжить», «Обработать заново» или «Пересоздать итоги».")
                    .font(.caption).foregroundStyle(.secondary)
                if model.installing { downloadStatus }
                else {
                    Button("Проверить установленные модели") { Task { await model.verifyModels() } }.disabled(!model.canManageModels).help("Проверить целостность файлов установленных моделей")
                    if model.verifyingModels { ProgressView().controlSize(.small) }
                }
            }
            Section("Загрузить модели") {
                Picker("Распознавание", selection: $asrID) {
                    ForEach(profiles.filter { $0.purpose == .asr }) { profile in
                        Text("\(profile.displayName) · \(size(profile.bytes))").tag(profile.id)
                    }
                }
                Picker("Итоги", selection: $summaryID) {
                    ForEach(profiles.filter { $0.purpose == .summary }) { profile in
                        Text("\(profile.displayName) · \(size(profile.bytes))").tag(profile.id)
                    }
                }
                ForEach(profiles.filter { $0.id == asrID || $0.id == summaryID }) { profile in
                    if let warning = model.hardware.warning(for: profile) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button("Загрузить выбранные") { model.installModels(downloads) }.buttonStyle(.borderedProminent).disabled(downloads.isEmpty).help("Скачать выбранные модели и необходимые зависимости")
                    Text(downloads.isEmpty ? "Уже установлены" : "Всего: \(size(downloads.reduce(0) { $0 + $1.bytes }))").font(.caption).foregroundStyle(.secondary)
                }
                Text("Нужные токенизатор и модель участников загрузятся автоматически. После успешной установки новая модель станет выбранной; ранее загруженные останутся на диске.")
                    .font(.caption).foregroundStyle(.secondary)
                Menu("Импортировать из папки…") {
                    ForEach(profiles) { profile in Button(profile.displayName) { model.importModel(profile) }.help("Выбрать папку с файлами модели \(profile.displayName)") }
                }.help("Установить модель из локальной папки")
            }.disabled(!model.canManageModels)
            Section("Загруженные модели") {
                if model.modelLibrary.installedAt.isEmpty { Text("Пока нет загруженных моделей").foregroundStyle(.secondary) }
                ForEach(ModelRole.allCases, id: \.self) { role in
                    let installed = profiles.filter { $0.purpose == role && model.modelLibrary.isInstalled($0) }
                    if !installed.isEmpty {
                        Text(role.title).font(.caption).foregroundStyle(.secondary)
                        ForEach(installed) { profile in installedRow(profile) }
                    }
                }
            }
            Section("Этот Mac") {
                Text("\(model.hardware.chip) · \(model.hardware.cpuCores) ядер CPU · \(model.hardware.memoryBytes / 1_073_741_824) ГБ RAM")
                Text("Бюджет GPU (Metal): \(String(format: "%.1f ГБ", Double(model.hardware.gpuWorkingSetBytes) / 1_073_741_824)). Модели запускаются по очереди; оценка памяти относится к одному этапу, а не к сумме всех скачанных моделей.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Локальные данные") {
                Button("Показать папку данных") { if let root = model.repository?.root { NSWorkspace.shared.open(root) } }.help("Открыть папку записей и моделей в Finder")
                Button("Лицензии") { NSWorkspace.shared.open(model.resources.appendingPathComponent("Licenses")) }.help("Открыть лицензии сторонних компонентов")
                Text("LocalScribe " + (Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.1") + " · локальная предварительная сборка").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    @ViewBuilder private func installedRow(_ profile: ModelProfile) -> some View {
        HStack(alignment: .top) {
            if profile.purpose == .asr || profile.purpose == .summary {
                Toggle(profile.displayName, isOn: Binding(get: { model.modelLibrary.isSelected(profile) }, set: { checked in if checked { model.selectModel(profile) } }))
                    .toggleStyle(.checkbox).disabled(!model.canManageModels).help("Использовать \(profile.displayName) для новых заданий")
            } else {
                Label(profile.displayName, systemImage: model.modelLibrary.isSelected(profile) ? "checkmark.circle.fill" : "circle")
            }
            Spacer()
            if model.hardware.warning(for: profile) != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(model.hardware.warning(for: profile) ?? "")
            }
            Text(size(profile.bytes)).font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive) { model.removeModel(profile) } label: { Image(systemName: "trash").foregroundStyle(.red) }
                .buttonStyle(.borderless).help("Удалить \(profile.displayName)").accessibilityLabel("Удалить \(profile.displayName)").disabled(!model.canManageModels)
        }
    }
    @ViewBuilder private var downloadStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.downloadBatch).fontWeight(.medium)
            if let progress = model.downloadProgress, let profile = profiles.first(where: { $0.id == progress.profileID }) {
                ProgressView(value: progress.fraction).accessibilityLabel("Общий прогресс загрузки модели")
                HStack {
                    Text("\(Int(progress.fraction * 100))% · \(size(progress.downloadedBytes)) / \(size(progress.totalBytes))").monospacedDigit()
                    Spacer()
                    Text("Проверено файлов: \(progress.completedFiles) / \(profile.files.count)")
                }.font(.caption)
                if profile.files.indices.contains(progress.fileIndex) {
                    Text(profile.files[progress.fileIndex].localPath).font(.caption).lineLimit(2).textSelection(.enabled)
                }
                DisclosureGroup("Все файлы модели", isExpanded: $showFiles) {
                    ForEach(Array(profile.files.enumerated()), id: \.offset) { index, file in
                        HStack {
                            Image(systemName: index < progress.completedFiles ? "checkmark.circle.fill" : "doc")
                                .foregroundStyle(index < progress.completedFiles ? .green : .secondary)
                            Text(file.localPath).lineLimit(2).help(file.localPath)
                            Spacer()
                            if index == progress.fileIndex {
                                ProgressView(value: file.size > 0 ? Double(progress.fileBytes) / Double(file.size) : 0).frame(width: 70)
                            }
                            Text(size(file.size)).foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                }
            }
            Button("Отменить загрузку", action: model.cancelInstall).help("Отменить установку; проверенные файлы сохранятся для продолжения")
        }
    }
}
