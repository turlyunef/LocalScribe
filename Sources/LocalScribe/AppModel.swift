import SwiftUI
import AppKit
import AVFoundation
import LocalScribeCore

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var recordingGroups = RecordingGroups() { didSet { recordingSearch.update(recordings, groups: recordingGroups) } }
    let recordingSearch = RecordingSearch()
    private var recordingsByID: [String: Manifest] = [:]
    @Published private(set) var deletingGroupID: String?
    @Published var sidebarRevealID: String?
    @Published private(set) var sidebarSelection = SidebarSelection()
    @Published private(set) var deletingSidebarRecordings = false
    private var reportedGroupsError: String?
    private var reportedUnreadableRecordingIDs: [String] = []
    private var deletingRecordingIDs: Set<String> = []
    private var recordingAdmission: [String: UInt64] = [:]
    private var finalizingRecordingID: String?
    private var startingGroupID: String?
    @Published var recordings: [Manifest] = [] {
        didSet {
            recordingsByID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
            recordingSearch.update(recordings, groups: recordingGroups)
            refreshPresentation()
        }
    }
    @Published var selection: String? {
        didSet {
            sidebarSelection = SidebarSelection(selection)
            retainSearchSelection()
            if oldValue != selection { jumpTo = nil; transcript = nil; summary = nil; resultSignature = ""; resultEdit = nil }
            loadResult()
        }
    }
    @Published var transcript: Transcript? { didSet { resultRevision &+= 1; refreshPresentation() } }
    @Published var summary: Summary? { didSet { resultRevision &+= 1; refreshPresentation() } }
    @Published var resultEdit: ResultEditDraft?
    @Published private(set) var savingResult = false
    let errorHandler = AppErrorHandler()
    let indicators = ActivityIndicators()
    let resultPresentation = ResultPresentation()
    private var resultRevision: UInt64 = 0
    private(set) var copyTask: Task<Void, Never>?
    private var exportTasks: [UUID: Task<Void, Never>] = [:]
    var status: String { get { indicators.status } set { indicators.status = newValue } }
    @Published var modelsStatus = "Проверяем модели…"
    @Published var modelsReady = false
    @Published var installing = false
    @Published var verifyingModels = false
    @Published var modelLibrary = ModelLibrary()
    @Published var downloadProgress: ModelInstallProgress?
    @Published var downloadBatch = ""
    let hardware: ModelHardware
    var canManageModels: Bool { !savingResult && resultEdit == nil && !preparingStorage && !installing && !verifyingModels && !busy && queued.isEmpty && !resourcesPaused && !startingRecording && !finalizingRecording && recordingID == nil && !shuttingDown }
    var activeCatalog: ModelCatalog? {
        guard let catalog, let selected = modelLibrary.activeCatalog(from: catalog),
              selected.models.allSatisfy({ hardware.compatibility(for: $0).isCompatible }) else { return nil }
        return selected
    }
    func isRecommended(_ profile: ModelProfile) -> Bool {
        guard let catalog, let role = profile.purpose else { return false }
        return hardware.recommendedProfile(for: role, in: catalog)?.id == profile.id
    }
    func initialModelID(for role: ModelRole) -> String {
        guard let catalog else { return "" }
        if let selected = catalog.models.first(where: { $0.id == modelLibrary.selectedByRole[role.rawValue] && $0.purpose == role }),
           hardware.compatibility(for: selected).isCompatible { return selected.id }
        return hardware.recommendedProfile(for: role, in: catalog)?.id ?? ""
    }
    @Published var backgroundRecognition: Bool {
        didSet { userDefaults.set(backgroundRecognition, forKey: "backgroundRecognition") }
    }
    @Published var automaticSummaries: Bool {
        didSet { userDefaults.set(automaticSummaries, forKey: "automaticSummaries") }
    }
    private let userDefaults: UserDefaults
    @Published var recordingID: String?
    @Published var startingRecording = false
    @Published var finalizingRecording = false
    var elapsed: Double { get { indicators.elapsed } set { indicators.elapsed = newValue } }
    var level: Double { get { indicators.level } set { indicators.level = newValue } }
    var soundNotice: String? { get { indicators.soundNotice } set { indicators.soundNotice = newValue } }
    @Published var busy = false
    @Published var shuttingDown = false
    @Published private(set) var preparingStorage = true
    @Published var tab: ExportPart = .transcript { didSet { refreshPresentation() } }
    @Published var jumpTo: ResultJumpRequest?
    let repository: RecordingRepository?
    let archive: RecordingCoordinator?
    private var archiveRevision: UInt64 = 0
    let catalog: ModelCatalog?
    let resources: URL
    private let workerOverride: URL?
    let supervisor = WorkerSupervisor()
    private let installer = ModelInstaller()
    private let downloader = ModelDownloadClient()
    private var recorder: MicrophoneRecorder?
    @Published private var queued: [String] = []
    private var enqueuing: [String: UUID] = [:]
    private var queueGeneration: UInt64 = 0
    private var activeID: String?
    // Unlike activeID, this survives cancellation/resource pause until every
    // worker reader and the queue's file cleanup have finished.
    private var processingRecordingID: String?
    private var stopping = false
    private var resourcesPaused = false
    private var memoryLimited = false
    private var captureLimited = false
    private var suspendingQueue = false
    // Sleep/shutdown pauses own admission barriers independently of row cancellation.
    private var queuePauses: [UUID: String] = [:]
    private var resourcePauseTask: Task<Void, Never>?
    private var memorySource: DispatchSourceMemoryPressure?
    private var sleepObserver: NSObjectProtocol?
    private var installTask: Task<Void, Never>?
    private var warningTasks: [UUID: Task<Void, Never>] = [:]
    let importQueue = ImportQueue()
    enum DuplicateImportAction { case openExisting, importAgain, cancel }
    var resolveDuplicateImport: (DuplicateRecording) -> DuplicateImportAction = { _ in
        let alert = NSAlert(); alert.messageText = "Такой файл уже есть в архиве"
        alert.addButton(withTitle: "Открыть существующую"); alert.addButton(withTitle: "Импортировать ещё раз"); alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .openExisting
        case .alertSecondButtonReturn: return .importAgain
        default: return .cancel
        }
    }
    private var resultSignature = ""
    private var resultLoadID = UUID()
    var selected: Manifest? { recordings.first { $0.id == selection } }
    var resultTabs: [ExportPart] { selected?.warnings.isEmpty == false ? [.transcript, .summary, .warnings] : [.transcript, .summary] }
    var exportParts: [ExportPart] { resultTabs + [.all] }
    var tools: URL { resources.appendingPathComponent("tools") }
    var worker: URL { workerOverride ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalScribeWorker") }
    init(repository providedRepository: RecordingRepository? = nil, startServices: Bool = true, workerExecutable: URL? = nil,
         userDefaults: UserDefaults = .standard, catalog providedCatalog: ModelCatalog? = nil, hardware: ModelHardware = .current,
         importProbe: @escaping @Sendable (URL, URL) throws -> AudioInfo = { try Media.probe($0, tools: $1, cancellable: true) }) {
        self.userDefaults = userDefaults
        self.hardware = hardware
        backgroundRecognition = userDefaults.object(forKey: "backgroundRecognition") as? Bool ?? true
        automaticSummaries = userDefaults.object(forKey: "automaticSummaries") as? Bool ?? true
        workerOverride = workerExecutable
        let bundled = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        resources = FileManager.default.fileExists(atPath: bundled.appendingPathComponent("models.lock.json").path) ? bundled : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        catalog = providedCatalog ?? (try? Disk.read(ModelCatalog.self, at: resources.appendingPathComponent("models.lock.json")))
        do { let repo = try providedRepository ?? RecordingRepository(); repository = repo; archive = RecordingCoordinator(repository: repo, importProbe: importProbe) }
        catch { repository = nil; archive = nil; errorHandler.report(message: "Не удалось открыть локальное хранилище: \(error.localizedDescription)") }
        recordingSearch.onVisibilityChange = { [weak self] in self?.retainSearchSelection() }
        if !startServices { preparingStorage = false; Task { await reload() }; return }
        memorySource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        memorySource?.setEventHandler { [weak self] in
            guard let self else { return }
            if self.memorySource?.data.intersection([.warning, .critical]).isEmpty == true {
                self.resumeAfterMemoryPressure()
            } else {
                self.pauseForCaptureResources(memoryPressure: true)
            }
        }
        memorySource?.resume()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if self?.recordingID != nil { await self?.stopRecording(warning: "Сон системы прервал запись.") }
                await self?.pause(reason: "Обработка прервана перед сном. Нажмите «Продолжить» после пробуждения.")
            }
        }
        Task {
            status = "Восстанавливаем локальное хранилище…"
            if let archive {
                do { applySnapshot(try await archive.recover()) }
                catch {
                    errorHandler.report(message: "Не удалось восстановить локальное хранилище: \(error.localizedDescription)")
                    await reload()
                }
            }
            preparingStorage = false
            if status == "Восстанавливаем локальное хранилище…" { status = "" }
            await verifyModels()
        }
        if CommandLine.arguments.contains("--self-check") { Task { await sandboxSelfCheck() } }
        if CommandLine.arguments.contains("--self-check-microphone") { Task { await microphoneSelfCheck() } }
    }
    func reload() async {
        guard let archive else { return }
        applySnapshot(await archive.snapshot())
        await recordingSearch.waitForLayout()
    }
    private func applySnapshot(_ snapshot: RecordingCoordinator.Snapshot) {
        guard snapshot.revision >= archiveRevision else { return }
        if snapshot.revision != archiveRevision {
            archiveRevision = snapshot.revision
            recordings = snapshot.manifests
            recordingGroups = snapshot.groups
            var retained = sidebarSelection
            retained.retain(Set(recordings.map(\.id)))
            if let selection, !recordings.contains(where: { $0.id == selection }) {
                self.selection = recordings.first { retained.ids.contains($0.id) }?.id
            }
            sidebarSelection = retained
            retainSearchSelection()
            if snapshot.unreadableRecordingIDs != reportedUnreadableRecordingIDs {
                reportedUnreadableRecordingIDs = snapshot.unreadableRecordingIDs
                if !snapshot.unreadableRecordingIDs.isEmpty {
                    errorHandler.report(message: "Не удалось прочитать записи архива: " + snapshot.unreadableRecordingIDs.joined(separator: ", ") + ". Файлы сохранены для восстановления. Проверьте manifest.json в каталогах этих записей.")
                }
            }
            if let error = snapshot.groupsError, error != reportedGroupsError {
                reportedGroupsError = error; errorHandler.report(message: error)
            }
        }
        loadResult()
    }
    private func refreshPresentation() {
        if tab == .warnings && !resultTabs.contains(.warnings) { tab = .transcript; return }
        resultPresentation.update(manifest: selected, transcript: transcript, summary: summary, revision: resultRevision, part: tab)
    }
    func renameRecording(_ id: String, title: String) async {
        guard !preparingStorage, let archive else { return }
        do {
            try await archive.rename(id, title: title)
            await reload()
        } catch {
            errorHandler.report(error)
        }
    }
    func loadResult() {
        guard let selected, let archive else { transcript = nil; summary = nil; resultSignature = ""; return }
        let signature = selected.id + (selected.activeRunId ?? "") + (selected.pendingRunId ?? "") + selected.state.rawValue
        guard resultSignature != signature else { return }
        resultSignature = signature
        transcript = nil; summary = nil
        let loadID = UUID(); resultLoadID = loadID
        Task {
            do {
                let results = try await archive.perform { try $0.results(selected) }
                guard self.selection == selected.id, self.resultSignature == signature, self.resultLoadID == loadID else { return }
                self.transcript = results.0; self.summary = results.1
            } catch {
                guard self.selection == selected.id, self.resultSignature == signature, self.resultLoadID == loadID else { return }
                self.errorHandler.report(error)
            }
        }
    }
    var canEditResult: Bool {
        guard let selected else { return false }
        return !preparingStorage && !shuttingDown && !savingResult && !busy
            && !startingRecording && !finalizingRecording && recordingID == nil
            && selected.activeRunId != nil && selected.pendingRunId == nil
            && !selected.state.processing && ![JobState.recording, .queued].contains(selected.state)
            && transcript != nil
    }
    func beginResultEditing() {
        guard canEditResult, let selected, let runID = selected.activeRunId, let transcript else { return }
        resultEdit = ResultEditDraft(recordingID: selected.id, runID: runID, transcript: transcript, summary: summary)
    }
    func saveResultEdits(_ draft: ResultEditDraft) async throws {
        guard !savingResult, !shuttingDown, let archive, resultEdit?.id == draft.id else {
            throw ScribeError.message("Редактор уже закрыт. Откройте результат заново.")
        }
        savingResult = true
        defer { savingResult = false }
        try await archive.saveResultEdits(draft)
        // Invalidate even a load of the same recording/run that started earlier.
        resultLoadID = UUID(); resultSignature = ""
        if resultEdit?.id == draft.id { resultEdit = nil }
        await reload()
        status = "Изменения сохранены"
    }
    func verifyModels() async {
        guard let catalog, let repository, canManageModels else { return }
        verifyingModels = true; modelsStatus = "Проверяем целостность моделей…"
        defer { verifyingModels = false; if !queued.isEmpty { Task { await processQueue() } } }
        do {
            let hardware = hardware
            modelLibrary = try await Task.detached(priority: .utility) { try ModelLibrary.load(at: repository.models, catalog: catalog, hardware: hardware) }.value
            updateModelsStatus()
        } catch { modelsReady = false; modelsStatus = "Не удалось проверить модели"; errorHandler.report(error) }
    }
    private func updateModelsStatus() {
        modelsReady = activeCatalog != nil
        let incompatible = catalog?.models.filter { modelLibrary.isSelected($0) }.compactMap { hardware.warning(for: $0) } ?? []
        modelsStatus = !incompatible.isEmpty ? "Выберите совместимую модель. " + incompatible.joined(separator: " ") :
            (modelsReady ? "Модели готовы · обработка без интернета" : "Загрузите модели для всех этапов обработки")
    }
    func profilesToInstall(asrID: String, summaryID: String) -> [ModelProfile] {
        guard let catalog,
              let asr = catalog.models.first(where: { $0.id == asrID && $0.purpose == .asr }),
              let summary = catalog.models.first(where: { $0.id == summaryID && $0.purpose == .summary }),
              let tokenizer = catalog.models.first(where: { $0.id == (asr.tokenizerID ?? "tokenizer") && $0.purpose == .tokenizer }),
              let diarization = catalog.models.first(where: { $0.id == "diarization" && $0.purpose == .diarization }) else { return [] }
        let profiles = [tokenizer, asr, diarization, summary]
        guard profiles.allSatisfy({ hardware.compatibility(for: $0).isCompatible }) else { return [] }
        return profiles.filter { !modelLibrary.isInstalled($0) }
    }
    private func compatibleProfiles(_ requested: [ModelProfile]) -> [ModelProfile]? {
        do {
            guard let catalog else { return nil }
            return try requested.map { request in
                guard let profile = catalog.models.first(where: { $0.id == request.id }) else {
                    throw ScribeError.message("Модель отсутствует в закреплённом каталоге")
                }
                try hardware.requireCompatibility(for: profile)
                return profile
            }
        } catch { errorHandler.report(error); return nil }
    }
    func installModels(_ profiles: [ModelProfile]) {
        guard let repository, let catalog, canManageModels, !profiles.isEmpty,
              let profiles = compatibleProfiles(profiles) else { return }
        installing = true; downloadProgress = nil
        installTask = Task {
            defer {
                installing = false; installTask = nil; downloadProgress = nil; downloadBatch = ""; downloader.close()
                Task { await processQueue() }
            }
            do {
                for (index, profile) in profiles.enumerated() {
                    try Task.checkCancellation()
                    downloadBatch = "Модель \(index + 1) из \(profiles.count) · \(profile.displayName)"
                    downloadProgress = ModelInstallProgress(profile: profile)
                    try await installer.install(profile, root: repository.models, fetch: { index, progress in
                        try await self.downloader.fetch(profileID: profile.id, index: index, progress: progress)
                    }) { progress in Task { @MainActor in self.receiveProgress(progress) } }
                    downloader.releaseDownload()
                    // Publish only after every file passed its size and SHA-256 checks.
                    var updated = modelLibrary
                    updated.installed(profile, catalog: catalog, hardware: hardware)
                    try updated.save(at: repository.models); modelLibrary = updated
                }
                updateModelsStatus()
            } catch {
                updateModelsStatus()
                if Task.isCancelled { modelsStatus += " · загрузка отменена" }
                else { errorHandler.report(error); modelsStatus += " · загрузка не завершена" }
            }
        }
    }
    private func receiveProgress(_ progress: ModelInstallProgress) {
        guard installing, downloadProgress?.profileID == progress.profileID else { return }
        if let current = downloadProgress {
            guard progress.completedFiles >= current.completedFiles,
                  progress.completedFiles != current.completedFiles || progress.downloadedBytes >= current.downloadedBytes else { return }
            if progress.fileIndex == current.fileIndex && progress.phase.rawValue < current.phase.rawValue { return }
        }
        downloadProgress = progress
        switch progress.phase {
        case .checking: modelsStatus = "Проверяем файлы модели…"
        case .downloading: modelsStatus = "Загружаем файлы модели…"
        case .verifying: modelsStatus = "Проверяем размер и SHA-256…"
        case .complete: modelsStatus = "Модель загружена и проверена"
        }
    }
    func cancelInstall() { installTask?.cancel(); downloader.cancel() }
    func importModel(_ profile: ModelProfile) {
        guard let repository, let catalog, canManageModels, let profile = compatibleProfiles([profile])?.first else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Выберите папку модели \(profile.displayName) из закреплённого каталога"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        installing = true; downloadProgress = ModelInstallProgress(profile: profile); downloadBatch = profile.displayName
        installTask = Task {
            defer {
                installing = false; installTask = nil; downloadProgress = nil; downloadBatch = ""
                if access { url.stopAccessingSecurityScopedResource() }
                Task { await processQueue() }
            }
            do {
                try await installer.install(profile, root: repository.models, localSource: url) { progress in Task { @MainActor in self.receiveProgress(progress) } }
                var updated = modelLibrary; updated.installed(profile, catalog: catalog, hardware: hardware)
                try updated.save(at: repository.models); modelLibrary = updated; updateModelsStatus()
            } catch {
                updateModelsStatus()
                if !Task.isCancelled { errorHandler.report(error) }
                else { modelsStatus += " · импорт отменён" }
            }
        }
    }
    func selectModel(_ profile: ModelProfile) {
        guard let repository, let catalog, canManageModels, !modelLibrary.isSelected(profile),
              let profile = compatibleProfiles([profile])?.first else { return }
        do {
            var updated = modelLibrary; try updated.select(profile, catalog: catalog, hardware: hardware)
            try updated.save(at: repository.models); modelLibrary = updated; updateModelsStatus()
        } catch { errorHandler.report(error) }
    }
    func removeModel(_ profile: ModelProfile) {
        guard let repository, let catalog, canManageModels else { return }
        let alert = NSAlert(); alert.messageText = "Удалить \(profile.displayName)?"
        alert.informativeText = "Будут удалены только файлы этой модели. Аудио, расшифровки и итоги сохранятся. Если модель выбрана, будет использована последняя установленная из оставшихся совместимых моделей того же назначения."
        alert.addButton(withTitle: "Удалить модель"); alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try modelLibrary.remove(profile, at: repository.models, catalog: catalog, hardware: hardware); updateModelsStatus() }
        catch { errorHandler.report(error); Task { await verifyModels() } }
    }
    func chooseImport() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "MP3, M4A, WAV, FLAC, OGG, OPUS — до 3 часов"
        guard panel.runModal() == .OK else { return }; importURLs(panel.urls)
    }
    func importURLs(_ urls: [URL], groupID: String? = nil) {
        let destination = groupID ?? recordingGroups.defaultID
        for url in urls { enqueueImport(groupID: destination) { url } }
    }
    func importProviders(_ providers: [NSItemProvider], groupID: String? = nil) {
        let destination = groupID ?? recordingGroups.defaultID
        for provider in providers { enqueueImport(groupID: destination) { try await DroppedFileURL.load(provider) } }
    }
    private func enqueueImport(groupID: String, _ loadURL: @escaping @MainActor () async throws -> URL?) {
        guard !preparingStorage, !shuttingDown, let archive else { return }
        do {
            try importQueue.enqueue { [self] in
                do {
                    guard let url = try await loadURL() else { return }
                    try Task.checkCancellation()
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let tools = self.tools
                    do {
                        let manifest = try await archive.importFile(url, tools: tools, groupID: groupID)
                        await completeImport(manifest)
                    } catch let duplicate as DuplicateRecording {
                        try Task.checkCancellation()
                        guard !shuttingDown else { return }
                        switch resolveDuplicateImport(duplicate) {
                        case .openExisting: selection = duplicate.id
                        case .importAgain:
                            try Task.checkCancellation()
                            let manifest = try await archive.importFile(url, tools: tools, allowDuplicate: true, groupID: groupID)
                            await completeImport(manifest)
                        case .cancel: break
                        }
                    }
                } catch { errorHandler.report(error) }
            }
        } catch { errorHandler.report(error) }
    }
    func completeImport(_ manifest: Manifest) async {
        // Import may finish while a result sheet owns an unsaved local draft.
        if resultEdit == nil && !savingResult { selection = manifest.id }
        await reload(); await enqueue(manifest.id)
    }
    func startRecording(groupID: String? = nil) async {
        guard resultEdit == nil, !savingResult, recordingID == nil, let repository, let archive, !preparingStorage, !stopping, !shuttingDown, !startingRecording, !finalizingRecording, !installing else { return }
        let destination = groupID ?? recordingGroups.defaultID
        startingGroupID = destination
        startingRecording = true
        defer { startingGroupID = nil; startingRecording = false; Task { await processQueue() } }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { errorHandler.report(message: "Доступ к микрофону запрещён. Разрешите LocalScribe доступ в настройках конфиденциальности macOS."); return }
        guard !shuttingDown else { return }
        var m = Manifest(sourceType: "microphone", title: "Запись \(Date().formatted(date: .abbreviated, time: .shortened))", filename: "original.caf")
        m.state = .recording
        do {
            try await archive.createRecording(m, groupID: destination)
            guard !shuttingDown else {
                try await archive.update(m.id) { $0.state = .interrupted }
                return
            }
            let capture = MicrophoneRecorder()
            capture.onMeter = { [weak self] level, elapsed, notice in Task { @MainActor in self?.level = level; self?.elapsed = elapsed; self?.soundNotice = notice } }
            capture.onStopNeeded = { [weak self] reason in Task { @MainActor in await self?.stopRecording(warning: reason) } }
            capture.onWarning = { [weak self] warning in
                guard let self, let id = self.recordingID else { return }
                let taskID = UUID()
                self.warningTasks[taskID] = Task {
                    defer { self.warningTasks.removeValue(forKey: taskID) }
                    _ = try? await archive.update(id) { m in
                        if !m.warnings.contains(warning) { m.warnings.append(warning) }
                    }
                    await self.reload()
                }
            }
            try capture.start(folder: repository.folder(m.id).appendingPathComponent("capture"))
            capture.onResourcePressure = { [weak self] in Task { @MainActor in self?.pauseForCaptureResources() } }
            recorder = capture; recordingID = m.id; selection = m.id; elapsed = 0; soundNotice = nil
            supervisor.recordingActive = true
            // Model selection is frozen now, even if this job waits behind older work.
            if backgroundRecognition, modelsReady, let catalog = activeCatalog {
                do {
                    m = try await archive.beginRun(m.id, catalog: catalog, liveCapture: true)
                    await enqueueCapture(m.id)
                } catch {
                    _ = try? await archive.update(m.id) { m in
                        m.captureProcessing = .failed
                        m.lastError = "Фоновое распознавание не запущено. Звук продолжает сохраняться."
                    }
                }
            }
            await revealRecording(m.id)
        } catch {
            let message = error.localizedDescription
            _ = try? await archive.update(m.id) { $0.state = .failed; $0.lastError = message }
            errorHandler.report(error); await reload()
        }
    }
    func stopRecording(warning: String? = nil) async {
        guard let id = recordingID, let archive, !stopping else { return }
        finalizingRecordingID = id
        stopping = true; finalizingRecording = true; status = "Сохраняем аудио…"
        defer {
            finalizingRecordingID = nil
            stopping = false; finalizingRecording = false; supervisor.recordingActive = false
            captureLimited = false; resourcesPaused = memoryLimited
            if status == "Сохраняем аудио…" { status = "" }
            Task { await processQueue() }
        }
        do {
            let frames = try await recorder?.stop() ?? 0; recorder = nil
            if frames == 0 {
                let m = try await archive.update(id) { m in
                    m.state = .failed; m.lastError = warning ?? "Микрофон ещё не передал звук. Начните новую запись."
                }
                recordingID = nil
                queued.removeAll { $0 == id }
                if activeID == id { activeID = nil; await supervisor.cancel() }
                errorHandler.report(message: m.lastError); await reload(); return
            }
            if let warning {
                try await archive.update(id) { $0.warnings.append(warning) }
                errorHandler.report(message: warning)
            }
            try await finalizeCapture(id, expectedFrames: frames); recordingID = nil; await enqueue(id)
        } catch {
            recordingID = nil; recorder = nil; errorHandler.report(error)
            queued.removeAll { $0 == id }
            if activeID == id { activeID = nil; await supervisor.cancel() }
            let recoverable = await archive.perform { repository in
                let parts = (try? FileManager.default.contentsOfDirectory(at: repository.folder(id).appendingPathComponent("capture"), includingPropertiesForKeys: nil)) ?? []
                return parts.contains { $0.pathExtension == "caf" && !$0.lastPathComponent.contains(".partial.") }
            }
            _ = try? await archive.update(id) { m in
                m.state = recoverable ? .interrupted : .failed
                m.lastError = recoverable ? "Фрагменты сохранены. Нажмите «Продолжить» для сборки." : "Нет сохранённого звука. Начните новую запись."
            }
        }
        await reload()
    }
    func finalizeCapture(_ id: String, expectedFrames: Int64? = nil) async throws {
        guard let repository, let archive else { return }
        let manifest = try await archive.load(id)
        let folder = repository.folder(id), destination = folder.appendingPathComponent(manifest.originalRelativePath)
        let (frames, rate, hash) = try await archive.perform { _ -> (Int64, Double, String) in
            try Disk.directory(destination.deletingLastPathComponent())
            let result = try Media.assembleCapture(folder.appendingPathComponent("capture"), destination: destination)
            return (result.0, result.1, try Disk.hash(destination))
        }
        if let expectedFrames, frames != expectedFrames { throw ScribeError.message("Сохранены не все сэмплы микрофона. Фрагменты оставлены для восстановления.") }
        let state: JobState = activeID == id ? .transcribing : .recorded
        // Apply only capture fields to the latest manifest, preserving renames/warnings.
        let m = try await archive.update(id) { m in
            m.durationMs = Int(Double(frames)/rate*1000); m.sampleRate = rate; m.channels = 1; m.sha256 = hash; m.sourceComplete = true
            if m.state == .cancelled || m.captureProcessing == .cancelled {
                m.state = .cancelled; m.captureProcessing = nil
            } else {
                m.state = state
            }
        }
        try await archive.perform { repository in
            let liveRun = m.pendingRunId.flatMap { pending -> URL? in
                let run = repository.run(id, pending)
                let info = try? Disk.read(RunInfo.self, at: run.appendingPathComponent("run.json"))
                return info?.liveCapture == true || FileManager.default.fileExists(atPath: run.appendingPathComponent("capture-run.json").path) ? run : nil
            }
            if let run = liveRun {
                let captureInfo = try Disk.read(RunInfo.self, at: run.appendingPathComponent("capture-run.json"))
                let fragments = try CaptureIntegrity.fragments(at: folder.appendingPathComponent("capture"))
                let seal = CaptureSeal(info: captureInfo, sourceHash: hash, fragments: fragments)
                try CaptureIntegrity.verify(seal, info: captureInfo, folder: folder.appendingPathComponent("capture"), original: destination)
                try Disk.write(seal, to: run.appendingPathComponent("capture-seal.json"))
            } else {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent("capture"))
            }
        }
    }
    func resume(_ id: String) {
        guard !preparingStorage, !shuttingDown, !finalizingRecording, queuePauses.isEmpty, !deletingRecordingIDs.contains(id), id != recordingID, id != activeID else { return }
        let generation = queueGeneration, admission = recordingAdmission[id, default: 0]
        finalizingRecordingID = id
        finalizingRecording = true
        Task {
            defer { finalizingRecording = false; finalizingRecordingID = nil }
            do {
                if let archive {
                    let (needsAssembly, hasParts) = try await archive.perform { repository in
                        let m = try repository.load(id)
                        let needsSeal = m.pendingRunId.map {
                            let run = repository.run(id, $0)
                            return FileManager.default.fileExists(atPath: run.appendingPathComponent("capture-run.json").path)
                                && !FileManager.default.fileExists(atPath: run.appendingPathComponent("capture-seal.json").path)
                        } ?? false
                        let parts = (try? FileManager.default.contentsOfDirectory(at: repository.folder(id).appendingPathComponent("capture"), includingPropertiesForKeys: nil)) ?? []
                        return (!m.sourceComplete || needsSeal, parts.contains { $0.pathExtension == "caf" && !$0.lastPathComponent.contains(".partial.") })
                    }
                    guard generation == queueGeneration, admission == recordingAdmission[id, default: 0], !deletingRecordingIDs.contains(id), !shuttingDown else { return }
                    if needsAssembly {
                        guard hasParts else {
                            let message = "В этой записи нет сохранённого звука. Начните новую запись."
                            try await archive.update(id) { m in m.state = .failed; m.lastError = message }
                            await reload(); errorHandler.report(message: message); return
                        }
                        try await finalizeCapture(id)
                    }
                }
                guard generation == queueGeneration, admission == recordingAdmission[id, default: 0], !deletingRecordingIDs.contains(id), !shuttingDown else { return }
                await enqueue(id, allowCancelled: true)
            } catch { errorHandler.report(error) }
        }
    }
    func repeatAnalysis(summaryOnly: Bool, language: String? = nil) async {
        guard let archive, let catalog = activeCatalog, var m = selected, canManageModels, modelsReady else { return }
        finalizingRecording = true
        defer { finalizingRecording = false }
        let summaryLanguage = summaryOnly ? language ?? transcript?.primaryLanguage ?? "ru" : language
        do { m = try await archive.beginRun(m.id, catalog: catalog, summaryLanguage: summaryLanguage, summaryOnly: summaryOnly); await reload(); await enqueue(m.id) }
        catch { errorHandler.report(error) }
    }
    func queuePosition(for id: String) -> Int? {
        queued.firstIndex(of: id).map { $0 + 1 }
    }
    func moveToFrontOfQueue(_ id: String) {
        guard !preparingStorage, !shuttingDown, id != activeID,
              let index = queued.firstIndex(of: id), index > 0 else { return }
        var reordered = queued
        reordered.remove(at: index)
        reordered.insert(id, at: 0)
        queued = reordered
    }
    func enqueueCapture(_ id: String) async {
        guard let archive else { return }
        let generation = queueGeneration, admission = recordingAdmission[id, default: 0], pauseReason = queuePauses.values.first
        let valid = await archive.perform { repository in
            guard let manifest = try? repository.load(id), manifest.state == .recording, manifest.captureProcessing != .cancelled,
                  let pending = manifest.pendingRunId,
                  let info = try? Disk.read(RunInfo.self, at: repository.run(id, pending).appendingPathComponent("run.json")) else { return false }
            return info.liveCapture == true
        }
        guard valid, generation == queueGeneration, admission == recordingAdmission[id, default: 0], !deletingRecordingIDs.contains(id), activeID != id, !shuttingDown else { return }
        if let reason = queuePauses.values.first ?? pauseReason {
            await interruptEnqueue(id, reason: reason); return
        }
        if !queued.contains(id) { queued.append(id) }
        Task { await processQueue() }
    }
    private func interruptEnqueue(_ id: String, reason: String) async {
        _ = try? await archive?.update(id) { m in
            if m.state == .recording { m.captureProcessing = .interrupted } else { m.state = .interrupted }
            m.lastError = reason
        }
        await reload()
    }
    func enqueue(_ id: String, allowCancelled: Bool = false) async {
        guard let archive, !deletingRecordingIDs.contains(id), enqueuing[id] == nil else { return }
        let request = UUID(), generation = queueGeneration
        let pauseReason = queuePauses.values.first
        enqueuing[id] = request
        defer {
            if enqueuing[id] == request { enqueuing.removeValue(forKey: id) }
            if !busy { Task { await processQueue() } }
        }
        let m: Manifest
        do { m = try await archive.load(id) }
        catch {
            errorHandler.report(message: "Не удалось прочитать запись для продолжения обработки. Файлы сохранены; проверьте архив и повторите попытку.")
            return
        }
        guard m.sourceComplete, id != activeID,
              allowCancelled || m.state != .cancelled,
              generation == queueGeneration, !deletingRecordingIDs.contains(id), enqueuing[id] == request else { return }
        if shuttingDown {
            _ = try? await archive.update(id) { m in
                m.state = .interrupted; m.lastError = "Приложение закрыто. Можно продолжить обработку."
            }
            await reload(); return
        }
        if let reason = queuePauses.values.first ?? pauseReason {
            await interruptEnqueue(id, reason: reason); return
        }
        let canQueue = m.pendingRunId != nil || modelsReady
        // Reserve FIFO position before suspending for persistence.
        if canQueue, !queued.contains(id) { queued.append(id) }
        _ = try? await archive.update(id) { m in
            m.state = canQueue ? .queued : .waitingForModels; m.lastError = nil
        }
        await reload()
    }
    private func requireHardware(for role: ModelRole, info: RunInfo, catalog: ModelCatalog) throws {
        let pinned = try catalog.pinned(to: info)
        guard let profile = pinned.models.first(where: { $0.purpose == role }) else { throw ScribeError.message("Модель этапа отсутствует") }
        try hardware.requireCompatibility(for: profile)
    }
    func processQueue() async {
        guard deletingGroupID == nil, !deletingSidebarRecordings, !preparingStorage, !busy, !resourcesPaused, !suspendingQueue, queuePauses.isEmpty, resourcePauseTask == nil, !installing, !verifyingModels, !startingRecording, !shuttingDown,
              let repository, let archive, let catalog else { return }
        busy = true; defer { busy = false; activeID = nil; processingRecordingID = nil; status = "" }
        while deletingGroupID == nil && !deletingSidebarRecordings && queued.first.map({ enqueuing[$0] == nil }) == true && !resourcesPaused && !suspendingQueue && queuePauses.isEmpty && resourcePauseTask == nil && !shuttingDown {
            if ProcessInfo.processInfo.thermalState == .critical {
                status = "Обработка ожидает охлаждения Mac"
                try? await Task.sleep(for: .seconds(2)); continue
            }
            let id = queued.removeFirst(); activeID = id; processingRecordingID = id
            do {
                var m = try await archive.load(id)
                if m.pendingRunId == nil {
                    guard modelsReady, let selectedCatalog = activeCatalog else {
                        try await archive.update(id) { $0.state = .waitingForModels }; continue
                    }
                    m = try await archive.beginRun(m.id, catalog: selectedCatalog)
                }
                var info = try await archive.perform { try $0.resumeRun(id, catalog: catalog) }
                guard activeID == id else { throw CancellationError() }
                m = try await archive.load(id)
                let livePending = info.liveCapture == true && info.sourceHash == "capture:" + info.id
                let run = repository.run(id,info.id)
                if livePending {
                    try requireHardware(for: .asr, info: info, catalog: catalog)
                    m = try await archive.update(id) { m in
                        // A saved capture can start its live ASR after waiting in
                        // the queue. Its main state now describes processing.
                        if m.state == .recording {
                            m.captureProcessing = .transcribing
                        } else {
                            m.state = .transcribing; m.captureProcessing = nil
                        }
                    }
                    await reload()
                    guard activeID == id else { throw CancellationError() }
                    var command = WorkerCommand(jobId: id, runId: info.id, stage: .transcribing, recordingPath: repository.folder(id).path, modelsPath: repository.models.path, toolsPath: tools.path)
                    command.liveCapture = true
                    try await runWorker(command)
                    guard activeID == id else { throw CancellationError() }
                    let captureInfo = info
                    info = try await archive.perform { try $0.bindLiveTranscript(id, info: captureInfo) }
                    m = try await archive.update(id) { $0.captureProcessing = nil }
                }
                let stages: [Stage] = [.preparingAudio,.transcribing,.diarizing,.summarizing]
                for stage in stages {
                    if activeID != id { throw CancellationError() }
                    // Explicit recreation records a requested language, even before
                    // the first successful run; older summary-only runs pin a source.
                    // Read the preference at the stage boundary, including after live ASR.
                    if stage == .summarizing, !automaticSummaries, info.summaryLanguage == nil, info.transcriptSourceRunID == nil { continue }
                    m = try await archive.load(id)
                    if try await archive.perform({ [m, info] _ in try Self.stageComplete(stage, run: run, manifest: m, info: info) }) { continue }
                    guard m.sourceComplete else { throw ScribeError.message("Исходник ещё записывается") }
                    let role: ModelRole? = stage == .transcribing ? .asr : stage == .diarizing ? .diarization : stage == .summarizing ? .summary : nil
                    if let role { try requireHardware(for: role, info: info, catalog: catalog) }
                    guard activeID == id else { throw CancellationError() }
                    m = try await archive.update(id) { $0.state = JobState(rawValue: stage.rawValue)! }
                    await reload()
                    guard activeID == id else { throw CancellationError() }
                    let command = WorkerCommand(jobId: id, runId: info.id, stage: stage, recordingPath: repository.folder(id).path, modelsPath: repository.models.path, toolsPath: tools.path)
                    try await runWorker(command)
                    guard activeID == id else { throw CancellationError() }
                    guard try await archive.perform({ [m, info] _ in try Self.stageComplete(stage, run: run, manifest: m, info: info) }) else { throw ScribeError.message("Worker не создал проверяемый результат этапа") }
                    await reload()
                }
                guard activeID == id else { throw CancellationError() }
                let completedRunID = info.id
                // A transcript-only result is valid, but any existing final JSON
                // must still pass validation before replacing the previous result.
                try await archive.perform { [m] repository in
                    var completed = m; completed.activeRunId = completedRunID
                    _ = try repository.results(completed)
                }
                guard activeID == id else { throw CancellationError() }
                try await archive.update(id) { m in
                    m.activeRunId = completedRunID; m.pendingRunId = nil; m.captureProcessing = nil
                    m.state = m.warnings.isEmpty ? .completed : .completedWithWarnings; m.lastError = nil
                }
            } catch {
                let message = (error as? ScribeError)?.localizedDescription
                    ?? "Обработка прервана. Готовые результаты и контрольные точки сохранены."
                if activeID == id, !(error is CancellationError) { errorHandler.report(message: message) }
                if !(resourcesPaused && queued.contains(id)) {
                    let isRecording = recordingID == id, ownsJob = activeID == id
                    _ = try? await archive.update(id) { m in
                        // A queued job can be cancelled while its previous worker
                        // is still unwinding a resource pause.
                        guard m.state != .cancelled, m.captureProcessing != .cancelled else { return }
                        if isRecording || !m.sourceComplete && m.state == .recording {
                            // Processing failure never changes microphone ownership/state.
                            m.captureProcessing = ownsJob ? .failed : .interrupted
                        } else if m.state.processing || m.state == .queued || m.state == .recorded {
                            m.state = ownsJob ? .failed : .interrupted
                        }
                        m.lastError = message
                    }
                }
            }
            // Only the owning queue task clears activeID, after all readers exit.
            await archive.perform { try? $0.cleanupTemporaryFiles(id) }
            activeID = nil; processingRecordingID = nil; await reload()
        }
    }
    private func runWorker(_ command: WorkerCommand) async throws {
        try await supervisor.run(command, executable: worker) { event in
            if event.type == "progress" { self.status = event.message }
            if event.type == "checkpoint" {
                self.resultSignature = ""; self.loadResult()
            }
            if event.type == "warning", let archive = self.archive {
                _ = try? await archive.update(command.jobId) { current in
                    if !current.warnings.contains(event.message) { current.warnings.append(event.message) }
                }
                await self.reload()
            }
        }
    }
    func resumeAfterMemoryPressure() {
        memoryLimited = false; resourcesPaused = captureLimited
        Task { await resourcePauseTask?.value; await processQueue() }
    }
    func pauseForCaptureResources(memoryPressure: Bool = false) {
        if memoryPressure { memoryLimited = true } else { captureLimited = true }
        resourcesPaused = true
        guard resourcePauseTask == nil else { return }
        resourcePauseTask = Task {
            if let id = activeID {
                activeID = nil
                if !queued.contains(id) { queued.insert(id, at: 0) }
                if let archive {
                    _ = try? await archive.update(id) { m in
                        if m.state == .recording { m.captureProcessing = .interrupted } else { m.state = .queued }
                        m.lastError = "Распознавание приостановлено, чтобы сохранить звук при нехватке ресурсов."
                    }
                }
                await supervisor.cancel()
                while busy { try? await Task.sleep(for: .milliseconds(50)) }
            }
            resourcePauseTask = nil
            await reload()
            if !resourcesPaused { await processQueue() }
        }
    }
    nonisolated static func stageComplete(_ stage: Stage, run: URL, manifest: Manifest, info: RunInfo) throws -> Bool {
        // A validated final transcript completes every audio/ASR stage, including
        // a summary-only run copied from a manually edited revision.
        if stage == .preparingAudio || stage == .transcribing,
           let transcript = try? Disk.read(Transcript.self, at: run.appendingPathComponent("transcript.json")),
           transcript.fingerprint == info.fingerprint, transcript.diarized {
            try transcript.validate(durationMs: manifest.durationMs)
            return true
        }
        switch stage {
        case .preparingAudio:
            guard let checkpoint = try? Disk.read([String:String].self, at: run.appendingPathComponent("prepared.json")), checkpoint["fingerprint"] == info.fingerprint,
                  let file = try? AVAudioFile(forReading: run.appendingPathComponent("work/audio.wav")) else { return false }
            return file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1 && abs(Double(file.length)/16 - Double(manifest.durationMs)) < 150
        case .transcribing, .diarizing:
            let name = stage == .transcribing ? "asr-transcript.json" : "transcript.json"
            guard let t = try? Disk.read(Transcript.self, at: run.appendingPathComponent(name)), t.fingerprint == info.fingerprint else { return false }
            try t.validate(durationMs: manifest.durationMs); return stage != .diarizing || t.diarized
        case .summarizing:
            guard let s = try? Disk.read(Summary.self, at: run.appendingPathComponent("summary.json")), let t = try? Disk.read(Transcript.self, at: run.appendingPathComponent("transcript.json")) else { return false }
            try s.validate(against: t); return s.language == (info.summaryLanguage ?? t.primaryLanguage)
        }
    }
    func pause(reason: String) async {
        queueGeneration &+= 1
        let pauseID = UUID()
        queuePauses[pauseID] = reason
        defer { queuePauses.removeValue(forKey: pauseID) }
        let ids = queued + (activeID.map { [$0] } ?? [])
        queued.removeAll(); activeID = nil
        if let archive {
            for id in Set(ids) {
                _ = try? await archive.update(id) { m in
                    guard m.state != .cancelled, m.captureProcessing != .cancelled else { return }
                    if m.state == .recording { m.captureProcessing = .interrupted } else { m.state = .interrupted }
                    m.lastError = reason
                }
            }
        }
        await supervisor.cancel()
        while busy { try? await Task.sleep(for: .milliseconds(50)) }
        await reload()
    }
    func cancelSelected() async {
        guard let id = selection else { return }
        await cancel(id)
    }
    func cancel(_ id: String) async {
        guard let archive else { return }
        recordingAdmission[id, default: 0] &+= 1
        enqueuing.removeValue(forKey: id)
        queued.removeAll { $0 == id }
        if activeID == id || processingRecordingID == id {
            suspendingQueue = true; activeID = nil
            await supervisor.cancel()
            while busy { try? await Task.sleep(for: .milliseconds(50)) }
            suspendingQueue = false
            Task { await processQueue() }
        }
        _ = try? await archive.update(id) { m in
            if m.state == .recording { m.captureProcessing = .cancelled } else { m.state = .cancelled }
        }
        await reload()
    }
    func deleteSelected() async {
        guard deletingGroupID == nil, !deletingSidebarRecordings, let selected, let archive, selected.id != recordingID, !finalizingRecording else { return }
        let alert = NSAlert(); alert.messageText = "Удалить запись и результаты?"; alert.informativeText = "Будут удалены только копия аудио и результаты в LocalScribe. Внешний оригинал и ваши экспорты сохранятся."
        alert.addButton(withTitle: "Удалить запись"); alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await cancelSelected()
        do { try await archive.delete(selected); selection = nil; await reload() } catch { errorHandler.report(error) }
    }
    var sidebarRecordingOrder: [String] {
        recordingGroups.groups.filter { recordingSearch.expanded($0) }.flatMap { recordingSearch.visible[$0.id] ?? [] }
    }
    func selectSidebarRecording(_ id: String, command: Bool = false, shift: Bool = false) {
        var next = sidebarSelection
        next.click(id, command: command, shift: shift, order: sidebarRecordingOrder)
        let primary = next.ids.contains(id) ? id : sidebarRecordingOrder.first { next.ids.contains($0) }
        if selection != primary { selection = primary }
        sidebarSelection = next
    }
    func selectSidebarContext(_ id: String) {
        var next = sidebarSelection
        next.contextClick(id)
        if !next.ids.contains(selection ?? "") { selection = id }
        sidebarSelection = next
    }
    func sidebarActionIDs(for id: String) -> Set<String> {
        let ids = sidebarSelection.ids.contains(id) ? sidebarSelection.ids : [id]
        return recordingSearch.active && recordingSearch.completed ? ids.intersection(recordingSearch.matchingIDs) : ids
    }
    func moveRecordings(_ ids: Set<String>, to groupID: String) async {
        guard let archive, deletingGroupID == nil, !deletingSidebarRecordings else { return }
        do { try await archive.moveRecordings(ids, to: groupID); await reload() }
        catch { errorHandler.report(error) }
    }
    func canDeleteSidebarRecordings(_ ids: Set<String>) -> Bool {
        !ids.isEmpty && deletingGroupID == nil && !deletingSidebarRecordings
            && Set([recordingID, finalizingRecordingID].compactMap { $0 }).isDisjoint(with: ids)
    }
    /// The confirmation view freezes the IDs; selection may change while it is open.
    func deleteSidebarRecordings(_ ids: Set<String>) async {
        guard let archive, canDeleteSidebarRecordings(ids) else { return }
        deletingSidebarRecordings = true
        deletingRecordingIDs.formUnion(ids)
        // Bar every selected job before cancellation can yield to an enqueue response.
        for id in ids {
            recordingAdmission[id, default: 0] &+= 1
            enqueuing.removeValue(forKey: id)
        }
        queued.removeAll { ids.contains($0) }
        defer {
            deletingSidebarRecordings = false
            deletingRecordingIDs.subtract(recordings.map(\.id))
            Task { await processQueue() }
        }
        for id in ids.sorted() { await cancel(id) }
        do {
            for manifest in recordings.filter({ ids.contains($0.id) }) {
                try await archive.delete(manifest)
            }
        } catch { errorHandler.report(error) }
        await reload()
    }
    var defaultGroup: RecordingGroup { recordingGroups.defaultGroup }
    func recordings(in groupID: String) -> [Manifest] {
        recordings.filter { recordingGroups.groupID(for: $0.id) == groupID }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }
    func visibleRecordings(in groupID: String) -> [Manifest] {
        (recordingSearch.visible[groupID] ?? []).compactMap { recordingsByID[$0] }
    }
    func sidebarGroups(editing id: String?) -> [RecordingGroup] {
        recordingGroups.groups.filter {
            !recordingSearch.active || !recordingSearch.completed || !(recordingSearch.visible[$0.id] ?? []).isEmpty || $0.id == id
        }
    }
    func sidebarGroupCount(_ id: String) -> String {
        let total = recordingSearch.normal[id]?.count ?? 0
        return recordingSearch.active ? "\(recordingSearch.filtered[id]?.count ?? 0) / \(total)" : "\(total)"
    }
    private func retainSearchSelection() {
        guard recordingSearch.active, recordingSearch.completed else { return }
        var retained = sidebarSelection
        retained.retain(recordingSearch.matchingIDs)
        sidebarSelection = retained
    }
    func setSidebarExpanded(_ group: RecordingGroup) async {
        if recordingSearch.active { recordingSearch.setExpanded(group.id, !recordingSearch.expanded(group)) }
        else { await changeGroups { try $0.setExpanded(group.id, !group.expanded) } }
    }
    func setAllSidebarExpanded(_ expanded: Bool) async {
        if recordingSearch.active { recordingSearch.setAllExpanded(expanded) }
        else { await changeGroups { $0.setAllExpanded(expanded) } }
    }
    func saveGroupName(_ name: String, id: String? = nil) async throws {
        guard let archive else { throw ScribeError.message("Хранилище недоступно") }
        try await archive.editGroups { groups in
            if let id { try groups.rename(id, name: name) }
            else { try groups.create(name: name) }
        }
        await reload()
    }
    func changeGroups(_ operation: @Sendable (inout RecordingGroups) throws -> Void) async {
        guard let archive else { return }
        do { try await archive.editGroups(operation); await reload() }
        catch { errorHandler.report(error) }
    }
    func moveRecording(_ id: String, to groupID: String) async {
        await moveRecordings([id], to: groupID)
    }
    func revealRecording(_ id: String) async {
        guard let archive else { return }
        await reload()
        let groupID = recordingGroups.groupID(for: id)
        do { try await archive.editGroups { try $0.setExpanded(groupID, true) } }
        catch { errorHandler.report(error) }
        await reload()
        selection = id; sidebarRevealID = id
    }
    func canDeleteRecordings(in groupID: String) -> Bool {
        if startingRecording && startingGroupID == groupID { return false }
        return ![recordingID, finalizingRecordingID].compactMap { $0 }.contains {
            recordingGroups.groupID(for: $0) == groupID
        }
    }
    /// Confirmation belongs to the view; this method rechecks live protection.
    func deleteGroup(_ id: String, deleteRecordings: Bool) async {
        guard let archive, deletingGroupID == nil, !deletingSidebarRecordings, id != RecordingGroup.ungroupedID else { return }
        guard !deleteRecordings || canDeleteRecordings(in: id) else {
            errorHandler.report(message: "Сначала остановите запись"); return
        }
        deletingGroupID = id
        var members: [String] = []
        defer {
            deletingGroupID = nil
            // Deleted IDs stay barred; surviving members can be explicitly resumed.
            deletingRecordingIDs.subtract(recordings.map(\.id))
            Task { await processQueue() }
        }
        do {
            members = try await archive.prepareGroupDeletion(id)
            if deleteRecordings {
                let protected = Set([recordingID, finalizingRecordingID].compactMap { $0 })
                guard canDeleteRecordings(in: id), protected.isDisjoint(with: members) else {
                    throw ScribeError.message("Сначала остановите запись")
                }
                deletingRecordingIDs.formUnion(members)
                // Invalidate all admissions before the first cancellation suspends.
                for member in members {
                    recordingAdmission[member, default: 0] &+= 1
                    enqueuing.removeValue(forKey: member)
                }
                queued.removeAll { members.contains($0) }
                for member in members { await cancel(member) }
            }
            try await archive.finishGroupDeletion(id, deleteRecordings: deleteRecordings)
        } catch {
            await archive.cancelGroupDeletion(id)
            errorHandler.report(error)
        }
        await reload()
        if let selection, !recordings.contains(where: { $0.id == selection }) { self.selection = nil }
    }
    func showAudio() { guard let selected, let repository else { return }; NSWorkspace.shared.activateFileViewerSelecting([repository.folder(selected.id).appendingPathComponent(selected.originalRelativePath)]) }
    func rendered(_ part: ExportPart, markdown: Bool = false) async throws -> String {
        try await renderedResult(part, markdown: markdown).text
    }
    func renderedResult(_ part: ExportPart, markdown: Bool = false) async throws -> RenderedExport {
        guard let selected else { throw CancellationError() }
        return try await resultPresentation.render(manifest: selected, transcript: transcript, summary: summary, revision: resultRevision, part: part, markdown: markdown)
    }
    func copy(_ part: ExportPart) {
        copyTask?.cancel()
        copyTask = Task {
            do {
                let text = try await rendered(part)
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                status = "Скопировано"
            } catch { errorHandler.report(error) }
        }
    }
    func export(markdown: Bool, part: ExportPart) {
        guard let selected else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = selected.displayTitle.replacingOccurrences(of: "/", with: "-") + (markdown ? ".md" : ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let request = UUID()
        exportTasks[request] = Task {
            defer { exportTasks.removeValue(forKey: request) }
            await export(to: url, markdown: markdown, part: part)
        }
    }
    func export(to url: URL, markdown: Bool, part: ExportPart) async {
        do {
            let text = try await rendered(part, markdown: markdown)
            try await Task.detached(priority: .userInitiated) {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }.value
        } catch is CancellationError { }
        catch { errorHandler.report(message: "Не удалось экспортировать: \(error.localizedDescription)") }
    }
    func shutdown() async {
        shuttingDown = true
        copyTask?.cancel()
        for task in Array(exportTasks.values) { await task.value }
        recordingSearch.shutdown()
        importQueue.cancel()
        memorySource?.cancel(); memorySource = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }; sleepObserver = nil
        installTask?.cancel(); downloader.close()
        while startingRecording { try? await Task.sleep(for: .milliseconds(50)) }
        if recordingID != nil { await stopRecording() }
        while savingResult { try? await Task.sleep(for: .milliseconds(50)) }
        while finalizingRecording { try? await Task.sleep(for:.milliseconds(50)) }
        await pause(reason:"Приложение закрыто. Можно продолжить обработку."); supervisor.terminateNow()
        await installTask?.value
        await importQueue.waitUntilIdle()
        for task in Array(warningTasks.values) { await task.value }
        await archive?.flushIndex()
    }
    /// Explicit developer mode: short real input test, no models/archive, audio deleted.
    private func microphoneSelfCheck() async {
        guard let repository else { return }
        let base = repository.root.appendingPathComponent("diagnostics")
        let temporary = base.appendingPathComponent("microphone-\(UUID().uuidString)")
        let captureFolder = temporary.appendingPathComponent("capture")
        let reportURL = base.appendingPathComponent("microphone-probe-result.json")
        defer { try? FileManager.default.removeItem(at:temporary) }
        var report = ["status":"running","phase":"permission","version":AppInfo.version]
        try? Disk.write(report,to:reportURL)
        let capture = MicrophoneRecorder()
        var reason: String?, lastElapsed = 0.0
        capture.onStopNeeded = { value in Task { @MainActor in reason = value } }
        capture.onMeter = { _, elapsed, _ in Task { @MainActor in lastElapsed = elapsed } }
        do {
            guard await AVCaptureDevice.requestAccess(for:.audio) else { throw ScribeError.message("Доступ к микрофону не разрешён") }
            status = "Техническая проверка микрофона: 12 секунд, звук будет удалён"
            try capture.start(folder:captureFolder)
            report["phase"] = "capturing"; try Disk.write(report,to:reportURL)
            let started = Date()
            let inject = CommandLine.arguments.contains("--self-check-microphone-events")
            var benignSent = false, restartSent = false
            while Date().timeIntervalSince(started) < 12 && reason == nil {
                let elapsed = Date().timeIntervalSince(started)
                if inject && elapsed >= 2 && !benignSent { benignSent = true; capture.simulateConfigurationChangeForDiagnostics(stopEngine:false) }
                if inject && elapsed >= 4 && !restartSent { restartSent = true; capture.simulateConfigurationChangeForDiagnostics(stopEngine:true) }
                try await Task.sleep(for:.milliseconds(100))
            }
            let frames = try await capture.stop()
            if let reason { throw ScribeError.message(reason) }
            let parts = try FileManager.default.contentsOfDirectory(at:captureFolder,includingPropertiesForKeys:nil).filter { $0.pathExtension == "caf" && !$0.lastPathComponent.contains(".partial.") }
            let (assembled,rate) = try Media.assembleCapture(captureFolder,destination:temporary.appendingPathComponent("assembled.caf"))
            guard frames == assembled, Double(frames)/rate >= 11, parts.count >= 2 else { throw ScribeError.message("Запись не сохранила ожидаемые фрагменты") }
            if inject { guard capture.engineRestartCount >= 1 else { throw ScribeError.message("Восстановление аудиодвижка не проверено") } }
            report = ["status":"passed","version":AppInfo.version,"frames":String(frames),"sampleRate":String(rate),"seconds":String(Double(frames)/rate),"completedParts":String(parts.count),"configurationEvents":String(capture.configurationEventCount),"engineRestarts":String(capture.engineRestartCount),"meterSeconds":String(lastElapsed),"injectedEvents":String(inject),"audio":"deleted; no archive or models"]
        } catch {
            _ = try? await capture.stop()
            report = ["status":"failed","version":AppInfo.version,"error":error.localizedDescription,"configurationEvents":String(capture.configurationEventCount),"engineRestarts":String(capture.engineRestartCount),"audio":"deleted; no archive or models"]
        }
        try? Disk.write(report,to:reportURL)
        NSApplication.shared.terminate(nil)
    }
    /// Developer diagnostic. Exercises the actual signed parent -> worker -> ffmpeg chain.
    /// Synthetic silence lives under diagnostics, never in the user's archive.
    private func sandboxSelfCheck() async {
        guard let repository, let catalog else { NSApplication.shared.terminate(nil); return }
        let diagnostics = repository.root.appendingPathComponent("diagnostics")
        let full = CommandLine.arguments.contains("--self-check-full")
        var testModels: URL?
        var events: [String] = []
        do {
            var manifest = Manifest(sourceType:full ? "technical-probe" : "diagnostic",title:"Sandbox probe",filename:full ? "probe.wav" : "original.caf")
            let folder = diagnostics.appendingPathComponent(manifest.id), source = folder.appendingPathComponent(manifest.originalRelativePath)
            try Disk.directory(source.deletingLastPathComponent())
            let modelRoot = full ? folder.appendingPathComponent("models") : repository.models
            if full {
                try Disk.directory(modelRoot); testModels = modelRoot
                let bundledModels = resources.appendingPathComponent("ProbeModels")
                // A separate developer probe bundle supplies read-only public weights. The
                // shipping app never embeds them or gains access to arbitrary external paths.
                for profile in catalog.models where ModelRole(rawValue: profile.id) != nil { try await installer.install(profile,root:modelRoot,localSource:bundledModels.appendingPathComponent(profile.id)) { _ in } }
                try FileManager.default.copyItem(at:resources.appendingPathComponent("probe.wav"),to:source)
                let audio = try Media.probe(source,tools:tools)
                manifest.durationMs = Int((audio.duration*1000).rounded()); manifest.sampleRate = audio.sampleRate; manifest.channels = audio.channels
            } else {
                let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                do { let file = try AVAudioFile(forWriting: source, settings: format.settings); let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!; buffer.frameLength = 8000; memset(buffer.floatChannelData![0],0,8000*4); try file.write(from: buffer) }
                manifest.durationMs = 500; manifest.sampleRate = 16000; manifest.channels = 1
            }
            manifest.sourceComplete = true; manifest.sha256 = try Disk.hash(source)
            let info = RunInfo(sourceHash: manifest.sha256, profileHash: catalog.fingerprint)
            let run = folder.appendingPathComponent("runs/\(info.id)")
            try Disk.write(manifest, to: folder.appendingPathComponent("manifest.json")); try Disk.write(info, to: run.appendingPathComponent("run.json"))
            let stages: [Stage] = full ? [.preparingAudio,.transcribing,.diarizing,.summarizing] : [.preparingAudio]
            for stage in stages {
                let command = WorkerCommand(jobId:manifest.id,runId:info.id,stage:stage,recordingPath:folder.path,modelsPath:modelRoot.path,toolsPath:tools.path)
                try await supervisor.run(command,executable:worker,diagnosticURL:full ? run.appendingPathComponent("\(stage.rawValue).stderr") : nil) { event in
                    events.append(stage.rawValue+":"+event.type)
                    self.status = event.message
                    try? Disk.write(["stage":stage.rawValue,"event":event.type,"message":event.message],to:diagnostics.appendingPathComponent("sandbox-probe-progress.json"))
                }
            }
            let prepared = try Disk.read([String:String].self, at: run.appendingPathComponent("prepared.json"))
            guard prepared["fingerprint"] == info.fingerprint else { throw ScribeError.message("Invalid self-check checkpoint") }
            if full {
                let transcript = try Disk.read(Transcript.self,at:run.appendingPathComponent("transcript.json"))
                let summary = try Disk.read(Summary.self,at:run.appendingPathComponent("summary.json"))
                try transcript.validate(durationMs:manifest.durationMs); try summary.validate(against:transcript)
                try Disk.write(["status":"passed","recordingPath":folder.path,"runPath":run.path,"check":"all real models in signed network-denied sandbox"],to:diagnostics.appendingPathComponent("sandbox-probe-result.json"))
                try? FileManager.default.removeItem(at:modelRoot)
                NSApplication.shared.terminate(nil); return
            }
            let checkFile = try await downloader.fetch(profileID:nil)
            let checkData = try checkFile.readToEnd() ?? Data(); try checkFile.close(); downloader.close()
            guard String(data:checkData,encoding:.utf8) == "LocalScribe model service" else { throw ScribeError.message("Неверный ответ XPC-загрузчика") }
            if CommandLine.arguments.contains("--self-check-download"), let profile = catalog.models.first(where:{$0.id == "tokenizer"}), let index = profile.files.indices.min(by:{profile.files[$0].size < profile.files[$1].size}) {
                let progress = Progress(totalUnitCount: profile.files[index].size)
                let file = try await downloader.fetch(profileID:profile.id,index:index) { progress.completedUnitCount = $0 }
                let bytes = try file.readToEnd() ?? Data(); try file.close(); downloader.close()
                let output = diagnostics.appendingPathComponent("download-probe.json")
                try bytes.write(to:output,options:.atomic)
                guard try Disk.hash(output) == profile.files[index].sha256 else { throw ScribeError.message("XPC-загрузка не прошла SHA-256") }
                guard progress.completedUnitCount > 0 else { throw ScribeError.message("XPC-загрузчик не передал прогресс в байтах") }
                try Disk.write(["status":"passed", "bytes":String(bytes.count), "progressBytes":String(progress.completedUnitCount)], to: diagnostics.appendingPathComponent("model-download-probe-result.json"))
            }
            try Disk.write(["status":"passed","events":events.joined(separator:","),"version":AppInfo.version,"check":"signed parent -> inherited network-denied worker -> bundled ffmpeg; XPC downloader file descriptor"], to: diagnostics.appendingPathComponent("sandbox-probe-result.json"))
        } catch {
            try? Disk.write(["status":"failed","error":error.localizedDescription,"events":events.joined(separator:",")], to: diagnostics.appendingPathComponent("sandbox-probe-result.json"))
        }
        if let testModels { try? FileManager.default.removeItem(at:testModels) }
        NSApplication.shared.terminate(nil)
    }
}
