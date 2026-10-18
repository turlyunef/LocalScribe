import Foundation
import LocalScribeCore

/// Prepared once per summary invocation, including when resuming saved reviews.
struct SummarySourceIndex: Sendable {
    let transcript: Transcript
    let lines: [String]
    let tokenCounts: [Int]
    let indexByID: [String: Int]

    init(_ transcript: Transcript, tokenCount: @Sendable (String) async -> Int) async {
        self.transcript = transcript
        var lines: [String] = [], counts: [Int] = [], indexes: [String: Int] = [:]
        for (index, segment) in transcript.segments.enumerated() {
            let line = "[\(segment.id) \(timecode(segment.startMs)) \(segment.speakerId ?? "unknown") uncertain=\(segment.uncertain)] \(segment.text)"
            lines.append(line)
            counts.append(await tokenCount(line))
            indexes[segment.id] = index
        }
        self.lines = lines; tokenCounts = counts; indexByID = indexes
    }

    func context(_ segments: [Segment]) -> String {
        segments.map { lines[indexByID[$0.id]!] }.joined(separator: "\n")
    }

    func evidenceContext(for finding: Finding) -> [Segment] {
        var indexes: Set<Int> = []
        for id in finding.evidenceSegmentIds {
            guard let index = indexByID[id] else { continue }
            for neighbour in max(0, index - 2)...min(transcript.segments.count - 1, index + 2) {
                indexes.insert(neighbour)
            }
        }
        return indexes.sorted().map { transcript.segments[$0] }
    }

    func laterGroups(after finding: Finding) -> [[Segment]] {
        let lastEvidence = finding.evidenceSegmentIds.compactMap { indexByID[$0] }.max() ?? 0
        var groups: [[Segment]] = [], batch: [Segment] = [], tokens = 0
        // Preserve the original non-overlapping 1200-token amendment boundaries,
        // including a single turn that exceeds that budget. Extraction overlaps differ.
        for index in transcript.segments.indices.dropFirst(lastEvidence + 1) {
            let count = tokenCounts[index]
            if tokens + count > 1200 && !batch.isEmpty {
                groups.append(batch); batch = []; tokens = 0
            }
            batch.append(transcript.segments[index]); tokens += count
        }
        if !batch.isEmpty { groups.append(batch) }
        return groups
    }
}
