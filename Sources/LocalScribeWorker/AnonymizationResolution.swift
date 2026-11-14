import Foundation
import LocalScribeCore

/// One candidate that was verified against the target text: the fragment
/// equals the scalars of `range` and `dataType` is an exact saved wording.
/// Coordinates are scalar offsets of one target (body or imported name).
struct AnonymizationSpanCandidate: Sendable, Equatable {
    var dataType: String
    var range: Range<Int>
    var value: String
    var doubtful: Bool
}

/// The document-wide outcome of resolving all candidates of one target:
/// confirmed disjoint replacements plus disputed spans that stay verbatim and
/// produce one DOUBTFUL_FRAGMENT warning each.
struct AnonymizationReplacementPlan: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var range: Range<Int>
        var dataType: String
        var value: String
    }
    var replacements: [Item] = []
    var doubtfulRanges: [Range<Int>] = []
}

/// Resolves candidates across the whole document after the windows were
/// merged, following the interview decisions of the domain design:
/// - in every cluster of intersecting candidates, the single confirmed outer
///   range that contains all the others is replaced wholesale, absorbing
///   nested doubts and nested values (they still get their own substitutions
///   in standalone occurrences outside the cluster);
/// - an outer doubt, an intersection without a single confirmed outer range
///   and a type conflict on one range keep the disputed text verbatim with a
///   DOUBTFUL_FRAGMENT warning;
/// - repeated values are not merged here: every standalone replacement
///   occurrence survives and the substitution stage keys them by value.
enum AnonymizationResolution {
    static func resolve(candidates: [AnonymizationSpanCandidate]) -> AnonymizationReplacementPlan {
        // Deduplicate exact repeats (same type, same range): the doubt flag
        // aggregates conservatively.
        var unique: [String: AnonymizationSpanCandidate] = [:]
        var order: [String] = []
        for candidate in candidates {
            let key = "\(candidate.dataType)\u{1}\(candidate.range.lowerBound)-\(candidate.range.upperBound)"
            if var existing = unique[key] {
                existing.doubtful = existing.doubtful || candidate.doubtful
                unique[key] = existing
            } else {
                unique[key] = candidate
                order.append(key)
            }
        }
        let input = order.compactMap { unique[$0] }
        let clusters = cluster(input)
        var plan = AnonymizationReplacementPlan()
        for cluster in clusters {
            let containers = cluster.filter { candidate in
                !candidate.doubtful && cluster.allSatisfy { other in
                    other.range.lowerBound >= candidate.range.lowerBound && other.range.upperBound <= candidate.range.upperBound
                }
            }
            if let container = containers.first, containers.count == 1 {
                plan.replacements.append(.init(range: container.range, dataType: container.dataType, value: container.value))
            } else {
                // No single confirmed outer range: the whole disputed union
                // stays verbatim with one warning.
                let union = cluster.reduce(cluster[0].range) {
                    Swift.min($0.lowerBound, $1.range.lowerBound)..<Swift.max($0.upperBound, $1.range.upperBound)
                }
                plan.doubtfulRanges.append(union)
            }
        }
        plan.replacements.sort { $0.range.lowerBound < $1.range.lowerBound }
        plan.doubtfulRanges.sort { $0.lowerBound < $1.lowerBound }
        return plan
    }

    /// Groups candidates into connected clusters of intersecting ranges
    /// (equal ranges intersect); candidates of one cluster are adjacent in the
    /// returned arrays.
    private static func cluster(_ candidates: [AnonymizationSpanCandidate]) -> [[AnonymizationSpanCandidate]] {
        let sorted = candidates.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var clusters: [[AnonymizationSpanCandidate]] = []
        var current: [AnonymizationSpanCandidate] = []
        var reach = Int.min
        for candidate in sorted {
            if !current.isEmpty && candidate.range.lowerBound >= reach {
                clusters.append(current)
                current = []
            }
            current.append(candidate)
            reach = Swift.max(reach, candidate.range.upperBound)
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }
}
