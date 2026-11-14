import Foundation

/// One saved reverse transformation of a text card. Both versions and their
/// highlights remain readable after the card publishes a new anonymization.
public struct AnonymizationRestoration: Codable, Equatable, Sendable {
    /// Before decoding, a UTF-16 input can use twice as many bytes as UTF-8.
    /// Reserve room for the longest supported BOM when checking the file size.
    public static let maximumImportFileBytes = 2 * Int64(Disk.maximumJSONBytes) + 3

    public let source: TextRevision
    public let result: TextRevision
    public let sourceFormat: AnonymizationSourceFormat
    public let pairs: [ReplacementPair]

    /// A compact pair with single-digit offsets is smaller than every pair in
    /// the archive. Use that lower bound to stop before an oversized list is
    /// allocated, then check the exact encoded size at commit time.
    private static let minimumPairJSONBytes: Int = {
        let range = TextRange(start: 0, end: 1)
        let pair = ReplacementPair(sourceRange: range, resultRange: range)
        return (try? JSONEncoder().encode(pair).count) ?? 0
    }()

    func validate() throws {
        let error = ScribeError.message("Некорректный результат обратного преобразования")
        guard UUID(uuidString: source.id) != nil, UUID(uuidString: result.id) != nil,
              source.id != result.id, source.text.contains(where: { !$0.isWhitespace }) else {
            throw error
        }
        let input = Array(source.text.unicodeScalars)
        let output = Array(result.text.unicodeScalars)
        var inputEnd = 0
        var outputEnd = 0
        for pair in pairs {
            guard pair.sourceRange.isValid(withinScalarCount: input.count),
                  pair.resultRange.isValid(withinScalarCount: output.count),
                  pair.sourceRange.start >= UInt(inputEnd), pair.resultRange.start >= UInt(outputEnd) else {
                throw error
            }
            let inputStart = Int(pair.sourceRange.start)
            let outputStart = Int(pair.resultRange.start)
            guard input[inputEnd..<inputStart].elementsEqual(output[outputEnd..<outputStart]) else {
                throw error
            }
            inputEnd = Int(pair.sourceRange.end)
            outputEnd = Int(pair.resultRange.end)
            guard !input[inputStart..<inputEnd].elementsEqual(output[outputStart..<outputEnd]) else {
                throw error
            }
        }
        guard input[inputEnd...].elementsEqual(output[outputEnd...]) else { throw error }
    }

    static func transform(_ source: TextRevision, sourceFormat: AnonymizationSourceFormat,
                          original: String, anonymized: AnonymizationResult) throws -> Self {
        var outputBudget = Disk.maximumJSONBytes - source.text.utf8.count
        let sizeError = ScribeError.message("Текст для обратного преобразования слишком большой для карточки")
        guard outputBudget > 0 else { throw sizeError }
        guard source.text.contains(where: { !$0.isWhitespace }) else {
            throw ScribeError.message("Текст для обратного преобразования пуст")
        }
        let originals = Array(original.unicodeScalars)
        let substitutes = Array(anonymized.text.text.unicodeScalars)
        var lookup = ReplacementTrie()
        for pair in anonymized.pairs {
            let placeholder = substitutes[Int(pair.resultRange.start)..<Int(pair.resultRange.end)]
            let original = originals[Int(pair.sourceRange.start)..<Int(pair.sourceRange.end)]
            lookup.insert(placeholder: placeholder, original: original)
        }

        // Scan the supplied text only. Restored values never feed back into
        // lookup, even when an original value is itself a placeholder.
        let input = Array(source.text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var pairs: [ReplacementPair] = []
        var inputPosition = 0
        var copiedThrough = 0
        var outputCount = 0
        while inputPosition < input.count {
            let start = inputPosition
            guard let (match, end) = lookup.longestMatch(in: input, from: start) else {
                inputPosition += 1
                continue
            }
            inputPosition = end
            guard case .unambiguous(let original) = match,
                  !input[start..<end].elementsEqual(original) else { continue }

            let outputStart = outputCount + start - copiedThrough
            outputCount = outputStart + original.count
            outputBudget -= minimumPairJSONBytes
            guard outputCount <= outputBudget else { throw sizeError }
            output.append(contentsOf: input[copiedThrough..<start])
            output.append(contentsOf: original)
            copiedThrough = end
            pairs.append(ReplacementPair(
                sourceRange: TextRange(start: UInt(start), end: UInt(end)),
                resultRange: TextRange(start: UInt(outputStart), end: UInt(outputCount))))
        }
        guard outputCount + input.count - copiedThrough <= outputBudget else { throw sizeError }
        output.append(contentsOf: input[copiedThrough...])
        return Self(source: source, result: TextRevision(id: UUID().uuidString, text: String(output)),
                    sourceFormat: sourceFormat, pairs: pairs)
    }
}

/// The saved scalar sequences are literal, including any Markdown escaping.
/// Prefer the longest standalone match at each position. When several
/// originals share a placeholder, preserve the complete ambiguous match.
private struct ReplacementTrie {
    enum Match: Equatable {
        case unambiguous([Unicode.Scalar])
        case ambiguous
    }

    private struct Node {
        var children: [Unicode.Scalar: Int] = [:]
        var match: Match?
    }

    private var nodes = [Node()]

    mutating func insert(placeholder: ArraySlice<Unicode.Scalar>, original: ArraySlice<Unicode.Scalar>) {
        var node = 0
        for scalar in placeholder {
            if let child = nodes[node].children[scalar] {
                node = child
            } else {
                let child = nodes.count
                nodes[node].children[scalar] = child
                nodes.append(Node())
                node = child
            }
        }
        let match = Match.unambiguous(Array(original))
        if let existing = nodes[node].match {
            if existing != match { nodes[node].match = .ambiguous }
        } else {
            nodes[node].match = match
        }
    }

    func longestMatch(in scalars: [Unicode.Scalar], from start: Int) -> (Match, Int)? {
        guard var node = nodes[0].children[scalars[start]],
              start == 0 || !Self.continuesWord(scalars[start - 1], scalars[start]) else { return nil }
        var end = start + 1
        var longest: (Match, Int)?
        while true {
            if let match = nodes[node].match,
               end == scalars.count || !Self.continuesWord(scalars[end - 1], scalars[end]) {
                longest = (match, end)
            }
            guard end < scalars.count, let child = nodes[node].children[scalars[end]] else { return longest }
            node = child
            end += 1
        }
    }

    // Match the standalone-word rule used during anonymization, including
    // combining marks and the punctuation around Markdown link text.
    private static let wordScalars = CharacterSet.alphanumerics.union(.nonBaseCharacters)

    private static func continuesWord(_ left: Unicode.Scalar, _ right: Unicode.Scalar) -> Bool {
        wordScalars.contains(left) && wordScalars.contains(right)
    }
}
