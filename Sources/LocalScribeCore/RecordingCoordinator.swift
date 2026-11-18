import Foundation
import os

/// The GUI's single archive owner. Synchronous transactions on this actor never
/// suspend between reading and publishing a manifest, and never run on MainActor.
public actor RecordingCoordinator {
    private static let logger = Logger(subsystem: "local.localscribe.mac", category: "recording-coordinator")
    public struct Snapshot: Sendable {
        public let revision: UInt64
        public let manifests: [Manifest]
        public let groups: RecordingGroups
        public let groupsError: String?
        public let unreadableRecordingIDs: [String]
        /// Non-nil when the recordings directory exists but cannot be read: the
        /// archive is not empty on disk and the previous index stays untouched.
        public let archiveError: String?
    }
    private let repository: RecordingRepository
    private var manifests: [Manifest] = []
    private var positions: [String: Int] = [:]
    private var initialized = false
    private var groupsInitialized = false
    private var groups = RecordingGroups()
    private var groupsError: String?
    private var unreadableRecordingIDs: [String] = []
    private var archiveError: String?
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
        return Snapshot(revision: revision, manifests: manifests, groups: groups, groupsError: groupsError,
                        unreadableRecordingIDs: unreadableRecordingIDs, archiveError: archiveError)
    }
    public func recover() throws -> Snapshot {
        initializeGroups()
        cancelIndexTask()
        do {
            var invalid: [String] = []
            var unreadable: Error?
            let recovered = try repository.recover(reportInvalid: { invalid.append($0) },
                                                   reportUnreadable: { unreadable = $0 })
            unreadableRecordingIDs = invalid.sorted()
            archiveError = unreadable.map(Self.listingFailureMessage)
            replace(recovered)
            // Membership pruning relies on a complete listing.
            if archiveError == nil { try pruneDeletedMembership() }
        }
        catch {
            // A failed batch may already have committed some manifests.
            replace(readListing())
            if archiveError == nil { scheduleIndex() }
            throw error
        }
        indexDirty = false
        return snapshot()
    }
    private func initialize() {
        initializeGroups()
        if !initialized { replace(readListing()) }
    }
    private func readListing() -> [Manifest] {
        var invalid: [String] = []
        var unreadable: Error?
        let values = repository.list(reportInvalid: { invalid.append($0) }, reportUnreadable: { unreadable = $0 })
        unreadableRecordingIDs = invalid.sorted()
        archiveError = unreadable.map(Self.listingFailureMessage)
        return values
    }
    /// The user-facing explanation for an existing but unreadable recordings
    /// directory, mirroring the groups error reporting.
    private static func listingFailureMessage(_ error: Error) -> String {
        "Не удалось прочитать каталог записей: \(error.localizedDescription). Архив не изменялся; проверьте права доступа к папке recordings."
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
        unreadableRecordingIDs.removeAll { $0 == manifest.id }
        if let position = positions[manifest.id] {
            manifests[position] = manifest
            revision &+= 1
        } else {
            replace((manifests + [manifest]).sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
            })
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
        // Never overwrite the derived index with the empty listing of an
        // unreadable archive; the previous index stays until it is readable.
        guard indexDirty, archiveError == nil else { return }
        do { try repository.writeIndex(manifests); indexDirty = false }
        catch {
            // The index stays dirty and is rewritten on the next flush.
            Self.logger.error("Could not persist recording index: \(error.localizedDescription, privacy: .private)")
        }
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
    public func appendWarning(_ warning: String, to id: String) throws -> Bool {
        initialize()
        var manifest = try repository.load(id)
        guard !manifest.warnings.contains(warning) else { return false }
        manifest.warnings.append(warning)
        try repository.save(manifest)
        publish(manifest)
        return true
    }
    public func rename(_ id: String, title: String) throws {
        initialize()
        try repository.rename(id, title: title)
        publish(try repository.load(id))
    }
    public func beginRun(_ id: String, catalog: ModelCatalog, summaryLanguage: String? = nil,
                         summaryOnly: Bool = false, liveCapture: Bool = false, recognitionTerms: [String]? = nil) throws -> Manifest {
        initialize()
        var manifest = try repository.load(id)
        _ = try repository.beginRun(&manifest, catalog: catalog, summaryLanguage: summaryLanguage,
                                    summaryOnly: summaryOnly, liveCapture: liveCapture, recognitionTerms: recognitionTerms)
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
        let manifest = try repository.importFile(source, info: info, allowDuplicate: allowDuplicate, existingRecordings: manifests,
                                                 verifyAudio: { [importProbe] in try importProbe($0, tools) }) { manifest in
            try reserveDestination(manifest.id, groupID: groupID)
        }
        publish(manifest)
        return manifest
    }
    public func delete(_ manifest: Manifest) throws {
        try delete(manifest, immediatelyFlushIndex: true)
    }
    private func delete(_ manifest: Manifest, immediatelyFlushIndex: Bool) throws {
        initialize()
        defer { if immediatelyFlushIndex { flushIndex() } }
        do { try removeRecording(repository, manifest) }
        catch {
            // Removal may have made progress before failing. Re-read the source
            // of truth instead of publishing an already removed manifest again.
            replace(readListing())
            if archiveError == nil { scheduleIndex() }
            throw error
        }
        replace(manifests.filter { $0.id != manifest.id })
        scheduleIndex()
        // Single deletion flushes on exit; group deletion flushes once per batch.
    }
    private func pruneDeletedMembership() throws {
        guard groupsError == nil, deletingGroups.isEmpty else { return }
        var next = groups
        for id in groups.membership.keys where positions[id] == nil {
            do {
                // A damaged or inaccessible directory must retain its assignment.
                _ = try repository.folder(id).resourceValues(forKeys: [.isDirectoryKey])
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                try next.assign(id, to: RecordingGroup.ungroupedID)
            } catch { continue }
        }
        if next != groups { try commitGroups(next) }
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
        try moveRecordings([id], to: groupID)
    }
    /// Validate the entire batch before one atomic catalog publication.
    public func moveRecordings(_ ids: Set<String>, to groupID: String) throws {
        try requireGroups()
        guard !deletingGroups.contains(groupID), ids.allSatisfy({ !deletingGroups.contains(groups.groupID(for: $0)) }) else {
            throw ScribeError.message("Дождитесь удаления группы")
        }
        var next = groups
        for id in ids.sorted() {
            _ = try repository.load(id)
            try next.assign(id, to: groupID)
        }
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
    /// Validate the whole membership first: one damaged entry keeps the group
    /// and every healthy recording. No suspension between deletions and
    /// publication. If an I/O removal fails mid-batch, retain the group and
    /// publish only the deletions that actually succeeded.
    public func finishGroupDeletion(_ id: String, deleteRecordings: Bool) throws {
        try requireGroups()
        guard deletingGroups.contains(id) else { throw ScribeError.message("Удаление группы не подготовлено") }
        defer { deletingGroups.remove(id) }
        if deleteRecordings {
            let members = manifests.filter { groups.groupID(for: $0.id) == id }
            // Do not silently discard membership of damaged archive entries.
            // Validate before removing anything: a damaged member aborts the
            // whole batch with the group and its recordings fully intact.
            let known = Set(members.map(\.id))
            for (recordingID, groupID) in groups.membership where groupID == id && !known.contains(recordingID) {
                if FileManager.default.fileExists(atPath: repository.folder(recordingID).path) {
                    throw ScribeError.message("В группе есть повреждённая запись. Группа сохранена; проверьте архив.")
                }
            }
            // Also flush partial progress if any removal fails mid-batch.
            defer { flushIndex() }
            for manifest in members { try delete(manifest, immediatelyFlushIndex: false) }
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
