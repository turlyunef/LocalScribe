import Foundation
import LocalScribeCore

enum ASRWordRepairIssue: String, Codable, CaseIterable, Sendable {
    case emptyCandidate, missingWordTimings, inputTooLarge, boundaryCrossing
    case overlappingDuplicate, nonMonotonicTimings, noAnchors, edgeDifference, preservedDeletion, ignoredInsertion
    case broadDifference, ambiguousTiming, protectedToken, uncertainCandidate
}

struct ASRWordRepairEdit: Codable, Sendable {
    var segmentIndex: Int
    var wordIndex: Int
    var original: Word
    var candidate: Word
    var replacementText: String
}

struct ASRWordRepairResult: Codable, Sendable {
    var algorithmVersion: String
    var proposed: [Segment]
    var edits: [ASRWordRepairEdit]
    var issues: [ASRWordRepairIssue]
}

/// Experimental proposals only. Exact, time-compatible anchors bracket small
/// substitutions; unmatched original words are never deleted or replaced wholesale.
enum ASRWordRepair {
    static let version = "asr-word-repair-v1"
    private static let maximumWords = 256
    private static let maximumDifferenceWords = 3
    private static let timingToleranceMs = 500
    private static let protectedKeys: Set<String> = [
        "не", "ни", "нет", "без", "никогда", "нельзя", "да",
        "no", "not", "never", "without", "none", "nor", "yes", "true", "false"
    ]

    private struct Token {
        var segment: Int
        var wordIndex: Int
        var word: Word
        var key: String?
        var lexicalRange: NSRange?
        var uncertain: Bool
        var inside: Bool
    }

