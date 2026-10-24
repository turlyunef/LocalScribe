import Foundation
import Combine
import LocalScribeCore

/// One CPU job and one replaceable pending request. All snapshots are values;
/// no archive, model SDK or UI object crosses the executor boundary.
@MainActor final class RecordingSearch: ObservableObject {
    struct Row: Equatable, Sendable {
        let id: String
        let date: Date
        let group: String
    }
    struct Stamp: Equatable, Sendable {
        let query: UInt64
        let corpus: UInt64
        let layout: UInt64
    }
    struct Request: Sendable {
        let stamp: Stamp
        let titles: [RecordingTitleSearch.Title]
        let rows: [Row]
        let tokens: [RecordingTitleSearch.Token]
        let index: RecordingTitleSearch.Index
        let indexedRevision: UInt64?
        let sortedRows: [Row]
        let sortedRevision: UInt64?
    }
    struct Output: Sendable {
        let stamp: Stamp
        let index: RecordingTitleSearch.Index
        let sortedRows: [Row]
        let normal: [String: [String]]
        let filtered: [String: [String]]
        let matches: Set<String>
    }
    typealias Executor = @Sendable (Request) async throws -> Output
    @Published var query = "" { didSet { changeQuery() } }
    @Published private(set) var active = false
    @Published private(set) var completed = false
    @Published private(set) var normal: [String: [String]] = [:]
    @Published private(set) var filtered: [String: [String]] = [:]
    @Published private(set) var matchingIDs: Set<String> = []
    @Published private var collapsed: Set<String> = []
    private(set) var corpusRevision: UInt64 = 0
    private(set) var queryGeneration: UInt64 = 0
    private var layoutRevision: UInt64 = 0
    private var titles: [RecordingTitleSearch.Title] = []
    private var rows: [Row] = []
    private var tokens: [RecordingTitleSearch.Token] = []
    private var index = RecordingTitleSearch.Index()
    private var indexedRevision: UInt64?
    private var sortedRows: [Row] = []
    private var sortedRevision: UInt64?
    private var running: Task<Output, Error>?
    private var pending = false
    private var stopped = false
    private let executor: Executor
    var onVisibilityChange: (() -> Void)?
    // Numeric instrumentation/test seam; never contains title/query text.
    var onPublication: (() -> Void)?
    private(set) var lastApplyDuration = Duration.zero
    var isRunning: Bool { running != nil || pending }
    var visible: [String: [String]] { active && completed ? filtered : normal }

    init(executor: @escaping Executor = { request in try await RecordingSearch.execute(request) }) { self.executor = executor }
    deinit { running?.cancel() }

    func update(_ manifests: [Manifest], groups: RecordingGroups) {
        guard !stopped else { return }
        let nextTitles = manifests.map { RecordingTitleSearch.Title(id: $0.id, title: $0.displayTitle) }
        let nextRows = manifests.map { Row(id: $0.id, date: $0.createdAt, group: groups.groupID(for: $0.id)) }
        let corpusChanged = titles != nextTitles, layoutChanged = rows != nextRows
        guard corpusChanged || layoutChanged else { return }
        titles = nextTitles; rows = nextRows
        if corpusChanged { corpusRevision &+= 1 }
        if layoutChanged { layoutRevision &+= 1 }
        // Removed IDs must disappear before even an uncooperative old job returns.
        let existing = Set(manifests.map(\.id))
        normal = normal.mapValues { $0.filter { existing.contains($0) } }
        filtered = filtered.mapValues { $0.filter { existing.contains($0) } }
        matchingIDs.formIntersection(existing)
        schedule()
    }
    private func changeQuery() {
        guard !stopped else { return }
        let next = RecordingTitleSearch.tokens(query)
        guard next != tokens else { return }
        tokens = next; queryGeneration &+= 1
        active = !tokens.isEmpty
        collapsed = []
        if !active { completed = false; matchingIDs = []; onVisibilityChange?() }
        schedule()
    }
    func expanded(_ group: RecordingGroup) -> Bool { active ? !collapsed.contains(group.id) : group.expanded }
    func setExpanded(_ id: String, _ expanded: Bool) {
        if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
    }
    func setAllExpanded(_ expanded: Bool) {
        collapsed = expanded ? [] : Set(visible.filter { !$0.value.isEmpty }.map(\.key))
    }
    func shutdown() {
        stopped = true; pending = false; running?.cancel()
        onVisibilityChange = nil; onPublication = nil
    }
    /// Barrier for archive publication/tests. Query changes never wait synchronously.
    func waitUntilIdle() async {
        while let task = running {
            _ = await task.result
            await Task.yield()
        }
    }
    /// Status-only archive updates must never wait for an unrelated query.
    func waitForLayout() async {
        while sortedRevision != layoutRevision, let task = running {
            _ = await task.result
            await Task.yield()
        }
    }
    private var stamp: Stamp { Stamp(query: queryGeneration, corpus: corpusRevision, layout: layoutRevision) }
    private func schedule() {
        pending = true
        running?.cancel()
        launchIfIdle()
    }
    private func launchIfIdle() {
        guard !stopped, running == nil, pending else { return }
        pending = false
        // Clearing uses the prepared ordinary snapshot immediately, with no scan.
        if tokens.isEmpty, indexedRevision == corpusRevision, sortedRevision == layoutRevision { return }
        let request = Request(stamp: stamp, titles: titles, rows: rows, tokens: tokens, index: index,
                              indexedRevision: indexedRevision, sortedRows: sortedRows, sortedRevision: sortedRevision)
        let executor = executor
        let task = Task.detached(priority: .userInitiated) { try await executor(request) }
        running = task
        Task { [weak self] in
            let result = await task.result
            guard let self else { return }
            self.running = nil
            if !self.stopped, case .success(let output) = result { self.accept(output) }
            self.launchIfIdle()
        }
    }
    /// Stamp validation is independent of executor cancellation cooperation.
    func accept(_ output: Output) {
        guard !stopped, output.stamp == stamp else { return }
        let start = ContinuousClock.now
        index = output.index; indexedRevision = corpusRevision
        sortedRows = output.sortedRows; sortedRevision = layoutRevision
        normal = output.normal; filtered = output.filtered; matchingIDs = output.matches
        completed = active
        onVisibilityChange?()
        lastApplyDuration = start.duration(to: .now)
        onPublication?()
    }
    nonisolated static func execute(_ request: Request) async throws -> Output {
        let index = request.indexedRevision == request.stamp.corpus ? request.index :
            try RecordingTitleSearch.Index(titles: request.titles, reusing: request.index)
        try Task.checkCancellation()
        var comparisons = 0
        let sorted = request.sortedRevision == request.stamp.layout ? request.sortedRows : try request.rows.sorted {
            comparisons += 1
            if comparisons & 255 == 0 { try Task.checkCancellation() }
            return $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
        let matches = request.tokens.isEmpty ? Set<String>() : try index.matches(request.tokens)
        var normal: [String: [String]] = [:], filtered: [String: [String]] = [:]
        for row in sorted {
            try Task.checkCancellation()
            normal[row.group, default: []].append(row.id)
            if matches.contains(row.id) { filtered[row.group, default: []].append(row.id) }
        }
        try Task.checkCancellation()
        return Output(stamp: request.stamp, index: index, sortedRows: sorted, normal: normal, filtered: filtered, matches: matches)
    }
}
