import LocalScribeCore

/// Gaps between whole timestamped paragraphs, with overlapping speech merged.
struct PlaybackPauseIndex: Sendable {
    private struct Pause: Sendable {
        let startMs: Int
        let endMs: Int
    }
    private var pauses: [Pause] = []
    private var starts: [Int] = []

    init(_ segments: [Segment] = []) {
        let ordered = segments.filter { $0.startMs >= 0 && $0.endMs > $0.startMs }
            .sorted { $0.startMs < $1.startMs }
        guard let first = ordered.first else { return }
        starts = Array(Set(ordered.map(\.startMs))).sorted()
        if first.startMs > 0 {
            pauses.append(Pause(startMs: 0, endMs: first.startMs))
        }
        var end = first.endMs
        for segment in ordered.dropFirst() {
            if segment.startMs - end >= 1000 {
                pauses.append(Pause(startMs: end, endMs: segment.startMs))
            }
            end = max(end, segment.endMs)
        }
    }

    func adjacentSpeech(at seconds: Double, direction: Int) -> Double? {
        guard seconds.isFinite else { return nil }
        // Ignore the small clock advance after a precise seek, so repeated
        // presses can move backwards through paragraph starts.
        let boundary = seconds * 1000 + (direction < 0 ? -50 : 50)
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if Double(starts[middle]) <= boundary { lower = middle + 1 }
            else { upper = middle }
        }
        let index = direction < 0 ? lower - 1 : lower
        guard starts.indices.contains(index) else { return nil }
        return Double(starts[index]) / 1000
    }

    func nextSpeech(at seconds: Double) -> Double? {
        guard seconds.isFinite else { return nil }
        // Use the same seconds scale as the returned destination. Converting
        // it back to milliseconds can round a speech start into the preceding
        // pause (for example, 1.001 * 1000 < 1001), causing endless seeks.
        var lower = 0
        var upper = pauses.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if Double(pauses[middle].endMs) / 1000 <= seconds { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower < pauses.count, Double(pauses[lower].startMs) / 1000 <= seconds else { return nil }
        return Double(pauses[lower].endMs) / 1000
    }
}
