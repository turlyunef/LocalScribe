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
    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _diagramWorkspace = StateObject(wrappedValue: DiagramWorkspaceModel(model: model))
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if mode == .recordings {
                    RecordingGroupsSidebar(model: model, mode: $mode)
                } else {
                    DiagramGroupsSidebar(model: model, workspace: diagramWorkspace, mode: $mode)
                }
            }.navigationTitle("LocalScribe")
                .navigationSplitViewColumnWidth(min: 240, ideal: 290)
            VStack(spacing: 6) {
                Label("Всё обрабатывается на Mac", systemImage: "lock.shield").font(.caption)
                    .accessibilityIdentifier("sidebar.localProcessing")
                SettingsLink { Text(model.modelsReady ? "Модели готовы" : "Установить модели") }.font(.caption).help("Открыть настройки и управление моделями")
                    .accessibilityIdentifier("sidebar.models")
            }.foregroundStyle(.secondary).padding()
        } detail: {
            if mode == .recordings {
                RecordingDetailColumn(model: model)
            } else {
                DiagramDetailColumn(model: model, workspace: diagramWorkspace)
            }
        }
        .disabled(model.preparingStorage || model.shuttingDown)
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

struct ModelSettings: View {
    @ObservedObject var model: AppModel
    @State private var asrID = ""
    @State private var summaryID = ""
    @State private var showFiles = false
    @State private var manuallyChosenRoles: Set<ModelRole> = []
    private var profiles: [ModelProfile] { model.catalog?.models ?? [] }
    private var downloads: [ModelProfile] { model.profilesToInstall(asrID: asrID, summaryID: summaryID) }
    private var downloadSelectionCompatible: Bool {
        let selected = profiles.filter { $0.id == asrID || $0.id == summaryID || $0.purpose == .diarization }
        return selected.contains { $0.id == asrID && $0.purpose == .asr } &&
            selected.contains { $0.id == summaryID && $0.purpose == .summary } &&
            selected.allSatisfy { model.hardware.compatibility(for: $0).isCompatible }
    }
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
                ModelPopup(options: profiles.map(menuOption), selection: .constant(""), prompt: "Импортировать из папки…", imports: true) { id in
                    if let profile = profiles.first(where: { $0.id == id }) { model.importModel(profile) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings.models.import")
            }.disabled(!model.canManageModels)
            Section("Модель схем (режим «Схемы»)") {
                Text(model.diagramModelsReady ? "Модель схем готова · распознавание без интернета" : "Загрузите модель схем; полный комплект моделей записей для этого не нужен")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.diagramModels.status")
                ForEach(profiles.filter { $0.purpose == .diagram }) { profile in
                    diagramProfileRow(profile)
                }
                if profiles.filter({ $0.purpose == .diagram }).isEmpty {
                    Text("Профиль модели схем отсутствует в каталоге").foregroundStyle(.secondary)
                }
            }
            Section("Загруженные модели") {
                ForEach(profiles.filter { $0.purpose == nil && model.modelLibrary.isInstalled($0) }) { profile in
                    installedRow(profile)
                }
                if model.modelLibrary.installedAt.isEmpty { Text("Пока нет загруженных моделей").foregroundStyle(.secondary) }
                ForEach(ModelRole.audioRoles, id: \.self) { role in
                    let installed = profiles.filter { $0.purpose == role && model.modelLibrary.isInstalled($0) }
                    if !installed.isEmpty {
                        Text(role.title).font(.caption).foregroundStyle(.secondary)
                        ForEach(installed) { profile in installedRow(profile) }
                    }
                }
            }
            Section {
                if let profile = model.activeCatalog?.models.first(where: { $0.purpose == .asr }), !profile.supportsClosedFragments {
                    Text("Выбранный профиль обрабатывает запись после остановки микрофона. Фоновое распознавание для него пока недоступно.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Распознавать во время записи", isOn: $model.backgroundRecognition)
                    .toggleStyle(.checkbox)
                    .disabled(model.recordingID != nil || model.startingRecording || model.finalizingRecording)
                    .accessibilityIdentifier("settings.backgroundRecognition")
                    .help("Применяется с начала следующей записи. Обработка ждёт завершения старых заданий; участники и итоги — после остановки.")
                if model.backgroundRecognition && !model.modelsReady {
                    Text("Для фонового распознавания сначала установите модели")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.backgroundRecognition.modelsRequired")
                }
                Toggle("Создавать автоматически итоги встречи", isOn: $model.automaticSummaries)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("settings.automaticSummaries")
                    .help("Отключите, чтобы завершать обработку после расшифровки и определения участников. «Пересоздать итоги» с выбором языка доступно при любом значении настройки.")
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
            .onAppear { initializeSelection() }
            .onChange(of: profiles.map(\.id)) { _, _ in initializeSelection() }
            .onChange(of: model.modelLibrary.selectedByRole) { _, _ in initializeSelection() }
    }
    private func initializeSelection() {
        if !manuallyChosenRoles.contains(.asr) { asrID = model.initialModelID(for: .asr) }
        if !manuallyChosenRoles.contains(.summary) { summaryID = model.initialModelID(for: .summary) }
    }
    private func menuOption(_ profile: ModelProfile) -> ModelMenuOption {
        ModelMenuOption(profile: profile, hardware: model.hardware, recommended: model.isRecommended(profile))
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
    /// The optional diagram model: installation never affects audio readiness
    /// and never queues recordings or diagrams.
    @ViewBuilder private func diagramProfileRow(_ profile: ModelProfile) -> some View {
        HStack(alignment: .top) {
            if model.modelLibrary.isInstalled(profile) {
                Toggle(isOn: Binding(get: { model.modelLibrary.isSelected(profile) }, set: { checked in if checked { model.selectModel(profile) } })) {
                    Text(profile.displayName)
                }
                .toggleStyle(.checkbox)
                .disabled(!model.canManageModels || !model.hardware.compatibility(for: profile).isCompatible)
                .help(model.hardware.warning(for: profile) ?? "Использовать \(profile.displayName) для распознавания схем")
                .accessibilityIdentifier("settings.diagramModels.installed.\(profile.id)")
                Spacer()
                Text(size(profile.bytes)).font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { model.removeModel(profile) } label: { Image(systemName: "trash").foregroundStyle(.red) }
                    .buttonStyle(.borderless).help("Удалить \(profile.displayName)").accessibilityLabel("Удалить \(profile.displayName)")
                    .disabled(!model.canManageModels)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(profile.displayName)
                        Spacer()
                        Button("Загрузить") { model.installModels([profile]) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canManageModels || !model.hardware.compatibility(for: profile).isCompatible)
                            .help("Скачать и проверить все файлы модели")
                            .accessibilityIdentifier("settings.diagramModels.install.\(profile.id)")
                        Text(size(profile.bytes)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let ram = profile.recommendedMemoryGB, let working = profile.workingMemoryGB {
                        Text("RAM: от \(ram) ГБ · рабочий объём: \(working) ГБ").font(.caption).foregroundStyle(.secondary)
                    }
                    if let description = profile.profileDescription {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                    if let warning = model.hardware.warning(for: profile) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
    @ViewBuilder private func installedRow(_ profile: ModelProfile) -> some View {
        HStack(alignment: .top) {
            if profile.purpose == .asr || profile.purpose == .summary {
                Toggle(isOn: Binding(get: { model.modelLibrary.isSelected(profile) }, set: { checked in if checked { model.selectModel(profile) } })) {
                    Text(profile.displayName + (model.isRecommended(profile) ? " · Максимально рекомендуется" : ""))
                        .fontWeight(model.isRecommended(profile) ? .bold : .regular)
                }
                .toggleStyle(.checkbox)
                .disabled(!model.canManageModels || !model.hardware.compatibility(for: profile).isCompatible)
                .foregroundStyle(model.hardware.compatibility(for: profile).isCompatible ? Color.primary : Color.secondary)
                .help(model.hardware.warning(for: profile) ?? "Использовать \(profile.displayName) для новых заданий")
                .accessibilityIdentifier("settings.models.installed.\(profile.id)")
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
