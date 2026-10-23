import Foundation

/// The GUI's single archive owner. Synchronous transactions on this actor never
/// suspend between reading and publishing a manifest, and never run on MainActor.
public actor RecordingCoordinator {
    public struct Snapshot: Sendable {
        public let revision: UInt64
        public let manifests: [Manifest]
        public let groups: RecordingGroups
        public let groupsError: String?
    }
    private let repository: RecordingRepository
    private var manifests: [Manifest] = []
    private var positions: [String: Int] = [:]
    private var initialized = false
    private var groupsInitialized = false
    private var groups = RecordingGroups()
    private var groupsError: String?
    private var deletingGroups: Set<String> = []
    private let removeRecording: @Sendable (RecordingRepository, Manifest) throws -> Void
    private var revision: UInt64 = 0
    private var indexDirty = false
    private var indexTask: Task<Void, Never>?
    private var indexGeneration: UInt64 = 0
    private let indexDelay: Duration
    private let importProbe: @Sendable (URL, URL) throws -> AudioInfo

    public init(repository: RecordingRepository, indexDelay: Duration = .milliseconds(250),
                removeRecording: @escaping @Sendable (RecordingRepository, Manifest) throws -> Void = { try $0.delete($1) },
                importProbe: @escaping @Sendable (URL, URL) throws -> AudioInfo = { try Media.probe($0, tools: $1, cancellable: true) }) {
        self.repository = repository; self.indexDelay = indexDelay
        self.importProbe = importProbe
        self.removeRecording = removeRecording
    }

    public func snapshot() -> Snapshot {
        initialize()
        return Snapshot(revision: revision, manifests: manifests, groups: groups, groupsError: groupsError)
    }
    public func recover() throws -> Snapshot {
        initializeGroups()
        cancelIndexTask()
        do { replace(try repository.recover()) }
        catch {
            // A failed batch may already have committed some manifests.
            replace(repository.list())
            scheduleIndex()
            throw error
        }
        indexDirty = false
        return snapshot()
    }
    private func initialize() {
        initializeGroups()
        if !initialized { replace(repository.list()) }
    }
    private func initializeGroups() {
        guard !groupsInitialized else { return }
        do { groups = try repository.loadGroups() }
        catch { groupsError = "Не удалось прочитать группы: \(error.localizedDescription)" }
        groupsInitialized = true
    }
    private func replace(_ values: [Manifest]) {
        manifests = values
        positions = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.element.id, $0.offset) })
        initialized = true; revision &+= 1
    }
    private func publish(_ manifest: Manifest) {
        if let position = positions[manifest.id] {
            manifests[position] = manifest
            revision &+= 1
        } else {
            replace((manifests + [manifest]).sorted { $0.createdAt > $1.createdAt })
        }
        scheduleIndex()
    }
    private func scheduleIndex() {
        indexDirty = true
        guard indexTask == nil else { return }
        let delay = indexDelay, generation = indexGeneration
        indexTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.flushScheduledIndex(generation: generation)
        }
    }
    private func flushScheduledIndex(generation: UInt64) {
        guard generation == indexGeneration else { return }
        flushIndex()
    }
    private func cancelIndexTask() {
        indexGeneration &+= 1
        indexTask?.cancel(); indexTask = nil
    }
    /// Best effort: persistence has already succeeded at the manifest boundary.
    /// Also used as a barrier during shutdown and by deterministic callers/tests.
    public func flushIndex() {
        cancelIndexTask()
        guard indexDirty else { return }
        do { try repository.writeIndex(manifests); indexDirty = false } catch { }
    }
    public func load(_ id: String) throws -> Manifest { try repository.load(id) }
    /// Explicit refresh for a known external change; ordinary UI reloads use the snapshot.
    @discardableResult public func refresh(_ id: String) throws -> Manifest {
        initialize()
        let manifest = try repository.load(id)
        publish(manifest)
        return manifest
    }
    public func save(_ manifest: Manifest) throws {
        initialize()
        try repository.save(manifest)
        publish(manifest)
    }
    @discardableResult public func update(_ id: String, _ change: @Sendable (inout Manifest) -> Void) throws -> Manifest {
        initialize()
        var manifest = try repository.load(id)
        change(&manifest)
        guard manifest.id == id else { throw ScribeError.message("Нельзя изменить идентификатор записи") }
        try repository.save(manifest)
        publish(manifest)
        return manifest
    }
    public func rename(_ id: String, title: String) throws {
        initialize()
        try repository.rename(id, title: title)
        publish(try repository.load(id))
    }
    public func beginRun(_ id: String, catalog: ModelCatalog, summaryLanguage: String? = nil,
                         summaryOnly: Bool = false, liveCapture: Bool = false) throws -> Manifest {
        initialize()
        var manifest = try repository.load(id)
        _ = try repository.beginRun(&manifest, catalog: catalog, summaryLanguage: summaryLanguage,
                                    summaryOnly: summaryOnly, liveCapture: liveCapture)
        publish(manifest)
        return manifest
    }
    public func saveResultEdits(_ draft: ResultEditDraft) throws {
        initialize()
        publish(try repository.saveResultEdits(draft))
    }
    public func importFile(_ source: URL, tools: URL, allowDuplicate: Bool = false, groupID: String = RecordingGroup.ungroupedID) throws -> Manifest {
        try Task.checkCancellation()
        initialize()
        let info = try importProbe(source, tools)
        let manifest = try repository.importFile(source, info: info, allowDuplicate: allowDuplicate) { manifest in
            try reserveDestination(manifest.id, groupID: groupID)
        }
        publish(manifest)
        return manifest
    }
    public func delete(_ manifest: Manifest) throws {
        initialize()
        do { try removeRecording(repository, manifest) }
        catch {
            // Removal may have made progress before failing. Re-read the source
            // of truth instead of publishing an already removed manifest again.
            replace(repository.list())
            scheduleIndex(); flushIndex()
            throw error
        }
        replace(manifests.filter { $0.id != manifest.id })
        scheduleIndex()
        // Avoid retaining deleted metadata even during the coalescing interval.
        flushIndex()
    }
    private func requireGroups() throws {
        initialize()
        if let groupsError { throw ScribeError.message(groupsError) }
    }
    private func commitGroups(_ value: RecordingGroups) throws {
        try repository.saveGroups(value)
        groups = value; revision &+= 1
    }
    public func editGroups(_ change: @Sendable (inout RecordingGroups) throws -> Void) throws {
        try requireGroups()
        guard deletingGroups.isEmpty else { throw ScribeError.message("Дождитесь удаления группы") }
        var next = groups
        try change(&next)
        if next != groups { try commitGroups(next) }
    }
    /// Called before publishing a new manifest. A failed manifest write can leave
    /// an unused UUID reservation; it never creates a visible recording.
    private func reserveDestination(_ recordingID: String, groupID: String) throws {
        try requireGroups()
        guard !deletingGroups.contains(groupID) else { throw ScribeError.message("Группа удаляется. Повторите добавление после удаления.") }
        // A destination removed while microphone permission/provider loading was
        // pending resolves to the system group, never to a newly chosen default.
        let target = groups.groups.contains { $0.id == groupID } ? groupID : RecordingGroup.ungroupedID
        var next = groups
        try next.assign(recordingID, to: target)
        if next != groups { try commitGroups(next) }
    }
    public func createRecording(_ manifest: Manifest, groupID: String) throws {
        initialize()
        guard !manifests.contains(where: { $0.id == manifest.id }) else { throw ScribeError.message("Запись уже существует") }
        try reserveDestination(manifest.id, groupID: groupID)
        try repository.save(manifest)
        publish(manifest)
    }
    public func moveRecording(_ id: String, to groupID: String) throws {
        try requireGroups()
        guard !deletingGroups.contains(groups.groupID(for: id)), !deletingGroups.contains(groupID) else {
            throw ScribeError.message("Дождитесь удаления группы")
        }
        _ = try repository.load(id)
        var next = groups
        try next.assign(id, to: groupID)
        if next != groups { try commitGroups(next) }
    }
    /// Freeze membership while the GUI cancels just these jobs and joins worker.
    public func prepareGroupDeletion(_ id: String) throws -> [String] {
        try requireGroups()
        guard deletingGroups.isEmpty, id != RecordingGroup.ungroupedID, groups.groups.contains(where: { $0.id == id }) else {
            throw ScribeError.message("Нельзя удалить эту группу сейчас")
        }
        deletingGroups.insert(id)
        return manifests.filter { groups.groupID(for: $0.id) == id }.map(\.id)
    }
    public func cancelGroupDeletion(_ id: String) { deletingGroups.remove(id) }
    /// No suspension between deletions and publication. If a member fails, retain
    /// the group and publish only the deletions that actually succeeded.
    public func finishGroupDeletion(_ id: String, deleteRecordings: Bool) throws {
        try requireGroups()
        guard deletingGroups.contains(id) else { throw ScribeError.message("Удаление группы не подготовлено") }
        defer { deletingGroups.remove(id) }
        if deleteRecordings {
            let members = manifests.filter { groups.groupID(for: $0.id) == id }
            for manifest in members { try delete(manifest) }
            // Do not silently discard membership of damaged archive entries.
            let known = Set(members.map(\.id))
            for (recordingID, groupID) in groups.membership where groupID == id && !known.contains(recordingID) {
                if FileManager.default.fileExists(atPath: repository.folder(recordingID).path) {
                    throw ScribeError.message("В группе есть повреждённая запись. Группа сохранена; проверьте архив.")
                }
            }
        }
        var next = groups
        try next.remove(id)
        try commitGroups(next)
    }
    /// File-only work shares the same serial executor as manifest transactions.
    public func perform<T: Sendable>(_ operation: @Sendable (RecordingRepository) throws -> T) rethrows -> T {
        try operation(repository)
    }
}
