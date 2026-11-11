import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case recordings = "Записи", diagrams = "Схемы"
    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var diagramWorkspace: DiagramWorkspaceModel
    @State private var mode: WorkspaceMode = .recordings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var recordingSheet = false
    @State private var deletingRecordings: SidebarDeletion?
    @State private var deletingDiagrams: SidebarDiagramDeletion?
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
                    DiagramGroupsSidebar(model: model, workspace: diagramWorkspace, mode: $mode, deletion: $deletingDiagrams)
                }
            }.navigationSplitViewColumnWidth(min: 300, ideal: 300)
            VStack(spacing: 6) {
                Label(L10n.text("Всё обрабатывается на Mac"), systemImage: "lock.shield").font(.caption)
                    .accessibilityIdentifier("sidebar.localProcessing")
                Button((mode == .recordings ? model.modelsReady : model.diagramModelsReady) ? L10n.text("Модели готовы") : L10n.text("Установить модели")) {
                    model.settingsWindow.show(tab: mode == .recordings ? .recordings : .diagrams)
                }
                .buttonStyle(.link).font(.caption).help(L10n.text("Открыть настройки и управление моделями"))
                .accessibilityIdentifier("sidebar.models")
            }.foregroundStyle(.secondary).padding()
        } detail: {
            if mode == .recordings {
                RecordingDetailColumn(model: model, recordingSheet: $recordingSheet)
            } else {
                DiagramDetailColumn(model: model, workspace: diagramWorkspace) { id in
                    SidebarDiagramDeletion.request([id], model: model, presentation: $deletingDiagrams)
                }
            }
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem { Spacer() }
            ToolbarItem {
                Button { model.settingsWindow.show() } label: {
                    Label(L10n.text("Настройки"), systemImage: "gearshape")
                }
                .help(L10n.text("Открыть настройки"))
                .accessibilityIdentifier("workspace.settings")
            }
        }
        .sheet(item: $deletingDiagrams) { deletion in
            DeleteDiagramsView(workspace: diagramWorkspace, ids: deletion.ids) { deletingDiagrams = nil }
        }
        .background(WorkspaceKeyboardShortcut(handle: handleShortcut))
        .disabled(blocked)
    }

    private var blocked: Bool { model.preparingStorage || model.shuttingDown }

    private func handleShortcut(_ shortcut: WorkspaceKeyboardShortcut.Action) -> Bool {
        guard !blocked, !recordingSheet, deletingRecordings == nil, deletingDiagrams == nil,
              model.resultEdit == nil else { return false }
        switch shortcut {
        case .closeSelection:
            if mode == .diagrams {
                guard diagramWorkspace.selected != nil else { return false }
                diagramWorkspace.selection = nil
            } else {
                guard model.selected != nil else { return false }
                model.selection = nil
            }
            return true
        case .deleteSelection:
            guard columnVisibility != .detailOnly else { return false }
            if mode == .diagrams {
                let search = diagramWorkspace.search
                var ids = diagramWorkspace.sidebarSelection.ids
                if search.active {
                    guard search.hasCurrentQueryResults else { return false }
                    ids.formIntersection(diagramWorkspace.sidebarDiagramOrder)
                }
                return SidebarDiagramDeletion.request(ids, model: model, presentation: $deletingDiagrams)
            }
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
        Text(finalizing ? L10n.text("Сохраняем аудио…") : "\(prefix) · \(timecode(Int(indicators.elapsed * 1000)))").monospacedDigit()
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
            Tab(L10n.text("Записи"), systemImage: "waveform", value: .recordings) { recordingSettings }
            Tab(L10n.text("Схемы"), systemImage: "square.grid.2x2", value: .diagrams) { diagramSettings }
            Tab(L10n.text("Общие"), systemImage: "gearshape", value: .general) { generalSettings }
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
            Section(L10n.text("Источники записи")) {
                CaptureSourceSettings(draft: draft, devices: model.microphoneDevices)
            }
            modelActivity
            Section(L10n.text("Модели записей")) {
                if !model.installing && !model.verifyingModels { Text(model.modelsStatus) }
                Text(L10n.text("Выбранные модели применяются к новым заданиям. Сохранённые записи меняются только по команде «Продолжить», «Обработать заново» или «Пересоздать итоги»."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Загрузить модели записей")) {
                modelPicker(L10n.text("Распознавание"), role: .asr, selection: $asrID)
                modelPicker(L10n.text("Итоги"), role: .summary, selection: $summaryID)
                ForEach(profiles.filter { $0.id == asrID || $0.id == summaryID }) { profile in
                    if profile.experimental == true {
                        Text(L10n.text("Экспериментальный профиль · качество на встречах ещё не принято"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let ram = profile.recommendedMemoryGB, let working = profile.workingMemoryGB {
                        Text(L10n.text("RAM: от %1$@ ГБ · рабочий объём этапа: %2$@ ГБ", String(ram), String(working)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let description = profile.displayDescription {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                    if profile.purpose == .asr {
                        Text(profile.supportsClosedFragments ? L10n.text("Фоновое распознавание: доступно") : L10n.text("Только готовые записи; фоновое распознавание недоступно"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let warning = model.hardware.warning(for: profile) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button(L10n.text("Загрузить выбранные")) { model.installModels(downloads) }.buttonStyle(.borderedProminent).disabled(downloads.isEmpty).help(L10n.text("Скачать выбранные модели и необходимые зависимости"))
                    Text(!downloadSelectionCompatible ? L10n.text("Нет совместимого комплекта") : downloads.isEmpty ? L10n.text("Уже установлены") : L10n.text("Всего: %1$@", size(downloads.reduce(0) { $0 + $1.bytes }))).font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.text("Нужные токенизатор, выравниватель и модель участников загрузятся автоматически. После успешной установки новая модель станет выбранной; ранее загруженные останутся на диске."))
                    .font(.caption).foregroundStyle(.secondary)
                importPicker(recordingProfiles, identifier: "settings.models.import")
            }.disabled(!model.canManageModels)
            Section(L10n.text("Загруженные модели")) {
                ForEach(profiles.filter { $0.purpose == nil && model.modelLibrary.isInstalled($0) }) { profile in
                    installedRow(profile)
                }
                if !recordingProfiles.contains(where: model.modelLibrary.isInstalled) {
                    Text(L10n.text("Пока нет загруженных моделей")).foregroundStyle(.secondary)
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
                    Text(L10n.text("Выбранный профиль обрабатывает запись после остановки микрофона. Фоновое распознавание для него пока недоступно."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L10n.text("Распознавать во время записи"), isOn: $draft.backgroundRecognition)
                    .toggleStyle(.checkbox)
                    .disabled(model.recordingID != nil || model.startingRecording || model.finalizingRecording)
                    .accessibilityIdentifier("settings.backgroundRecognition")
                    .help(L10n.text("Применяется с начала следующей записи. Обработка ждёт завершения старых заданий; участники и итоги — после остановки."))
                if draft.backgroundRecognition && !model.modelsReady {
                    Text(L10n.text("Для фонового распознавания сначала установите модели"))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.backgroundRecognition.modelsRequired")
                }
                Toggle(L10n.text("Создавать автоматически итоги встречи"), isOn: $draft.automaticSummaries)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("settings.automaticSummaries")
                    .help(L10n.text("Отключите, чтобы завершать обработку после расшифровки и определения участников. «Пересоздать итоги» с выбором языка доступно при любом значении настройки."))
            }
        }.formStyle(.grouped)
    }

    private var diagramSettings: some View {
        Form {
            modelActivity
            Section(L10n.text("Модели схем")) {
                Group {
                    if let active = selectedProfile(for: .diagram), model.hardware.compatibility(for: active).isCompatible {
                        Text(L10n.text("Выбрана %1$@ · распознавание без интернета", active.displayName))
                    } else {
                        Text(L10n.text("Загрузите или выберите совместимую модель схем"))
                    }
                }
                .accessibilityIdentifier("settings.diagramModels.status")
                Text(L10n.text("Выбранная модель применяется к новым запускам распознавания схем."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if diagramProfiles.isEmpty {
                Section { Text(L10n.text("Профили моделей схем отсутствуют в каталоге")).foregroundStyle(.secondary) }
            } else {
                Section(L10n.text("Загрузить модель схем")) {
                    modelPicker(L10n.text("Распознавание"), role: .diagram, selection: $diagramID)
                    if let profile = diagramProfiles.first(where: { $0.id == diagramID }) {
                        if let ram = profile.recommendedMemoryGB, let working = profile.workingMemoryGB {
                            Text(L10n.text("RAM: от %1$@ ГБ · рабочий объём этапа: %2$@ ГБ", String(ram), String(working)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let warning = model.hardware.warning(for: profile) {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button(L10n.text("Загрузить выбранную")) { model.installModels([profile]) }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.modelLibrary.isInstalled(profile) || !model.hardware.compatibility(for: profile).isCompatible)
                                .accessibilityIdentifier("settings.diagramModels.install.\(profile.id)")
                            Text(model.modelLibrary.isInstalled(profile) ? L10n.text("Уже установлена") : size(profile.bytes))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    importPicker(diagramProfiles, identifier: "settings.diagramModels.import")
                }.disabled(!model.canManageModels)
            }
            Section(L10n.text("Загруженные модели")) {
                let installed = diagramProfiles.filter(model.modelLibrary.isInstalled)
                if installed.isEmpty { Text(L10n.text("Пока нет загруженных моделей")).foregroundStyle(.secondary) }
                ForEach(installed) { profile in installedRow(profile) }
            }
        }.formStyle(.grouped)
    }

    private var generalSettings: some View {
        Form {
            Section(L10n.text("Язык")) {
                Picker(L10n.text("Язык приложения"), selection: $draft.applicationLanguage) {
                    ForEach(ApplicationLanguage.allCases, id: \.self) { language in
                        Text(language.title).tag(language)
                    }
                }
                .accessibilityIdentifier("settings.applicationLanguage")
                Text(L10n.text("Изменение языка вступит в силу после перезапуска приложения."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            modelActivity
            Section(L10n.text("Обслуживание моделей")) {
                Button(L10n.text("Проверить установленные модели")) { Task { await model.verifyModels() } }
                    .disabled(!model.canManageModels).help(L10n.text("Проверить целостность файлов установленных моделей"))
                    .accessibilityIdentifier("settings.models.verify")
            }
            Section(L10n.text("Этот Mac")) {
                Text(L10n.text("%1$@ · %2$@ ядер CPU · %3$@ ГБ RAM", model.hardware.chip, String(model.hardware.cpuCores), String(model.hardware.memoryBytes / 1_073_741_824)))
                    .accessibilityIdentifier("settings.hardware")
                Text(L10n.text("Доступно моделям с резервом системы: %1$@ ГБ. Бюджет GPU (Metal): %2$@ ГБ. Модели запускаются по очереди; оценка памяти относится к одному этапу, а не к сумме всех скачанных моделей.", memoryGB(model.hardware.modelBudgetBytes), memoryGB(model.hardware.gpuWorkingSetBytes)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("Локальные данные")) {
                Button(L10n.text("Показать папку данных")) { if let root = model.repository?.root { NSWorkspace.shared.open(root) } }.help(L10n.text("Открыть папку записей и моделей в Finder"))
                Button(L10n.text("Лицензии")) { NSWorkspace.shared.open(model.resources.appendingPathComponent("Licenses")) }.help(L10n.text("Открыть лицензии сторонних компонентов"))
                Text(L10n.text("LocalScribe %1$@ · локальная предварительная сборка", AppInfo.version)).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    @ViewBuilder private var modelActivity: some View {
        if model.installing || model.verifyingModels {
            Section(L10n.text("Операции с моделями")) {
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
        ModelPopup(options: candidates.map(menuOption), selection: .constant(""), prompt: L10n.text("Импортировать из папки…"), imports: true) { id in
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
    private func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file).locale(L10n.locale)) }
    private func memoryGB(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))
    }
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
                    Text(model.isRecommended(profile) ? L10n.text("%1$@ · Максимально рекомендуется", profile.displayName) : profile.displayName)
                        .fontWeight(model.isRecommended(profile) ? .bold : .regular)
                }
                .toggleStyle(.checkbox)
                .disabled(!model.canManageModels || !model.hardware.compatibility(for: profile).isCompatible)
                .foregroundStyle(model.hardware.compatibility(for: profile).isCompatible ? Color.primary : Color.secondary)
                .help(model.hardware.warning(for: profile) ?? L10n.text("Использовать %1$@ для новых заданий", profile.displayName))
                .accessibilityIdentifier("settings.\(profile.purpose == .diagram ? "diagramModels" : "models").installed.\(profile.id)")
                .accessibilityHint(model.hardware.warning(for: profile) ?? L10n.text("Модель совместима с этим Mac"))
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
                .buttonStyle(.borderless).help(L10n.text("Удалить %1$@", profile.displayName)).accessibilityLabel(L10n.text("Удалить %1$@", profile.displayName)).disabled(!model.canManageModels)
        }
    }
    @ViewBuilder private var downloadStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.downloadBatch).fontWeight(.medium)
            if let progress = model.downloadProgress, let profile = profiles.first(where: { $0.id == progress.profileID }) {
                ProgressView(value: progress.fraction).accessibilityLabel(L10n.text("Общий прогресс загрузки модели"))
                HStack {
                    Text("\(Int(progress.fraction * 100))% · \(size(progress.downloadedBytes)) / \(size(progress.totalBytes))").monospacedDigit()
                    Spacer()
                    Text(L10n.text("Проверено файлов: %1$@ / %2$@", String(progress.completedFiles), String(profile.files.count)))
                }.font(.caption)
                if profile.files.indices.contains(progress.fileIndex) {
                    let file = profile.files[progress.fileIndex]
                    Text(file.localPath).font(.caption).lineLimit(2).textSelection(.enabled)
                    if model.downloadingModels,
                       let url = try? ModelProfile.downloadURL(repository: profile.repository, revision: profile.revision, path: file.path) {
                        Text(L10n.text("Источник: %1$@", url.absoluteString))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings.models.downloadSource")
                    }
                }
                DisclosureGroup(L10n.text("Все файлы модели"), isExpanded: $showFiles) {
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
            Button(L10n.text("Отменить загрузку"), action: model.cancelInstall).help(L10n.text("Отменить установку; проверенные файлы сохранятся для продолжения"))
        }
    }
}

private struct CaptureSourceSettings: View {
    private enum Choice: Hashable {
        case builtIn, systemDefault, device(String)
    }

    @ObservedObject var draft: SettingsDraft
    @ObservedObject var devices: MicrophoneDevices

    private var selection: MicrophoneSelection { draft.recordingSources.microphone }
    private var connectedMicrophones: [MicrophoneInputDevice] { devices.snapshot.devices.filter { !$0.isBuiltIn } }

    private var microphoneChoice: Binding<Choice> {
        Binding {
            switch selection {
            case .builtIn: return .builtIn
            case .systemDefault: return .systemDefault
            case .device(let uid, _): return .device(uid)
            }
        } set: { choice in
            switch choice {
            case .builtIn: draft.recordingSources.microphone = .builtIn
            case .systemDefault: draft.recordingSources.microphone = .systemDefault
            case .device(let uid):
                if let device = devices.snapshot.devices.first(where: { $0.uid == uid }) {
                    draft.recordingSources.microphone = device.selection
                }
            }
        }
    }

    var body: some View {
        Toggle(L10n.text("Микрофон"), isOn: $draft.recordingSources.microphoneEnabled)
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("settings.recordingMicrophoneEnabled")
        Picker(L10n.text("Устройство ввода"), selection: microphoneChoice) {
            Text(L10n.text("Встроенный микрофон")).tag(Choice.builtIn)
            Text(L10n.text("Как в настройках macOS")).tag(Choice.systemDefault)
            if !connectedMicrophones.isEmpty {
                Section(L10n.text("Подключённые микрофоны")) {
                    ForEach(connectedMicrophones) { device in
                        Text(device.name).tag(Choice.device(device.uid))
                    }
                }
            }
            if case let .device(uid, name) = selection, !connectedMicrophones.contains(where: { $0.uid == uid }) {
                Text(devices.snapshot.device(for: selection)?.name ?? name).tag(Choice.device(uid))
            }
        }
        .disabled(!draft.recordingSources.microphoneEnabled)
        .accessibilityIdentifier("settings.recordingMicrophone")
        if devices.snapshot.device(for: selection) == nil {
            Text(unavailableTitle)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.recordingMicrophone.unavailable")
            if draft.recordingSources.microphoneEnabled,
               let fallback = devices.snapshot.candidates(for: selection).first {
                Text(L10n.text("Резервный микрофон: %1$@", fallback.isBuiltIn ? L10n.text("Встроенный микрофон") : fallback.name))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.recordingMicrophone.fallback")
            }
        }
        Toggle(L10n.text("Системный звук"), isOn: $draft.recordingSources.systemAudioEnabled)
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("settings.recordingSystemAudioEnabled")
        if !draft.recordingSources.hasEnabledSource {
            Text(L10n.message("Включите хотя бы один источник записи."))
                .foregroundStyle(.secondary)
        }
        Text(L10n.text("Изменения применяются к следующей записи."))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var unavailableTitle: String {
        if case .device = selection { return L10n.text("Не подключён") }
        return L10n.message(selection.unavailableMessage)
    }
}
