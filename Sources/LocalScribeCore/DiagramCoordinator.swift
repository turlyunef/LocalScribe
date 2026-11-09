import Foundation

/// The single owner of diagram archive transactions. Synchronous transactions
/// on this actor never suspend between reading and publishing a manifest, and
/// never run on MainActor. Waiting for model availability is not this actor's
/// job: it only stores state.
public actor DiagramCoordinator {
    public struct Snapshot: Sendable {
        public let revision: UInt64
        public let manifests: [DiagramManifest]
        public let groups: RecordingGroups
        public let groupsError: String?
        public let unreadableDiagramIDs: [String]
    }
    private let repository: DiagramRepository
    private let removeItem: @Sendable (DiagramRepository, String) throws -> Void
    private var manifests: [DiagramManifest] = []
    private var positions: [String: Int] = [:]
    private var initialized = false
    private var groupsInitialized = false
    private var groups = RecordingGroups()
    private var groupsError: String?
    private var groupDeletion: (id: String, members: Set<String>)?
    private var unreadableDiagramIDs: [String] = []
    private var revision: UInt64 = 0

    public init(repository: DiagramRepository,
                removeItem: @escaping @Sendable (DiagramRepository, String) throws -> Void = { try $0.delete($1) }) {
        self.repository = repository
        self.removeItem = removeItem
    }

    public func snapshot() -> Snapshot {
        initialize()
        return Snapshot(revision: revision, manifests: manifests, groups: groups,
                        groupsError: groupsError, unreadableDiagramIDs: unreadableDiagramIDs)
    }

    /// One pass over the archive: groups through the neutral URL reader, then
    /// items. A corrupted groups catalog is never overwritten; it blocks group
    /// changes until it is repaired manually.
    public func recover() throws -> Snapshot {
        initializeGroups()
        do {
            var invalid: [String] = []
            let recovered = try repository.recover(reportInvalid: { invalid.append($0) })
            unreadableDiagramIDs = invalid.sorted()
            replace(recovered)
            try pruneDeletedMembership()
        } catch {
            // A failed batch may already have committed some manifests.
            replace(readListing())
            throw error
        }
        return snapshot()
    }

    // MARK: - Items

    public func load(_ id: String) throws -> DiagramManifest { try repository.load(id) }

    /// Explicit refresh for a known external change; ordinary UI reloads use the snapshot.
    @discardableResult public func refresh(_ id: String) throws -> DiagramManifest {
        initialize()
        let manifest = try repository.load(id)
        publish(manifest)
        return manifest
    }

    public func save(_ manifest: DiagramManifest) throws {
        initialize()
        try repository.save(manifest)
        publish(manifest)
    }

    @discardableResult public func update(_ id: String, _ change: @Sendable (inout DiagramManifest) throws -> Void) throws -> DiagramManifest {
        initialize()
        var manifest = try repository.load(id)
        try change(&manifest)
        guard manifest.id == id else { throw ScribeError.message("Нельзя изменить идентификатор схемы") }
        try repository.save(manifest)
        publish(manifest)
        return manifest
    }

    /// Import transaction: verified copy, then the group reservation hook
    /// (a vanished destination resolves to «Без темы», never to a new default),
    /// then the manifest publication.
    @discardableResult public func importImage(_ source: URL, groupID: String = RecordingGroup.ungroupedID,
                                               allowDuplicate: Bool = false) throws -> DiagramManifest {
        try Task.checkCancellation()
        try requireGroups()
        let manifest = try repository.importImage(at: source, existingDiagrams: allowDuplicate ? nil : manifests) { manifest in
            try reserveDestination(manifest.id, groupID: groupID)
        }
        publish(manifest)
        return manifest
    }

    public func rename(_ id: String, title: String) throws {
        initialize()
        try repository.rename(id, title: title)
        publish(try repository.load(id))
    }

    /// Publish what actually remains, whether or not a removal failed.
    public func delete(_ ids: Set<String>) throws {
        initialize()
        var firstFailure: (any Error)?
        for id in ids.sorted() {
            do { try removeItem(repository, id) }
            catch { firstFailure = error; break }
        }
        replace(readListing())
        if let firstFailure { throw firstFailure }
    }

    // MARK: - Runs

    @discardableResult public func beginRun(_ id: String, profile: ModelProfile) throws -> DiagramManifest {
        initialize()
        var manifest = try repository.load(id)
        _ = try repository.beginRun(&manifest, profile: profile)
        publish(manifest)
        return manifest
    }

    public func resumeRun(_ id: String) throws -> DiagramRunInfo {
        initialize()
        return try repository.resumeRun(try repository.load(id))
    }

    /// Switch activeRunId only after the published result passes full
    /// validation. A validation error keeps the previous active run and the
    /// pending run untouched.
    @discardableResult public func completeRun(_ id: String, runId: String, warnings: [String] = []) throws -> DiagramManifest {
        initialize()
        var manifest = try repository.load(id)
        // The finished run must still be the pending one: a stale worker event
        // cannot replace a newer job. A cancellation that landed before the
        // completed event must never be overwritten by a late publication.
        guard manifest.pendingRunId == runId else { throw ScribeError.message("Задание схемы не является текущим") }
        guard manifest.state != .cancelled else { throw ScribeError.message("Схема уже отменена; результат не публикуется") }
        _ = try repository.results(id, runId: runId)
        manifest.activeRunId = runId
        manifest.pendingRunId = nil
        manifest.state = warnings.isEmpty ? .completed : .completedWithWarnings
        manifest.warnings = warnings
        manifest.lastError = nil
        try repository.save(manifest)
        publish(manifest)
        return manifest
    }

    /// A failed retry never destroys the previous result: both the active run
    /// and the pending run stay referenceable.
    @discardableResult public func failRun(_ id: String, message: String) throws -> DiagramManifest {
        initialize()
        var manifest = try repository.load(id)
        manifest.state = .failed
        manifest.lastError = message
        try repository.save(manifest)
        publish(manifest)
        return manifest
    }

    /// Cancellation keeps pendingRunId as is: a retry always creates a new run.
    @discardableResult public func cancel(_ id: String, onlyPending: Bool = false) throws -> DiagramManifest {
        initialize()
        var manifest = try repository.load(id)
        guard !onlyPending || manifest.state.processing || manifest.state == .queued else { return manifest }
        manifest.state = .cancelled
        try repository.save(manifest)
        publish(manifest)
        return manifest
    }

    // MARK: - Groups

    public func editGroups(_ change: @Sendable (inout RecordingGroups) throws -> Void) throws {
        try requireGroups()
        guard groupDeletion == nil else { throw ScribeError.message("Дождитесь удаления группы схем") }
        var next = groups
        try change(&next)
        // An unchanged catalog (including a no-op setAllExpanded) is not written.
        if next != groups { try commitGroups(next) }
    }

    /// Validate the entire batch before one atomic catalog publication.
    public func moveDiagrams(_ ids: Set<String>, to groupID: String) throws {
        try requireGroups()
        if let deletion = groupDeletion, deletion.id == groupID || !deletion.members.isDisjoint(with: ids) {
            throw ScribeError.message("Дождитесь удаления группы схем")
        }
        var next = groups
        for id in ids.sorted() {
            _ = try repository.load(id)
            try next.assign(id, to: groupID)
        }
        if next != groups { try commitGroups(next) }
    }

    /// Freeze membership before the UI cancels the group's jobs.
    public func prepareGroupDeletion(_ id: String) throws -> Set<String> {
        try requireGroups()
        guard groupDeletion == nil, groups.groups.contains(where: { $0.id == id && !$0.isSystem }) else {
            throw ScribeError.message("Нельзя удалить эту группу схем сейчас")
        }
        let members = Set(groups.membership.compactMap { $0.value == id ? $0.key : nil })
        groupDeletion = (id, members)
        return members
    }

    public func finishGroupDeletion(_ id: String) throws {
        guard let deletion = groupDeletion, deletion.id == id else {
            throw ScribeError.message("Удаление группы схем не подготовлено")
        }
        defer { groupDeletion = nil }
        var next = groups
        try next.remove(id)
        // Skip stale assignments to missing items. Preserve damaged or
        // inaccessible items and their group.
        var files: Set<String> = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let damaged = ScribeError.message("В группе есть повреждённая или недоступная схема. Группа сохранена.")
        do {
            for member in deletion.members {
                let values: URLResourceValues
                do { values = try repository.folder(member).resourceValues(forKeys: keys) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw damaged
                }
                try DiagramRepository.validate(repository.load(member))
                files.insert(member)
            }
        } catch {
            replace(readListing())
            throw damaged
        }
        try delete(files)
        try commitGroups(next)
    }

    /// File-only work shares the same serial executor as manifest transactions.
    public func perform<T: Sendable>(_ operation: @Sendable (DiagramRepository) throws -> T) rethrows -> T {
        try operation(repository)
    }

    // MARK: - Private

    private func initialize() {
        initializeGroups()
        if !initialized { replace(readListing()) }
    }
    private func readListing() -> [DiagramManifest] {
        var invalid: [String] = []
        let values = repository.list(reportInvalid: { invalid.append($0) })
        unreadableDiagramIDs = invalid.sorted()
        return values
    }
    private func initializeGroups() {
        guard !groupsInitialized else { return }
        do { groups = try RecordingGroups.loadCatalog(at: repository.groupsURL) }
        catch { groupsError = "Не удалось прочитать группы: \(error.localizedDescription)" }
        groupsInitialized = true
    }
    private func replace(_ values: [DiagramManifest]) {
        manifests = values
        positions = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.element.id, $0.offset) })
        initialized = true; revision &+= 1
    }
    private func publish(_ manifest: DiagramManifest) {
        unreadableDiagramIDs.removeAll { $0 == manifest.id }
        if let position = positions[manifest.id] {
            manifests[position] = manifest
            revision &+= 1
        } else {
            replace((manifests + [manifest]).sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
            })
        }
    }
    private func requireGroups() throws {
        initialize()
        if let groupsError { throw ScribeError.message(groupsError) }
    }
    private func commitGroups(_ value: RecordingGroups) throws {
        try RecordingGroups.writeCatalog(value, at: repository.groupsURL)
        groups = value; revision &+= 1
    }
    /// Called before publishing a new manifest: a destination removed while the
    /// provider was loading resolves to the system group, never to a new default.
    private func reserveDestination(_ diagramID: String, groupID: String) throws {
        try requireGroups()
        let available = groupDeletion?.id != groupID && groups.groups.contains { $0.id == groupID }
        let target = available ? groupID : RecordingGroup.ungroupedID
        var next = groups
        try next.assign(diagramID, to: target)
        if next != groups { try commitGroups(next) }
    }
    /// Prune membership only for items whose archive directory is confirmed
    /// absent. Damaged or inaccessible directories keep their assignment.
    private func pruneDeletedMembership() throws {
        guard groupsError == nil else { return }
        var next = groups
        for id in groups.membership.keys where positions[id] == nil {
            do {
                _ = try repository.folder(id).resourceValues(forKeys: [.isDirectoryKey])
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                try next.assign(id, to: RecordingGroup.ungroupedID)
            } catch { continue }
        }
        if next != groups { try commitGroups(next) }
    }
}
