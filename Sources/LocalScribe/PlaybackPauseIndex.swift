import LocalScribeCore

/// Gaps between whole timestamped paragraphs, with overlapping speech merged.
struct PlaybackPauseIndex: Sendable {
    private struct Pause: Sendable {
        let startMs: Int
        let endMs: Int
    }
    private var pauses: [Pause] = []

    init(_ segments: [Segment] = []) {
        let ordered = segments.filter { $0.startMs >= 0 && $0.endMs > $0.startMs }
            .sorted { $0.startMs < $1.startMs }
        guard let first = ordered.first else { return }
        var end = first.endMs
        for segment in ordered.dropFirst() {
            if segment.startMs - end >= 1000 {
                pauses.append(Pause(startMs: end, endMs: segment.startMs))
            }
            end = max(end, segment.endMs)
        }
    }

    func nextSpeech(at seconds: Double) -> Double? {
        guard seconds.isFinite else { return nil }
        let milliseconds = seconds * 1000
        var lower = 0
        var upper = pauses.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if Double(pauses[middle].endMs) <= milliseconds { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower < pauses.count, Double(pauses[lower].startMs) <= milliseconds else { return nil }
        return Double(pauses[lower].endMs) / 1000
    }
}
