import Foundation
import LocalScribeCore

enum ASRReviewReason: String, Codable, CaseIterable, Sendable {
    case uncertainText, uncoveredSignal
}

struct ASRContextReviewRequest: Codable, Sendable, Equatable {
    var startMs: Int
    var endMs: Int
    var contextStartMs: Int
    var contextEndMs: Int
    var reasons: [ASRReviewReason]
}

struct ASRContextReview: Codable, Sendable {
    var request: ASRContextReviewRequest
    // Both hypotheses use the original timeline. Neither is an accepted edit.
    var original: [Segment]
    var candidate: [Segment]
    var wordRepair: ASRWordRepairResult?
}

struct ASRContextReviewBatch: Codable, Sendable {
    var schemaVersion = 1
    var coreStartMs: Int
    var coreEndMs: Int
    var deferredTargets: Int
    var unchangedContextTargets: Int
    var reviews: [ASRContextReview]
}

/// Experimental, bounded candidate generation. Energy is a trigger for review,
/// not proof of speech; decoder confidence is not a correctness verdict.
enum ASRContextReviewPlanner {
    struct Plan {
        var requests: [ASRContextReviewRequest]
        var deferredTargets: Int
        var unchangedContextTargets: Int
    }

    static let maximumCallsPerWindow = 3
    static let maximumTargetMs = 20_000
    static let maximumContextMs = 30_000

    static func plan(segments: [Segment], samples: [Float], readStartMs: Int, readEndMs: Int,
                     coreStartMs: Int, coreEndMs: Int, originMs: Int, durationMs: Int,
                     previousContexts: [Range<Int>] = []) -> Plan {
        var targets: [(Range<Int>, Set<ASRReviewReason>)] = []
        for segment in segments where segment.uncertain {
            let start = max(coreStartMs, segment.startMs), end = min(coreEndMs, segment.endMs)
            if start < end { targets.append((start..<end, [.uncertainText])) }
        }
        if let end = WhisperASRWindowing.missingASRPrefixEnd(segments: segments, samples: samples,
            readStartMs: readStartMs, coreStartMs: coreStartMs, coreEndMs: coreEndMs) {
            targets.append((coreStartMs..<end, [.uncoveredSignal]))
        }
        targets += WhisperASRWindowing.missingASRInteriorRanges(segments: segments, samples: samples,
            readStartMs: readStartMs, coreStartMs: coreStartMs, coreEndMs: coreEndMs)
            .map { ($0, [.uncoveredSignal]) }
        targets.sort { $0.0.lowerBound < $1.0.lowerBound }
        var merged: [(Range<Int>, Set<ASRReviewReason>)] = []
        for target in targets {
            if let previous = merged.last, target.0.lowerBound <= previous.0.upperBound + 500 {
                merged[merged.count - 1] = (previous.0.lowerBound..<max(previous.0.upperBound, target.0.upperBound),
                                          previous.1.union(target.1))
            } else { merged.append(target) }
        }
        var requests: [ASRContextReviewRequest] = []
        var unchanged = 0
        let contextLength = min(maximumContextMs, max(0, durationMs - originMs))
        for (range, reasons) in merged {
            for start in stride(from: range.lowerBound, to: range.upperBound, by: maximumTargetMs) {
                let end = min(range.upperBound, start + maximumTargetMs)
                let contextStart = max(originMs, min(durationMs - contextLength, (start + end) / 2 - contextLength / 2))
                let contextEnd = contextStart + contextLength
                // An identical input with identical decoder options adds no
                // controlled context change. Do not spend a call on it.
                if (contextStart == readStartMs && contextEnd == readEndMs)
                    || previousContexts.contains(contextStart..<contextEnd) { unchanged += 1; continue }
                requests.append(.init(startMs: start, endMs: end, contextStartMs: contextStart,
                    contextEndMs: contextEnd, reasons: ASRReviewReason.allCases.filter { reasons.contains($0) }))
            }
        }
        return Plan(requests: Array(requests.prefix(maximumCallsPerWindow)),
                    deferredTargets: max(0, requests.count - maximumCallsPerWindow), unchangedContextTargets: unchanged)
    }

    static func ownedSegments(_ segments: [Segment], startMs: Int, endMs: Int) -> [Segment] {
        segments.compactMap { segment in
            var copy = segment
            if !segment.words.isEmpty {
                let owned = segment.words.filter { let mid = ($0.startMs + $0.endMs) / 2; return mid >= startMs && mid < endMs }
                guard let first = owned.first, let last = owned.last else { return nil }
                copy.words = owned; copy.text = owned.map(\.text).joined()
                copy.startMs = first.startMs; copy.endMs = last.endMs
            } else {
                let midpoint = (segment.startMs + segment.endMs) / 2
                guard midpoint >= startMs && midpoint < endMs else { return nil }
            }
            return copy
        }
    }
}
