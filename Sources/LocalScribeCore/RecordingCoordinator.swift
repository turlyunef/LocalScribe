import Foundation

/// The GUI's single archive owner. Synchronous transactions on this actor never
/// suspend between reading and publishing a manifest, and never run on MainActor.
public actor RecordingCoordinator {
    public struct Snapshot: Sendable {
        public let revision: UInt64
        public let manifests: [Manifest]
    }
    private let repository: RecordingRepository
    private var manifests: [Manifest] = []
    private var positions: [String: Int] = [:]
    private var initialized = false
    private var revision: UInt64 = 0
    private var indexDirty = false
    private var indexTask: Task<Void, Never>?
    private var indexGeneration: UInt64 = 0
    private let indexDelay: Duration

    public init(repository: RecordingRepository, indexDelay: Duration = .milliseconds(250)) {
        self.repository = repository; self.indexDelay = indexDelay
    }

    public func snapshot() -> Snapshot {
        initialize()
        return Snapshot(revision: revision, manifests: manifests)
    }
    public func recover() throws -> Snapshot {
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
        if !initialized { replace(repository.list()) }
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
    public func importFile(_ source: URL, tools: URL, allowDuplicate: Bool = false) throws -> Manifest {
        initialize()
        let info = try Media.probe(source, tools: tools)
        let manifest = try repository.importFile(source, info: info, allowDuplicate: allowDuplicate)
        publish(manifest)
        return manifest
    }
    public func delete(_ manifest: Manifest) throws {
        initialize()
        try repository.delete(manifest)
        replace(manifests.filter { $0.id != manifest.id })
        scheduleIndex()
        // Avoid retaining deleted metadata even during the coalescing interval.
        flushIndex()
    }
    /// File-only work shares the same serial executor as manifest transactions.
    public func perform<T: Sendable>(_ operation: @Sendable (RecordingRepository) throws -> T) rethrows -> T {
        try operation(repository)
    }
}
