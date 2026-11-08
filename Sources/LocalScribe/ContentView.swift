import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case recordings = "Записи", diagrams = "Схемы"
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var diagramWorkspace: DiagramWorkspaceModel
    @State private var mode: WorkspaceMode = .recordings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var recordingSheet = false
    @State private var deletingRecordings: SidebarDeletion?
    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _diagramWorkspace = StateObject(wrappedValue: DiagramWorkspaceModel(model: model))
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                if mode == .recordings {
                    RecordingGroupsSidebar(model: model, mode: $mode, deletion: $deletingRecordings) {
                        recordingSheet = true
                    }
                } else {
                    DiagramGroupsSidebar(model: model, workspace: diagramWorkspace, mode: $mode)
                }
            }.navigationTitle("LocalScribe")
                .navigationSplitViewColumnWidth(min: 280, ideal: 290)
            VStack(spacing: 6) {
                Label("Всё обрабатывается на Mac", systemImage: "lock.shield").font(.caption)
                    .accessibilityIdentifier("sidebar.localProcessing")
                Button((mode == .recordings ? model.modelsReady : model.diagramModelsReady) ? "Модели готовы" : "Установить модели") {
                    model.settingsWindow.show(tab: mode == .recordings ? .recordings : .diagrams)
                }
                .buttonStyle(.link).font(.caption).help("Открыть настройки и управление моделями")
                .accessibilityIdentifier("sidebar.models")
            }.foregroundStyle(.secondary).padding()
        } detail: {
            if mode == .recordings {
                RecordingDetailColumn(model: model, recordingSheet: $recordingSheet)
            } else {
                DiagramDetailColumn(model: model, workspace: diagramWorkspace)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.settingsWindow.show() } label: {
                    Label("Настройки", systemImage: "gearshape")
                }
                .help("Открыть настройки")
                .accessibilityIdentifier("workspace.settings")
            }
        }
        .background(WorkspaceKeyboardShortcut(handle: handleShortcut))
        .disabled(blocked)
    }

    private var blocked: Bool { model.preparingStorage || model.shuttingDown }

    private func handleShortcut(_ shortcut: WorkspaceKeyboardShortcut.Action) -> Bool {
        guard !blocked, !recordingSheet, deletingRecordings == nil, model.resultEdit == nil else { return false }
        switch shortcut {
        case .closeSelection:
            if mode == .diagrams {
                guard diagramWorkspace.selected != nil else { return false }
                diagramWorkspace.selection = nil
                model.selection = nil
                mode = .recordings
            } else {
                guard model.selected != nil else { return false }
                model.selection = nil
            }
            return true
        case .deleteRecordings:
            guard mode == .recordings, columnVisibility != .detailOnly else { return false }
            let search = model.recordingSearch
            var ids = model.sidebarSelection.ids
            if search.active {
                guard search.hasCurrentQueryResults else { return false }
                ids.formIntersection(model.sidebarRecordingOrder)
            }
            return SidebarDeletion.request(ids, model: model, presentation: $deletingRecordings)
        }
    }
}

struct RecordingStatusText: View {
    @ObservedObject var indicators: ActivityIndicators
    var finalizing: Bool
    var prefix: String

    var body: some View {
        Text(finalizing ? "Сохраняем аудио…" : "\(prefix) · \(timecode(Int(indicators.elapsed * 1000)))").monospacedDigit()
    }
}

struct ResultTextView: NSViewRepresentable {
    var result: RenderedExport; var jumpRequest: ResultJumpRequest?; var onJump: (String) -> Void
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
        if let jumpRequest, context.coordinator.target != jumpRequest,
           let range = context.coordinator.timestampRanges[jumpRequest.segmentID] {
            view.scrollRangeToVisible(range); view.setSelectedRange(range); context.coordinator.target = jumpRequest
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var current = RenderedExport(); var target: ResultJumpRequest?; var onJump: ((String)->Void)?
        var timestampRanges: [String: NSRange] = [:]
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string:$0) }
            if let url, url.scheme == "localscribe", url.host == "segment" { onJump?(url.lastPathComponent) }
            return true
        }
    }
}

enum SettingsTab {
    case recordings, diagrams, general
}

