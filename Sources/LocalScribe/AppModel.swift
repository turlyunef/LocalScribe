import SwiftUI
import AppKit
import AVFoundation
import Metal
import LocalScribeCore

@MainActor final class AppModel: ObservableObject {
    @Published var recordings: [Manifest] = []
    @Published var selection: String? {
        didSet {
            if oldValue != selection { transcript = nil; summary = nil; resultSignature = "" }
            loadResult()
        }
    }
    @Published var transcript: Transcript?
    @Published var summary: Summary?
    @Published var error: String?
    @Published var status = ""
    @Published var modelsStatus = "Проверяем модели…"
    @Published var modelsReady = false
    @Published var installing = false
    @Published var verifyingModels = false
    @Published var modelLibrary = ModelLibrary()
    @Published var downloadProgress: ModelInstallProgress?
    @Published var downloadBatch = ""
    let hardware: ModelHardware = {
        let gpu = MTLCreateSystemDefaultDevice()
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return ModelHardware(chip: String(cString: name), memoryBytes: ProcessInfo.processInfo.physicalMemory,
                             cpuCores: ProcessInfo.processInfo.processorCount, gpuWorkingSetBytes: gpu?.recommendedMaxWorkingSetSize ?? 0,
                             appleSilicon: appleSilicon, supportsMetal: gpu != nil)
    }()
    var canManageModels: Bool { !preparingStorage && !installing && !verifyingModels && !busy && !startingRecording && !finalizingRecording && recordingID == nil && !shuttingDown }
    var activeCatalog: ModelCatalog? { catalog.flatMap { modelLibrary.activeCatalog(from: $0) } }
    @Published var recordingID: String?
    @Published var startingRecording = false
    @Published var finalizingRecording = false
    @Published var elapsed = 0.0
    @Published var level = 0.0
    @Published var soundNotice: String?
    @Published var busy = false
    @Published var shuttingDown = false
    @Published private(set) var preparingStorage = true
    @Published var tab: ExportPart = .transcript
    @Published var jumpTo: String?
    let repository: RecordingRepository?
    let catalog: ModelCatalog?
    let resources: URL
    let supervisor = WorkerSupervisor()
    private let installer = ModelInstaller()
    private let downloader = ModelDownloadClient()
    private var recorder: MicrophoneRecorder?
    private var queued: [String] = []
    private var activeID: String?
    private var stopping = false
    private var memorySource: DispatchSourceMemoryPressure?
    private var sleepObserver: NSObjectProtocol?
    private var installTask: Task<Void, Never>?
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    private var resultSignature = ""
    var selected: Manifest? { recordings.first { $0.id == selection } }
    var tools: URL { resources.appendingPathComponent("tools") }
    var worker: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalScribeWorker") }
    init() {
        let bundled = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        resources = FileManager.default.fileExists(atPath: bundled.appendingPathComponent("models.lock.json").path) ? bundled : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        catalog = try? Disk.read(ModelCatalog.self, at: resources.appendingPathComponent("models.lock.json"))
        do { let repo = try RecordingRepository(); repository = repo; recordings = repo.list() }
        catch { repository = nil; self.error = "Не удалось открыть локальное хранилище: \(error.localizedDescription)" }
        memorySource = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .main)
        memorySource?.setEventHandler { [weak self] in Task { @MainActor in await self?.pause(reason: "Обработка приостановлена из-за нехватки памяти. Можно продолжить с контрольной точки.") } }
        memorySource?.resume()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if self?.recordingID != nil { await self?.stopRecording(warning: "Сон системы прервал запись.") }
                await self?.pause(reason: "Обработка прервана перед сном. Нажмите «Продолжить» после пробуждения.")
            }
        }
        Task {
            status = "Восстанавливаем локальное хранилище…"
            if let repository {
                do {
                    recordings = try await Task.detached(priority: .utility) {
                        try repository.recover(); return repository.list()
                    }.value
                } catch { self.error = "Не удалось восстановить локальное хранилище: \(error.localizedDescription)" }
            }
            preparingStorage = false
            if status == "Восстанавливаем локальное хранилище…" { status = "" }
            await verifyModels()
        }
        if CommandLine.arguments.contains("--self-check") { Task { await sandboxSelfCheck() } }
        if CommandLine.arguments.contains("--self-check-microphone") { Task { await microphoneSelfCheck() } }
    }
    func reload() { recordings = repository?.list() ?? []; loadResult() }
    func renameRecording(_ id: String, title: String) {
        guard !preparingStorage, let repository else { return }
        do {
            try repository.rename(id, title: title)
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
    func loadResult() {
        guard let selected, let repository else { transcript = nil; summary = nil; resultSignature = ""; return }
        let signature = selected.id + (selected.activeRunId ?? "") + (selected.pendingRunId ?? "") + selected.state.rawValue
        guard resultSignature != signature else { return }
        resultSignature = signature
        Task {
            let results = await Task.detached(priority: .userInitiated) { repository.results(selected) }.value
            guard self.selection == selected.id, self.resultSignature == signature else { return }
            self.transcript = results.0; self.summary = results.1
        }
    }
    func verifyModels() async {
        guard let catalog, let repository, canManageModels else { return }
        verifyingModels = true; modelsStatus = "Проверяем целостность моделей…"
        defer { verifyingModels = false; if !queued.isEmpty { Task { await processQueue() } } }
        do {
            modelLibrary = try await Task.detached(priority: .utility) { try ModelLibrary.load(at: repository.models, catalog: catalog) }.value
            updateModelsStatus()
        } catch { modelsReady = false; modelsStatus = "Не удалось проверить модели"; self.error = error.localizedDescription }
    }
    private func updateModelsStatus() {
        modelsReady = activeCatalog != nil
        modelsStatus = modelsReady ? "Модели готовы · обработка без интернета" : "Загрузите модели для всех этапов обработки"
    }
    func profilesToInstall(asrID: String, summaryID: String) -> [ModelProfile] {
        guard let catalog else { return [] }
        let asr = catalog.models.first { $0.id == asrID && $0.purpose == .asr }
        let ids = [asr?.tokenizerID ?? "tokenizer", asrID, "diarization", summaryID]
        return ids.compactMap { id in catalog.models.first { $0.id == id && !modelLibrary.isInstalled($0) } }
    }
    private func confirmHardware(_ profiles: [ModelProfile], action: String) -> Bool {
        let warnings = profiles.compactMap { hardware.warning(for: $0) }
        guard !warnings.isEmpty else { return true }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Модель может быть слишком тяжёлой для этого Mac"
        alert.informativeText = hardware.chip + " · \(hardware.cpuCores) ядер CPU\n\n" + warnings.joined(separator: "\n\n")
        alert.addButton(withTitle: action); alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func installModels(_ profiles: [ModelProfile]) {
        guard let repository, let catalog, canManageModels, !profiles.isEmpty,
              confirmHardware(profiles, action: "Всё равно загрузить") else { return }
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
                    updated.installed(profile, catalog: catalog)
                    try updated.save(at: repository.models); modelLibrary = updated
                }
                updateModelsStatus()
            } catch {
                updateModelsStatus()
                if Task.isCancelled { modelsStatus += " · загрузка отменена" }
                else { self.error = error.localizedDescription; modelsStatus += " · загрузка не завершена" }
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
        guard let repository, let catalog, canManageModels, confirmHardware([profile], action: "Всё равно импортировать") else { return }
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
                var updated = modelLibrary; updated.installed(profile, catalog: catalog)
                try updated.save(at: repository.models); modelLibrary = updated; updateModelsStatus()
            } catch {
                updateModelsStatus()
                if !Task.isCancelled { self.error = error.localizedDescription }
                else { modelsStatus += " · импорт отменён" }
            }
        }
    }
    func selectModel(_ profile: ModelProfile) {
        guard let repository, let catalog, canManageModels, !modelLibrary.isSelected(profile),
              confirmHardware([profile], action: "Всё равно выбрать") else { return }
        do {
            var updated = modelLibrary; try updated.select(profile, catalog: catalog)
            try updated.save(at: repository.models); modelLibrary = updated; updateModelsStatus()
        } catch { self.error = error.localizedDescription }
    }
    func removeModel(_ profile: ModelProfile) {
        guard let repository, let catalog, canManageModels else { return }
        let alert = NSAlert(); alert.messageText = "Удалить \(profile.displayName)?"
        alert.informativeText = "Будут удалены только файлы этой модели. Аудио, расшифровки и итоги сохранятся. Если модель выбрана, будет использована последняя установленная из оставшихся моделей того же назначения."
        alert.addButton(withTitle: "Удалить модель"); alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try modelLibrary.remove(profile, at: repository.models, catalog: catalog); updateModelsStatus() }
        catch { self.error = error.localizedDescription; Task { await verifyModels() } }
    }
    func chooseImport() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "MP3, M4A, WAV, FLAC, OGG, OPUS — до 3 часов"
        guard panel.runModal() == .OK else { return }; importURLs(panel.urls)
    }
    func importURLs(_ urls: [URL]) {
        guard !preparingStorage, !shuttingDown, let repository else { return }
        let taskID = UUID()
        importTasks[taskID] = Task {
            defer { importTasks.removeValue(forKey: taskID) }
            for url in urls {
                guard !shuttingDown else { return }
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let tools = self.tools
                do {
                    let manifest = try await Task.detached(priority: .userInitiated) { let info = try Media.probe(url, tools: tools); return try repository.importFile(url, info: info) }.value
                    selection = manifest.id; reload(); enqueue(manifest.id)
                } catch let duplicate as DuplicateRecording {
                    guard !shuttingDown else { return }
                    let alert = NSAlert(); alert.messageText = "Такой файл уже есть в архиве"; alert.addButton(withTitle: "Открыть существующую"); alert.addButton(withTitle: "Импортировать ещё раз"); alert.addButton(withTitle: "Отмена")
                    let answer = alert.runModal()
                    if answer == .alertFirstButtonReturn { selection = duplicate.id }
                    if answer == .alertSecondButtonReturn {
                        do {
                            let manifest = try await Task.detached { let info = try Media.probe(url, tools: tools); return try repository.importFile(url, info: info, allowDuplicate: true) }.value
                            selection = manifest.id; reload(); enqueue(manifest.id)
                        } catch { self.error = error.localizedDescription }
                    }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    func startRecording() async {
        guard recordingID == nil, let repository, !preparingStorage, !stopping, !shuttingDown, !startingRecording, !finalizingRecording, !installing else { return }
        startingRecording = true
        defer { startingRecording = false }
        await pause(reason: "Обработка приостановлена на время записи. Нажмите «Продолжить», когда будет удобно.")
        guard await AVCaptureDevice.requestAccess(for: .audio) else { error = "Доступ к микрофону запрещён. Разрешите LocalScribe доступ в настройках конфиденциальности macOS."; return }
        guard !shuttingDown else { return }
        var m = Manifest(sourceType: "microphone", title: "Запись \(Date().formatted(date: .abbreviated, time: .shortened))", filename: "original.caf")
        m.state = .recording
        do {
            try repository.save(m)
            let capture = MicrophoneRecorder()
            capture.onMeter = { [weak self] level, elapsed, notice in Task { @MainActor in self?.level = level; self?.elapsed = elapsed; self?.soundNotice = notice } }
            capture.onStopNeeded = { [weak self] reason in Task { @MainActor in await self?.stopRecording(warning: reason) } }
            capture.onWarning = { [weak self] warning in
                guard let self, let id = self.recordingID, var m = try? repository.load(id) else { return }
                if !m.warnings.contains(warning) { m.warnings.append(warning); try? repository.save(m); self.reload() }
            }
            try capture.start(folder: repository.folder(m.id).appendingPathComponent("capture"))
            recorder = capture; recordingID = m.id; selection = m.id; elapsed = 0; reload()
        } catch { m.state = .failed; m.lastError = error.localizedDescription; try? repository.save(m); self.error = error.localizedDescription; reload() }
    }
    func stopRecording(warning: String? = nil) async {
        guard let id = recordingID, let repository, !stopping else { return }
        stopping = true; finalizingRecording = true; status = "Сохраняем аудио…"
        defer { stopping = false; finalizingRecording = false; if status == "Сохраняем аудио…" { status = "" } }
        do {
            let frames = try await recorder?.stop() ?? 0; recorder = nil
            if frames == 0 {
                var m = try repository.load(id); m.state = .failed
                m.lastError = warning ?? "Микрофон ещё не передал звук. Начните новую запись."
                try repository.save(m); recordingID = nil; self.error = m.lastError; reload(); return
            }
            if let warning { var m = try repository.load(id); m.warnings.append(warning); try repository.save(m) }
            try await finalizeCapture(id); recordingID = nil; enqueue(id)
        } catch {
            recordingID = nil; recorder = nil; self.error = error.localizedDescription
            if var m = try? repository.load(id) {
                let parts = (try? FileManager.default.contentsOfDirectory(at:repository.folder(id).appendingPathComponent("capture"),includingPropertiesForKeys:nil)) ?? []
                let recoverable = parts.contains { $0.pathExtension == "caf" && !$0.lastPathComponent.contains(".partial.") }
                m.state = recoverable ? .interrupted : .failed
                m.lastError = recoverable ? "Фрагменты сохранены. Нажмите «Продолжить» для сборки." : "Нет сохранённого звука. Начните новую запись."
                try? repository.save(m)
            }
        }
        reload()
    }
    func finalizeCapture(_ id: String) async throws {
        guard let repository, var m = try? repository.load(id) else { return }
        let folder = repository.folder(id), destination = folder.appendingPathComponent(m.originalRelativePath)
        try Disk.directory(destination.deletingLastPathComponent())
        let (frames, rate, hash) = try await Task.detached { () throws -> (Int64, Double, String) in
            let result = try Media.assembleCapture(folder.appendingPathComponent("capture"), destination: destination)
            return (result.0, result.1, try Disk.hash(destination))
        }.value
        // The title may have changed while the audio was being assembled.
        m = try repository.load(id)
        m.durationMs = Int(Double(frames)/rate*1000); m.sampleRate = rate; m.channels = 1; m.sha256 = hash; m.sourceComplete = true; m.state = .recorded
        try repository.save(m)
        // Finalized fragments are removed only after the original and manifest have been validated.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("capture"))
    }
    func resume(_ id: String) {
        guard !preparingStorage, !shuttingDown, !finalizingRecording else { return }
        finalizingRecording = true
        Task {
            defer { finalizingRecording = false }
            do {
                if let repository, var m = try? repository.load(id), !m.sourceComplete {
                    let parts = (try? FileManager.default.contentsOfDirectory(at:repository.folder(id).appendingPathComponent("capture"),includingPropertiesForKeys:nil)) ?? []
                    guard parts.contains(where:{ $0.pathExtension == "caf" && !$0.lastPathComponent.contains(".partial.") }) else {
                        m.state = .failed; m.lastError = "В этой записи нет сохранённого звука. Начните новую запись."
                        try repository.save(m); reload(); self.error = m.lastError; return
                    }
                    try await finalizeCapture(id)
                }
                enqueue(id)
            } catch { self.error = error.localizedDescription }
        }
    }
    func repeatAnalysis(summaryOnly: Bool, language: String? = nil) {
        guard let repository, let catalog = activeCatalog, var m = selected, canManageModels, modelsReady else { return }
        do { _ = try repository.beginRun(&m, catalog: catalog, summaryLanguage: language, summaryOnly: summaryOnly); reload(); enqueue(m.id) }
        catch { self.error = error.localizedDescription }
    }
    func enqueue(_ id: String) {
        guard let repository, var m = try? repository.load(id), m.sourceComplete, id != activeID else { return }
        if shuttingDown { m.state = .interrupted; m.lastError = "Приложение закрыто. Можно продолжить обработку."; try? repository.save(m); reload(); return }
        m.state = modelsReady ? .queued : .waitingForModels; m.lastError = nil; try? repository.save(m)
        if modelsReady, !queued.contains(id) { queued.append(id) }
        reload(); if !busy, recordingID == nil { Task { await processQueue() } }
    }
    private func processQueue() async {
        guard !preparingStorage, !busy, !installing, !verifyingModels, !startingRecording, !shuttingDown, recordingID == nil, modelsReady, let repository, let catalog = activeCatalog else { return }
        busy = true; defer { busy = false; activeID = nil; status = ""; reload() }
        while !queued.isEmpty && recordingID == nil && modelsReady {
            if ProcessInfo.processInfo.thermalState == .critical { error = "Mac перегрет. Обработку можно продолжить после охлаждения."; break }
            let id = queued.removeFirst(); activeID = id
            do {
                var m = try repository.load(id)
                var info: RunInfo?
                if let pending = m.pendingRunId { info = try? Disk.read(RunInfo.self, at: repository.run(id,pending).appendingPathComponent("run.json")) }
                if info?.sourceHash != m.sha256 || info?.profileHash != catalog.fingerprint || info?.pipelineVersion != RunInfo(sourceHash: "", profileHash: "").pipelineVersion {
                    info = try repository.beginRun(&m, catalog: catalog)
                }
                guard let info else { throw ScribeError.message("Не удалось создать задание") }
                let run = repository.run(id,info.id)
                let stages: [Stage] = [.preparingAudio,.transcribing,.diarizing,.summarizing]
                for stage in stages {
                    if activeID != id { throw CancellationError() }
                    // Summary-only runs do not require a WAV when their transcript checkpoint is valid.
                    if stage == .preparingAudio, let t = try? Disk.read(Transcript.self, at: run.appendingPathComponent("transcript.json")), t.fingerprint == info.fingerprint { continue }
                    if try stageComplete(stage, run: run, manifest: m, info: info) { continue }
                    m = try repository.load(id); m.state = JobState(rawValue: stage.rawValue)!; try repository.save(m); reload()
                    let command = WorkerCommand(jobId: id, runId: info.id, stage: stage, recordingPath: repository.folder(id).path, modelsPath: repository.models.path, toolsPath: tools.path)
                    try await supervisor.run(command, executable: worker) { event in
                        if event.type == "progress" { self.status = event.message }
                        if event.type == "checkpoint", event.artifact?.hasPrefix("asr/") == true { self.resultSignature = ""; self.loadResult() }
                        if event.type == "warning", var current = try? repository.load(id) { if !current.warnings.contains(event.message) { current.warnings.append(event.message) }; try? repository.save(current) }
                    }
                    guard try stageComplete(stage, run: run, manifest: m, info: info) else { throw ScribeError.message("Worker не создал проверяемый результат этапа") }
                    reload()
                }
                m = try repository.load(id)
                m.activeRunId = info.id; m.pendingRunId = nil; m.state = m.warnings.isEmpty ? .completed : .completedWithWarnings; m.lastError = nil
                try repository.save(m)
            } catch {
                if var m = try? repository.load(id) {
                    if m.state.processing { m.state = activeID == id ? .failed : .interrupted; m.lastError = (error as? ScribeError)?.localizedDescription ?? "Обработка прервана. Готовые результаты и контрольные точки сохранены."; try? repository.save(m) }
                }
            }
            await Task.detached(priority: .utility) { try? repository.cleanupTemporaryFiles(id) }.value
            activeID = nil; reload()
        }
    }
    private func stageComplete(_ stage: Stage, run: URL, manifest: Manifest, info: RunInfo) throws -> Bool {
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
        if let repository {
            for id in queued {
                if var m = try? repository.load(id) { m.state = .interrupted; m.lastError = reason; try? repository.save(m) }
            }
        }
        queued.removeAll()
        guard let id = activeID else { reload(); return }
        activeID = nil
        if let repository, var m = try? repository.load(id) { m.state = .interrupted; m.lastError = reason; try? repository.save(m) }
        await supervisor.cancel()
        while busy { try? await Task.sleep(for: .milliseconds(50)) }
        reload()
    }
    func cancelSelected() async {
        guard let id = selection, let repository else { return }
        queued.removeAll { $0 == id }
        if activeID == id {
            let waiting = queued
            await pause(reason: "Обработка отменена пользователем")
            for other in waiting { enqueue(other) }
        }
        if var m = try? repository.load(id) { m.state = .cancelled; try? repository.save(m) }; reload()
    }
    func deleteSelected() async {
        guard let selected, let repository, selected.id != recordingID, !finalizingRecording else { return }
        let alert = NSAlert(); alert.messageText = "Удалить запись и результаты?"; alert.informativeText = "Будут удалены только копия аудио и результаты в LocalScribe. Внешний оригинал и ваши экспорты сохранятся."
        alert.addButton(withTitle: "Удалить запись"); alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await cancelSelected()
        do { try repository.delete(selected); selection = nil; reload() } catch { self.error = error.localizedDescription }
    }
    func showAudio() { guard let selected, let repository else { return }; NSWorkspace.shared.activateFileViewerSelecting([repository.folder(selected.id).appendingPathComponent(selected.originalRelativePath)]) }
    func rendered(_ part: ExportPart, markdown: Bool = false) -> String {
        guard let selected else { return "" }; return ExportService.render(manifest: selected, transcript: transcript, summary: summary, part: part, markdown: markdown)
    }
    func copy(_ part: ExportPart) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rendered(part), forType: .string); status = "Скопировано" }
    func export(markdown: Bool, part: ExportPart) {
        guard let selected else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = selected.displayTitle.replacingOccurrences(of: "/", with: "-") + (markdown ? ".md" : ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try rendered(part, markdown: markdown).write(to: url, atomically: true, encoding: .utf8) } catch { self.error = "Не удалось экспортировать: \(error.localizedDescription)" }
    }
    func shutdown() async {
        shuttingDown = true
        memorySource?.cancel(); memorySource = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }; sleepObserver = nil
        installTask?.cancel(); downloader.close()
        if recordingID != nil { await stopRecording() }
        while finalizingRecording { try? await Task.sleep(for:.milliseconds(50)) }
        await pause(reason:"Приложение закрыто. Можно продолжить обработку."); supervisor.terminateNow()
        await installTask?.value
        for task in Array(importTasks.values) { await task.value }
    }
    /// Explicit developer mode: short real input test, no models/archive, audio deleted.
    private func microphoneSelfCheck() async {
        guard let repository else { return }
        let base = repository.root.appendingPathComponent("diagnostics")
        let temporary = base.appendingPathComponent("microphone-\(UUID().uuidString)")
        let captureFolder = temporary.appendingPathComponent("capture")
        let reportURL = base.appendingPathComponent("microphone-probe-result.json")
        defer { try? FileManager.default.removeItem(at:temporary) }
        var report = ["status":"running","phase":"permission","version":"0.1.1"]
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
            report = ["status":"passed","version":"0.1.1","frames":String(frames),"sampleRate":String(rate),"seconds":String(Double(frames)/rate),"completedParts":String(parts.count),"configurationEvents":String(capture.configurationEventCount),"engineRestarts":String(capture.engineRestartCount),"meterSeconds":String(lastElapsed),"injectedEvents":String(inject),"audio":"deleted; no archive or models"]
        } catch {
            _ = try? await capture.stop()
            report = ["status":"failed","version":"0.1.1","error":error.localizedDescription,"configurationEvents":String(capture.configurationEventCount),"engineRestarts":String(capture.engineRestartCount),"audio":"deleted; no archive or models"]
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
            try Disk.write(["status":"passed","events":events.joined(separator:","),"version":"0.1.0","check":"signed parent -> inherited network-denied worker -> bundled ffmpeg; XPC downloader file descriptor"], to: diagnostics.appendingPathComponent("sandbox-probe-result.json"))
        } catch {
            try? Disk.write(["status":"failed","error":error.localizedDescription,"events":events.joined(separator:",")], to: diagnostics.appendingPathComponent("sandbox-probe-result.json"))
        }
        if let testModels { try? FileManager.default.removeItem(at:testModels) }
        NSApplication.shared.terminate(nil)
    }
}
