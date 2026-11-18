import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import LocalScribeCore

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case recordings = "Записи", diagrams = "Схемы", anonymization = "Обезличивание"
    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
}

struct ContentView: View {
    private static let sidebarWidth: CGFloat = 300

    @ObservedObject var model: AppModel
    @StateObject private var diagramWorkspace: DiagramWorkspaceModel
    @StateObject private var textWorkspace: AnonymizationWorkspaceModel
    @State private var mode: WorkspaceMode = .recordings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var recordingSheet = false
    @State private var deletingRecordings: SidebarDeletion?
    @State private var deletingDiagrams: SidebarDiagramDeletion?
    @State private var deletingTexts: SidebarTextDeletion?
    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _diagramWorkspace = StateObject(wrappedValue: DiagramWorkspaceModel(model: model))
        _textWorkspace = StateObject(wrappedValue: AnonymizationWorkspaceModel(model: model))
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                WorkspaceModePicker(mode: $mode)
                switch mode {
                case .recordings:
                    RecordingGroupsSidebar(model: model, deletion: $deletingRecordings) {
                        recordingSheet = true
                    }
                case .diagrams:
                    DiagramGroupsSidebar(model: model, workspace: diagramWorkspace, deletion: $deletingDiagrams)
                case .anonymization:
                    AnonymizationGroupsSidebar(model: model, workspace: textWorkspace, deletion: $deletingTexts)
                }
            }
            .frame(minWidth: Self.sidebarWidth)
            .navigationSplitViewColumnWidth(min: Self.sidebarWidth, ideal: Self.sidebarWidth)
            VStack(spacing: 6) {
                Label(L10n.text("Всё обрабатывается на Mac"), systemImage: "lock.shield").font(.caption)
                    .accessibilityIdentifier("sidebar.localProcessing")
                Button(modelsReadyLabel) {
                    model.settingsWindow.show(tab: settingsTab)
                }
                .buttonStyle(.link).font(.caption).help(L10n.text("Открыть настройки и управление моделями"))
                .accessibilityIdentifier("sidebar.models")
            }.foregroundStyle(.secondary).padding()
        } detail: {
            ZStack(alignment: .topLeading) {
                switch mode {
                case .recordings:
                    RecordingDetailColumn(model: model, recordingSheet: $recordingSheet)
                case .diagrams:
                    DiagramDetailColumn(model: model, workspace: diagramWorkspace) { id in
                        SidebarDiagramDeletion.request([id], model: model, presentation: $deletingDiagrams)
                    }
                case .anonymization:
                    AnonymizationDetailColumn(workspace: textWorkspace) { id in
                        // The card's trash button concerns only the open card.
                        SidebarTextDeletion.request([id], model: model, presentation: $deletingTexts)
                    }
                }
            }
            .ignoresSafeArea(.container, edges: sidebarVisible ? .top : [])
            .background {
                WorkspaceToolbar(sidebarVisible: sidebarVisible,
                                 showSidebar: { columnVisibility = .all },
                                 openSettings: blocked ? nil : { model.settingsWindow.show() })
            }
        }
        .sheet(item: $deletingDiagrams) { deletion in
            DeleteDiagramsView(workspace: diagramWorkspace, ids: deletion.ids) { deletingDiagrams = nil }
        }
        .sheet(item: $deletingTexts) { deletion in
            DeleteTextCardsView(model: model, ids: deletion.ids) { deletingTexts = nil }
        }
        .background(WorkspaceKeyboardShortcut(handle: handleShortcut))
        // Leaving the texts section is explicit navigation: imported cards of
        // a running batch stop auto-opening afterwards (AC-36).
        .onChange(of: mode) { previous, current in
            if previous == .anonymization, current != previous {
                textWorkspace.stopImportAutoReveal()
            }
        }
        .onChange(of: model.recordingID) { _, id in
            if id != nil, model.captureCaptions?.recordingID == id { mode = .recordings }
        }
        .disabled(blocked)
    }

    private var blocked: Bool { model.preparingStorage || model.shuttingDown }
    private var sidebarVisible: Bool { columnVisibility != .detailOnly }

    private var settingsTab: SettingsTab {
        switch mode {
        case .recordings: return .recordings
        case .diagrams: return .diagrams
        case .anonymization: return .anonymization
        }
    }

    private var modelsReadyLabel: String {
        let ready: Bool
        switch mode {
        case .recordings: ready = model.modelsReady
        case .diagrams: ready = model.diagramModelsReady
        case .anonymization: ready = model.anonymizationModelsReady
        }
        return ready ? L10n.text("Модели готовы") : L10n.text("Установить модели")
    }

    private func handleShortcut(_ shortcut: WorkspaceKeyboardShortcut.Action) -> Bool {
        guard !blocked, !recordingSheet, deletingRecordings == nil, deletingDiagrams == nil,
              deletingTexts == nil, model.resultEdit == nil else { return false }
        switch shortcut {
        case .command(let command):
            return handleCommand(command)
        case .togglePlayback:
            // Space drives the player of the open recording card only; other
            // sections and cards without audio pass the key through.
            guard mode == .recordings, model.playbackSource != nil else { return false }
            model.playback.toggle()
            return true
        case .selectAdjacent(let down):
            // Arrows drive the visible list of the open section only.
            switch mode {
            case .recordings: return model.moveSidebarSelection(down: down)
            case .diagrams: return diagramWorkspace.moveSidebarSelection(down: down)
            case .anonymization: return textWorkspace.moveSidebarSelection(down: down)
            }
        case .closeSelection:
            switch mode {
            case .diagrams:
                guard diagramWorkspace.selected != nil else { return false }
                diagramWorkspace.selection = nil
            case .anonymization:
                guard textWorkspace.selected != nil else { return false }
                textWorkspace.selection = nil
            case .recordings:
                guard model.selected != nil else { return false }
                model.selection = nil
            }
            return true
        case .deleteSelection:
            guard columnVisibility != .detailOnly else { return false }
            switch mode {
            case .diagrams:
                let search = diagramWorkspace.search
                var ids = diagramWorkspace.sidebarSelection.ids
                if search.active {
                    guard search.hasCurrentQueryResults else { return false }
                    ids.formIntersection(diagramWorkspace.sidebarDiagramOrder)
                }
                return SidebarDiagramDeletion.request(ids, model: model, presentation: $deletingDiagrams)
            case .anonymization:
                // The confirmation set comes from the section selection,
                // narrowed to the current search results while a filter is
                // active (AC-24).
                let search = textWorkspace.search
                var ids = textWorkspace.sidebarSelection.ids
                if search.active {
                    guard search.hasCurrentQueryResults else { return false }
                    ids.formIntersection(textWorkspace.sidebarTextOrder)
                }
                return SidebarTextDeletion.request(ids, model: model, presentation: $deletingTexts)
            case .recordings:
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

    private func handleCommand(_ command: WorkspaceCommand) -> Bool {
        switch command {
        case .newRecording:
            guard model.canStartRecording else { return false }
            mode = .recordings
            recordingSheet = true
        case .recordings: mode = .recordings
        case .diagrams: mode = .diagrams
        case .anonymization: mode = .anonymization
        case .importFile:
            switch mode {
            case .recordings: model.chooseImport()
            case .diagrams: diagramWorkspace.presentImportPanel()
            case .anonymization: return false // The text card knows which import action is visible.
            }
        case .revealSource:
            switch mode {
            case .recordings:
                guard model.selected != nil else { return false }
                model.showAudio()
            case .diagrams:
                guard let diagram = diagramWorkspace.selected else { return false }
                diagramWorkspace.showImageInFinder(diagram)
            case .anonymization: return false
            }
        case .copyResult:
            switch mode {
            case .recordings:
                guard model.selected != nil, model.resultTabs.contains(model.tab),
                      let part = model.tab.exportPart else { return false }
                model.copy(part)
            case .diagrams:
                guard diagramWorkspace.result != nil else { return false }
                diagramWorkspace.copy(diagramWorkspace.resultTab)
            case .anonymization: return false // The text card itself chooses the result.
            }
        case .addGroup: return false // The active sidebar owns the group editor.
        }
        return true
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
    var result: RenderedExport
    var jumpRequest: ResultJumpRequest?
    var playback: RecordingPlayback? = nil
    var playbackIndex: TranscriptPlaybackIndex? = nil
    var onJump: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = SelectableResultTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.isEditable = false; view.isSelectable = true; view.allowsUndo = false
        view.textContainerInset = NSSize(width: 20, height: 20); view.font = .systemFont(ofSize: 14); view.delegate = context.coordinator
        view.isAutomaticLinkDetectionEnabled = false
        view.seekOnClick = { [weak coordinator = context.coordinator] offset in
            guard let coordinator, let segment = coordinator.index?.segment(atTextOffset: offset) else { return }
            coordinator.onJump?(segment.segmentID)
        }
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        let coordinator = context.coordinator
        coordinator.onJump = onJump
        coordinator.index = playbackIndex
        if coordinator.current != result {
            coordinator.current = result
            coordinator.timestampRanges.removeAll()
            let value = NSMutableAttributedString(string: result.text, attributes: [.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.labelColor])
            for timestamp in result.timestamps {
                value.addAttribute(.link, value: "localscribe://segment/\(timestamp.segmentID)", range: timestamp.range)
                if timestamp.isTranscript { coordinator.timestampRanges[timestamp.segmentID] = timestamp.range }
            }
            view.textStorage?.setAttributedString(value)
            coordinator.target = nil
            coordinator.highlightedRange = nil
        }
        coordinator.observe(playback, in: view)
        if let jumpRequest, coordinator.target != jumpRequest,
           let range = coordinator.timestampRanges[jumpRequest.segmentID] {
            view.scrollRangeToVisible(range); view.setSelectedRange(range); coordinator.target = jumpRequest
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var current = RenderedExport(); var target: ResultJumpRequest?; var onJump: ((String)->Void)?
        var timestampRanges: [String: NSRange] = [:]
        var index: TranscriptPlaybackIndex?
        var highlightedRange: NSRange?
        private weak var playback: RecordingPlayback?
        private var observation: AnyCancellable?
        private var wasFollowing = false

        func observe(_ next: RecordingPlayback?, in view: NSTextView) {
            if playback !== next {
                observation = nil
                playback = next
                if let next {
                    observation = next.$position.combineLatest(next.$followsTranscript).sink { [weak self, weak view] position, follows in
                        guard let view else { return }
                        self?.highlight(at: position, follows: follows, in: view)
                    }
                }
            }
            highlight(at: next?.position, follows: next?.followsTranscript == true, in: view)
        }

        private func highlight(at seconds: Double?, follows: Bool, in view: NSTextView) {
            let next = seconds.flatMap { index?.segment(at: ($0 * 1000).rounded())?.segmentRange }
            let changed = next != highlightedRange
            if changed, let storage = view.textStorage {
                storage.beginEditing()
                if let highlightedRange {
                    storage.removeAttribute(.backgroundColor, range: highlightedRange)
                }
                if let next {
                    storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.18), range: next)
                }
                storage.endEditing()
                highlightedRange = next
            }
            if follows, changed || !wasFollowing, let next,
               (view as? SelectableResultTextView)?.isHandlingMouse != true {
                // Scroll to the start of a long utterance without moving the selection.
                view.scrollRangeToVisible(NSRange(location: next.location, length: 0))
            }
            wasFollowing = follows
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string:$0) }
            if let url, url.scheme == "localscribe", url.host == "segment" { onJump?(url.lastPathComponent) }
            return true
        }
    }
}

