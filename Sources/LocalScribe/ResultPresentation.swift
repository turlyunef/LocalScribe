import SwiftUI
import LocalScribeCore

/// Each click is an event even when its segment is the same as the previous one.
struct ResultJumpRequest: Equatable {
    let id = UUID()
    let segmentID: String
}

struct TranscriptPlaybackIndex: Sendable {
    private let documentOrder: [ExportTimestamp]
    private let timeOrder: [ExportTimestamp]
    private let latestEnds: [Int]

    init(_ result: RenderedExport) {
        let segments = result.timestamps.filter { $0.segmentRange != nil }
        documentOrder = segments
        timeOrder = segments.sorted {
            $0.startMs == $1.startMs ? $0.range.location < $1.range.location : $0.startMs < $1.startMs
        }
        var latest = 0
        latestEnds = timeOrder.map {
            latest = max(latest, $0.endMs)
            return latest
        }
    }

    func segment(at milliseconds: Double) -> ExportTimestamp? {
        // Pick the earliest active segment in an overlap. The running maximum
        // finds it in logarithmic time even when earlier segments overlap.
        let index = firstIndex(count: latestEnds.count) { Double(latestEnds[$0]) > milliseconds }
        guard index < timeOrder.count, Double(timeOrder[index].startMs) <= milliseconds else { return nil }
        return timeOrder[index]
    }

    func segment(atTextOffset offset: Int) -> ExportTimestamp? {
        let index = firstIndex(count: documentOrder.count) { (documentOrder[$0].segmentRange.map(NSMaxRange) ?? 0) > offset }
        guard index < documentOrder.count, let range = documentOrder[index].segmentRange,
              NSLocationInRange(offset, range) else { return nil }
        return documentOrder[index]
    }

    private func firstIndex(count: Int, where matches: (Int) -> Bool) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if matches(middle) { upper = middle } else { lower = middle + 1 }
        }
        return lower
    }
}

/// Frequent capture/progress changes are observed only by the indicator views.
@MainActor final class ActivityIndicators: ObservableObject {
    @Published var status = ""
    @Published var elapsed = 0.0
    @Published var level = 0.0
    @Published var soundNotice: String?
    @Published var waitingForSystemAudio = false
    @Published var microphoneStatus: CaptureMicrophoneStatus?
    @Published var captureWarnings: [String] = []
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
        let state: JobState
        let previousResult: Bool
        let warnings: [String]
        let sourceComplete: Bool

        init(_ m: Manifest, revision: UInt64) {
            recordingID = m.id; self.revision = revision; title = m.displayTitle
            createdAt = m.createdAt; recordedAt = m.recordedAt; durationMs = m.durationMs
            state = m.activeRunId == nil ? m.state : m.warnings.isEmpty ? .completed : .completedWithWarnings
            previousResult = m.activeRunId != nil && m.pendingRunId != nil
            warnings = m.warnings; sourceComplete = m.sourceComplete
        }
    }
    private struct Key: Hashable {
        let content: ContentKey
        let part: ExportPart
        let markdown: Bool
    }

    private struct Presentation: Sendable {
        let result: RenderedExport
        let playbackIndex: TranscriptPlaybackIndex?

        init(_ result: RenderedExport = RenderedExport(), part: ExportPart? = nil, markdown: Bool = false) {
            self.result = result
            playbackIndex = part == .transcript && !markdown ? TranscriptPlaybackIndex(result) : nil
        }
    }
    @Published private var presented = Presentation()
    var result: RenderedExport { presented.result }
    var playbackIndex: TranscriptPlaybackIndex? { presented.playbackIndex }
    @Published private(set) var isRendering = false
    private(set) var renderCount = 0
    private var content: ContentKey?
    private var requested: Key?
    private var cache: [Key: Presentation] = [:]
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
            presented = Presentation(); isRendering = false
            return
        }
        let key = key(manifest, revision: revision, part: part, markdown: false)
        guard requested != key else { return }
        requested = key; task?.cancel(); task = nil
        if let cached = cache[key] { presented = cached; isRendering = false; return }
        // Clear links as well as text immediately; an older async result must not
        // remain interactive while a different recording/tab is being prepared.
        presented = Presentation(); isRendering = true
        task = Task { [weak self] in
            // Coalesce transcript + summary publication and rapid tab changes.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.renderCount += 1
            let renderer = self.renderer
            let value = await Task.detached(priority: .userInitiated) {
                Presentation(renderer(manifest, transcript, summary, part, false), part: part)
            }.value
            guard !Task.isCancelled, self.requested == key else { return }
            self.cache[key] = value; self.presented = value; self.isRendering = false; self.task = nil
        }
    }

    /// Explicit copy/export uses the same cache and background renderer as the view.
    /// A changed selection/content must never publish an obsolete action result.
    func render(manifest: Manifest, transcript: Transcript?, summary: Summary?, revision: UInt64,
                part: ExportPart, markdown: Bool) async throws -> RenderedExport {
        let key = key(manifest, revision: revision, part: part, markdown: markdown)
        try Task.checkCancellation()
        if let cached = cache[key] { return cached.result }
        renderCount += 1
        let renderer = self.renderer
        let value = await Task.detached(priority: .userInitiated) {
            Presentation(renderer(manifest, transcript, summary, part, markdown), part: part, markdown: markdown)
        }.value
        try Task.checkCancellation()
        guard content == key.content else { throw CancellationError() }
        cache[key] = value
        return value.result
    }
}
