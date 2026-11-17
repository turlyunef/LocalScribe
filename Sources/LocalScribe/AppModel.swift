import SwiftUI
import AppKit
import AVFoundation
import LocalScribeCore

/// Jobs of all three archives share one FIFO and one worker slot; the kind
/// keeps identical UUIDs in the recording, diagram and text archives from
/// colliding. Cancelling or deleting one kind never touches the others.
enum QueueJobKind: Hashable, Sendable { case recording, diagram, text }
struct QueueJobID: Hashable, Sendable {
    let kind: QueueJobKind
    let id: String
    static func recording(_ id: String) -> QueueJobID { QueueJobID(kind: .recording, id: id) }
    static func diagram(_ id: String) -> QueueJobID { QueueJobID(kind: .diagram, id: id) }
    static func text(_ id: String) -> QueueJobID { QueueJobID(kind: .text, id: id) }
    var isRecording: Bool { kind == .recording }
    var isText: Bool { kind == .text }
    var diagnosticOperation: DiagnosticOperation {
        switch kind {
        case .recording: return .recording
        case .diagram: return .diagram
        case .text: return .anonymization
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var recordingGroups = RecordingGroups()
    let recordingSearch = RecordingSearch()
    private var recordingsByID: [String: Manifest] = [:]
    // Diagram archive state: an independent snapshot pipeline fed by DiagramCoordinator.
    let diagramSearch = RecordingSearch()
    private var diagramsByID: [String: DiagramManifest] = [:]
    @Published private(set) var diagrams: [DiagramManifest] = [] {
        didSet {
            diagramsByID = Dictionary(diagrams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            diagramSearch.update(diagrams.map { RecordingSearch.TitleSearchEntry(id: $0.id, title: $0.displayTitle, date: $0.createdAt) }, groups: diagramGroups)
        }
    }
    @Published private(set) var diagramGroups = RecordingGroups()
    let diagramRepository: DiagramRepository?
    let diagramArchive: DiagramCoordinator?
    private var diagramArchiveRevision: UInt64 = 0
    private var reportedDiagramGroupsError: String?
    private var reportedUnreadableDiagramIDs: [String] = []
    @Published private(set) var deletingDiagramJobs = false
    @Published private(set) var deletingGroupID: String?
    // Text-anonymization archive state (work 5): a third independent snapshot
    // pipeline fed by AnonymizationCoordinator. The coordinator owns the
    // authoritative AnonymizationArchiveCatalog; the GUI works with a bridged
    // RecordingGroups projection so the shared sidebar/search infrastructure
    // is reused without a second stored group source of truth.
    let anonymizationSearch = RecordingSearch()
    private var textCardsByID: [String: AnonymizationCardSummary] = [:]
    @Published private(set) var textCards: [AnonymizationCardSummary] = [] {
        didSet {
            textCardsByID = Dictionary(textCards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // The summary carries no date; the import position is a stable
            // descending order key for the shared title-search engine.
            anonymizationSearch.update(textCards.map {
                RecordingSearch.TitleSearchEntry(id: $0.id, title: $0.displayName,
                                                date: Date(timeIntervalSince1970: TimeInterval($0.importOrder)))
            }, groups: textGroups)
        }
    }
    @Published private(set) var textGroups = RecordingGroups()
    let textRepository: AnonymizationRepository?
    let textArchive: AnonymizationCoordinator?
    private var textArchiveRevision: UInt64 = 0
    private var reportedTextGroupsError: String?
    private var reportedUnreadableTextIDs: [String] = []
    /// True while confirmed text cards (or a group with its files) are being
    /// deleted: the queue admits no new job, so the stopped worker's slot
    /// passes to the deletion before the order of the other jobs resumes.
    @Published private(set) var deletingTextJobs = false
    @Published var sidebarRevealID: String?
    @Published private(set) var sidebarSelection = SidebarSelection()
    @Published private(set) var deletingSidebarRecordings = false
    private var reportedGroupsError: String?
    private var reportedUnreadableRecordingIDs: [String] = []
    private var deletingJobIDs: Set<QueueJobID> = []
    private var jobAdmission: [QueueJobID: UInt64] = [:]
    private var finalizingRecordingID: String?
    private var startingGroupID: String?
    @Published var recordings: [Manifest] = [] {
        didSet {
            recordingsByID = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            recordingSearch.update(recordings, groups: recordingGroups)
            refreshPresentation()
        }
    }
    @Published var selection: String? {
        didSet {
            sidebarSelection = SidebarSelection(selection)
            retainSearchSelection()
            if oldValue != selection {
                playback.select(playbackSource)
                jumpTo = nil; transcript = nil; summary = nil; resultSignature = ""; resultEdit = nil
                if tab == .live { tab = .transcript }
                loadLiveCaptions()
            }
            loadResult()
        }
    }
    @Published var transcript: Transcript? {
        didSet {
            playback.updateTranscript(transcript)
            resultRevision &+= 1
            refreshPresentation()
        }
    }
    @Published var summary: Summary? { didSet { resultRevision &+= 1; refreshPresentation() } }
    @Published var resultEdit: ResultEditDraft?
    @Published private(set) var savingResult = false
    let errorHandler: AppErrorHandler
    private var processingDiagnostic = DiagnosticJob()
    private var diagnosticModes: [QueueJobID: DiagnosticMode] = [:]
    lazy var diagnosticsWindow = DiagnosticsWindow(handler: errorHandler)
    let indicators = ActivityIndicators()
    let resultPresentation = ResultPresentation()
    let playback = RecordingPlayback()
    private var resultRevision: UInt64 = 0
    private(set) var copyTask: Task<Void, Never>?
    private var exportTasks: [UUID: Task<Void, Never>] = [:]
    var status: String { get { indicators.status } set { indicators.status = newValue } }
    private var queueStatus: String?
    private func showQueueStatus(_ message: String) {
        let localized = L10n.message(message)
        queueStatus = localized
        status = localized
    }
    @Published var settingsTab: SettingsTab = .recordings
    lazy var settingsWindow = SettingsWindow(model: self, defaults: userDefaults)
    @Published var modelsStatus = L10n.text("Проверяем модели…")
    @Published var modelsReady = false
    @Published var installing = false
    private(set) var downloadingModels = false
    @Published var verifyingModels = false
    var canStartRecording: Bool {
        repository != nil && archive != nil && resultEdit == nil && !savingResult
            && recordingID == nil && !startingRecording && !stopping && !finalizingRecording
            && !installing && !preparingStorage && !shuttingDown && !suspendingCaptureForSleep
    }
    @Published var modelLibrary = ModelLibrary()
    @Published var downloadProgress: ModelInstallProgress?
    @Published var downloadBatch = ""
    @Published private(set) var anonymizationSettings = AnonymizationSettings()
    @Published private(set) var anonymizationSettingsDamaged = false
    /// Normalized global recognition dictionary shared by WhisperKit and
    /// Qwen3-ASR. Saved once in settings; a run pins its own snapshot.
    @Published private(set) var recognitionDictionary: [String] = []
    @Published private(set) var readyPackageIDs: Set<String> = []
    private var packageReadinessLoaded = false
    let packageRegistry = ModelPackageRegistry()
    private var anonymizationStore: AnonymizationSettingsStore?
    let hardware: ModelHardware
    var canManageModels: Bool { !savingResult && resultEdit == nil && !preparingStorage && !installing && !verifyingModels && !busy && queued.isEmpty && !resourcesPaused && !startingRecording && !finalizingRecording && recordingID == nil && !shuttingDown }
    var activeCatalog: ModelCatalog? {
        guard let catalog, let summary = readyTaskModel(.summary),
              let selected = modelLibrary.activeCatalog(from: catalog, summary: summary),
              selected.models.allSatisfy({ hardware.compatibility(for: $0).isCompatible }) else { return nil }
        return selected
    }

    /// The dictionary hint applies only to WhisperKit and Qwen3-ASR jobs; other
    /// backends never pin it, keeping their run fingerprints unchanged.
    func recognitionTerms(for catalog: ModelCatalog) -> [String]? {
        guard !recognitionDictionary.isEmpty,
              let backend = catalog.models.first(where: { $0.purpose == .asr })?.resolvedASRBackend,
              RecognitionDictionary.supportsHint(backend: backend) else { return nil }
        return recognitionDictionary
    }

    func selectedTaskModel(_ task: ModelTask) -> ModelProfile? {
        guard let profile = assignedTaskModel(task),
              ModelTaskSupport.compatibility(task: task, profile: profile, hardware: hardware).isCompatible else { return nil }
        return profile
    }
    private func assignedTaskModel(_ task: ModelTask) -> ModelProfile? {
        guard let id = effectiveAnonymizationSettings.profileID(for: task) else { return nil }
        return catalog?.models.first { $0.id == id }
    }
    private func readyTaskModel(_ task: ModelTask) -> ModelProfile? {
        guard let profile = selectedTaskModel(task), packageIsReady(profile) else { return nil }
        return profile
    }
    /// Whether the profile's package has a published verified installation
    /// that is not pending a confirmed removal.
    func packageIsReady(_ profile: ModelProfile) -> Bool {
        readyPackageIDs.contains(profile.effectivePackageID) || (!packageReadinessLoaded && modelLibrary.isInstalled(profile))
    }
    private var effectiveAnonymizationSettings: AnonymizationSettings {
        // Native selections are used until settings have been loaded, or if
        // their file is damaged. Installing a model never fills another slot.
        guard !packageReadinessLoaded || anonymizationSettingsDamaged else { return anonymizationSettings }
        var settings = anonymizationSettings
        for task in [ModelTask.summary, .diagramRecognition] where settings.profileID(for: task) == nil {
            guard let role = task.legacyRole else { continue }
            settings.setProfile(modelLibrary.selectedByRole[role.rawValue], for: task)
        }
        return settings
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
    @Published private(set) var automaticLiveCaptions: Bool {
        didSet { userDefaults.set(automaticLiveCaptions, forKey: "automaticLiveCaptions") }
    }
    @Published var automaticSummaries: Bool {
        didSet { userDefaults.set(automaticSummaries, forKey: "automaticSummaries") }
    }
    @Published private(set) var recordingSources: RecordingSourcePreferences
    let microphoneDevices: MicrophoneDevices
    var applicationLanguage: ApplicationLanguage { ApplicationLanguage.selection(in: userDefaults) }
    var applicationTheme: ApplicationTheme { ApplicationTheme.selection(in: userDefaults) }
    private let userDefaults: UserDefaults
    @Published var recordingID: String?
    @Published var startingRecording = false
    @Published var finalizingRecording = false
    var elapsed: Double { get { indicators.elapsed } set { indicators.elapsed = newValue } }
    var level: Double { get { indicators.level } set { indicators.level = newValue } }
    var soundNotice: String? { get { indicators.soundNotice } set { indicators.soundNotice = newValue } }
    @Published var busy = false {
        didSet {
            if !busy {
                let waiters = queueIdleWaiters
                queueIdleWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
    }
    private var queueIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private func waitUntilQueueIdle() async {
        guard busy else { return }
        await withCheckedContinuation { queueIdleWaiters.append($0) }
    }
    @Published var shuttingDown = false
    @Published private(set) var preparingStorage = true
    @Published var tab: RecordingResultTab = .transcript { didSet { refreshPresentation() } }
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
    private var recorder: (any RecordingCapture)?
    private var startingRecordingID: String?
    private var recordingStartTask: Task<Void, Never>?
    private var openingCapture = false
    @Published private var suspendingCaptureForSleep = false
    private var startInterruption: String?
    private var startupStopReason: String?
    private var pendingCaptureWarnings: [String] = []
    private var liveCaptureStart: Task<Void, Never>?
    @Published private(set) var captureCaptions: RecordingLiveCaptions?
    @Published private(set) var liveCaptionLanguage: LiveCaptionLanguage
    @Published private var archivedCaptions: RecordingLiveCaptions?
    private var captionsLoadTask: Task<Void, Never>?
    private var captionsSwitchTask: Task<Void, Never>?
    private var captionsOverrideID: String?
    private let recognizeLiveCaptions: LiveCaptionRecognition.Recognizer
    private let recognizeMixedLiveCaptions: LiveCaptionRecognition.Session
    private let requestMicrophoneAccess: @MainActor () async -> Bool
    private let makeRecordingCapture: @MainActor (MicrophoneDevices) -> any RecordingCapture
    @Published private var queued: [QueueJobID] = []
    private var enqueuing: [QueueJobID: UUID] = [:]
    private var queueGeneration: UInt64 = 0
    private var activeJob: QueueJobID?
    // Unlike activeJob, this survives cancellation/resource pause until every
    // worker reader and the queue's file cleanup have finished.
    private var processingJob: QueueJobID?
    private var stopping = false
    private var resourcesPaused = false
    private var memoryLimited = false
    private var captureLimited = false
    @Published private(set) var resourcePauseTitle: String?
    @Published private(set) var resourcePauseMessage: String?
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
    var resolveDuplicateImport: (DuplicateRecording) -> DuplicateImportAction = { _ in AppModel.presentDuplicateImportAlert() }

    static func presentDuplicateImportAlert() -> DuplicateImportAction {
        let alert = NSAlert(); alert.messageText = L10n.text("Такой файл уже есть в архиве")
        alert.addButton(withTitle: L10n.text("Открыть существующую")); alert.addButton(withTitle: L10n.text("Импортировать ещё раз")); alert.addButton(withTitle: L10n.text("Отмена"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .openExisting
        case .alertSecondButtonReturn: return .importAgain
        default: return .cancel
        }
    }
    private var resultSignature = ""
    private var resultLoadID = UUID()
    var selected: Manifest? { selection.flatMap { recordingsByID[$0] } }
    var selectedCaptions: RecordingLiveCaptions? {
        if let captureCaptions, captureCaptions.recordingID == selection { return captureCaptions }
        return archivedCaptions?.recordingID == selection ? archivedCaptions : nil
    }
    var resultTabs: [RecordingResultTab] {
        var tabs: [RecordingResultTab] = [.transcript, .summary]
        if selectedCaptions != nil { tabs.append(.live) }
        if selected?.warnings.isEmpty == false { tabs.append(.warnings) }
        return tabs
    }
    var exportParts: [ExportPart] { resultTabs.compactMap(\.exportPart) + [.all] }
    var tools: URL { resources.appendingPathComponent("tools") }
    var worker: URL { workerOverride ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalScribeWorker") }
    init(repository providedRepository: RecordingRepository? = nil, startServices: Bool = true, workerExecutable: URL? = nil,
         userDefaults: UserDefaults = .standard, catalog providedCatalog: ModelCatalog? = nil, hardware: ModelHardware = .current,
         microphoneDevices suppliedMicrophoneDevices: MicrophoneDevices? = nil,
         requestMicrophoneAccess: @escaping @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) },
         makeRecordingCapture: @escaping @MainActor (MicrophoneDevices) -> any RecordingCapture = { MicrophoneRecorder(devices: $0) },
         recognizeLiveCaptions: @escaping LiveCaptionRecognition.Recognizer = LiveCaptionRecognition.recognize,
         recognizeMixedLiveCaptions: @escaping LiveCaptionRecognition.Session = LiveCaptionRecognition.recognizeMixed,
         importProbe: @escaping @Sendable (URL, URL) throws -> AudioInfo = { try Media.probe($0, tools: $1, cancellable: true) }) {
        self.userDefaults = userDefaults
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.makeRecordingCapture = makeRecordingCapture
        self.recognizeLiveCaptions = recognizeLiveCaptions
        self.recognizeMixedLiveCaptions = recognizeMixedLiveCaptions
        self.hardware = hardware
        errorHandler = AppErrorHandler(hardware: hardware)
        let automaticLiveCaptions = userDefaults.bool(forKey: "automaticLiveCaptions")
        self.automaticLiveCaptions = automaticLiveCaptions
        liveCaptionLanguage = userDefaults.string(forKey: "liveCaptionLanguage")
            .flatMap(LiveCaptionLanguage.init(rawValue:)) ?? .interfaceLanguage
        backgroundRecognition = !automaticLiveCaptions && (userDefaults.object(forKey: "backgroundRecognition") as? Bool ?? true)
        automaticSummaries = userDefaults.object(forKey: "automaticSummaries") as? Bool ?? true
        recognitionDictionary = (userDefaults.stringArray(forKey: "recognitionDictionary") ?? []).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        recordingSources = RecordingSourcePreferences(defaults: userDefaults)
        microphoneDevices = suppliedMicrophoneDevices ?? MicrophoneDevices(observeChanges: startServices)
        workerOverride = workerExecutable
        let bundled = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        resources = FileManager.default.fileExists(atPath: bundled.appendingPathComponent("models.lock.json").path) ? bundled : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
        catalog = providedCatalog ?? (try? Disk.read(ModelCatalog.self, at: resources.appendingPathComponent("models.lock.json")))
        let diagnosticRoot = providedRepository?.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("LocalScribe", isDirectory: true)
        errorHandler.startJournal(at: diagnosticRoot)
        do { let repo = try providedRepository ?? RecordingRepository(); repository = repo; archive = RecordingCoordinator(repository: repo, importProbe: importProbe) }
        catch {
            repository = nil; archive = nil
            errorHandler.report(error, operation: .archive,
                                failure: DiagnosticFailure(.storageUnavailable, phase: .sourceOpen, error: error))
        }
        // The diagram archive is a sibling branch of the same Application Support
        // root; its failure never blocks the recording workspace.
        if let repository {
            do {
                let repo = try DiagramRepository(root: repository.root.appendingPathComponent("diagrams"))
                diagramRepository = repo; diagramArchive = DiagramCoordinator(repository: repo)
            } catch {
                diagramRepository = nil; diagramArchive = nil
                errorHandler.report(message: L10n.text("Хранилище схем недоступно: %1$@. Записи продолжают работать.", L10n.message(error.localizedDescription)))
            }
        } else { diagramRepository = nil; diagramArchive = nil }
        // The text-anonymization archive is a sibling branch of the same root
        // (the "texts" folder opened by AnonymizationBootstrap); its failure
        // never blocks the recording or diagram workspaces.
        if let repository {
            do {
                let repo = try AnonymizationRepository(root: repository.root.appendingPathComponent("texts"))
                textRepository = repo; textArchive = AnonymizationCoordinator(repository: repo)
            } catch {
                textRepository = nil; textArchive = nil
                errorHandler.report(message: L10n.text("Хранилище текстов недоступно: %1$@. Записи продолжают работать.", L10n.message(error.localizedDescription)))
            }
        } else { textRepository = nil; textArchive = nil }
        if let repository { anonymizationStore = AnonymizationSettingsStore(root: repository.root) }
        recordingSearch.onVisibilityChange = { [weak self] in self?.retainSearchSelection() }
        if !startServices { preparingStorage = false; Task { await reload(); await reloadDiagrams(); await reloadTexts() }; return }
        memorySource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        memorySource?.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.memorySource?.data.intersection([.warning, .critical]).isEmpty == true {
                    self.errorHandler.note(.memoryNormal)
                    self.resumeAfterMemoryPressure()
                } else {
                    self.errorHandler.note(self.memorySource?.data.contains(.critical) == true ? .memoryCritical : .memoryWarning)
                    self.pauseForCaptureResources(memoryPressure: true)
                }
            }
        }
        memorySource?.resume()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.prepareForSleep()
            }
        }
        Task {
            status = L10n.message("Восстанавливаем локальное хранилище…")
            if let archive {
                do { applySnapshot(try await archive.recover()) }
                catch {
                    errorHandler.report(message: L10n.text("Не удалось восстановить локальное хранилище: %1$@", L10n.message(error.localizedDescription)))
                    await reload()
                }
            }
            if let diagramArchive {
                // Leftover queued/recognizing runs become «Прервана»; the
                // recording archive recovery above is independent.
                do { applyDiagramSnapshot(try await diagramArchive.recover()) }
                catch {
                    errorHandler.report(message: L10n.text("Не удалось восстановить хранилище схем: %1$@. Записи продолжают работать.", L10n.message(error.localizedDescription)))
                    await reloadDiagrams()
                }
            }
            if let textArchive {
                // Recovery resolves import/deletion journals and interrupts
                // leftover queued/running attempts of text cards.
                do { applyTextSnapshot(try await textArchive.recover()) }
                catch {
                    errorHandler.report(message: L10n.text("Не удалось восстановить хранилище текстов: %1$@. Записи продолжают работать.", L10n.message(error.localizedDescription)))
                    await reloadTexts()
                }
            }
            preparingStorage = false
            if status == L10n.message("Восстанавливаем локальное хранилище…") { status = "" }
            await verifyModels(verifyContents: false)
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
            recordingGroups = snapshot.groups
            recordings = snapshot.manifests
            if let captureCaptions, recordingID != captureCaptions.recordingID,
               recordingsByID[captureCaptions.recordingID] == nil { self.captureCaptions = nil }
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
        guard let part = tab.exportPart else { return }
        resultPresentation.update(manifest: selected, transcript: transcript, summary: summary, revision: resultRevision, part: part)
    }

    private func loadLiveCaptions() {
        captionsLoadTask?.cancel()
        archivedCaptions = nil
        guard let id = selection, let archive, captureCaptions?.recordingID != id else { return }
        captionsLoadTask = Task {
            do {
                let phrases = try await archive.perform {
                    try Task.checkCancellation()
                    return try $0.liveCaptions(id)
                }
                guard !Task.isCancelled, selection == id, let phrases else { return }
                archivedCaptions = RecordingLiveCaptions(recordingID: id, archive: archive, phrases: phrases)
            } catch {
                guard !Task.isCancelled, selection == id, selected != nil else { return }
                errorHandler.report(message: L10n.text("Не удалось открыть предрасшифровку."))
            }
        }
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
        guard !deletingJobIDs.contains(.recording(selected.id)) else { return }
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
        status = L10n.message("Изменения сохранены")
    }
    func verifyModels(verifyContents: Bool = true) async {
        guard let catalog, let repository, canManageModels else { return }
        verifyingModels = true
        modelsStatus = verifyContents ? L10n.text("Проверяем целостность моделей…") : L10n.text("Проверяем модели…")
        defer { verifyingModels = false; if !queued.isEmpty { Task { await processQueue() } } }
        do {
            let hardware = hardware
            modelLibrary = try await Task.detached(priority: .utility) {
                try ModelLibrary.load(at: repository.models, catalog: catalog, hardware: hardware,
                                      verifyContents: verifyContents)
            }.value
            await reloadAnonymizationState()
            updateModelsStatus()
        } catch {
            modelsReady = false
            modelsStatus = L10n.text("Не удалось проверить модели")
            errorHandler.report(error, operation: .modelVerification,
                                failure: DiagnosticFailure(.modelValidation, phase: .modelValidation, error: error))
        }
    }

    /// Load or migrate the anonymization settings record (first open copies the
    /// previous summary and diagram selections) and refresh the package
    /// readiness snapshot from the freshly verified library. File reads happen
    /// off the main actor; a damaged record is reported and never replaced.
    func reloadAnonymizationState() async {
        guard let repository else { return }
        let store = anonymizationStore ?? AnonymizationSettingsStore(root: repository.root)
        anonymizationStore = store
        let catalog = catalog ?? ModelCatalog(models: [])
        let library = modelLibrary
        // ModelLibrary has already verified each installed folder.
        var verified: [String: ModelPackageInstallation] = [:]
        for profile in catalog.models where library.isInstalled(profile) {
            let packageID = profile.effectivePackageID
            if verified[packageID] == nil {
                verified[packageID] = ModelPackageInstallation(packageID: packageID, installedProfileID: profile.id)
            }
        }
        await packageRegistry.replaceInstallations(verified)
        packageReadinessLoaded = true
        readyPackageIDs = await packageRegistry.readyPackageIDs()
        do {
            let settings = try await Task.detached(priority: .utility) {
                try store.loadOrMigrate(catalog: catalog, library: library)
            }.value
            anonymizationSettings = settings
            anonymizationSettingsDamaged = false
            // A readiness change wakes the waiting cards of the text archive
            // only: settings changes never start pending recordings (AC-30).
            await wakeWaitingTextCards()
        } catch {
            anonymizationSettingsDamaged = true
            errorHandler.report(error)
        }
    }
    private func updateModelsStatus() {
        modelsReady = activeCatalog != nil
        var incompatible = catalog?.models.filter {
            $0.purpose != .diagram && $0.purpose != .summary && modelLibrary.isSelected($0)
        }.compactMap { hardware.warning(for: $0) } ?? []
        if let summary = assignedTaskModel(.summary),
           let reason = ModelTaskSupport.compatibility(task: .summary, profile: summary, hardware: hardware).explanation {
            incompatible.append(L10n.message(reason))
        }
        modelsStatus = !incompatible.isEmpty ? L10n.text("Выберите совместимую модель. ") + incompatible.joined(separator: " ") :
            (modelsReady ? L10n.text("Модели готовы · обработка без интернета") : L10n.text("Загрузите модели для всех этапов обработки"))
    }
    func profilesToInstall(asrID: String, summaryID: String) -> [ModelProfile] {
        guard let summary = catalog?.models.first(where: { $0.id == summaryID }),
              ModelTaskSupport.compatibility(task: .summary, profile: summary, hardware: hardware).isCompatible else { return [] }
        return audioStackToInstall(asrID: asrID) + (packageIsReady(summary) ? [] : [summary])
    }
    func audioStackToInstall(asrID: String) -> [ModelProfile] {
        guard let catalog,
              let asr = catalog.models.first(where: { $0.id == asrID && $0.purpose == .asr }),
              let tokenizer = catalog.models.first(where: { $0.id == (asr.tokenizerID ?? "tokenizer") && $0.purpose == .tokenizer }),
              let diarization = catalog.models.first(where: { $0.id == "diarization" && $0.purpose == .diarization }) else { return [] }
        var stack = [tokenizer, asr, diarization]
        if let id = asr.alignerID {
            guard let aligner = catalog.models.first(where: { $0.id == id && $0.purpose == nil }) else { return [] }
            stack.insert(aligner, at: 1)
        }
        guard stack.allSatisfy({ hardware.compatibility(for: $0).isCompatible }) else { return [] }
        return stack.filter { !modelLibrary.isInstalled($0) }
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
        downloadingModels = true; installing = true; downloadProgress = nil
        installTask = Task {
            defer {
                downloadingModels = false; installing = false; installTask = nil; downloadProgress = nil; downloadBatch = ""; downloader.close()
                Task { await processQueue() }
            }
            errorHandler.note(.downloadStarted, operation: .modelDownload)
            do {
                for (index, profile) in profiles.enumerated() {
                    try Task.checkCancellation()
                    let installed = profile.effectiveSupportedTasks.isEmpty ? modelLibrary.isInstalled(profile) : packageIsReady(profile)
                    guard !installed else { continue }
                    downloadBatch = L10n.text("Модель %1$@ из %2$@ · %3$@", String(index + 1), String(profiles.count), profile.displayName)
                    downloadProgress = ModelInstallProgress(profile: profile)
                    try await installer.install(profile, root: repository.models, fetch: { index, progress in
                        try await self.downloader.fetch(profileID: profile.id, index: index, progress: progress)
                    }) { progress in Task { @MainActor in self.receiveProgress(progress) } }
                    downloader.releaseDownload()
                    // Publish only after every file passed its size and SHA-256 checks.
                    var updated = modelLibrary
                    updated.installed(profile, catalog: catalog, hardware: hardware)
                    try updated.save(at: repository.models); modelLibrary = updated
                    await noteInstalled(profile)
                }
                updateModelsStatus()
            } catch {
                updateModelsStatus()
                if Task.isCancelled { modelsStatus += L10n.text(" · загрузка отменена") }
                else { errorHandler.report(error, operation: .modelDownload); modelsStatus += L10n.text(" · загрузка не завершена") }
            }
        }
    }

    func noteInstalled(_ profile: ModelProfile) async {
        await packageRegistry.publishInstallation(packageID: profile.effectivePackageID, profileID: profile.id)
        readyPackageIDs = await packageRegistry.readyPackageIDs()
        // A finished installation can make the waiting text cards admissible.
        await wakeWaitingTextCards()
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
        case .checking: modelsStatus = L10n.text("Проверяем файлы модели…")
        case .downloading: modelsStatus = L10n.text("Загружаем файлы модели…")
        case .verifying: modelsStatus = L10n.text("Проверяем размер и SHA-256…")
        case .complete: modelsStatus = L10n.text("Модель загружена и проверена")
        }
    }
    func cancelInstall() { installTask?.cancel(); downloader.cancel() }
    func importModel(_ profile: ModelProfile) {
        guard let repository, let catalog, canManageModels, let profile = compatibleProfiles([profile])?.first else { return }
        if !profile.effectiveSupportedTasks.isEmpty, packageIsReady(profile) { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = L10n.text("Выберите папку модели %1$@ из закреплённого каталога", profile.displayName)
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
                try updated.save(at: repository.models); modelLibrary = updated
                await noteInstalled(profile)
                updateModelsStatus()
            } catch {
                updateModelsStatus()
                if !Task.isCancelled { errorHandler.report(error, operation: .modelImport) }
                else { modelsStatus += L10n.text(" · импорт отменён") }
            }
        }
    }
    func selectModel(_ profile: ModelProfile) async {
        guard canManageModels,
              let profile = compatibleProfiles([profile])?.first else { return }
        do {
            let draft = SettingsDraft(model: self)
            switch profile.purpose {
            case .summary: draft.summaryModelID = profile.id
            case .diagram: draft.diagramModelID = profile.id
            case let role?: draft.modelIDs[role] = profile.id
            case nil: return
            }
            try await draft.validateRecognitionDictionary(using: self)
            try applySettings(draft)
        }
        catch { errorHandler.report(error) }
    }
    func applySettings(_ draft: SettingsDraft) throws {
        var settings = anonymizationSettings
        try settings.applyDataTypes(draft.dataTypesLines)
        let dictionary = try RecognitionDictionary.normalize(draft.recognitionDictionaryLines)
        if let check = whisperDictionaryValidation(for: draft, terms: dictionary), draft.validatedDictionary != check {
            throw ScribeError.message("Словарь изменился. Сохраните настройки ещё раз.")
        }
        let taskChanges = draft.taskModelChanges(from: self)
        let libraryChanges = draft.changedModels(in: modelLibrary)
        if !taskChanges.isEmpty || !libraryChanges.isEmpty {
            guard canManageModels else {
                throw ScribeError.message("Выбор моделей можно сохранить после завершения записи и обработки.")
            }
        }
        for (task, id) in taskChanges {
            guard let profile = catalog?.models.first(where: { $0.id == id }) else {
                throw ScribeError.message("Модель отсутствует в закреплённом каталоге")
            }
            let compatibility = ModelTaskSupport.compatibility(task: task, profile: profile, hardware: hardware)
            if let explanation = compatibility.explanation { throw ScribeError.message(explanation) }
            settings.setProfile(id, for: task)
        }
        let updatedLibrary = try libraryChanges.isEmpty ? nil : librarySelecting(libraryChanges)
        let settingsChanged = settings != anonymizationSettings
        let store = settingsChanged ? try writableAnonymizationStore() : nil
        if let updatedLibrary, let repository {
            try updatedLibrary.save(at: repository.models)
        }
        if let store {
            do { try store.save(settings) }
            catch {
                if updatedLibrary != nil, let repository {
                    do { try modelLibrary.save(at: repository.models) }
                    catch { errorHandler.report(error) }
                }
                throw error
            }
            anonymizationSettings = settings
            Task { await wakeWaitingTextCards() }
        }
        if let updatedLibrary { modelLibrary = updatedLibrary }
        if settingsChanged || updatedLibrary != nil { updateModelsStatus() }
        if dictionary != recognitionDictionary {
            userDefaults.set(dictionary, forKey: "recognitionDictionary")
            recognitionDictionary = dictionary
        }
        if backgroundRecognition != draft.backgroundRecognition { backgroundRecognition = draft.backgroundRecognition }
        if automaticLiveCaptions != draft.automaticLiveCaptions { automaticLiveCaptions = draft.automaticLiveCaptions }
        if automaticSummaries != draft.automaticSummaries { automaticSummaries = draft.automaticSummaries }
        setRecordingSources(draft.recordingSources)
        if applicationLanguage != draft.applicationLanguage {
            userDefaults.set(draft.applicationLanguage.rawValue, forKey: ApplicationLanguage.defaultsKey)
        }
        if applicationTheme != draft.applicationTheme {
            userDefaults.set(draft.applicationTheme.rawValue, forKey: ApplicationTheme.defaultsKey)
            draft.applicationTheme.apply()
        }
    }

    func whisperDictionaryValidation(for draft: SettingsDraft, terms: [String]) -> WhisperDictionaryValidation? {
        let selected = modelLibrary.selectedByRole
        let asrID = draft.modelIDs[.asr] ?? selected[ModelRole.asr.rawValue] ?? initialModelID(for: .asr)
        let tokenizerID = draft.modelIDs[.tokenizer] ?? selected[ModelRole.tokenizer.rawValue]
        guard terms != recognitionDictionary || draft.modelIDs[.asr] != nil || draft.modelIDs[.tokenizer] != nil else { return nil }
        return whisperDictionaryValidation(asrID: asrID, terms: terms, tokenizerID: tokenizerID)
    }

    func whisperDictionaryValidation(asrID: String, terms: [String], tokenizerID: String? = nil) -> WhisperDictionaryValidation? {
        guard !terms.isEmpty, let repository, let catalog,
              let asr = catalog.models.first(where: { $0.id == asrID && $0.purpose == .asr }),
              asr.resolvedASRBackend == "whisper",
              let profile = catalog.models.first(where: { $0.id == (asr.tokenizerID ?? tokenizerID ?? "tokenizer") && $0.purpose == .tokenizer }),
              modelLibrary.isInstalled(profile),
              Set(profile.files.map(\.localPath)).isSuperset(of: ["tokenizer.json", "tokenizer_config.json"]) else { return nil }
        return WhisperDictionaryValidation(models: repository.models, profile: profile, terms: terms)
    }

    func setRecordingSources(_ preferences: RecordingSourcePreferences) {
        guard preferences != recordingSources else { return }
        preferences.save(to: userDefaults)
        recordingSources = preferences
    }

    private func writableAnonymizationStore() throws -> AnonymizationSettingsStore {
        guard !preparingStorage, !verifyingModels else {
            throw ScribeError.message("Дождитесь завершения проверки моделей.")
        }
        guard let store = anonymizationStore else { throw ScribeError.message("Настройки обезличивания недоступны") }
        guard !anonymizationSettingsDamaged else { throw ScribeError.message("Повреждённая запись настроек обезличивания") }
        return store
    }
    private func librarySelecting(_ changes: [ModelRole: String]) throws -> ModelLibrary {
        guard repository != nil, let catalog else {
            throw ScribeError.message("Выбор моделей можно сохранить после завершения записи и обработки.")
        }
        var updated = modelLibrary
        for (role, id) in changes {
            guard let profile = catalog.models.first(where: { $0.id == id && $0.purpose == role }) else {
                throw ScribeError.message("Модель отсутствует в закреплённом каталоге")
            }
            try updated.select(profile, catalog: catalog, hardware: hardware)
        }
        return updated
    }
    /// The confirmation dialog of a package removal (test seam through
    /// `presentRemovalDialog`). The body lists every tab whose assignment
    /// references the package; `listChanged` marks a re-confirmation shown
    /// after the affected list changed.
    struct ModelRemovalConfirmation {
        let title: String
        let body: String
        let confirmButton: String
        let cancelButton: String
    }
    /// Presented synchronously; tests override this seam.
    var presentRemovalDialog: (ModelRemovalConfirmation) -> Bool = { AppModel.runRemovalAlert($0) }

    private static func runRemovalAlert(_ confirmation: ModelRemovalConfirmation) -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.body
        alert.addButton(withTitle: confirmation.confirmButton)
        alert.addButton(withTitle: confirmation.cancelButton)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The dialog text of one package removal plan.
    static func removalConfirmation(profile: ModelProfile, plan: ModelPackageRemovalPlan, listChanged: Bool) -> ModelRemovalConfirmation {
        var body = L10n.text("Будут удалены файлы модели. Аудио, расшифровки, итоги и схемы сохранятся.")
        if plan.affectsAnything {
            let tabs = ModelTask.allCases.filter { plan.affectedTasks.contains($0) }.map(\.title).joined(separator: ", ")
            body += "\n\n" + L10n.text("Модель используется для следующих задач: %1$@. После удаления новые задания будут ждать её установки.", tabs)
        }
        if listChanged {
            body += "\n\n" + L10n.text("Состав затронутых вкладок изменился. Подтвердите актуальный список.")
        }
        return ModelRemovalConfirmation(title: L10n.text("Удалить модель %1$@?", profile.displayName),
                                        body: body,
                                        confirmButton: L10n.text("Удалить модель"),
                                        cancelButton: L10n.text("Отмена"))
    }

    /// Package-aware removal: the physical installation is shared by every
    /// member profile of the package, and the confirmation lists all tabs whose
    /// assignment references it. A list that changed before the confirmation is
    /// re-confirmed with the current tabs. Cancellation keeps the installation
    /// and the assignments.
    func removeModel(_ profile: ModelProfile) {
        guard let repository, let catalog, canManageModels else { return }
        let packageID = profile.effectivePackageID
        let members = catalog.models.filter { $0.effectivePackageID == packageID }
        var listChanged = false
        while true {
            let plan = ModelPackageRegistry.removalPlan(packageID: packageID, settings: effectiveAnonymizationSettings, catalog: catalog)
            let confirmation = Self.removalConfirmation(profile: profile, plan: plan, listChanged: listChanged)
            guard presentRemovalDialog(confirmation) else { return }
            // Re-check the affected tabs after the confirmation: a changed list
            // requires a fresh confirmation of the actual state.
            let current = ModelPackageRegistry.removalPlan(packageID: packageID, settings: effectiveAnonymizationSettings, catalog: catalog)
            guard current == plan else { listChanged = true; continue }
            executeConfirmedRemoval(packageID: packageID, members: members, catalog: catalog, repository: repository)
            return
        }
    }

    private func executeConfirmedRemoval(packageID: String, members: [ModelProfile], catalog: ModelCatalog, repository: RecordingRepository) {
        Task {
            // Readiness for new jobs switches off at once; started jobs keep
            // their pinned verified files until the workers exit (no leases yet
            // in this work — the queue integration holds them).
            await packageRegistry.confirmRemoval(packageID: packageID)
            readyPackageIDs = await packageRegistry.readyPackageIDs()
            do {
                var updated = modelLibrary
                for member in members where updated.isInstalled(member) {
                    try updated.remove(member, at: repository.models, catalog: catalog, hardware: hardware)
                }
                modelLibrary = updated
                try await packageRegistry.finishPhysicalRemoval(packageID: packageID)
                readyPackageIDs = await packageRegistry.readyPackageIDs()
                updateModelsStatus()
            } catch {
                // Restore readiness until the physical removal actually runs.
                await packageRegistry.cancelRemoval(packageID: packageID)
                readyPackageIDs = await packageRegistry.readyPackageIDs()
                errorHandler.report(error)
                Task { await verifyModels() }
            }
        }
    }
    func chooseImport() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = L10n.text("MP3, M4A, WAV, FLAC, OGG, OPUS — до 3 часов")
        guard panel.runModal() == .OK else { return }; importURLs(panel.urls)
    }
    func importURLs(_ urls: [URL], groupID: String? = nil) {
        let destination = groupID ?? recordingGroups.defaultID
        for url in urls { enqueueImport(groupID: destination) { url } }
    }
    @discardableResult
    func importProviders(_ providers: [NSItemProvider], groupID: String? = nil) -> Bool {
        guard !preparingStorage, !shuttingDown, archive != nil, !providers.isEmpty else { return false }
        let destination = groupID ?? recordingGroups.defaultID
        for provider in providers {
            // Provider loading must start inside the synchronous drop callback;
            // the queue only awaits the resulting URLs (see DroppedFileURL.start).
            let request = DroppedFileURL.start(provider)
            enqueueImport(groupID: destination, onDiscard: { request.cancel() }) { try await request.value() }
        }
        return true
    }
    private func enqueueImport(groupID: String, onDiscard: @escaping @MainActor () -> Void = {},
                               _ loadURL: @escaping @MainActor () async throws -> URL?) {
        guard !preparingStorage, !shuttingDown, let archive else { onDiscard(); return }
        do {
            try importQueue.enqueue(onDiscard: onDiscard) { [self] in
                do {
                    guard let url = try await loadURL() else { return }
                    try Task.checkCancellation()
                    errorHandler.note(.importStarted, operation: .importAudio)
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
                } catch { errorHandler.report(error, operation: .importAudio,
                                        failure: DiagnosticFailure(.operationFailed, phase: .sourceOpen, error: error)) }
            }
        } catch {
            onDiscard()
            errorHandler.report(error, operation: .importAudio,
                                        failure: DiagnosticFailure(.operationFailed, phase: .sourceOpen, error: error))
        }
    }
    func completeImport(_ manifest: Manifest) async {
        // Import may finish while a result sheet owns an unsaved local draft.
        if resultEdit == nil && !savingResult { selection = manifest.id }
        await reload(); await enqueue(manifest.id)
    }
    /// Both buttons reserve the destination and actual HAL input on this turn
    /// of MainActor, before a permission dialog or any other suspension.
    @discardableResult func requestRecording(groupID: String? = nil) -> Task<Void, Never>? {
        guard canStartRecording else { return nil }
        let destination = groupID ?? recordingGroups.defaultID
        let preferences = recordingSources
        do {
            guard preferences.hasEnabledSource else {
                throw ScribeError.message("Включите хотя бы один источник записи.")
            }
            let microphone: MicrophoneCaptureRequest?
            if preferences.microphoneEnabled {
                let initial = microphoneDevices.candidates(for: preferences.microphone).first
                if initial == nil, !preferences.systemAudioEnabled {
                    throw ScribeError.message(preferences.microphone.unavailableMessage)
                }
                microphone = MicrophoneCaptureRequest(selection: preferences.microphone, initial: initial)
            } else {
                microphone = nil
            }
            let manifest = Manifest(sourceType: "microphone", title: L10n.text("Запись %1$@", Date().formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))), filename: "original.caf")
            startingGroupID = destination
            startingRecordingID = manifest.id
            startingRecording = true
            let task = Task {
                await performRecordingStart(manifest, groupID: destination, microphone: microphone, systemAudio: preferences.systemAudioEnabled)
            }
            recordingStartTask = task
            return task
        } catch {
            errorHandler.report(error)
            return nil
        }
    }

    func startRecording(groupID: String? = nil) async {
        await requestRecording(groupID: groupID)?.value
    }

    private func clearRecordingStart(_ id: String) {
        guard startingRecordingID == id else { return }
        startingRecordingID = nil
        startingGroupID = nil
        openingCapture = false
        startInterruption = nil
        startupStopReason = nil
        pendingCaptureWarnings.removeAll()
        recordingStartTask = nil
        startingRecording = false
        Task { await processQueue() }
    }

    private func interruptRecordingStart(warning: String) async {
        guard let id = startingRecordingID else { return }
        startInterruption = warning
        recordingStartTask?.cancel()
        if openingCapture {
            // Join a start that can own hardware or publish an archive item.
            await recordingStartTask?.value
        } else {
            // A pending microphone permission dialog may outlive this attempt.
            clearRecordingStart(id)
        }
    }

    func prepareForSleep() async {
        errorHandler.note(.sleep)
        guard !suspendingCaptureForSleep else { return }
        suspendingCaptureForSleep = true
        let warning = "Сон системы прервал запись."
        let reason = "Обработка прервана перед сном. Нажмите «Продолжить» после пробуждения."
        let pauseID = UUID()
        queuePauses[pauseID] = reason
        defer {
            queuePauses.removeValue(forKey: pauseID)
            suspendingCaptureForSleep = false
        }
        await interruptRecordingStart(warning: warning)
        if recordingID != nil { await stopRecording(warning: warning) }
        await pause(reason: reason)
    }

    private func performRecordingStart(_ manifest: Manifest, groupID: String, microphone: MicrophoneCaptureRequest?, systemAudio: Bool) async {
        let id = manifest.id
        guard startingRecordingID == id, let repository, let archive else { return }
        defer { clearRecordingStart(id) }
        if microphone != nil {
            let granted = await requestMicrophoneAccess()
            guard startingRecordingID == id, !Task.isCancelled else { return }
            guard granted else {
                errorHandler.report(message: "Доступ к микрофону запрещён. Разрешите LocalScribe доступ в настройках конфиденциальности macOS.",
                                    operation: .capture, failure: DiagnosticFailure(.permissionDenied, phase: .captureStart))
                return
            }
        }
        guard !shuttingDown, !suspendingCaptureForSleep, !Task.isCancelled else { return }

        openingCapture = true
        let capture = makeRecordingCapture(microphoneDevices)
        var startupMicrophoneStatus: CaptureMicrophoneStatus?
        var startupMeter: CaptureMeterReading?
        capture.onMicrophoneStatus = { [weak self] status in
            guard let self, !self.stopping else { return }
            if self.recordingID == id {
                self.indicators.microphoneStatus = status
            } else if self.startingRecordingID == id {
                startupMicrophoneStatus = status
            }
        }
        capture.onMeter = { [weak self] reading in
            guard let self, !self.stopping else { return }
            guard self.recordingID == id else {
                if self.startingRecordingID == id { startupMeter = reading }
                return
            }
            self.level = reading.level
            self.elapsed = reading.elapsed
            self.soundNotice = reading.soundNotice
            self.indicators.waitingForSystemAudio = reading.waitingForSystemAudio
        }
        capture.onStopNeeded = { [weak self] reason in
            guard let self else { return }
            if self.recordingID == id {
                self.recordCaptureWarning(reason, id: id)
                Task { [weak self] in
                    guard let self, self.recordingID == id else { return }
                    await self.stopRecording(warning: reason)
                }
            } else if self.startingRecordingID == id {
                self.startupStopReason = self.startupStopReason ?? reason
            }
        }
        capture.onWarning = { [weak self] warning in
            guard let self else { return }
            if self.recordingID == id { self.recordCaptureWarning(warning, id: id) }
            else if self.startingRecordingID == id { self.pendingCaptureWarnings.append(warning) }
        }
        capture.onResourcePressure = { [weak self] in
            guard let self, self.recordingID == id, !self.stopping else { return }
            self.pauseForCaptureResources()
        }

        let folder = repository.folder(id)
        let captureFolder = folder.appendingPathComponent("capture")
        var published = manifest
        published.state = .recording
        published.recordedAt = Date()
        var registered = false
        do {
            // A crash after the first closed CAF must leave a recoverable recording.
            try await archive.createRecording(published, groupID: groupID)
            registered = true
            try Task.checkCancellation()
            try await capture.start(folder: captureFolder, microphone: microphone, systemAudio: systemAudio)
            try Task.checkCancellation()
            if let startupStopReason { throw ScribeError.message(startupStopReason) }
            let warnings = pendingCaptureWarnings
            if !warnings.isEmpty { try await archive.update(id) { $0.warnings = warnings } }

            recorder = capture
            selection = id
            elapsed = startupMeter?.elapsed ?? 0
            level = startupMeter?.level ?? 0
            soundNotice = startupMeter?.soundNotice
            indicators.microphoneStatus = startupMicrophoneStatus
            indicators.waitingForSystemAudio = startupMeter?.waitingForSystemAudio ?? systemAudio
            indicators.captureWarnings = []
            supervisor.recordingActive = true
            recordingID = id
            errorHandler.note(.captureStarted)
            for warning in pendingCaptureWarnings { recordCaptureWarning(warning, id: id) }

            let interruption = startInterruption ?? startupStopReason
            clearRecordingStart(id)
            if let interruption {
                await stopRecording(warning: interruption)
                return
            }
            captureCaptions = nil
            if automaticLiveCaptions {
                startLiveCaptions(id)
            } else {
                startLiveCapture(id, archive: archive)
            }
            await revealRecording(id, whileCapturing: true)
        } catch {
            _ = try? await capture.stop()
            if registered {
                let hasFragments = await archive.perform { _ in
                    guard FileManager.default.fileExists(atPath: captureFolder.path) else { return false }
                    // Preserve unknown contents for recovery if the directory cannot be read.
                    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: captureFolder.path) else { return true }
                    return contents.contains { $0.hasPrefix("part-") && $0.hasSuffix(".caf") && !$0.contains(".partial.") }
                }
                if hasFragments {
                    let reason = startInterruption ?? startupStopReason ?? error.localizedDescription
                    _ = try? await archive.update(id) {
                        $0.state = .interrupted
                        $0.lastError = reason
                    }
                } else {
                    do { try await archive.delete(published) }
                    catch { errorHandler.report(error) }
                }
                await reload()
            }
            if !Task.isCancelled {
                errorHandler.report(error, operation: .capture,
                                    job: DiagnosticJob(reference: DiagnosticJobReference(.recording, item: id)),
                                    failure: DiagnosticFailure(.operationFailed, phase: .captureStart, error: error))
            }
        }
    }

    func enableFallbackMicrophone() {
        guard recordingID != nil, !stopping, indicators.microphoneStatus == .mutedFallback else { return }
        recorder?.enableFallbackMicrophone()
    }

    private func recordCaptureWarning(_ warning: String, id: String) {
        guard recordingID == id, !indicators.captureWarnings.contains(warning), let archive else { return }
        indicators.captureWarnings.append(warning)
        let taskID = UUID()
        warningTasks[taskID] = Task {
            defer { warningTasks.removeValue(forKey: taskID) }
            do {
                try await archive.update(id) { m in
                    if !m.warnings.contains(warning) { m.warnings.append(warning) }
                }
                await reload()
            } catch { errorHandler.report(error) }
        }
    }

    private func startLiveCapture(_ id: String, archive: RecordingCoordinator) {
        // Freeze the catalog now. Stop joins this task before reading the run
        // to build its seal, even if beginRun is already on the archive actor.
        guard backgroundRecognition, modelsReady, let catalog = activeCatalog,
              catalog.models.first(where: { $0.purpose == .asr })?.supportsClosedFragments == true else { return }
        let admission = jobAdmission[.recording(id), default: 0]
        let generation = queueGeneration
        liveCaptureStart = Task {
            guard recordingID == id, !stopping, !shuttingDown, queuePauses.isEmpty,
                  generation == queueGeneration, admission == jobAdmission[.recording(id), default: 0] else { return }
            do {
                _ = try await archive.beginRun(id, catalog: catalog, liveCapture: true, recognitionTerms: recognitionTerms(for: catalog))
                guard recordingID == id, !stopping, generation == queueGeneration,
                      admission == jobAdmission[.recording(id), default: 0] else { return }
                await enqueueCapture(id)
            } catch {
                guard recordingID == id, !stopping, captionsOverrideID != id else { return }
                do {
                    try await archive.update(id) { m in
                        guard m.captureProcessing != .cancelled else { return }
                        m.captureProcessing = .failed
                        m.lastError = "Фоновое распознавание не запущено. Звук продолжает сохраняться."
                    }
                } catch is CancellationError { }
                catch {
                    errorHandler.report(message: L10n.text("Не удалось сохранить статус записи после сбоя фонового распознавания: %1$@", L10n.message(error.localizedDescription)))
                }
            }
        }
    }

    func startLiveCaptions(_ id: String) {
        guard recordingID == id, !stopping, !resourcesPaused, !shuttingDown, let recorder, let archive else { return }
        if captureCaptions?.recordingID != id {
            captureCaptions = RecordingLiveCaptions(recordingID: id, archive: archive)
        }
        guard let captureCaptions, !captureCaptions.isRunning else { return }
        deferBackgroundRecognitionForCaptions(id, archive: archive)
        let language = liveCaptionLanguage
        let recognize: LiveCaptionRecognition.Session
        if let locale = language.locale {
            let recognizeSystem = recognizeLiveCaptions
            recognize = { input, ready, receive in try await recognizeSystem(locale, input, ready, receive) }
        } else {
            recognize = recognizeMixedLiveCaptions
        }
        captureCaptions.start(language: language, recognize: recognize) { [weak recorder] audio in
            recorder?.setLiveCaptionAudio(audio)
        }
        if selection == id { tab = .live }
    }

    func setLiveCaptionLanguage(_ language: LiveCaptionLanguage, for id: String) {
        guard recordingID == id, !stopping, !shuttingDown, language != liveCaptionLanguage else { return }
        liveCaptionLanguage = language
        userDefaults.set(language.rawValue, forKey: "liveCaptionLanguage")
        if captureCaptions?.isRunning == true {
            freezeLiveCaptions(id)
            startLiveCaptions(id)
        }
    }

    func freezeLiveCaptions(_ id: String) {
        guard recordingID == id, captureCaptions?.recordingID == id else { return }
        recorder?.setLiveCaptionAudio(nil)
        captureCaptions?.freeze()
    }

    private func deferBackgroundRecognitionForCaptions(_ id: String, archive: RecordingCoordinator) {
        let job = QueueJobID.recording(id)
        let needsWorkerStop = activeJob == job || processingJob == job
        guard captionsOverrideID != id, liveCaptureStart != nil || needsWorkerStop || queued.contains(job) else { return }
        captionsOverrideID = id
        jobAdmission[job, default: 0] &+= 1
        queued.removeAll { $0 == job }
        if activeJob == job { activeJob = nil }
        captionsSwitchTask = Task {
            if needsWorkerStop {
                await supervisor.cancel()
                await waitUntilQueueIdle()
            }
            await liveCaptureStart?.value
            do {
                try await archive.update(id) { m in
                    guard m.captureProcessing != nil else { return }
                    m.captureProcessing = nil
                    m.lastError = nil
                }
            } catch {
                errorHandler.report(error)
            }
            captionsSwitchTask = nil
            await reload()
            await processQueue()
        }
    }

    func stopRecording(warning: String? = nil) async {
        guard let id = recordingID, let archive, !stopping else { return }
        finalizingRecordingID = id
        stopping = true; finalizingRecording = true; status = L10n.message("Сохраняем аудио…")
        if selection == id, captureCaptions?.recordingID == id { tab = .transcript }
        if let warning { recordCaptureWarning(warning, id: id) }
        defer {
            finalizingRecordingID = nil
            indicators.microphoneStatus = nil
            indicators.captureWarnings = []
            indicators.waitingForSystemAudio = false
            liveCaptureStart = nil
            captionsOverrideID = nil
            stopping = false; finalizingRecording = false; supervisor.recordingActive = false
            captureLimited = false; resourcesPaused = memoryLimited
            updateResourcePausePresentation()
            if status == L10n.message("Сохраняем аудио…") { status = "" }
            Task { await processQueue() }
        }
        do {
            let frames = try await recorder?.stop() ?? 0; recorder = nil
            if captureCaptions?.recordingID == id { await captureCaptions?.finish() }
            await captionsSwitchTask?.value
            await liveCaptureStart?.value
            for task in Array(warningTasks.values) { await task.value }
            let warnings = indicators.captureWarnings
            if frames == 0 {
                let m = try await archive.update(id) { m in
                    for warning in warnings where !m.warnings.contains(warning) { m.warnings.append(warning) }
                    m.state = .failed; m.lastError = warning ?? "Источники ещё не передали звук. Начните новую запись."
                }
                recordingID = nil
                queued.removeAll { $0 == .recording(id) }
                if activeJob == .recording(id) { activeJob = nil; await supervisor.cancel() }
                errorHandler.report(message: m.lastError, operation: .capture,
                                    job: DiagnosticJob(reference: DiagnosticJobReference(.recording, item: id, run: m.pendingRunId)),
                                    failure: DiagnosticFailure(.invalidInput, phase: .captureStop))
                errorHandler.note(.captureStopped)
                await reload(); return
            }
            if let warning { errorHandler.report(message: warning) }
            try await finalizeCapture(id, expectedFrames: frames, warnings: warnings); recordingID = nil; await enqueue(id)
        } catch {
            if captureCaptions?.recordingID == id { await captureCaptions?.finish() }
            await captionsSwitchTask?.value
            await liveCaptureStart?.value
            for task in Array(warningTasks.values) { await task.value }
            let warnings = indicators.captureWarnings
            recordingID = nil; recorder = nil
            errorHandler.report(error, operation: .capture,
                                job: DiagnosticJob(reference: DiagnosticJobReference(.recording, item: id, run: recordingsByID[id]?.pendingRunId)),
                                failure: DiagnosticFailure(.operationFailed, phase: .captureStop, error: error))
            queued.removeAll { $0 == .recording(id) }
            if activeJob == .recording(id) { activeJob = nil; await supervisor.cancel() }
            let recoverable = await archive.perform { repository in
                let parts = (try? FileManager.default.contentsOfDirectory(at: repository.folder(id).appendingPathComponent("capture"), includingPropertiesForKeys: nil)) ?? []
                return parts.contains { $0.pathExtension == "caf" && !$0.lastPathComponent.contains(".partial.") }
            }
            do {
                try await archive.update(id) { m in
                    for warning in warnings where !m.warnings.contains(warning) { m.warnings.append(warning) }
                    m.state = recoverable ? .interrupted : .failed
                    m.lastError = recoverable ? "Фрагменты сохранены. Нажмите «Продолжить» для сборки." : "Нет сохранённого звука. Начните новую запись."
                }
            } catch is CancellationError { }
            catch {
                errorHandler.report(message: L10n.text("Не удалось сохранить статус остановленной записи: %1$@", L10n.message(error.localizedDescription)))
            }
        }
        errorHandler.note(.captureStopped)
        await reload()
    }
    func finalizeCapture(_ id: String, expectedFrames: Int64? = nil, warnings: [String] = []) async throws {
        guard let repository, let archive else { return }
        let manifest = try await archive.load(id)
        let folder = repository.folder(id), destination = folder.appendingPathComponent(manifest.originalRelativePath)
        let (frames, rate, hash) = try await archive.perform { _ -> (Int64, Double, String) in
            try Disk.directory(destination.deletingLastPathComponent())
            let result = try Media.assembleCapture(folder.appendingPathComponent("capture"), destination: destination)
            return (result.0, result.1, try Disk.hash(destination))
        }
        if let expectedFrames, frames != expectedFrames { throw ScribeError.message("Сохранены не все сэмплы записи. Фрагменты оставлены для восстановления.") }
        let state: JobState = activeJob == .recording(id) ? .transcribing : .recorded
        // Apply only capture fields to the latest manifest, preserving renames/warnings.
        let m = try await archive.update(id) { m in
            for warning in warnings where !m.warnings.contains(warning) { m.warnings.append(warning) }
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
    @discardableResult func resume(_ id: String) -> Task<Void, Never>? {
        guard !preparingStorage, !shuttingDown, !finalizingRecording, queuePauses.isEmpty, !deletingJobIDs.contains(.recording(id)), id != recordingID, activeJob != .recording(id) else { return nil }
        let generation = queueGeneration, admission = jobAdmission[.recording(id), default: 0]
        finalizingRecordingID = id
        finalizingRecording = true
        return Task {
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
                    guard generation == queueGeneration, admission == jobAdmission[.recording(id), default: 0], !deletingJobIDs.contains(.recording(id)), !shuttingDown else { return }
                    if needsAssembly {
                        guard hasParts else {
                            let message = "В этой записи нет сохранённого звука. Начните новую запись."
                            try await archive.update(id) { m in m.state = .failed; m.lastError = message }
                            await reload(); errorHandler.report(message: message); return
                        }
                        try await finalizeCapture(id)
                    }
                }
                guard generation == queueGeneration, admission == jobAdmission[.recording(id), default: 0], !deletingJobIDs.contains(.recording(id)), !shuttingDown else { return }
                await enqueue(id, allowCancelled: true, mode: .resume)
            } catch { errorHandler.report(error) }
        }
    }
    func repeatAnalysis(summaryOnly: Bool, language: String? = nil) async {
        guard let archive, let catalog = activeCatalog, var m = selected, canManageModels, modelsReady else { return }
        finalizingRecording = true
        defer { finalizingRecording = false }
        let summaryLanguage = summaryOnly ? language ?? transcript?.primaryLanguage ?? "ru" : language
        // Summary-only recreation reuses the saved transcript; the dictionary
        // hint belongs to ASR runs only.
        let terms = summaryOnly ? nil : recognitionTerms(for: catalog)
        do { m = try await archive.beginRun(m.id, catalog: catalog, summaryLanguage: summaryLanguage, summaryOnly: summaryOnly, recognitionTerms: terms); await reload(); await enqueue(m.id, mode: .retry) }
        catch { errorHandler.report(error) }
    }
    func queuePosition(for id: String) -> Int? {
        queued.firstIndex(of: .recording(id)).map { $0 + 1 }
    }
    func moveToFrontOfQueue(_ id: String) {
        moveToFrontOfQueue(.recording(id))
    }
    func moveToFrontOfQueue(_ job: QueueJobID) {
        guard !preparingStorage, !shuttingDown, activeJob != job,
              let index = queued.firstIndex(of: job), index > 0 else { return }
        var reordered = queued
        reordered.remove(at: index)
        reordered.insert(job, at: 0)
        queued = reordered
    }
    func enqueueCapture(_ id: String) async {
        guard let archive else { return }
        let generation = queueGeneration, admission = jobAdmission[.recording(id), default: 0], pauseReason = queuePauses.values.first
        let valid = await archive.perform { repository in
            guard let manifest = try? repository.load(id), manifest.state == .recording, manifest.captureProcessing != .cancelled,
                  let pending = manifest.pendingRunId,
                  let info = try? Disk.read(RunInfo.self, at: repository.run(id, pending).appendingPathComponent("run.json")) else { return false }
            return info.liveCapture == true
        }
        guard valid, captionsOverrideID != id, finalizingRecordingID != id, generation == queueGeneration, admission == jobAdmission[.recording(id), default: 0],
              !deletingJobIDs.contains(.recording(id)), activeJob != .recording(id), !shuttingDown else { return }
        if let reason = queuePauses.values.first ?? pauseReason {
            await interruptEnqueue(id, reason: reason); return
        }
        if !queued.contains(.recording(id)) { queued.append(.recording(id)) }
        Task { await processQueue() }
    }
    private func interruptEnqueue(_ id: String, reason: String) async {
        do {
            _ = try await archive?.update(id) { m in
                if m.state == .recording { m.captureProcessing = .interrupted } else { m.state = .interrupted }
                m.lastError = reason
            }
        } catch is CancellationError { }
        catch {
            errorHandler.report(message: L10n.text("Не удалось сохранить статус прерванной записи: %1$@", L10n.message(error.localizedDescription)))
        }
        await reload()
    }
    func enqueue(_ id: String, allowCancelled: Bool = false, mode: DiagnosticMode? = nil) async {
        guard let archive, !deletingJobIDs.contains(.recording(id)), enqueuing[.recording(id)] == nil else { return }
        let request = UUID(), generation = queueGeneration
        let pauseReason = queuePauses.values.first
        enqueuing[.recording(id)] = request
        defer {
            if enqueuing[.recording(id)] == request { enqueuing.removeValue(forKey: .recording(id)) }
            if !busy { Task { await processQueue() } }
        }
        let m: Manifest
        do { m = try await archive.load(id) }
        catch {
            errorHandler.report(message: "Не удалось прочитать запись для продолжения обработки. Файлы сохранены; проверьте архив и повторите попытку.")
            return
        }
        guard m.sourceComplete, activeJob != .recording(id),
              allowCancelled || m.state != .cancelled,
              generation == queueGeneration, !deletingJobIDs.contains(.recording(id)), enqueuing[.recording(id)] == request else { return }
        if shuttingDown {
            do {
                try await archive.update(id) { m in
                    m.state = .interrupted; m.lastError = "Приложение закрыто. Можно продолжить обработку."
                }
            } catch is CancellationError { }
            catch {
                errorHandler.report(message: L10n.text("Не удалось сохранить статус записи перед закрытием приложения: %1$@", L10n.message(error.localizedDescription)))
            }
            await reload(); return
        }
        if let reason = queuePauses.values.first ?? pauseReason {
            await interruptEnqueue(id, reason: reason); return
        }
        let canQueue = m.pendingRunId != nil || modelsReady
        // Reserve FIFO position before suspending for persistence.
        if canQueue, !queued.contains(.recording(id)) {
            queued.append(.recording(id))
            if let mode { setDiagnosticMode(mode, for: .recording(id)) }
        }
        do {
            try await archive.update(id) { m in
                m.state = canQueue ? .queued : .waitingForModels; m.lastError = nil
            }
        } catch is CancellationError { }
        catch {
            errorHandler.report(message: L10n.text("Не удалось сохранить статус постановки записи в очередь: %1$@", L10n.message(error.localizedDescription)))
        }
        await reload()
    }
    private func requireHardware(for role: ModelRole, info: RunInfo, catalog: ModelCatalog) throws {
        let pinned = try catalog.pinned(to: info)
        guard let profile = pinned.models.first(where: { $0.purpose == role }) else { throw ScribeError.message("Модель этапа отсутствует") }
        try hardware.requireCompatibility(for: profile)
    }
    func processQueue() async {
        guard deletingGroupID == nil, !deletingSidebarRecordings, !deletingDiagramJobs, !deletingTextJobs, !preparingStorage, !busy, !resourcesPaused, !suspendingQueue, queuePauses.isEmpty, resourcePauseTask == nil, captionsSwitchTask == nil, !installing, !verifyingModels, !startingRecording, !shuttingDown,
              repository != nil, let archive, catalog != nil else { return }
        busy = true
        defer {
            activeJob = nil
            processingJob = nil
            if queueStatus == status { status = "" }
            queueStatus = nil
            busy = false
        }
        while deletingGroupID == nil && !deletingSidebarRecordings && !deletingDiagramJobs && !deletingTextJobs && queued.first.map({ enqueuing[$0] == nil }) == true && !resourcesPaused && !suspendingQueue && queuePauses.isEmpty && resourcePauseTask == nil && captionsSwitchTask == nil && !shuttingDown {
            if ProcessInfo.processInfo.thermalState == .critical {
                showQueueStatus("Обработка ожидает охлаждения Mac")
                try? await Task.sleep(for: .seconds(2)); continue
            }
            let job = queued.removeFirst(); activeJob = job; processingJob = job
            processingDiagnostic = DiagnosticJob(reference: DiagnosticJobReference(job.diagnosticOperation, item: job.id),
                                                 mode: diagnosticModes.removeValue(forKey: job) ?? .new, phase: .admission)
            do {
                switch job.kind {
                case .recording: try await processRecordingJob(job.id)
                case .diagram: try await processDiagramJob(job.id)
                case .text: try await processTextJob(job.id)
                }
            } catch {
                let failure = error as? WorkerFailureError
                let message = (error as? ScribeError)?.localizedDescription
                    ?? failure?.userMessage
                    ?? (job.isText ? "Обезличивание прервано. Прежний результат сохранён."
                                   : "Обработка прервана. Готовые результаты и контрольные точки сохранены.")
                if activeJob == job, !(error is CancellationError) {
                    if processingDiagnostic.live == true, recordingID == job.id, elapsed.isFinite {
                        processingDiagnostic.durationMs = Int(elapsed * 1_000)
                    }
                    let code: DiagnosticFailure.Code
                    switch processingDiagnostic.phase {
                    case .resultValidation: code = .invalidResult
                    case .resultWrite: code = .resultWrite
                    case .inputValidation: code = .invalidInput
                    case .modelValidation: code = .modelValidation
                    default: code = .operationFailed
                    }
                    errorHandler.report(error, operation: job.diagnosticOperation, job: processingDiagnostic,
                                        failure: DiagnosticFailure(code, phase: processingDiagnostic.phase, error: error),
                                        message: message)
                }
                // A cancellation that still owns the active job (a supervisor
                // kill without a UI cancel) never records a failure: the
                // attempt keeps its on-disk state for the restart recovery.
                if activeJob == job, !(error is CancellationError || (resourcesPaused && queued.contains(job))) {
                    if job.isRecording {
                        let isMicrophone = recordingID == job.id
                        _ = try? await archive.update(job.id) { m in
                            // A queued job can be cancelled while its previous worker
                            // is still unwinding a resource pause.
                            guard m.state != .cancelled, m.captureProcessing != .cancelled else { return }
                            if isMicrophone || !m.sourceComplete && m.state == .recording {
                                // Processing failure never changes microphone ownership/state.
                                m.captureProcessing = .failed
                            } else if m.state.processing || m.state == .queued || m.state == .recorded {
                                m.state = .failed
                            }
                            m.lastError = message
                        }
                    } else if job.isText, let textArchive {
                        // A failure records a safe PROCESSING reason on this attempt
                        // and never touches the published result (invariant 6).
                        _ = try? await textArchive.updateCard(job.id) { card in
                            guard card.latestAttempt.state == .running || card.latestAttempt.state == .queued else { return }
                            card.latestAttempt.state = .failed
                            card.latestAttempt.failure = .processing(message)
                        }
                    } else if let diagramArchive {
                        _ = try? await diagramArchive.update(job.id) { m in
                            guard m.state != .cancelled else { return }
                            if m.state.processing || m.state == .queued { m.state = .failed }
                            m.lastError = message
                        }
                    }
                }
            }
            // Only the owning queue task clears the active job, after all readers exit.
            if job.isRecording {
                await archive.perform { try? $0.cleanupTemporaryFiles(job.id) }
            }
            activeJob = nil; processingJob = nil
            if job.isRecording { await reload() } else if job.isText { await reloadTexts() } else { await reloadDiagrams() }
        }
    }
    /// One audio job: live ASR of an open capture plus the offline stage loop.
    /// All invariants (frozen run, per-stage pinned hardware checks, checkpoint
    /// validation before publication) are unchanged from the single-kind queue.
    private func processRecordingJob(_ id: String) async throws {
        let job = QueueJobID.recording(id)
        guard let repository, let archive, let catalog else { throw CancellationError() }
        var m = try await archive.load(id)
        processingDiagnostic.reference?.runID = m.pendingRunId.flatMap(UUID.init(uuidString:))
        processingDiagnostic.inputFormat = DiagnosticField.audioFormat((m.originalRelativePath as NSString).pathExtension.lowercased())
        processingDiagnostic.durationMs = m.durationMs
        processingDiagnostic.sampleRate = m.sampleRate.isFinite ? m.sampleRate : nil
        processingDiagnostic.channels = m.channels
        if m.pendingRunId == nil {
            guard modelsReady, let selectedCatalog = activeCatalog else {
                try await archive.update(id) { $0.state = .waitingForModels }; return
            }
            m = try await archive.beginRun(m.id, catalog: selectedCatalog, recognitionTerms: recognitionTerms(for: selectedCatalog))
        }
        processingDiagnostic.reference?.runID = m.pendingRunId.flatMap(UUID.init(uuidString:))
        processingDiagnostic.phase = .inputValidation
        var info = try await archive.perform { try $0.resumeRun(id, catalog: catalog) }
        processingDiagnostic.pipeline = info.pipelineVersion
        errorHandler.note(.jobStarted, job: processingDiagnostic)
        guard activeJob == job else { throw CancellationError() }
                m = try await archive.load(id)
                let livePending = info.liveCapture == true && info.sourceHash == "capture:" + info.id
                let run = repository.run(id,info.id)
                if livePending {
                    configureRecordingStage(.transcribing, info: info, catalog: catalog, live: true)
                    try requireHardware(for: .asr, info: info, catalog: catalog)
                    m = try await archive.update(id) { m in
                        // A saved capture can start its live ASR after waiting in
                        // the queue. Its main state now describes processing.
                        if m.state == .recording {
                            m.captureProcessing = .transcribing
                        } else {
                            m.state = .transcribing; m.captureProcessing = nil
                        }
                        m.lastError = nil
                    }
                    await reload()
                    guard activeJob == job else { throw CancellationError() }
                    var command = WorkerCommand(jobId: id, runId: info.id, stage: .transcribing, recordingPath: repository.folder(id).path, modelsPath: repository.models.path, toolsPath: tools.path)
                    command.liveCapture = true
                    try await runWorker(command)
                    guard activeJob == job else { throw CancellationError() }
                    let captureInfo = info
                    info = try await archive.perform { try $0.bindLiveTranscript(id, info: captureInfo) }
                    m = try await archive.update(id) { $0.captureProcessing = nil }
                }
                let stages: [Stage] = [.preparingAudio,.transcribing,.diarizing,.summarizing]
                for stage in stages {
                    if activeJob != job { throw CancellationError() }
                    // Explicit recreation records a requested language, even before
                    // the first successful run; older summary-only runs pin a source.
                    // Read the preference at the stage boundary, including after live ASR.
                    if stage == .summarizing, !automaticSummaries, info.summaryLanguage == nil, info.transcriptSourceRunID == nil { continue }
                    m = try await archive.load(id)
                    configureRecordingStage(stage, info: info, catalog: catalog)
                    processingDiagnostic.phase = .resultValidation
                    if try await archive.perform({ [m, info] _ in try Self.stageComplete(stage, run: run, manifest: m, info: info) }) { continue }
                    guard m.sourceComplete else { throw ScribeError.message("Исходник ещё записывается") }
                    let role: ModelRole? = stage == .transcribing ? .asr : stage == .diarizing ? .diarization : stage == .summarizing ? .summary : nil
                    processingDiagnostic.phase = .modelValidation
                    if let role { try requireHardware(for: role, info: info, catalog: catalog) }
                    guard activeJob == job else { throw CancellationError() }
                    guard let state = JobState(rawValue: stage.rawValue) else {
                        throw ScribeError.message("Некорректный этап обработки")
                    }
                    m = try await archive.update(id) {
                        $0.state = state
                        $0.lastError = nil
                    }
                    await reload()
                    guard activeJob == job else { throw CancellationError() }
                    let command = WorkerCommand(jobId: id, runId: info.id, stage: stage, recordingPath: repository.folder(id).path, modelsPath: repository.models.path, toolsPath: tools.path)
                    try await runWorker(command)
                    guard activeJob == job else { throw CancellationError() }
                    processingDiagnostic.phase = .resultValidation
                    guard try await archive.perform({ [m, info] _ in try Self.stageComplete(stage, run: run, manifest: m, info: info) }) else { throw ScribeError.message("Worker не создал проверяемый результат этапа") }
                    await reload()
                }
                guard activeJob == job else { throw CancellationError() }
                processingDiagnostic.phase = .resultValidation
                let completedRunID = info.id
                // A transcript-only result is valid, but any existing final JSON
                // must still pass validation before replacing the previous result.
                try await archive.perform { [m] repository in
                    var completed = m; completed.activeRunId = completedRunID
                    _ = try repository.results(completed)
                }
                guard activeJob == job else { throw CancellationError() }
                processingDiagnostic.phase = .resultWrite
                try await archive.update(id) { m in
                    m.activeRunId = completedRunID; m.pendingRunId = nil; m.captureProcessing = nil
                    m.state = m.warnings.isEmpty ? .completed : .completedWithWarnings; m.lastError = nil
                }
    }

    /// One diagram job: the run is frozen at enqueue time; recognition itself
    /// runs in the same single worker slot, and the coordinator switches the
    /// active run only after the artifact passes full validation.
    private func processDiagramJob(_ id: String) async throws {
        let job = QueueJobID.diagram(id)
        guard let repository, let diagramArchive, let diagramRepository else { throw ScribeError.message("Хранилище схем недоступно") }
        var m = try await diagramArchive.load(id)
        guard m.pendingRunId != nil else {
            // Diagram jobs always enter the FIFO with a frozen run; without one
            // the job returns to «Ожидает модель» and leaves the queue running.
            try await diagramArchive.update(id) { $0.state = .waitingForModels }
            return
        }
        processingDiagnostic.reference?.runID = m.pendingRunId.flatMap(UUID.init(uuidString:))
        processingDiagnostic.width = m.pixelWidth
        processingDiagnostic.height = m.pixelHeight
        if m.byteSize >= 0 { processingDiagnostic.bytes = UInt(m.byteSize) }
        processingDiagnostic.phase = .inputValidation
        let info = try await diagramArchive.resumeRun(id)
        processingDiagnostic.pipeline = info.pipelineVersion
        processingDiagnostic.prompt = info.promptVersion
        processingDiagnostic.preprocessing = info.preprocessingVersion
        if let profile = catalog?.models.first(where: { $0.id == info.modelID }) {
            processingDiagnostic.models = [DiagnosticJob.Model(profile, backend: .mlx)]
        }
        errorHandler.note(.jobStarted, job: processingDiagnostic)
        guard activeJob == job else { throw CancellationError() }
        m = try await diagramArchive.update(id) {
            $0.state = .recognizing; $0.lastError = nil
        }
        await reloadDiagrams()
        guard activeJob == job else { throw CancellationError() }
        let command = WorkerCommand(diagramJobId: id, runId: info.id, diagramPath: diagramRepository.folder(id).path, modelsPath: repository.models.path, toolsPath: tools.path)
        // The manifest still describes the previous validated result during a retry.
        var warnings: [String] = []
        try await superviseJob(command) { event in
            if event.type == "progress" { self.showQueueStatus(event.message) }
            if event.type == "warning", !warnings.contains(event.message) { warnings.append(event.message) }
        }
        guard activeJob == job else { throw CancellationError() }
        m = try await diagramArchive.load(id)
        guard activeJob == job, m.state != .cancelled else { throw CancellationError() }
        processingDiagnostic.phase = .resultValidation
        _ = try await diagramArchive.completeRun(id, runId: info.id, warnings: warnings)
        await reloadDiagrams()
    }
    private func setDiagnosticMode(_ mode: DiagnosticMode, for job: QueueJobID) {
        if diagnosticModes.count >= 256, let key = diagnosticModes.keys.first {
            diagnosticModes.removeValue(forKey: key)
        }
        diagnosticModes[job] = mode
    }

    private func configureRecordingStage(_ stage: Stage, info: RunInfo, catalog: ModelCatalog, live: Bool = false) {
        processingDiagnostic.stage = stage
        processingDiagnostic.live = live
        processingDiagnostic.phase = .modelValidation
        let roles: [ModelRole]
        switch stage {
        case .preparingAudio: roles = []
        case .transcribing: roles = [.asr, .tokenizer]
        case .diarizing: roles = [.diarization]
        case .summarizing: roles = [.summary]
        }
        processingDiagnostic.models = roles.compactMap { role in
            guard let id = try? info.modelID(for: role),
                  let profile = catalog.models.first(where: { $0.id == id }) else { return nil }
            let backend: DiagnosticJob.Model.Backend
            if role == .diarization { backend = .speakerKit }
            else if role == .summary { backend = .mlx }
            else if profile.resolvedASRBackend == "vibevoice-asr" { backend = .vibevoice }
            else { backend = .init(rawValue: profile.resolvedASRBackend) ?? .unknown }
            return DiagnosticJob.Model(profile, backend: backend)
        }
        if stage == .transcribing, let aligner = info.auxiliaryModelIDs?.values.first,
           let profile = catalog.models.first(where: { $0.id == aligner }) {
            processingDiagnostic.models.append(DiagnosticJob.Model(profile, backend: .qwen3))
        }
    }

    private func superviseJob(_ command: WorkerCommand, onEvent: @escaping @MainActor (WorkerEvent) async -> Void) async throws {
        processingDiagnostic.phase = .launch
        errorHandler.note(.stageStarted, job: processingDiagnostic)
        do {
            try await supervisor.run(command, executable: worker) { event in
                if event.type == "started" {
                    self.processingDiagnostic.phase = .inputValidation
                    self.errorHandler.note(.workerStarted, job: self.processingDiagnostic)
                } else if let phase = event.diagnosticPhase {
                    self.processingDiagnostic.phase = phase
                    self.errorHandler.note(.workerPhase, job: self.processingDiagnostic)
                } else if event.type == "progress", self.processingDiagnostic.phase == .inputValidation {
                    self.processingDiagnostic.phase = .processing
                }
                await onEvent(event)
            }
            errorHandler.note(.workerFinished, job: processingDiagnostic)
        } catch {
            errorHandler.note(.workerFinished, job: processingDiagnostic, worker: (error as? WorkerFailureError)?.exit)
            throw error
        }
    }

    private func runWorker(_ command: WorkerCommand) async throws {
        try await superviseJob(command) { event in
            if event.type == "progress" { self.showQueueStatus(event.message) }
            if event.type == "checkpoint" {
                self.resultSignature = ""; self.loadResult()
            }
            if event.type == "warning", let archive = self.archive,
               (try? await archive.appendWarning(event.message, to: command.jobId)) == true {
                await self.reload()
            }
        }
    }
    @discardableResult func resumeAfterMemoryPressure() -> Task<Void, Never> {
        memoryLimited = false; resourcesPaused = captureLimited
        updateResourcePausePresentation()
        return Task { await resourcePauseTask?.value; await processQueue() }
    }
    func pauseForCaptureResources(memoryPressure: Bool = false) {
        if memoryPressure { memoryLimited = true } else { captureLimited = true; errorHandler.note(.capturePressure) }
        resourcesPaused = true
        if let recordingID { freezeLiveCaptions(recordingID) }
        updateResourcePausePresentation()
        guard resourcePauseTask == nil else { return }
        let pauseMessage = resourcePauseMessage
        resourcePauseTask = Task {
            if let job = activeJob {
                activeJob = nil
                if !queued.contains(job) {
                    queued.insert(job, at: 0)
                    setDiagnosticMode(.resume, for: job)
                }
                if job.isRecording, let archive {
                    _ = try? await archive.update(job.id) { m in
                        if m.state == .recording { m.captureProcessing = .interrupted } else { m.state = .queued }
                        m.lastError = pauseMessage
                    }
                } else if job.isText, let textArchive {
                    // The attempt returns to the FIFO head and keeps its frozen
                    // input (or still-frozen retry snapshot) for the automatic
                    // continuation; the queue banner explains the pause.
                    _ = try? await textArchive.updateCard(job.id) { card in
                        if card.latestAttempt.state == .running || card.latestAttempt.state == .queued {
                            card.latestAttempt.state = .queued
                        }
                    }
                } else if !job.isRecording, let diagramArchive {
                    _ = try? await diagramArchive.update(job.id) {
                        if $0.state == .recognizing || $0.state == .queued { $0.state = .queued }
                        $0.lastError = pauseMessage
                    }
                }
                await supervisor.cancel()
                await waitUntilQueueIdle()
            }
            resourcePauseTask = nil
            await reload()
            if !resourcesPaused { await processQueue() }
        }
    }
    private func updateResourcePausePresentation() {
        if memoryLimited {
            resourcePauseTitle = "Очередь приостановлена: не хватает памяти"
            resourcePauseMessage = "Обработка приостановлена из-за нехватки памяти. Она продолжится автоматически, когда macOS сообщит, что память освободилась. Аудио и контрольные точки сохранены."
        } else if captureLimited {
            resourcePauseTitle = "Очередь приостановлена: сохраняем звук"
            resourcePauseMessage = "Фоновая обработка приостановлена, чтобы сохранить звук без потерь. Она продолжится автоматически после остановки записи."
        } else {
            resourcePauseTitle = nil
            resourcePauseMessage = nil
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
            let frames = file.length
            return file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1 && frames > 0
                && abs(Double(frames) / 16 - Double(manifest.durationMs)) < 150
                && (checkpoint["pcmFrames"].map { Int64($0) == frames } ?? true)
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
        let jobs = queued + (activeJob.map { [$0] } ?? [])
        queued.removeAll(); activeJob = nil
        for job in Set(jobs) {
            if job.isRecording, let archive {
                _ = try? await archive.update(job.id) { m in
                    guard m.state != .cancelled, m.captureProcessing != .cancelled else { return }
                    if m.state == .recording { m.captureProcessing = .interrupted } else { m.state = .interrupted }
                    m.lastError = reason
                }
            } else if job.isText, let textArchive {
                // Sleep/shutdown interrupts the attempt; an explicit retry
                // continues it later (like the restart recovery).
                _ = try? await textArchive.updateCard(job.id) { card in
                    guard card.latestAttempt.state == .queued || card.latestAttempt.state == .running else { return }
                    card.latestAttempt.state = .interrupted
                }
            } else if !job.isRecording, let diagramArchive {
                _ = try? await diagramArchive.update(job.id) { m in
                    guard m.state != .cancelled else { return }
                    if m.state.processing || m.state == .queued { m.state = .interrupted }
                    m.lastError = reason
                }
            }
        }
        await supervisor.cancel()
        await waitUntilQueueIdle()
        await reload()
        await reloadDiagrams()
        await reloadTexts()
    }
    func cancelSelected() async {
        guard let id = selection else { return }
        await cancel(id)
    }
    func cancel(_ id: String) async {
        guard let archive, captionsOverrideID != id else { return }
        jobAdmission[.recording(id), default: 0] &+= 1
        enqueuing.removeValue(forKey: .recording(id))
        queued.removeAll { $0 == .recording(id) }
        if activeJob == .recording(id) || processingJob == .recording(id) {
            suspendingQueue = true; activeJob = nil
            await supervisor.cancel()
            await waitUntilQueueIdle()
            suspendingQueue = false
            Task { await processQueue() }
        }
        guard captionsOverrideID != id else { return }
        _ = try? await archive.update(id) { m in
            if m.state == .recording { m.captureProcessing = .cancelled } else { m.state = .cancelled }
        }
        await reload()
    }
    func deleteSelected() async {
        guard let selected, archive != nil, canDeleteSidebarRecordings([selected.id]), !finalizingRecording else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("Удалить запись и результаты?"); alert.informativeText = L10n.text("Будут удалены только копия аудио и результаты в LocalScribe. Внешний оригинал и ваши экспорты сохранятся.")
        alert.addButton(withTitle: L10n.text("Удалить запись")); alert.addButton(withTitle: L10n.text("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn, !finalizingRecording else { return }
        await deleteSidebarRecordings([selected.id])
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
    /// Up/Down arrows move the single selection through the currently visible
    /// sidebar order (collapsed groups are skipped); the chosen row is revealed.
    @discardableResult
    func moveSidebarSelection(down: Bool) -> Bool {
        guard let next = SidebarNeighbor.next(current: selection, in: sidebarRecordingOrder, down: down) else { return false }
        selectSidebarRecording(next)
        sidebarRevealID = next
        return true
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
            && Set([recordingID, startingRecordingID, finalizingRecordingID].compactMap { $0 }).isDisjoint(with: ids)
    }
    /// The confirmation view freezes the IDs; selection may change while it is open.
    func deleteSidebarRecordings(_ ids: Set<String>) async {
        guard let archive, canDeleteSidebarRecordings(ids) else { return }
        deletingSidebarRecordings = true
        beginDeletingRecordings(ids)
        defer {
            deletingSidebarRecordings = false
            finishDeletingRecordings()
        }
        for id in ids.sorted() { await cancel(id) }
        do {
            for manifest in recordings.filter({ ids.contains($0.id) }) {
                try await archive.delete(manifest)
            }
        } catch { errorHandler.report(error) }
        await reload()
    }
    private func beginDeletingRecordings(_ ids: Set<String>) {
        let jobs = Set(ids.map { QueueJobID.recording($0) })
        deletingJobIDs.formUnion(jobs)
        // Cancellation can publish a new snapshot before the files are removed.
        // Discard any in-flight read for the selected recording before that reload.
        if let selection, ids.contains(selection) {
            playback.select(nil)
            resultSignature = ""
        }
        for job in jobs {
            jobAdmission[job, default: 0] &+= 1
            enqueuing.removeValue(forKey: job)
        }
        queued.removeAll { jobs.contains($0) }
    }
    private func finishDeletingRecordings() {
        // The refreshed archive contains any recordings that survived a partial failure.
        let reloadSelectedResult = selected.map { deletingJobIDs.contains(.recording($0.id)) } ?? false
        deletingJobIDs.subtract(recordings.map { QueueJobID.recording($0.id) })
        if reloadSelectedResult { loadResult() }
        Task { await processQueue() }
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
    func revealRecording(_ id: String, whileCapturing: Bool = false) async {
        guard let archive else { return }
        await reload()
        guard !whileCapturing || recordingID == id else { return }
        let groupID = recordingGroups.groupID(for: id)
        do { try await archive.editGroups { try $0.setExpanded(groupID, true) } }
        catch { errorHandler.report(error) }
        await reload()
        guard !whileCapturing || recordingID == id else { return }
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
        defer {
            deletingGroupID = nil
            finishDeletingRecordings()
        }
        do {
            let members = try await archive.prepareGroupDeletion(id)
            if deleteRecordings {
                let protected = Set([recordingID, finalizingRecordingID].compactMap { $0 })
                guard canDeleteRecordings(in: id), protected.isDisjoint(with: members) else {
                    throw ScribeError.message("Сначала остановите запись")
                }
                beginDeletingRecordings(Set(members))
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
    // MARK: - Diagrams

    var diagramProfile: ModelProfile? { readyTaskModel(.diagramRecognition) }
    var diagramModelsReady: Bool { diagramProfile != nil }
    /// Readiness of the anonymization assignment for the section's model link
    /// (AC-7): the selected model with a published verified package.
    /// Worker admission re-checks readiness at dequeue time (work 9).
    var anonymizationModelsReady: Bool {
        readyTaskModel(.anonymization) != nil
    }
    /// The acting byte limit for text import and run admission: the pair
    /// «assigned profile and this Mac» (AC-37). Nil while no profile is
    /// assigned — the import check is then deferred and the file waits with
    /// the model. Worker admission re-measures the run text (work 9). The var
    /// form is the qualification seam of work 13 and the test seam.
    var inputLimits = AnonymizationInputLimit()
    var anonymizationImportLimitBytes: UInt? {
        guard let profile = selectedTaskModel(.anonymization) else { return nil }
        return inputLimits.limitBytes(profile: profile, hardware: hardware)
    }
    func reloadDiagrams() async {
        guard let diagramArchive else { return }
        applyDiagramSnapshot(await diagramArchive.snapshot())
        await diagramSearch.waitForLayout()
    }
    private func applyDiagramSnapshot(_ snapshot: DiagramCoordinator.Snapshot?) {
        guard let snapshot, snapshot.revision >= diagramArchiveRevision, snapshot.revision != diagramArchiveRevision else { return }
        diagramArchiveRevision = snapshot.revision
        diagramGroups = snapshot.groups
        diagrams = snapshot.manifests
        if snapshot.unreadableDiagramIDs != reportedUnreadableDiagramIDs {
            reportedUnreadableDiagramIDs = snapshot.unreadableDiagramIDs
            if !snapshot.unreadableDiagramIDs.isEmpty {
                errorHandler.report(message: "Не удалось прочитать схемы архива: " + snapshot.unreadableDiagramIDs.joined(separator: ", ") + ". Файлы сохранены для восстановления. Проверьте manifest.json в каталогах этих схем.")
            }
        }
        if let error = snapshot.groupsError, error != reportedDiagramGroupsError {
            reportedDiagramGroupsError = error; errorHandler.report(message: error)
        }
    }
    /// Import publishes the manifest first; auto-queueing happens only when the
    /// diagram model is ready, otherwise the item waits with an explicit start.
    func importDiagramImage(at url: URL, groupID: String, allowDuplicate: Bool = false) async throws -> DiagramManifest {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        guard let diagramArchive else { throw ScribeError.message("Хранилище схем недоступно") }
        let manifest = try await diagramArchive.importImage(url, groupID: groupID, allowDuplicate: allowDuplicate)
        if !Task.isCancelled, !shuttingDown, diagramModelsReady, jobAdmission[.diagram(manifest.id)] == nil {
            await enqueueDiagram(manifest.id)
        }
        // Enqueue publishes its own snapshot. Also publish the archived image
        // if there was no model or preparing a run failed.
        if diagram(manifest.id) == nil { await reloadDiagrams() }
        return manifest
    }
    /// Explicit start or retry: a new run is always created; diagram runs never
    /// promise token-level continuation.
    func recognizeDiagram(_ id: String) async {
        let job = QueueJobID.diagram(id)
        guard !shuttingDown, let diagramArchive, !deletingJobIDs.contains(job) else { return }
        guard let profile = diagramProfile else {
            errorHandler.report(message: "Сначала загрузите модель схем в настройках")
            return
        }
        let admission = jobAdmission[job, default: 0]
        do {
            let previous = try await diagramArchive.load(id)
            _ = try await diagramArchive.beginRun(id, profile: profile)
            if previous.pendingRunId != nil || previous.activeRunId != nil || previous.state == .failed {
                setDiagnosticMode(.retry, for: job)
            }
            await reloadDiagrams()
            guard admission == jobAdmission[job, default: 0] else { return }
            await enqueueDiagram(id, allowCancelled: true)
        } catch {
            if admission == jobAdmission[job, default: 0] { errorHandler.report(error) }
        }
    }
    func enqueueDiagram(_ id: String, allowCancelled: Bool = false) async {
        let job = QueueJobID.diagram(id)
        guard let diagramArchive, !deletingJobIDs.contains(job), enqueuing[job] == nil else { return }
        let request = UUID(), generation = queueGeneration
        let pauseReason = queuePauses.values.first
        enqueuing[job] = request
        defer {
            if enqueuing[job] == request { enqueuing.removeValue(forKey: job) }
            if !busy { Task { await processQueue() } }
        }
        let m: DiagramManifest
        do { m = try await diagramArchive.load(id) }
        catch {
            guard enqueuing[job] == request else { return }
            errorHandler.report(message: "Не удалось прочитать схему для распознавания. Файлы сохранены; проверьте архив и повторите попытку.")
            return
        }
        guard allowCancelled || m.state != .cancelled, activeJob != job,
              generation == queueGeneration, !deletingJobIDs.contains(job), enqueuing[job] == request else { return }
        if shuttingDown {
            _ = try? await diagramArchive.update(id) {
                $0.state = .interrupted; $0.lastError = "Приложение закрыто. Можно повторить распознавание."
            }
            await reloadDiagrams(); return
        }
        if let reason = queuePauses.values.first ?? pauseReason {
            _ = try? await diagramArchive.update(id) {
                if $0.state != .cancelled { $0.state = .interrupted }
                $0.lastError = reason
            }
            await reloadDiagrams(); return
        }
        guard m.pendingRunId != nil || diagramProfile != nil else {
            // Without a frozen run and a ready model the item stays outside the FIFO.
            _ = try? await diagramArchive.update(id) { $0.state = .waitingForModels }
            await reloadDiagrams(); return
        }
        if m.pendingRunId == nil, let profile = diagramProfile {
            do { _ = try await diagramArchive.beginRun(id, profile: profile) }
            catch {
                if enqueuing[job] == request { errorHandler.report(error) }
                return
            }
        }
        guard generation == queueGeneration, !deletingJobIDs.contains(job), enqueuing[job] == request else { return }
        if !queued.contains(job) { queued.append(job) }
        _ = try? await diagramArchive.update(id) { $0.state = .queued; $0.lastError = nil }
        await reloadDiagrams()
    }
    func cancelDiagram(_ id: String, onlyPending: Bool = false) async {
        guard let diagramArchive else { return }
        jobAdmission[.diagram(id), default: 0] &+= 1
        enqueuing.removeValue(forKey: .diagram(id))
        queued.removeAll { $0 == .diagram(id) }
        if activeJob == .diagram(id) || processingJob == .diagram(id) {
            suspendingQueue = true; activeJob = nil
            await supervisor.cancel()
            await waitUntilQueueIdle()
            suspendingQueue = false
            Task { await processQueue() }
        }
        _ = try? await diagramArchive.cancel(id, onlyPending: onlyPending)
        await reloadDiagrams()
    }
    /// Deleting first bars re-admission, then waits for exactly its own worker
    /// and readers before removing artifacts — same lifecycle as recordings.
    func deleteDiagrams(_ ids: Set<String>) async {
        guard let diagramArchive, !ids.isEmpty else { return }
        await withDiagramDeletion {
            await cancelDiagramJobsForDeletion(ids)
            try await diagramArchive.delete(ids)
        }
    }
    private func withDiagramDeletion(cancelGroupID: String? = nil, _ operation: () async throws -> Void) async {
        guard !deletingDiagramJobs else {
            errorHandler.report(message: "Дождитесь удаления схем")
            return
        }
        deletingDiagramJobs = true
        defer {
            deletingDiagramJobs = false
            deletingJobIDs.subtract(diagrams.map { QueueJobID.diagram($0.id) })
            Task { await processQueue() }
        }
        do { try await operation() }
        catch {
            // Mirror the recording archive: a failed group deletion unfreezes membership.
            if let cancelGroupID { await diagramArchive?.cancelGroupDeletion(cancelGroupID) }
            errorHandler.report(error)
        }
        await reloadDiagrams()
    }
    private func cancelDiagramJobsForDeletion(_ ids: Set<String>) async {
        let jobs = Set(ids.map(QueueJobID.diagram))
        deletingJobIDs.formUnion(jobs)
        for job in jobs {
            jobAdmission[job, default: 0] &+= 1
            enqueuing.removeValue(forKey: job)
        }
        queued.removeAll { jobs.contains($0) }
        for id in ids.sorted() { await cancelDiagram(id, onlyPending: true) }
    }
    func renameDiagram(_ id: String, title: String) async {
        guard let diagramArchive else { return }
        do {
            _ = try await diagramArchive.rename(id, title: title)
            await reloadDiagrams()
        } catch { errorHandler.report(error) }
    }
    func moveDiagrams(_ ids: Set<String>, to groupID: String) async {
        guard let diagramArchive else { return }
        do {
            try await diagramArchive.moveDiagrams(ids, to: groupID)
            await reloadDiagrams()
        } catch { errorHandler.report(error) }
    }
    func changeDiagramGroups(_ operation: @Sendable (inout RecordingGroups) throws -> Void) async {
        guard let diagramArchive else { return }
        do {
            try await diagramArchive.editGroups(operation)
            await reloadDiagrams()
        } catch { errorHandler.report(error) }
    }
    func deleteDiagramGroup(_ id: String, deleteDiagrams: Bool) async {
        guard let diagramArchive, !deletingDiagramJobs, id != RecordingGroup.ungroupedID else { return }
        if deleteDiagrams {
            await withDiagramDeletion(cancelGroupID: id) {
                let members = try await diagramArchive.prepareGroupDeletion(id)
                await cancelDiagramJobsForDeletion(members)
                try await diagramArchive.finishGroupDeletion(id)
            }
        } else {
            await changeDiagramGroups { try $0.remove(id) }
        }
    }
    func diagramQueuePosition(for id: String) -> Int? {
        queued.firstIndex(of: .diagram(id)).map { $0 + 1 }
    }
    func diagrams(in groupID: String) -> [DiagramManifest] {
        diagrams.filter { diagramGroups.groupID(for: $0.id) == groupID }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }
    func diagram(_ id: String) -> DiagramManifest? { diagramsByID[id] }

    // MARK: - Text anonymization (work 5)

    /// Snapshot application for the text archive. The catalog is bridged into
    /// a RecordingGroups projection for the shared sidebar/search layer; the
    /// coordinator stays the only writer of the real catalog.
    private func applyTextSnapshot(_ snapshot: AnonymizationCoordinator.Snapshot) {
        guard snapshot.revision >= textArchiveRevision, snapshot.revision != textArchiveRevision else { return }
        textArchiveRevision = snapshot.revision
        if let bridged = Self.bridgedTextGroups(from: snapshot.catalog) {
            textGroups = bridged
        } else {
            errorHandler.report(message: "Каталог текстового архива повреждён или создан другой версией приложения")
        }
        textCards = snapshot.cards
        if snapshot.unreadableCardIDs != reportedUnreadableTextIDs {
            reportedUnreadableTextIDs = snapshot.unreadableCardIDs
            if !snapshot.unreadableCardIDs.isEmpty {
                errorHandler.report(message: "Не удалось прочитать тексты архива: " + snapshot.unreadableCardIDs.joined(separator: ", ") + ". Документы сохранены для восстановления. Проверьте card.json в каталогах этих карточек.")
            }
        }
        if let error = snapshot.catalogError, error != reportedTextGroupsError {
            reportedTextGroupsError = error; errorHandler.report(message: error)
        }
    }
    /// Projection of the authoritative text catalog into the shared group
    /// model: group ids are preserved so GUI operations address the real
    /// catalog entities, the system group stays last, and membership of
    /// «Без темы» maps to the shared model's absent-entry form. A healthy
    /// catalog always validates; a failure is reported and keeps the previous
    /// projection instead of replacing it with an empty one.
    private static func bridgedTextGroups(from catalog: AnonymizationArchiveCatalog) -> RecordingGroups? {
        let groups = catalog.groups.map { RecordingGroup(id: $0.id, name: $0.name, expanded: $0.isExpanded) }
        let membership = catalog.membership.filter { $0.value != AnonymizationGroup.systemID }
        return try? RecordingGroups(groups: groups, defaultID: catalog.defaultGroupID, membership: membership)
    }
    func reloadTexts() async {
        guard let textArchive else { return }
        applyTextSnapshot(await textArchive.snapshot())
        await anonymizationSearch.waitForLayout()
    }
    /// Archive renaming of a card's display name (row menu and header); the
    /// in-card editor of work 10 saves through its own draft.
    func renameTextCard(_ id: String, to name: String) async {
        guard let textArchive else { return }
        do {
            try await textArchive.rename(id, to: name)
            await reloadTexts()
        } catch { errorHandler.report(error) }
    }
    func moveTextCards(_ ids: Set<String>, to groupID: String) async {
        guard let textArchive else { return }
        do {
            try await textArchive.moveCards(ids, to: groupID)
            await reloadTexts()
        } catch { errorHandler.report(error) }
    }
    func changeTextGroups(_ operation: @Sendable (inout AnonymizationArchiveCatalog) throws -> Void) async {
        guard let textArchive else { return }
        do {
            try await textArchive.editGroups(operation)
            await reloadTexts()
        } catch { errorHandler.report(error) }
    }
    func textCard(_ id: String) -> AnonymizationCardSummary? { textCardsByID[id] }
    func textCards(in groupID: String) -> [AnonymizationCardSummary] {
        textCards.filter { textGroups.groupID(for: $0.id) == groupID }
    }
    var defaultTextGroup: RecordingGroup { textGroups.defaultGroup }

    // MARK: - Text anonymization queue (work 9)

    func textQueuePosition(for id: String) -> Int? {
        queued.firstIndex(of: .text(id)).map { $0 + 1 }
    }

    /// Admission of one text card into the common FIFO: only a `WAITING_MODEL`
    /// attempt enters, and only while the acting assignment is ready; without
    /// readiness the card stays outside the FIFO in «Ожидает модель» (AC-30).
    /// The FIFO slot is reserved synchronously before the first suspension, so
    /// ordered callers (the readiness wake, the serial import queue) keep their
    /// order even when admission requests interleave; the queue loop never
    /// takes a job with an open admission request. `queueGeneration`, the
    /// per-request `enqueuing` guard and `deletingJobIDs` mirror the
    /// recording/diagram enqueue invariants.
    func enqueueText(_ id: String) async {
        let job = QueueJobID.text(id)
        guard let textArchive, !preparingStorage, !shuttingDown,
              !deletingJobIDs.contains(job), enqueuing[job] == nil, activeJob != job else { return }
        let request = UUID(), generation = queueGeneration
        let pauseReason = queuePauses.values.first
        enqueuing[job] = request
        let reserved = pauseReason == nil && !queued.contains(job)
        if reserved { queued.append(job) }
        var confirmed = false
        defer {
            if enqueuing[job] == request {
                enqueuing.removeValue(forKey: job)
                // An admission that did not confirm the queued state gives the
                // reservation back; a confirmed one simply keeps the slot.
                if reserved && !confirmed { queued.removeAll { $0 == job } }
            }
            if !busy { Task { await processQueue() } }
        }
        let card: AnonymizationCardDocument
        do { card = try await textArchive.loadCard(id) }
        catch {
            errorHandler.report(message: "Не удалось прочитать карточку обезличивания для запуска. Документ сохранён; проверьте архив и повторите попытку.")
            return
        }
        guard card.latestAttempt.state == .waitingModel, activeJob != job,
              generation == queueGeneration, !deletingJobIDs.contains(job), enqueuing[job] == request else { return }
        if (queuePauses.values.first ?? pauseReason) != nil {
            // A sleep/shutdown pause invalidates this admission; the card needs
            // an explicit retry after the pause, exactly like diagram jobs.
            _ = try? await textArchive.updateCard(id) {
                guard $0.latestAttempt.state == .waitingModel else { return }
                $0.latestAttempt.state = .interrupted
            }
            await reloadTexts(); return
        }
        guard let catalog else { return }
        let readiness = await packageRegistry.anonymizationReadiness(
            settings: effectiveAnonymizationSettings, catalog: catalog, hardware: hardware)
        guard generation == queueGeneration, !deletingJobIDs.contains(job), enqueuing[job] == request else { return }
        guard readiness.isReady else {
            // No ready assignment: the card keeps waiting outside the FIFO.
            return
        }
        _ = try? await textArchive.updateCard(id) {
            guard $0.latestAttempt.state == .waitingModel else { return }
            $0.latestAttempt.state = .queued
        }
        guard generation == queueGeneration, !deletingJobIDs.contains(job), enqueuing[job] == request else { return }
        confirmed = true
        await reloadTexts()
    }

    /// Wake-up of waiting cards after a readiness change (installation,
    /// settings save, startup verification): cards enter the FIFO in
    /// `import_order` — `textCards` is already sorted by import position.
    /// The pass is gated by one up-front readiness check: a wake that starts
    /// before the registry publishes the installation never admits a partial
    /// suffix of the waiting cards when readiness flips mid-loop. Single-flight
    /// keeps concurrent readiness changes from interleaving admission loops;
    /// a request arriving mid-run triggers one trailing pass.
    private var wakingTextCards = false
    private var textWakeNeedsRepeat = false
    func wakeWaitingTextCards() async {
        guard !preparingStorage, !shuttingDown, let catalog else { return }
        guard await packageRegistry.anonymizationReadiness(
            settings: effectiveAnonymizationSettings, catalog: catalog, hardware: hardware).isReady else {
            // Nothing can be admitted yet; the next readiness change re-runs the wake.
            return
        }
        guard !wakingTextCards else { textWakeNeedsRepeat = true; return }
        wakingTextCards = true
        defer {
            wakingTextCards = false
            if textWakeNeedsRepeat {
                textWakeNeedsRepeat = false
                Task { await wakeWaitingTextCards() }
            }
        }
        for summary in textCards where summary.attemptState == .waitingModel {
            await enqueueText(summary.id)
        }
    }

    /// One text-anonymization job in the shared worker slot. Admission
    /// re-checks readiness and the byte limit, pins the profile, package,
    /// data types and source version into `input.json` + `RunInput`, holds the
    /// package lease until the worker exits, and publishes the artifact only
    /// for the current running attempt with a matching expected right version.
    private func processTextJob(_ id: String) async throws {
        let job = QueueJobID.text(id)
        guard let repository, let textArchive, let catalog else { throw ScribeError.message("Хранилище текстов недоступно") }
        let card = try await textArchive.loadCard(id)
        let attemptID = card.latestAttempt.id
        processingDiagnostic.reference?.runID = UUID(uuidString: attemptID)
        if processingDiagnostic.mode != .resume,
           card.latestAttempt.isRetry == true || card.latestAttempt.requestedSource != nil || card.latestAttempt.expectedResultRevisionID != nil {
            processingDiagnostic.mode = .retry
        }
        processingDiagnostic.pipeline = AnonymizationAttempt.pipelineVersion
        processingDiagnostic.inputFormat = card.sourceFormat.rawValue
        guard card.latestAttempt.state == .queued else { return }
        // Top-of-queue readiness re-check: a lost assignment returns the
        // attempt to «Ожидает модель» and frees the slot for the next job.
        let settings = effectiveAnonymizationSettings
        let readiness = await packageRegistry.anonymizationReadiness(
            settings: settings, catalog: catalog, hardware: hardware)
        guard activeJob == job else { throw CancellationError() }
        guard readiness.isReady, let profile = readiness.profile, let packageID = readiness.packageID,
              let lease = await packageRegistry.acquireLeaseIfReady(packageID: packageID, profileID: profile.id) else {
            _ = try? await textArchive.updateCard(id) { card in
                guard card.latestAttempt.id == attemptID, card.latestAttempt.state == .queued else { return }
                card.latestAttempt.state = .waitingModel
                // A retry that returns to waiting loses its frozen snapshot;
                // the first start after readiness takes the last saved source.
                card.latestAttempt.requestedSource = nil
            }
            await reloadTexts()
            return
        }
        // The explicit-retry snapshot wins only while it still names the
        // current left version; everything else (first run, retry after
        // waiting, an out-of-band edit) takes the last saved source at
        // admission. The run text is measured in UTF-8 without BOM against
        // the acting limit of «profile and this Mac» (AC-42).
        let source = card.latestAttempt.requestedSource.flatMap { requested in
            requested.id == card.source.id ? requested : nil
        } ?? card.source
        let limit = inputLimits.limitBytes(profile: profile, hardware: hardware)
        let actualBytes = UInt(Data(source.text.utf8).count)
        processingDiagnostic.bytes = actualBytes
        processingDiagnostic.limitBytes = limit
        processingDiagnostic.models = [DiagnosticJob.Model(profile, backend: .mlx)]
        errorHandler.note(.jobStarted, job: processingDiagnostic)
        if actualBytes > limit {
            await packageRegistry.release(lease)
            _ = try? await textArchive.updateCard(id) { card in
                guard card.latestAttempt.id == attemptID, card.latestAttempt.state == .queued else { return }
                card.latestAttempt.state = .failed
                card.latestAttempt.failure = .sizeLimit(actualBytes: actualBytes, limitBytes: limit)
            }
            errorHandler.report(message: "Размер текста превышает предел модели.", operation: .anonymization,
                                job: processingDiagnostic, failure: DiagnosticFailure(.sizeLimit, phase: .admission), show: false)
            await reloadTexts()
            return
        }
        // Freeze the run input off the main actor: profile, verified package,
        // the last saved data-type list and the chosen source version.
        let runInput = RunInput(source: source, profileID: profile.id, packageID: packageID, dataTypes: settings.dataTypes)
        let input = AnonymizationAttemptInput(
            fileId: id, attemptId: attemptID, source: source,
            importedNameStem: card.importedNameStem, sourceFormat: card.sourceFormat,
            dataTypes: settings.dataTypes, profileID: profile.id, packageID: packageID,
            automaticSubstitutions: card.automaticSubstitutions)
        let attemptURL: URL
        do {
            attemptURL = try await textArchive.perform { repository in
                let run = repository.run(id, attemptID)
                try Disk.write(input, to: run.appendingPathComponent(AnonymizationAttemptInput.filename))
                return run
            }
        } catch {
            await packageRegistry.release(lease)
            _ = try? await textArchive.updateCard(id) { card in
                guard card.latestAttempt.id == attemptID, card.latestAttempt.state == .queued else { return }
                card.latestAttempt.state = .failed
                card.latestAttempt.failure = .processing("Не удалось подготовить задание обезличивания")
            }
            if activeJob == job {
                errorHandler.report(error, operation: .anonymization, job: processingDiagnostic,
                                    failure: DiagnosticFailure(.resultWrite, phase: .resultWrite, error: error),
                                    message: "Не удалось подготовить задание обезличивания", show: false)
            }
            await reloadTexts()
            return
        }
        guard activeJob == job else {
            await packageRegistry.release(lease)
            throw CancellationError()
        }
        do {
            _ = try await textArchive.updateCard(id) { card in
                guard card.latestAttempt.id == attemptID, card.latestAttempt.state == .queued else {
                    throw ScribeError.message("Задание обезличивания не является текущим")
                }
                card.latestAttempt.state = .running
                card.latestAttempt.input = runInput
            }
        } catch {
            // The attempt went stale between the input freeze and the RUNNING
            // commit; the lease still has to close before the next job.
            await packageRegistry.release(lease)
            throw error
        }
        await reloadTexts()
        guard activeJob == job else {
            await packageRegistry.release(lease)
            throw CancellationError()
        }
        let command = WorkerCommand(anonymizationJobId: id, runId: attemptID,
                                    anonymizationPath: attemptURL.path,
                                    modelsPath: repository.models.path, toolsPath: tools.path)
        var workerError: Error?
        do {
            try await superviseJob(command) { event in
                // Events are already filtered by kind + jobId + runId by the
                // supervisor; foreign or late attempts cannot reach here.
                if event.type == "progress" { self.showQueueStatus(event.message) }
            }
        } catch { workerError = error }
        // The lease closes exactly when the worker has exited, before any
        // publication or the next job.
        await packageRegistry.release(lease)
        if let workerError { throw workerError }
        guard activeJob == job else { throw CancellationError() }
        processingDiagnostic.phase = .resultValidation
        try await publishAnonymizationResult(cardID: id, attemptID: attemptID,
                                              attemptURL: attemptURL, runInput: runInput)
        await reloadTexts()
    }

    /// Conditional publication of one finished attempt: only the current
    /// `RUNNING` attempt of an existing card whose expected right version still
    /// matches the published one. The artifact is read and validated as a
    /// whole — an incomplete or damaged result is never shown partially — and
    /// `SUCCEEDED` + result + the replenished substitution history commit as
    /// one atomic card transaction. Late, cancelled or stale completions leave
    /// the published result untouched (invariant 6).
    private func publishAnonymizationResult(cardID: String, attemptID: String, attemptURL: URL, runInput: RunInput) async throws {
        guard let textArchive else { return }
        let card = try await textArchive.loadCard(cardID)
        guard card.latestAttempt.id == attemptID, card.latestAttempt.state == .running else { return }
        // The consent to replace the right panel is bound to one version id:
        // a result that appeared or changed meanwhile cannot be replaced by
        // this attempt (AC-17/18).
        let currentRight = card.publishedResult?.text.id
        guard currentRight == card.latestAttempt.expectedResultRevisionID else {
            _ = try? await textArchive.updateCard(cardID) { card in
                guard card.latestAttempt.id == attemptID, card.latestAttempt.state == .running else { return }
                card.latestAttempt.state = .failed
                card.latestAttempt.failure = .processing("Правая версия результата изменилась. Повторите обезличивание заново.")
            }
            if activeJob == .text(cardID) {
                errorHandler.report(message: "Правая версия результата изменилась. Повторите обезличивание заново.",
                                    operation: .anonymization, job: processingDiagnostic,
                                    failure: DiagnosticFailure(.invalidResult, phase: .resultValidation), show: false)
            }
            return
        }
        let artifact: AnonymizationRunArtifact
        do {
            artifact = try await textArchive.perform { _ in
                try Disk.read(AnonymizationRunArtifact.self,
                              at: attemptURL.appendingPathComponent(AnonymizationRunArtifact.filename))
            }
            try artifact.validate(sourceScalarCount: card.source.text.unicodeScalars.count,
                                  importedNameScalarCount: card.importedNameStem.unicodeScalars.count)
            guard artifact.result.input == runInput else {
                throw ScribeError.message("Результат обезличивания не соответствует входу попытки")
            }
        } catch {
            throw ClassifiedDiagnosticError(error, code: .invalidResult, phase: .resultValidation,
                                             fallback: "Не удалось прочитать результат обезличивания")
        }
        processingDiagnostic.phase = .resultWrite
        _ = try await textArchive.updateCard(cardID) { card in
            guard card.latestAttempt.id == attemptID, card.latestAttempt.state == .running else { return }
            card.latestAttempt.state = .succeeded
            card.publishedResult = artifact.result
            card.automaticSubstitutions = artifact.substitutions
        }
    }

    /// Cancellation of exactly one text attempt (`QUEUED` or `RUNNING`): the
    /// supervisor stops the worker and its child processes, the previous
    /// result stays published, and the jobs of the other kinds keep their
    /// order (AC-10).
    func cancelTextCard(_ id: String) async {
        let job = QueueJobID.text(id)
        guard let textArchive else { return }
        jobAdmission[job, default: 0] &+= 1
        enqueuing.removeValue(forKey: job)
        queued.removeAll { $0 == job }
        if activeJob == job || processingJob == job {
            suspendingQueue = true; activeJob = nil
            await supervisor.cancel()
            await waitUntilQueueIdle()
            suspendingQueue = false
            Task { await processQueue() }
        }
        _ = try? await textArchive.updateCard(id) { card in
            guard card.latestAttempt.state == .queued || card.latestAttempt.state == .running else { return }
            card.latestAttempt.state = .cancelled
        }
        await reloadTexts()
    }

    // MARK: - Text anonymization deletion (work 11)

    func canDeleteTextCards(_ ids: Set<String>) -> Bool {
        !ids.isEmpty && !deletingTextJobs
    }

    /// Deletion of confirmed text cards: the frozen confirmation is re-checked
    /// against the live archive, admission of exactly those UUIDs closes
    /// before the first wait, their worker and its child processes stop, and
    /// only then the file removal runs through the coordinator's confirmed
    /// deletion transaction. A partial failure reports the reason and publishes
    /// the actual remainder; the surviving cards keep a cancelled attempt.
    func deleteTextCards(_ ids: Set<String>) async {
        guard let textArchive else { return }
        await withTextDeletion {
            // Another window may have removed some of the confirmed cards
            // since the dialog froze the set.
            let existing = ids.filter { textCardsByID[$0] != nil }
            guard !existing.isEmpty else { return }
            let confirmed = try await textArchive.prepareCardDeletion(Set(existing))
            await cancelTextJobsForDeletion(Set(confirmed))
            try await textArchive.finishCardDeletion()
        }
    }

    /// Group deletion of the text archive. The files variant follows the same
    /// confirmed transaction as card deletion — the workers of the confirmed
    /// membership stop before any folder is removed and a partial failure
    /// keeps the group with the actual remainder. The group-only variant moves
    /// the whole membership to «Без темы» in one catalog write and removes no
    /// files, so it needs no worker stop.
    func deleteTextGroup(_ id: String, deleteFiles: Bool) async {
        guard let textArchive, !deletingTextJobs, id != AnonymizationGroup.systemID else { return }
        guard deleteFiles else {
            await changeTextGroups { try $0.remove(id) }
            return
        }
        await withTextDeletion {
            let members = try await textArchive.prepareGroupDeletion(id)
            await cancelTextJobsForDeletion(members)
            try await textArchive.finishGroupDeletion(id, deleteFiles: true)
        }
    }

    /// Serializes text deletions against the queue and the sidebar: while set,
    /// the queue loop takes no new job and the dialogs refuse a second run.
    /// The refreshed snapshot decides which deleted UUIDs leave the admission
    /// block — survivors of a partial failure become operable again.
    private func withTextDeletion(_ operation: () async throws -> Void) async {
        guard !deletingTextJobs else {
            errorHandler.report(message: "Дождитесь удаления текстов")
            return
        }
        deletingTextJobs = true
        defer {
            deletingTextJobs = false
            deletingJobIDs.subtract(textCards.map { QueueJobID.text($0.id) })
            Task { await processQueue() }
        }
        do { try await operation() }
        catch {
            // Mirror the recording archive: a failed deletion unfreezes the catalog
            // and drops a persisted deletion intention.
            await textArchive?.cancelDeletion()
            errorHandler.report(error)
        }
        await reloadTexts()
    }

    /// Closes admission of the confirmed cards before the first wait and waits
    /// for exactly their own worker and readers — the same lifecycle as the
    /// recording and diagram deletions. Late admissions and publications of
    /// these UUIDs are refused by `deletingJobIDs`/`jobAdmission`; the order
    /// of foreign jobs is untouched.
    private func cancelTextJobsForDeletion(_ ids: Set<String>) async {
        guard let textArchive else { return }
        let jobs = Set(ids.map(QueueJobID.text))
        deletingJobIDs.formUnion(jobs)
        for job in jobs {
            jobAdmission[job, default: 0] &+= 1
            enqueuing.removeValue(forKey: job)
        }
        queued.removeAll { jobs.contains($0) }
        for id in ids.sorted() {
            let job = QueueJobID.text(id)
            if activeJob == job || processingJob == job {
                suspendingQueue = true; activeJob = nil
                await supervisor.cancel()
                await waitUntilQueueIdle()
                suspendingQueue = false
            }
            // A surviving document (a partial failure) must never keep a
            // phantom queued/running attempt after its worker was stopped.
            _ = try? await textArchive.updateCard(id) { card in
                guard card.latestAttempt.state == .queued || card.latestAttempt.state == .running else { return }
                card.latestAttempt.state = .cancelled
            }
        }
    }

    /// Consent state of a retry: replacing a manually edited right version
    /// needs the user's agreement, bound to the current version id (AC-18);
    /// an unedited or absent result retries without a dialog.
    enum AnonymizationRetryConsent {
        case notNeeded
        case needed(currentRevisionID: String)
    }
    func anonymizationRetryConsent(for id: String) async -> AnonymizationRetryConsent {
        guard let textArchive, let card = try? await textArchive.loadCard(id),
              let result = card.publishedResult else { return .notNeeded }
        return result.text.id == result.generatedText.id ? .notNeeded : .needed(currentRevisionID: result.text.id)
    }

    /// Explicit retry (AC-17/18): the command freezes the current left source
    /// and the replaceable right version. With a ready model the attempt goes
    /// straight into the FIFO keeping the snapshot; without one it waits with
    /// the model and the snapshot is dropped — the first start after readiness
    /// takes the last saved source. A failed retry never destroys the previous
    /// result: the old attempt is simply replaced by the new one in the card.
    func retryAnonymization(cardID: String, confirmingResultRevisionID: String? = nil) async {
        let job = QueueJobID.text(cardID)
        guard !preparingStorage, !shuttingDown, let textArchive, let catalog,
              !deletingJobIDs.contains(job) else { return }
        let card: AnonymizationCardDocument
        do { card = try await textArchive.loadCard(cardID) }
        catch { errorHandler.report(error); return }
        guard ![AnonymizationAttemptState.queued, .running].contains(card.latestAttempt.state) else { return }
        let expected: String?
        if let result = card.publishedResult {
            guard result.text.id == result.generatedText.id || confirmingResultRevisionID == result.text.id else {
                errorHandler.report(message: "Согласие на замену не подтверждено для текущей версии результата.")
                return
            }
            expected = result.text.id
        } else { expected = nil }
        let snapshot = card.source
        let readiness = await packageRegistry.anonymizationReadiness(
            settings: effectiveAnonymizationSettings, catalog: catalog, hardware: hardware)
        do {
            _ = try await textArchive.updateCard(cardID) { card in
                card.latestAttempt = AnonymizationAttempt(
                    state: .waitingModel,
                    // The snapshot survives only in a retry that never waits.
                    requestedSource: readiness.isReady ? snapshot : nil,
                    expectedResultRevisionID: expected, isRetry: true)
            }
            await reloadTexts()
            await enqueueText(cardID)
        } catch { errorHandler.report(error) }
    }

    func showAudio() { guard let selected, let repository else { return }; NSWorkspace.shared.activateFileViewerSelecting([repository.folder(selected.id).appendingPathComponent(selected.originalRelativePath)]) }

    var playbackSource: RecordingPlayback.Source? {
        guard let selected, let repository, selected.schemaVersion == 1, selected.sourceComplete,
              (0...Manifest.maximumDurationMs).contains(selected.durationMs), !shuttingDown,
              !deletingJobIDs.contains(.recording(selected.id)) else { return nil }
        return RecordingPlayback.Source(selected, folder: repository.folder(selected.id), tools: tools)
    }

    func isSavingAudio(for id: String) -> Bool {
        id == recordingID || id == finalizingRecordingID
    }

    func activateResultSegment(_ id: String, recordingID: String, from tab: RecordingResultTab) {
        guard selection == recordingID, self.tab == tab, !resultPresentation.isRendering,
              !deletingJobIDs.contains(.recording(recordingID)),
              let segment = transcript?.segments.first(where: { $0.id == id }) else { return }
        let startsPlayback = tab == .summary
        if startsPlayback {
            jumpTo = ResultJumpRequest(segmentID: id)
            self.tab = .transcript
        }
        guard let source = playbackSource else { return }
        playback.select(source)
        playback.updateTranscript(transcript)
        playback.seek(to: Double(segment.startMs) / 1000, play: startsPlayback)
    }
    func rendered(_ part: ExportPart, markdown: Bool = false) async throws -> String {
        try await renderedResult(part, markdown: markdown).text
    }
    func renderedResult(_ part: ExportPart, markdown: Bool = false) async throws -> RenderedExport {
        guard let selected else { throw CancellationError() }
        return try await resultPresentation.render(manifest: selected, transcript: transcript, summary: summary, revision: resultRevision, part: part, markdown: markdown)
    }
    func copy(_ part: ExportPart) {
        copyResult { try await self.rendered(part) }
    }
    func copyResult(to pasteboard: NSPasteboard = .general, _ render: @escaping @MainActor () async throws -> String) {
        copyTask?.cancel()
        copyTask = Task {
            do {
                let text = try await render()
                try Task.checkCancellation()
                guard !shuttingDown else { return }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                status = L10n.message("Скопировано")
            } catch { errorHandler.report(error) }
        }
    }
    func export(markdown: Bool, part: ExportPart) {
        guard let selected else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = selected.displayTitle.replacingOccurrences(of: "/", with: "-") + (markdown ? ".md" : ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveResultExport(to: url) { try await self.rendered(part, markdown: markdown) }
    }
    @discardableResult
    func saveResultExport(to url: URL, render: @escaping @MainActor () async throws -> String) -> Task<Void, Never> {
        let request = UUID()
        let task = Task {
            defer { exportTasks.removeValue(forKey: request) }
            await writeResultExport(to: url, render: render)
        }
        exportTasks[request] = task
        return task
    }
    func export(to url: URL, markdown: Bool, part: ExportPart) async {
        await writeResultExport(to: url) { try await self.rendered(part, markdown: markdown) }
    }
    private func writeResultExport(to url: URL, render: @MainActor () async throws -> String) async {
        do {
            let text = try await render()
            try await Task.detached(priority: .userInitiated) {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }.value
        } catch is CancellationError { }
        catch {
            errorHandler.report(error, operation: .export, failure: DiagnosticFailure(.resultWrite, phase: .resultWrite, error: error),
                                message: L10n.text("Не удалось экспортировать: %1$@", L10n.message(error.localizedDescription)))
        }
    }
    func shutdown() async {
        shuttingDown = true
        await playback.shutdown()
        copyTask?.cancel()
        for task in Array(exportTasks.values) { await task.value }
        recordingSearch.shutdown()
        diagramSearch.shutdown()
        anonymizationSearch.shutdown()
        importQueue.cancel()
        memorySource?.cancel(); memorySource = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }; sleepObserver = nil
        installTask?.cancel(); downloader.close()
        await interruptRecordingStart(warning: "Приложение закрыто.")
        if recordingID != nil { await stopRecording() }
        while savingResult { try? await Task.sleep(for: .milliseconds(50)) }
        while finalizingRecording { try? await Task.sleep(for:.milliseconds(50)) }
        await pause(reason:"Приложение закрыто. Можно продолжить обработку."); supervisor.terminateNow()
        await installTask?.value
        await importQueue.waitUntilIdle()
        for task in Array(warningTasks.values) { await task.value }
        await archive?.flushIndex()
        errorHandler.note(.appStopped)
        _ = await errorHandler.journal.snapshot()
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
        let capture = MicrophoneRecorder(devices: microphoneDevices)
        var reason: String?, lastElapsed = 0.0
        capture.onStopNeeded = { reason = $0 }
        capture.onMeter = { lastElapsed = $0.elapsed }
        do {
            guard await AVCaptureDevice.requestAccess(for:.audio) else { throw ScribeError.message("Доступ к микрофону не разрешён") }
            status = L10n.message("Техническая проверка микрофона: 12 секунд, звук будет удалён")
            let microphone = try microphoneDevices.resolve(.builtIn)
            try await capture.start(folder: captureFolder,
                                    microphone: MicrophoneCaptureRequest(selection: .builtIn, initial: microphone),
                                    systemAudio: false)
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
            let probeProfiles = try ModelRole.audioRoles.map { role in
                guard let profile = catalog.models.first(where: { $0.id == role.rawValue && $0.purpose == role }) else {
                    throw ScribeError.message("Не удалось прочитать закреплённый каталог моделей")
                }
                return profile
            }
            let probeCatalog = ModelCatalog(models: probeProfiles)
            var manifest = Manifest(sourceType:full ? "technical-probe" : "diagnostic",title:"Sandbox probe",filename:full ? "probe.wav" : "original.caf")
            let folder = diagnostics.appendingPathComponent(manifest.id), source = folder.appendingPathComponent(manifest.originalRelativePath)
            try Disk.directory(source.deletingLastPathComponent())
            let modelRoot = full ? folder.appendingPathComponent("models") : repository.models
            if full {
                try Disk.directory(modelRoot); testModels = modelRoot
                let bundledModels = resources.appendingPathComponent("ProbeModels")
                // A separate developer probe bundle supplies read-only public weights. The
                // shipping app never embeds them or gains access to arbitrary external paths.
                for profile in probeProfiles {
                    try await installer.install(profile, root: modelRoot, localSource: bundledModels.appendingPathComponent(profile.id)) { _ in }
                }
                try FileManager.default.copyItem(at:resources.appendingPathComponent("probe.wav"),to:source)
                let audio = try Media.probe(source,tools:tools)
                manifest.durationMs = Int((audio.duration*1000).rounded()); manifest.sampleRate = audio.sampleRate; manifest.channels = audio.channels
            } else {
                // Optional construction failures fall into the outer catch and
                // leave a neutral failed-probe record instead of crashing.
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000),
                      let channels = buffer.floatChannelData else {
                    throw ScribeError.message("Не удалось создать аудиобуфер для технической пробы")
                }
                do { let file = try AVAudioFile(forWriting: source, settings: format.settings); buffer.frameLength = 8000; memset(channels[0],0,8000*4); try file.write(from: buffer) }
                manifest.durationMs = 500; manifest.sampleRate = 16000; manifest.channels = 1
            }
            manifest.sourceComplete = true; manifest.sha256 = try Disk.hash(source)
            let info = RunInfo(sourceHash: manifest.sha256, profileHash: probeCatalog.fingerprint)
            _ = try catalog.pinned(to: info)
            let run = folder.appendingPathComponent("runs/\(info.id)")
            try Disk.write(manifest, to: folder.appendingPathComponent("manifest.json")); try Disk.write(info, to: run.appendingPathComponent("run.json"))
            let stages: [Stage] = full ? [.preparingAudio,.transcribing,.diarizing,.summarizing] : [.preparingAudio]
            for stage in stages {
                let command = WorkerCommand(jobId:manifest.id,runId:info.id,stage:stage,recordingPath:folder.path,modelsPath:modelRoot.path,toolsPath:tools.path)
                try await supervisor.run(command,executable:worker,diagnosticURL:full ? run.appendingPathComponent("\(stage.rawValue).stderr") : nil) { event in
                    events.append(stage.rawValue+":"+event.type)
                    self.status = L10n.message(event.message)
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