struct ModelSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var draft: SettingsDraft
    @State private var asrID = ""
    @State private var summaryID = ""
    @State private var diagramID = ""
    @State private var showFiles = false
    @State private var manuallyChosenRoles: Set<ModelRole> = []
    private var profiles: [ModelProfile] { model.catalog?.models ?? [] }
    private var recordingProfiles: [ModelProfile] { profiles.filter { $0.purpose != .diagram } }
    private var diagramProfiles: [ModelProfile] { profiles.filter { $0.purpose == .diagram } }
    private var downloads: [ModelProfile] { model.profilesToInstall(asrID: asrID, summaryID: summaryID) }
    private var downloadSelectionCompatible: Bool {
        let selected = profiles.filter { $0.id == asrID || $0.id == summaryID || $0.purpose == .diarization }
        return selected.contains { $0.id == asrID && $0.purpose == .asr } &&
            selected.contains { $0.id == summaryID && $0.purpose == .summary } &&
            selected.allSatisfy { model.hardware.compatibility(for: $0).isCompatible }
    }
    var body: some View {
        TabView(selection: $model.settingsTab) {
            Tab("Записи", systemImage: "waveform", value: .recordings) { recordingSettings }
            Tab("Схемы", systemImage: "square.grid.2x2", value: .diagrams) { diagramSettings }
            Tab("Общие", systemImage: "gearshape", value: .general) { generalSettings }
        }
        .onAppear { initializeSelection() }
        .onChange(of: profiles.map(\.id)) { _, _ in initializeSelection() }
        .onChange(of: model.modelLibrary.selectedByRole) { _, _ in initializeSelection() }
        .onChange(of: model.modelLibrary.installedAt) { _, installed in
            draft.modelIDs = draft.modelIDs.filter { installed[$0.value] != nil }
        }
    }

    private var recordingSettings: some View {
        Form {
            modelActivity
            Section("Модели записей") {
                if !model.installing && !model.verifyingModels { Text(model.modelsStatus) }
                Text("Выбранные модели применяются к новым заданиям. Сохранённые записи меняются только по команде «Продолжить», «Обработать заново» или «Пересоздать итоги».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Загрузить модели записей") {
                modelPicker("Распознавание", role: .asr, selection: $asrID)
                modelPicker("Итоги", role: .summary, selection: $summaryID)
                ForEach(profiles.filter { $0.id == asrID || $0.id == summaryID }) { profile in
                    if profile.experimental == true {
                        Text("Экспериментальный профиль · качество на встречах ещё не принято")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let ram = profile.recommendedMemoryGB, let working = profile.workingMemoryGB {
                        Text("RAM: от \(ram) ГБ · рабочий объём этапа: \(working) ГБ")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let description = profile.profileDescription {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                    if profile.purpose == .asr {
                        Text(profile.supportsClosedFragments ? "Фоновое распознавание: доступно" : "Только готовые записи; фоновое распознавание недоступно")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let warning = model.hardware.warning(for: profile) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button("Загрузить выбранные") { model.installModels(downloads) }.buttonStyle(.borderedProminent).disabled(downloads.isEmpty).help("Скачать выбранные модели и необходимые зависимости")
                    Text(!downloadSelectionCompatible ? "Нет совместимого комплекта" : downloads.isEmpty ? "Уже установлены" : "Всего: \(size(downloads.reduce(0) { $0 + $1.bytes }))").font(.caption).foregroundStyle(.secondary)
                }
                Text("Нужные токенизатор, выравниватель и модель участников загрузятся автоматически. После успешной установки новая модель станет выбранной; ранее загруженные останутся на диске.")
                    .font(.caption).foregroundStyle(.secondary)
                importPicker(recordingProfiles, identifier: "settings.models.import")
            }.disabled(!model.canManageModels)
            Section("Загруженные модели") {
                ForEach(profiles.filter { $0.purpose == nil && model.modelLibrary.isInstalled($0) }) { profile in
                    installedRow(profile)
                }
                if !recordingProfiles.contains(where: model.modelLibrary.isInstalled) {
                    Text("Пока нет загруженных моделей").foregroundStyle(.secondary)
                }
                ForEach(ModelRole.audioRoles, id: \.self) { role in
                    let installed = profiles.filter { $0.purpose == role && model.modelLibrary.isInstalled($0) }
                    if !installed.isEmpty {
                        Text(role.title).font(.caption).foregroundStyle(.secondary)
                        ForEach(installed) { profile in installedRow(profile) }
                    }
                }
            }
            Section {
                if let profile = selectedProfile(for: .asr), !profile.supportsClosedFragments {
                    Text("Выбранный профиль обрабатывает запись после остановки микрофона. Фоновое распознавание для него пока недоступно.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Распознавать во время записи", isOn: $draft.backgroundRecognition)
                    .toggleStyle(.checkbox)
                    .disabled(model.recordingID != nil || model.startingRecording || model.finalizingRecording)
                    .accessibilityIdentifier("settings.backgroundRecognition")
                    .help("Применяется с начала следующей записи. Обработка ждёт завершения старых заданий; участники и итоги — после остановки.")
                if draft.backgroundRecognition && !model.modelsReady {
                    Text("Для фонового распознавания сначала установите модели")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.backgroundRecognition.modelsRequired")
                }
                Toggle("Создавать автоматически итоги встречи", isOn: $draft.automaticSummaries)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("settings.automaticSummaries")
                    .help("Отключите, чтобы завершать обработку после расшифровки и определения участников. «Пересоздать итоги» с выбором языка доступно при любом значении настройки.")
            }
        }.formStyle(.grouped)
    }

    private var diagramSettings: some View {
        Form {
            modelActivity
            Section("Модели схем") {
                Group {
                    if let active = selectedProfile(for: .diagram), model.hardware.compatibility(for: active).isCompatible {
                        Text("Выбрана \(active.displayName) · распознавание без интернета")
                    } else {
                        Text("Загрузите или выберите совместимую модель схем")
                    }
                }
                .accessibilityIdentifier("settings.diagramModels.status")
                Text("Выбранная модель применяется к новым запускам распознавания схем.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if diagramProfiles.isEmpty {
                Section { Text("Профили моделей схем отсутствуют в каталоге").foregroundStyle(.secondary) }
            } else {
                Section("Загрузить модель схем") {
                    modelPicker("Распознавание", role: .diagram, selection: $diagramID)
                    if let profile = diagramProfiles.first(where: { $0.id == diagramID }) {
                        if let ram = profile.recommendedMemoryGB, let working = profile.workingMemoryGB {
                            Text("RAM: от \(ram) ГБ · рабочий объём этапа: \(working) ГБ")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let warning = model.hardware.warning(for: profile) {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button("Загрузить выбранную") { model.installModels([profile]) }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.modelLibrary.isInstalled(profile) || !model.hardware.compatibility(for: profile).isCompatible)
                                .accessibilityIdentifier("settings.diagramModels.install.\(profile.id)")
                            Text(model.modelLibrary.isInstalled(profile) ? "Уже установлена" : size(profile.bytes))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    importPicker(diagramProfiles, identifier: "settings.diagramModels.import")
                }.disabled(!model.canManageModels)
            }
            Section("Загруженные модели") {
                let installed = diagramProfiles.filter(model.modelLibrary.isInstalled)
                if installed.isEmpty { Text("Пока нет загруженных моделей").foregroundStyle(.secondary) }
                ForEach(installed) { profile in installedRow(profile) }
            }
        }.formStyle(.grouped)
    }

    private var generalSettings: some View {
        Form {
            modelActivity
            Section("Обслуживание моделей") {
                Button("Проверить установленные модели") { Task { await model.verifyModels() } }
                    .disabled(!model.canManageModels).help("Проверить целостность файлов установленных моделей")
                    .accessibilityIdentifier("settings.models.verify")
            }
            Section("Этот Mac") {
                Text("\(model.hardware.chip) · \(model.hardware.cpuCores) ядер CPU · \(model.hardware.memoryBytes / 1_073_741_824) ГБ RAM")
                    .accessibilityIdentifier("settings.hardware")
                Text("Доступно моделям с резервом системы: \(String(format: "%.1f ГБ", Double(model.hardware.modelBudgetBytes) / 1_073_741_824)). Бюджет GPU (Metal): \(String(format: "%.1f ГБ", Double(model.hardware.gpuWorkingSetBytes) / 1_073_741_824)). Модели запускаются по очереди; оценка памяти относится к одному этапу, а не к сумме всех скачанных моделей.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Локальные данные") {
                Button("Показать папку данных") { if let root = model.repository?.root { NSWorkspace.shared.open(root) } }.help("Открыть папку записей и моделей в Finder")
                Button("Лицензии") { NSWorkspace.shared.open(model.resources.appendingPathComponent("Licenses")) }.help("Открыть лицензии сторонних компонентов")
                Text("LocalScribe " + AppInfo.version + " · локальная предварительная сборка").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    @ViewBuilder private var modelActivity: some View {
        if model.installing || model.verifyingModels {
            Section("Операции с моделями") {
                Text(model.modelsStatus)
                if model.installing { downloadStatus }
                else { ProgressView().controlSize(.small) }
            }
        }
    }

    private func initializeSelection() {
        if !manuallyChosenRoles.contains(.asr) { asrID = model.initialModelID(for: .asr) }
        if !manuallyChosenRoles.contains(.summary) { summaryID = model.initialModelID(for: .summary) }
        if !manuallyChosenRoles.contains(.diagram) { diagramID = model.initialModelID(for: .diagram) }
    }
    private func menuOption(_ profile: ModelProfile) -> ModelMenuOption {
        ModelMenuOption(profile: profile, hardware: model.hardware, recommended: model.isRecommended(profile))
    }
    private func importPicker(_ candidates: [ModelProfile], identifier: String) -> some View {
        ModelPopup(options: candidates.map(menuOption), selection: .constant(""), prompt: "Импортировать из папки…", imports: true) { id in
            if let profile = candidates.first(where: { $0.id == id }) { model.importModel(profile) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
    }
    private func modelPicker(_ title: String, role: ModelRole, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
            ModelPopup(options: profiles.filter { $0.purpose == role }.map(menuOption), selection: Binding(
                get: { selection.wrappedValue },
                set: { value in manuallyChosenRoles.insert(role); selection.wrappedValue = value }
            ))
                .accessibilityLabel(title)
                .accessibilityIdentifier("settings.models.\(role.rawValue)")
        }
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func selectedProfile(for role: ModelRole) -> ModelProfile? {
        let id = draft.modelIDs[role] ?? model.modelLibrary.selectedByRole[role.rawValue]
        return profiles.first { $0.id == id && model.modelLibrary.isInstalled($0) }
    }
    @ViewBuilder private func installedRow(_ profile: ModelProfile) -> some View {
        HStack(alignment: .top) {
            if let role = profile.purpose, role == .asr || role == .summary || role == .diagram {
                Toggle(isOn: Binding(
                    get: { selectedProfile(for: role)?.id == profile.id },
                    set: { checked in
                        if checked { draft.modelIDs[role] = model.modelLibrary.isSelected(profile) ? nil : profile.id }
                    }
                )) {
                    Text(profile.displayName + (model.isRecommended(profile) ? " · Максимально рекомендуется" : ""))
                        .fontWeight(model.isRecommended(profile) ? .bold : .regular)
                }
                .toggleStyle(.checkbox)
                .disabled(!model.canManageModels || !model.hardware.compatibility(for: profile).isCompatible)
                .foregroundStyle(model.hardware.compatibility(for: profile).isCompatible ? Color.primary : Color.secondary)
                .help(model.hardware.warning(for: profile) ?? "Использовать \(profile.displayName) для новых заданий")
                .accessibilityIdentifier("settings.\(profile.purpose == .diagram ? "diagramModels" : "models").installed.\(profile.id)")
                .accessibilityHint(model.hardware.warning(for: profile) ?? "Модель совместима с этим Mac")
            } else {
                Label(profile.displayName, systemImage: model.modelLibrary.isSelected(profile) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.hardware.compatibility(for: profile).isCompatible ? Color.primary : Color.secondary)
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
                    let file = profile.files[progress.fileIndex]
                    Text(file.localPath).font(.caption).lineLimit(2).textSelection(.enabled)
                    if model.downloadingModels,
                       let url = try? ModelProfile.downloadURL(repository: profile.repository, revision: profile.revision, path: file.path) {
                        Text("Источник: \(url.absoluteString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings.models.downloadSource")
                    }
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