    static func propose(original: [Segment], candidate: [Segment], startMs: Int, endMs: Int) -> ASRWordRepairResult {
        var issues: Set<ASRWordRepairIssue> = []
        var proposed = original
        var edits: [ASRWordRepairEdit] = []
        func result() -> ASRWordRepairResult {
            .init(algorithmVersion: version, proposed: proposed, edits: edits,
                  issues: ASRWordRepairIssue.allCases.filter { issues.contains($0) })
        }
        guard !candidate.isEmpty else { issues.insert(.emptyCandidate); return result() }
        guard original.allSatisfy({ !$0.words.isEmpty && $0.words.map(\.text).joined() == $0.text }),
              candidate.allSatisfy({ !$0.words.isEmpty && $0.words.map(\.text).joined() == $0.text }) else {
            issues.insert(.missingWordTimings); return result()
        }
        guard original.reduce(0, { $0 + $1.words.count }) <= maximumWords,
              candidate.reduce(0, { $0 + $1.words.count }) <= maximumWords,
              (original + candidate).reduce(0, { $0 + $1.text.utf16.count }) <= 65_536 else {
            issues.insert(.inputTooLarge); return result()
        }
        let source = tokens(original, startMs: startMs, endMs: endMs)
        let alternate = tokens(candidate, startMs: startMs, endMs: endMs)
        if (source + alternate).contains(where: { !$0.inside }) { issues.insert(.boundaryCrossing) }
        if hasDuplicate(source) || hasDuplicate(alternate) { issues.insert(.overlappingDuplicate) }
        guard [source, alternate].allSatisfy({ words in
            zip(words, words.dropFirst()).allSatisfy { $0.0.word.startMs <= $0.1.word.startMs }
        }) else { issues.insert(.nonMonotonicTimings); return result() }

        // A short, bounded LCS aligns repeated words by their actual time as well
        // as spelling. Similar text at another point is not an anchor.
        var table = Array(repeating: Array(repeating: 0, count: alternate.count + 1), count: source.count + 1)
        for i in source.indices.reversed() {
            for j in alternate.indices.reversed() {
                if isAnchor(source[i], alternate[j]) { table[i][j] = 1 + table[i + 1][j + 1] }
                else { table[i][j] = max(table[i + 1][j], table[i][j + 1]) }
            }
        }
        var anchors: [(Int, Int)] = [], i = 0, j = 0
        while i < source.count && j < alternate.count {
            if isAnchor(source[i], alternate[j]) { anchors.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        guard let first = anchors.first, let last = anchors.last else { issues.insert(.noAnchors); return result() }
        if first.0 > 0 || first.1 > 0 || last.0 + 1 < source.count || last.1 + 1 < alternate.count {
            issues.insert(.edgeDifference)
        }
        for pair in zip(anchors, anchors.dropFirst()) {
            let originals = (pair.0.0 + 1)..<pair.1.0
            let alternatives = (pair.0.1 + 1)..<pair.1.1
            if originals.isEmpty {
                if !alternatives.isEmpty { issues.insert(.ignoredInsertion) }
                continue
            }
            if alternatives.isEmpty { issues.insert(.preservedDeletion); continue }
            guard originals.count <= maximumDifferenceWords, alternatives.count <= maximumDifferenceWords else {
                issues.insert(.broadDifference); continue
            }
            var matches: [(Int, Int)] = []
            for a in alternatives {
                guard !alternate[a].uncertain else { issues.insert(.uncertainCandidate); continue }
                guard alternate[a].inside, let key = alternate[a].key else { continue }
                if isProtected(key) { issues.insert(.protectedToken); continue }
                let eligible = originals.filter { s in
                    source[s].inside && source[s].uncertain && source[s].key != nil
                        && source[s].key != key && compatibleScript(source[s].key!, key)
                        && stableTiming(source[s].word, alternate[a].word)
                }
                guard eligible.count == 1 else { issues.insert(.ambiguousTiming); continue }
                let s = eligible[0]
                if isProtected(source[s].key!) { issues.insert(.protectedToken); continue }
                matches.append((s, a))
            }
            let ordered = matches.sorted { $0.0 < $1.0 }
            guard Set(ordered.map { $0.0 }).count == ordered.count,
                  zip(ordered, ordered.dropFirst()).allSatisfy({ $0.0.1 < $0.1.1 }) else {
                issues.insert(.ambiguousTiming); continue
            }
            if ordered.count < originals.count { issues.insert(.preservedDeletion) }
            for (s, a) in ordered {
                guard let range = source[s].lexicalRange, let replacementRange = alternate[a].lexicalRange else { continue }
                let replacement = (alternate[a].word.text as NSString).substring(with: replacementRange)
                let text = (source[s].word.text as NSString).replacingCharacters(in: range, with: replacement)
                proposed[source[s].segment].words[source[s].wordIndex].text = text
                edits.append(.init(segmentIndex: source[s].segment, wordIndex: source[s].wordIndex,
                    original: source[s].word, candidate: alternate[a].word, replacementText: text))
            }
        }
        for index in Set(edits.map(\.segmentIndex)) {
            proposed[index].text = proposed[index].words.map(\.text).joined()
            // Old timings describe different words. Keep segment bounds/IDs,
            // discard the changed segment's word alignment, and retain uncertainty.
            proposed[index].words = []
            proposed[index].uncertain = true
        }
        return result()
    }

    private static func tokens(_ segments: [Segment], startMs: Int, endMs: Int) -> [Token] {
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}\\p{M}]+")
        return segments.enumerated().flatMap { segmentIndex, segment in
            segment.words.enumerated().map { wordIndex, word in
                let matches = regex.matches(in: word.text, range: NSRange(location: 0, length: word.text.utf16.count))
                let range = matches.count == 1 ? matches[0].range : nil
                let key = range.map { (word.text as NSString).substring(with: $0)
                    .precomposedStringWithCompatibilityMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                    .replacingOccurrences(of: "ё", with: "е") }
                return Token(segment: segmentIndex, wordIndex: wordIndex, word: word, key: key,
                    lexicalRange: range, uncertain: segment.uncertain,
                    inside: word.startMs >= startMs && word.endMs <= endMs && word.startMs < word.endMs)
            }
        }
    }

    private static func isAnchor(_ a: Token, _ b: Token) -> Bool {
        a.key != nil && a.key == b.key && a.inside && b.inside
            && abs((a.word.startMs + a.word.endMs) / 2 - (b.word.startMs + b.word.endMs) / 2) <= timingToleranceMs
            && min(a.word.endMs, b.word.endMs) > max(a.word.startMs, b.word.startMs)
    }

    private static func stableTiming(_ a: Word, _ b: Word) -> Bool {
        let overlap = max(0, min(a.endMs, b.endMs) - max(a.startMs, b.startMs))
        return overlap * 2 >= a.endMs - a.startMs && overlap * 2 >= b.endMs - b.startMs
            && abs((a.startMs + a.endMs) / 2 - (b.startMs + b.endMs) / 2) <= timingToleranceMs
    }

    private static func isProtected(_ key: String) -> Bool {
        protectedKeys.contains(key) || key.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private static func compatibleScript(_ a: String, _ b: String) -> Bool {
        for script in ["Latin", "Cyrillic"] {
            let pattern = "^[\\p{\(script)}]+$"
            if a.range(of: pattern, options: .regularExpression) != nil && b.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    private static func hasDuplicate(_ tokens: [Token]) -> Bool {
        zip(tokens, tokens.dropFirst()).contains { a, b in
            a.key != nil && a.key == b.key && min(a.word.endMs, b.word.endMs) > max(a.word.startMs, b.word.startMs)
        }
    }
}
