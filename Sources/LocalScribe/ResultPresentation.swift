import SwiftUI
import LocalScribeCore

/// Frequent capture/progress changes are observed only by the indicator views.
@MainActor final class ActivityIndicators: ObservableObject {
    @Published var status = ""
    @Published var elapsed = 0.0
    @Published var level = 0.0
    @Published var soundNotice: String?
}

/// A bounded cache for the selected result. Keys compare only small metadata and
/// explicit content revisions, never the text/segment arrays on a view update.
@MainActor final class ResultPresentation: ObservableObject {
    typealias Renderer = @Sendable (Manifest, Transcript?, Summary?, ExportPart, Bool) -> RenderedExport
    private struct ContentKey: Hashable {
        let recordingID: String
        let revision: UInt64
        let title: String
        let createdAt: Date
        let recordedAt: Date?
        let durationMs: Int
        let state: String
        let previousResult: Bool
        let warnings: [String]
        let sourceComplete: Bool

        init(_ m: Manifest, revision: UInt64) {
            recordingID = m.id; self.revision = revision; title = m.displayTitle
            createdAt = m.createdAt; recordedAt = m.recordedAt; durationMs = m.durationMs
            state = m.activeRunId == nil ? m.state.title : m.warnings.isEmpty ? "Готово" : "Готово с предупреждениями"
            previousResult = m.activeRunId != nil && m.pendingRunId != nil
            warnings = m.warnings; sourceComplete = m.sourceComplete
        }
    }
    private struct Key: Hashable {
        let content: ContentKey
        let part: ExportPart
        let markdown: Bool
    }

    @Published private(set) var result = RenderedExport()
    @Published private(set) var isRendering = false
    private(set) var renderCount = 0
    private var content: ContentKey?
    private var requested: Key?
    private var cache: [Key: RenderedExport] = [:]
    private(set) var task: Task<Void, Never>?
    private let renderer: Renderer

    init(renderer: @escaping Renderer = { manifest, transcript, summary, part, markdown in
        ExportService.renderResult(manifest: manifest, transcript: transcript, summary: summary, part: part, markdown: markdown)
    }) {
        self.renderer = renderer
    }

    private func key(_ manifest: Manifest, revision: UInt64, part: ExportPart, markdown: Bool) -> Key {
        let next = ContentKey(manifest, revision: revision)
        if content != next { cache.removeAll(); content = next }
        return Key(content: next, part: part, markdown: markdown)
    }

    func update(manifest: Manifest?, transcript: Transcript?, summary: Summary?, revision: UInt64, part: ExportPart) {
        guard let manifest else {
            task?.cancel(); task = nil; requested = nil; content = nil; cache.removeAll()
            result = RenderedExport(); isRendering = false
            return
        }
        let key = key(manifest, revision: revision, part: part, markdown: false)
        guard requested != key else { return }
        requested = key; task?.cancel(); task = nil
        if let cached = cache[key] { result = cached; isRendering = false; return }
        // Clear links as well as text immediately; an older async result must not
        // remain interactive while a different recording/tab is being prepared.
        result = RenderedExport(); isRendering = true
        task = Task { [weak self] in
            // Coalesce transcript + summary publication and rapid tab changes.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.renderCount += 1
            let renderer = self.renderer
            let value = await Task.detached(priority: .userInitiated) {
                renderer(manifest, transcript, summary, part, false)
            }.value
            guard !Task.isCancelled, self.requested == key else { return }
            self.cache[key] = value; self.result = value; self.isRendering = false; self.task = nil
        }
    }

    /// Explicit copy/export uses the same cache and background renderer as the view.
    /// A changed selection/content must never publish an obsolete action result.
    func render(manifest: Manifest, transcript: Transcript?, summary: Summary?, revision: UInt64,
                part: ExportPart, markdown: Bool) async throws -> RenderedExport {
        let key = key(manifest, revision: revision, part: part, markdown: markdown)
        try Task.checkCancellation()
        if let cached = cache[key] { return cached }
        renderCount += 1
        let renderer = self.renderer
        let value = await Task.detached(priority: .userInitiated) {
            renderer(manifest, transcript, summary, part, markdown)
        }.value
        try Task.checkCancellation()
        guard content == key.content else { throw CancellationError() }
        cache[key] = value
        return value
    }
}