private final class SelectableResultTextView: NSTextView {
    var seekOnClick: ((Int) -> Void)?
    private(set) var isHandlingMouse = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let offset = characterIndexForInsertion(at: point)
        let isPlainClick = event.clickCount == 1 && event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty
        let isText = offset < (textStorage?.length ?? 0)
        let isLink = isText && textStorage?.attribute(.link, at: offset, effectiveRange: nil) != nil
        isHandlingMouse = true
        super.mouseDown(with: event)
        isHandlingMouse = false
        guard isPlainClick, isText, !isLink, selectedRange().length == 0 else { return }
        seekOnClick?(offset)
    }
}

enum SettingsTab {
    case recordings, diagrams, anonymization, general
}

struct ModelSettings: View {
    private static let recognitionDictionaryMaxHeight =
        25 * NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: NSFont.systemFontSize))
    @ObservedObject var model: AppModel
    @ObservedObject var draft: SettingsDraft
    @State private var asrID = ""
    @State private var showFiles = false
    @State private var choseASR = false
    @State private var dictionaryBudgetError: (check: WhisperDictionaryValidation, message: String)?
    private var profiles: [ModelProfile] { model.catalog?.models ?? [] }
    private var summaryProfiles: [ModelProfile] { profiles.filter { $0.supports(.summary) } }
    private var diagramProfiles: [ModelProfile] { profiles.filter { $0.supports(.diagramRecognition) } }
    private var anonymizationProfiles: [ModelProfile] { profiles.filter { $0.supports(.anonymization) } }
    private var auxiliaryProfiles: [ModelProfile] { profiles.filter { $0.purpose == nil && $0.effectiveSupportedTasks.isEmpty } }
    private var recordingProfiles: [ModelProfile] {
        auxiliaryProfiles + profiles.filter { $0.purpose == .asr || $0.purpose == .diarization || $0.purpose == .tokenizer } + summaryProfiles
    }
    private var summarySelection: Binding<String> { taskSelection(.summary, draftID: $draft.summaryModelID) }
    private var diagramSelection: Binding<String> { taskSelection(.diagramRecognition, draftID: $draft.diagramModelID) }
    private var anonymizationSelection: Binding<String> { taskSelection(.anonymization, draftID: $draft.anonymizationProfileID) }
    private var selectedSummaryProfile: ModelProfile? {
        summaryProfiles.first { $0.id == summarySelection.wrappedValue && model.hardware.compatibility(for: $0).isCompatible }
    }
    private var downloads: [ModelProfile] {
        if let summary = selectedSummaryProfile { return model.profilesToInstall(asrID: asrID, summaryID: summary.id) }
        return model.audioStackToInstall(asrID: asrID)
    }
    private var downloadSelectionCompatible: Bool {
        let asrCompatible = profiles.contains {
            $0.id == asrID && $0.purpose == .asr && model.hardware.compatibility(for: $0).isCompatible
        }
        return asrCompatible || selectedSummaryProfile != nil
    }
    var body: some View {
        let check = recognitionDictionaryBudgetCheck
        TabView(selection: $model.settingsTab) {
            Tab(L10n.text("Записи"), systemImage: "waveform", value: .recordings) { recordingSettings }
            Tab(L10n.text("Схемы"), systemImage: "square.grid.2x2", value: .diagrams) { diagramSettings }
            Tab(L10n.text("Обезличивание"), systemImage: "character.cursor.ibeam", value: .anonymization) { anonymizationSettingsTab }
            Tab(L10n.text("Общие"), systemImage: "gearshape", value: .general) { generalSettings }
        }
        .disabled(draft.saving)
        .onAppear { initializeSelection() }
        .onChange(of: profiles.map(\.id)) { _, _ in initializeSelection() }
        .onChange(of: model.modelLibrary.selectedByRole) { _, _ in initializeSelection() }
        .onChange(of: model.modelLibrary.installedAt) { _, installed in
            draft.modelIDs = draft.modelIDs.filter { installed[$0.value] != nil }
        }
        .task(id: check) {
            guard let check else { dictionaryBudgetError = nil; return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await check.validate()
                try Task.checkCancellation()
                dictionaryBudgetError = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                dictionaryBudgetError = (check, L10n.message(error.localizedDescription))
            }
        }
    }

    private var recordingSettings: some View {
        Form {
            Section(L10n.text("Источники записи")) {
                RecordingSourceControls(preferences: $draft.recordingSources, devices: model.microphoneDevices,
                                        identifierPrefix: "settings")
                Text(L10n.text("Изменения применяются к следующей записи."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            modelActivity
            Section(L10n.text("Модели записей")) {
                if !model.installing && !model.verifyingModels { Text(model.modelsStatus) }
                Text(L10n.text("Выбранные модели применяются к новым заданиям. Сохранённые записи меняются только по команде «Продолжить», «Обработать заново» или «Пересоздать итоги»."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if recognitionDictionarySupported {
                Section(L10n.text("Словарь распознавания")) {
                    TextEditor(text: $draft.recognitionDictionaryText)
                        .font(.system(size: NSFont.systemFontSize))
                        .frame(minHeight: 72, maxHeight: Self.recognitionDictionaryMaxHeight)
                        .accessibilityLabel(L10n.text("Словарь распознавания"))
                        .accessibilityIdentifier("settings.recognitionDictionary")
                    Text(L10n.text("Один термин на строку: названия продуктов, аббревиатуры, имена участников. Модель получает их как подсказку по написанию при расшифровке новых заданий. Список общий для WhisperKit и Qwen3-ASR и сохраняется, даже если поле сейчас скрыто."))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.recognitionDictionary.hint")
                    if let error = recognitionDictionaryError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.recognitionDictionary.error")
                    }
                }
            }
            Section(L10n.text("Загрузить модели записей")) {
                asrModelPicker
                taskModelPicker(L10n.text("Итоги"), task: .summary, candidates: summaryProfiles,
                                selection: summarySelection, identifier: "settings.models.summary")
                ForEach(profiles.filter { $0.id == asrID || $0.id == summarySelection.wrappedValue }) { profile in
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
                    Button(L10n.text("Загрузить выбранные")) {
                        if let summary = selectedSummaryProfile { draft.summaryModelID = summary.id }
                        model.installModels(downloads)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(downloads.isEmpty)
                    .help(L10n.text("Скачать выбранные модели и необходимые зависимости"))
                    Text(!downloadSelectionCompatible ? L10n.text("Нет совместимого комплекта") : downloads.isEmpty ? L10n.text("Уже установлены") : L10n.text("Всего: %1$@", size(downloads.reduce(0) { $0 + $1.bytes }))).font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.text("Нужные токенизатор, выравниватель и модель участников загрузятся автоматически. Выбор модели для итогов сохраняется по кнопке «ОК»."))
                    .font(.caption).foregroundStyle(.secondary)
                importPicker(recordingProfiles, identifier: "settings.models.import")
            }.disabled(!model.canManageModels)
            Section(L10n.text("Загруженные модели")) {
                ForEach(auxiliaryProfiles.filter(model.modelLibrary.isInstalled)) { profile in
                    installedRow(profile)
                }
                if !recordingProfiles.contains(where: isInstalled) {
                    Text(L10n.text("Пока нет загруженных моделей")).foregroundStyle(.secondary)
                }
                ForEach(ModelRole.audioRoles, id: \.self) { role in
                    let installed = role == .summary
                        ? installedTaskProfiles(summaryProfiles)
                        : recordingProfiles.filter { $0.purpose == role && model.modelLibrary.isInstalled($0) }
                    if !installed.isEmpty {
                        Text(role.title).font(.caption).foregroundStyle(.secondary)
                        ForEach(installed) { profile in installedRow(profile) }
                    }
                }
            }
            Section {
                if let profile = selectedASRProfile, !profile.supportsClosedFragments {
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
                Toggle(L10n.text("Показывать предрасшифровку в эфире"), isOn: $draft.automaticLiveCaptions)
                    .toggleStyle(.checkbox)
                    .disabled(model.recordingID != nil || model.startingRecording || model.finalizingRecording)
                    .accessibilityIdentifier("settings.automaticLiveCaptions")
                    .help(L10n.text("Открывает вкладку «В эфире» при начале записи с выбранным языком предрасшифровки."))
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
                if let active = model.selectedTaskModel(.diagramRecognition), model.packageIsReady(active) {
                    Text(L10n.text("Выбрана %1$@ · распознавание без интернета", active.displayName))
                        .accessibilityIdentifier("settings.diagramModels.status")
                } else {
                    Text(L10n.text("Загрузите или выберите совместимую модель схем"))
                        .accessibilityIdentifier("settings.diagramModels.status")
                }
                Text(L10n.text("Выбранная модель применяется к новым запускам распознавания схем."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if diagramProfiles.isEmpty {
                Section { Text(L10n.text("В каталоге нет моделей для распознавания схем.")).foregroundStyle(.secondary) }
            } else {
                Section(L10n.text("Загрузить модель схем")) {
                    taskModelPicker(L10n.text("Распознавание"), task: .diagramRecognition,
                                    candidates: diagramProfiles, selection: diagramSelection,
                                    identifier: "settings.models.diagram")
                    if let profile = diagramProfiles.first(where: { $0.id == diagramSelection.wrappedValue }) {
                        if let ram = profile.recommendedMemoryGB, let working = profile.workingMemoryGB {
                            Text(L10n.text("RAM: от %1$@ ГБ · рабочий объём этапа: %2$@ ГБ", String(ram), String(working)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let warning = model.hardware.warning(for: profile) {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button(L10n.text("Загрузить выбранную")) {
                                draft.diagramModelID = profile.id
                                model.installModels([profile])
                            }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.packageIsReady(profile) || !model.hardware.compatibility(for: profile).isCompatible)
                                .accessibilityIdentifier("settings.diagramModels.install.\(profile.id)")
                            Text(model.packageIsReady(profile) ? L10n.text("Уже установлена") : size(profile.bytes))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    importPicker(diagramProfiles, identifier: "settings.diagramModels.import")
                }.disabled(!model.canManageModels)
            }
            Section(L10n.text("Загруженные модели")) {
                let installed = installedTaskProfiles(diagramProfiles)
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
            Section(L10n.text("Тема")) {
                Picker(L10n.text("Тема приложения"), selection: $draft.applicationTheme) {
                    ForEach(ApplicationTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .accessibilityIdentifier("settings.applicationTheme")
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

    private var anonymizationSettingsTab: some View {
        Form {
            Section(L10n.text("Типы данных для замены")) {
                TextEditor(text: $draft.dataTypesText)
                    .font(.system(size: NSFont.systemFontSize))
                    .frame(minHeight: 96)
                    .accessibilityLabel(L10n.text("Типы данных для замены"))
                    .accessibilityIdentifier("settings.anonymization.dataTypes")
                Text(L10n.text("Один тип данных на строку"))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.anonymization.dataTypes.hint")
                if AnonymizationSettings.sanitizeDataTypes(draft.dataTypesLines).isEmpty {
                    Label(L10n.message("Укажите хотя бы один тип данных"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.anonymization.dataTypes.error")
                }
            }
            modelActivity
            Section(L10n.text("Модели")) {
                taskModelPicker(L10n.text("Обезличивание"), task: .anonymization,
                                candidates: anonymizationProfiles, selection: anonymizationSelection,
                                identifier: "settings.anonymization.profile")
                    .disabled(anonymizationProfiles.isEmpty)
                if anonymizationProfiles.isEmpty {
                    Text(L10n.text("В каталоге пока нет моделей, проверенных для обезличивания."))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.anonymization.noProfiles")
                } else {
                    anonymizationInstallControls(profileID: anonymizationSelection.wrappedValue)
                    importPicker(anonymizationProfiles, identifier: "settings.anonymization.import")
                }
            }.disabled(!model.canManageModels)
            Section(L10n.text("Загруженные модели")) {
                let relevant = installedTaskProfiles(anonymizationProfiles)
                if relevant.isEmpty {
                    Text(L10n.text("Пока нет загруженных моделей")).foregroundStyle(.secondary)
                } else {
                    ForEach(relevant) { profile in installedRow(profile) }
                }
            }
        }.formStyle(.grouped)
    }

    @ViewBuilder private func anonymizationInstallControls(profileID: String) -> some View {
        if let profile = anonymizationProfiles.first(where: { $0.id == profileID }) {
            let compatibility = ModelTaskSupport.compatibility(task: .anonymization, profile: profile, hardware: model.hardware)
            if let reasons = compatibility.explanation {
                Label(L10n.message(reasons), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.anonymization.incompatible.\(profile.id)")
            } else {
                HStack {
                    Button(L10n.text("Загрузить выбранную")) { model.installModels([profile]) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.installing || model.packageIsReady(profile))
                        .accessibilityIdentifier("settings.anonymization.install.\(profile.id)")
                    if model.packageIsReady(profile) {
                        Label(L10n.text("Установлена · готова к новым заданиям"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                            .accessibilityIdentifier("settings.anonymization.ready.\(profile.id)")
                    } else {
                        Text(L10n.text("Не установлена · задания будут ждать модель: %1$@", size(profile.bytes)))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.anonymization.waiting.\(profile.id)")
                    }
                }
            }
        } else {
            Text(L10n.text("Выберите совместимую модель. До установки задания будут ждать модель."))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.anonymization.emptySlot")
        }
    }

    private func taskModelPicker(_ title: String, task: ModelTask, candidates: [ModelProfile],
                                 selection: Binding<String>, identifier: String) -> some View {
        let options = candidates.map { profile in
            let reasons = ModelTaskSupport.compatibility(task: task, profile: profile, hardware: model.hardware).reasons
            return ModelMenuOption(profile: profile,
                                   reason: reasons.isEmpty ? nil : reasons.map(L10n.message).joined(separator: "; "),
                                   recommended: profile.purpose == task.legacyRole && model.isRecommended(profile),
                                   installed: model.packageIsReady(profile))
        }
        return HStack {
            Text(title)
            ModelPopup(options: options, selection: selection, prompt: modelPickerPrompt(options))
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }

    private func modelPickerPrompt(_ options: [ModelMenuOption]) -> String {
        options.contains(where: \.enabled) ? L10n.text("Модель не выбрана") : L10n.text("Нет совместимой модели")
    }

    private func taskSelection(_ task: ModelTask, draftID: Binding<String>) -> Binding<String> {
        Binding(get: {
            if !draftID.wrappedValue.isEmpty { return draftID.wrappedValue }
            if let profile = model.selectedTaskModel(task) { return profile.id }
            return profiles.first {
                $0.supports(task) && $0.purpose == task.legacyRole && model.isRecommended($0) && !model.packageIsReady($0)
            }?.id ?? ""
        }, set: { draftID.wrappedValue = $0 })
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
        if !choseASR { asrID = model.initialModelID(for: .asr) }
    }
    private func menuOption(_ profile: ModelProfile) -> ModelMenuOption {
        ModelMenuOption(profile: profile, hardware: model.hardware,
                        recommended: model.isRecommended(profile), installed: isInstalled(profile))
    }
    private func importPicker(_ candidates: [ModelProfile], identifier: String) -> some View {
        let options = candidates.map { profile in
            let option = menuOption(profile)
            guard !profile.effectiveSupportedTasks.isEmpty, model.packageIsReady(profile) else { return option }
            return ModelMenuOption(profile: profile, reason: option.reason ?? L10n.text("Уже установлена"),
                                   recommended: false, installed: true)
        }
        return ModelPopup(options: options, selection: .constant(""), prompt: L10n.text("Импортировать из папки…"), imports: true) { id in
            if let profile = candidates.first(where: { $0.id == id }) { model.importModel(profile) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
    }
    private var asrModelPicker: some View {
        let title = L10n.text("Распознавание")
        let options = profiles.filter { $0.purpose == .asr }.map(menuOption)
        return HStack {
            Text(title)
            ModelPopup(options: options, selection: Binding(
                get: { asrID },
                set: { id in
                    choseASR = true
                    asrID = id
                    let installed = model.modelLibrary.installedAt[id] != nil
                    let alreadySelected = model.modelLibrary.selectedByRole[ModelRole.asr.rawValue] == id
                    draft.modelIDs[.asr] = installed && !alreadySelected ? id : nil
                }
            ), prompt: modelPickerPrompt(options))
                .accessibilityLabel(title)
                .accessibilityIdentifier("settings.models.asr")
        }
    }
    private func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file).locale(L10n.locale)) }
    private func memoryGB(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))
    }
    private var selectedASRProfile: ModelProfile? {
        let id = draft.modelIDs[.asr] ?? model.modelLibrary.selectedByRole[ModelRole.asr.rawValue]
        return profiles.first { $0.id == id && model.modelLibrary.isInstalled($0) }
    }
    /// The dictionary hint field follows the picker choice, including a profile
    /// that is selected but not downloaded yet.
    private var recognitionDictionarySupported: Bool {
        guard let backend = profiles.first(where: { $0.id == asrID && $0.purpose == .asr })?.resolvedASRBackend else { return false }
        return RecognitionDictionary.supportsHint(backend: backend)
    }
    private var recognitionDictionaryError: String? {
        do {
            _ = try RecognitionDictionary.normalize(draft.recognitionDictionaryLines)
            if let error = dictionaryBudgetError, error.check == recognitionDictionaryBudgetCheck { return error.message }
            return nil
        } catch { return L10n.message(error.localizedDescription) }
    }
    private var recognitionDictionaryBudgetCheck: WhisperDictionaryValidation? {
        guard let terms = try? RecognitionDictionary.normalize(draft.recognitionDictionaryLines) else { return nil }
        return model.whisperDictionaryValidation(asrID: asrID, terms: terms)
    }
    private func isInstalled(_ profile: ModelProfile) -> Bool {
        profile.effectiveSupportedTasks.isEmpty
            ? model.modelLibrary.isInstalled(profile)
            : model.packageIsReady(profile)
    }
    private func installedTaskProfiles(_ candidates: [ModelProfile]) -> [ModelProfile] {
        var packages: Set<String> = []
        return candidates.filter { model.packageIsReady($0) && packages.insert($0.effectivePackageID).inserted }
    }
    @ViewBuilder private func installedRow(_ profile: ModelProfile) -> some View {
        HStack(alignment: .top) {
            Text(model.isRecommended(profile) ? L10n.text("%1$@ · Максимально рекомендуется", profile.displayName) : profile.displayName)
                .fontWeight(model.isRecommended(profile) ? .bold : .regular)
                .foregroundStyle(model.hardware.compatibility(for: profile).isCompatible ? Color.primary : Color.secondary)
                .accessibilityIdentifier("settings.\(profile.purpose == .diagram ? "diagramModels" : "models").installed.\(profile.id)")
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

struct RecordingSourceControls: View {
    private enum Choice: Hashable {
        case builtIn, systemDefault, device(String)
    }

    @Binding var preferences: RecordingSourcePreferences
    @ObservedObject var devices: MicrophoneDevices
    let identifierPrefix: String

    private var selection: MicrophoneSelection { preferences.microphone }
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
            case .builtIn: preferences.microphone = .builtIn
            case .systemDefault: preferences.microphone = .systemDefault
            case .device(let uid):
                if let device = devices.snapshot.devices.first(where: { $0.uid == uid }) {
                    preferences.microphone = device.selection
                }
            }
        }
    }

    var body: some View {
        Toggle(L10n.text("Микрофон"), isOn: $preferences.microphoneEnabled)
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("\(identifierPrefix).recordingMicrophoneEnabled")
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
        .disabled(!preferences.microphoneEnabled)
        .accessibilityIdentifier("\(identifierPrefix).recordingMicrophone")
        if devices.snapshot.device(for: selection) == nil {
            Text(unavailableTitle)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifierPrefix).recordingMicrophone.unavailable")
            if preferences.microphoneEnabled,
               let fallback = devices.snapshot.candidates(for: selection).first {
                Text(L10n.text("Резервный микрофон: %1$@", fallback.isBuiltIn ? L10n.text("Встроенный микрофон") : fallback.name))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(identifierPrefix).recordingMicrophone.fallback")
            }
        }
        Toggle(L10n.text("Системный звук"), isOn: $preferences.systemAudioEnabled)
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("\(identifierPrefix).recordingSystemAudioEnabled")
        if !preferences.hasEnabledSource {
            Text(L10n.message("Включите хотя бы один источник записи."))
                .foregroundStyle(.secondary)
        }
    }

    private var unavailableTitle: String {
        if case .device = selection { return L10n.text("Не подключён") }
        return L10n.message(selection.unavailableMessage)
    }
}
