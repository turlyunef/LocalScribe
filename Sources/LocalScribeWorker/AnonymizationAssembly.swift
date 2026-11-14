import Foundation
import LocalScribeCore

/// One textual replacement ready for assembly: a disjoint scalar range of the
/// source plus its final context-shaped representation (already percent-
/// encoded inside link destinations or escaped inside link text).
struct AnonymizationAssemblyReplacement: Sendable, Equatable {
    var range: Range<Int>
    var text: String
}

/// Result of assembling one target: the generated text, the generated range
/// of every replacement and a scalar index mapping that also serves spans
/// which were preserved verbatim (disputed fragments).
struct AnonymizationAssemblyOutput: Sendable, Equatable {
    var text: String
    var replacementRanges: [Range<Int>]
    /// For every source scalar index, its offset in the generated text;
    /// scalars inside a replacement map to the replacement's start.
    var sourceToGenerated: [Int]
}

enum AnonymizationAssemblyError: Error {
    /// A confirmed replacement cannot be represented correctly in its
    /// Markdown context; the whole attempt must fail safely.
    case unrepresentable
}

/// Builds the generated text from the original scalar slices and the
/// confirmed replacements. Between replacements every original scalar,
/// punctuation and line break survives verbatim. For Markdown, the context of
/// each replacement decides its representation: percent-encoded inside link
/// destinations (keeping `mailto:` links working), backslash-escaped inside
/// link text. A replacement may swallow whole link constructs (they simply
/// disappear); anything that would corrupt a surviving construct is
/// unrepresentable and fails the attempt.
enum AnonymizationAssembly {
    // MARK: - Markdown context scan

    struct MarkdownSpan: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case destination, linkText }
        var range: Range<Int>
        var kind: Kind
    }

    /// Deterministic lightweight scan for inline link constructs, autolinks
    /// and reference-style definitions. Fenced code blocks and inline code
    /// spans are skipped; the scan records only spans whose Markdown meaning
    /// is unambiguous.
    static func markdownSpans(in scalars: [Unicode.Scalar], format: AnonymizationSourceFormat) -> [MarkdownSpan] {
        guard format == .markdown else { return [] }
        let count = scalars.count
        var spans: [MarkdownSpan] = []
        var index = 0
        var lineStart = 0
        var inFence = false
        func isEscaped(_ i: Int) -> Bool {
            var backslashes = 0, j = i - 1
            while j >= 0, scalars[j] == "\\" { backslashes += 1; j -= 1 }
            return backslashes % 2 == 1
        }
        while index < count {
            // Fenced code toggles at a line start (``` or ~~~ with up to
            // three leading spaces); nothing inside a fence is a context.
            if index == lineStart {
                var fenceOffset = 0
                while index + fenceOffset < count, scalars[index + fenceOffset] == " ", fenceOffset < 3 { fenceOffset += 1 }
                if let marker = (index + fenceOffset < count ? scalars[index + fenceOffset] : nil),
                   (marker == "`" || marker == "~"),
                   index + fenceOffset + 2 < count,
                   scalars[index + fenceOffset + 1] == marker, scalars[index + fenceOffset + 2] == marker {
                    if !inFence { inFence = true }
                    else if lineIsOnlyFence(scalars, from: index, marker: marker) { inFence = false }
                    index = endOfLine(scalars, from: index)
                    lineStart = index
                    continue
                }
                if !inFence, scalars[index] == "[", !isEscaped(index),
                   let span = referenceDefinitionDestination(scalars, labelStart: index) {
                    spans.append(span)
                    index = endOfLine(scalars, from: index)
                    lineStart = index
                    continue
                }
            }
            if !inFence {
                let current = scalars[index]
                if current == "`" {
                    var close = index + 1
                    while close < count, scalars[close] != "`" { close += 1 }
                    index = close < count ? close + 1 : count
                    continue
                }
                if current == "<", !isEscaped(index), let close = findAutolinkEnd(scalars, from: index),
                   isAutolinkContent(scalars[(index + 1)..<close]) {
                    spans.append(MarkdownSpan(range: (index + 1)..<close, kind: .destination))
                    index = close + 1
                    continue
                }
                if current == "[", !isEscaped(index),
                   let (textEnd, destinationSpan) = inlineLinkParts(scalars, openBracket: index) {
                    spans.append(MarkdownSpan(range: (index + 1)..<textEnd, kind: .linkText))
                    if let destinationSpan { spans.append(MarkdownSpan(range: destinationSpan, kind: .destination)) }
                    index = destinationSpan.map { $0.upperBound + 1 } ?? textEnd + 1
                    continue
                }
            }
            if scalars[index] == "\n" { lineStart = index + 1 }
            index += 1
        }
        return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func lineIsOnlyFence(_ scalars: [Unicode.Scalar], from start: Int, marker: Unicode.Scalar) -> Bool {
        var index = start
        while index < scalars.count, scalars[index] != "\n" {
            if scalars[index] != marker && scalars[index] != " " { return false }
            index += 1
        }
        return true
    }

    private static func endOfLine(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count, scalars[index] != "\n" { index += 1 }
        return index < scalars.count ? index + 1 : scalars.count
    }

    private static func findAutolinkEnd(_ scalars: [Unicode.Scalar], from open: Int) -> Int? {
        var index = open + 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\n" { return nil }
            if scalar == ">" { return index }
            index += 1
        }
        return nil
    }

    private static func isAutolinkContent(_ inner: ArraySlice<Unicode.Scalar>) -> Bool {
        let scalars = Array(inner)
        guard !scalars.isEmpty, !scalars.contains(where: { $0 == " " || $0 == "<" }) else { return false }
        return scalars.contains(where: { $0 == ":" || $0 == "@" })
    }

    /// `[text](destination)`: the text's closing bracket index and the
    /// destination span inside the parentheses (nil when the parentheses do
    /// not close on the same line — a reference link, not an inline one).
    private static func inlineLinkParts(_ scalars: [Unicode.Scalar], openBracket: Int) -> (textEnd: Int, destination: Range<Int>?)? {
        var index = openBracket + 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\n" { return nil }
            if scalar == "[" { return nil } // no nested brackets: stay conservative
            if scalar == "]" { break }
            index += 1
        }
        guard index < scalars.count, scalars[index] == "]" else { return nil }
        let textEnd = index
        guard index + 1 < scalars.count, scalars[index + 1] == "(" else { return nil }
        var close = index + 2
        var depth = 1
        while close < scalars.count {
            let scalar = scalars[close]
            if scalar == "\n" { return (textEnd, nil) }
            if scalar == "(" { depth += 1 }
            if scalar == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            close += 1
        }
        guard close < scalars.count, scalars[close] == ")" else { return (textEnd, nil) }
        let destination = (textEnd + 2)..<close
        guard !destination.isEmpty else { return (textEnd, nil) }
        return (textEnd, destination)
    }

    private static func referenceDefinitionDestination(_ scalars: [Unicode.Scalar], labelStart: Int) -> MarkdownSpan? {
        var index = labelStart + 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\n" || scalar == "[" { return nil }
            if scalar == "]" { break }
            index += 1
        }
        guard index < scalars.count, scalars[index] == "]",
              index + 1 < scalars.count, scalars[index + 1] == ":" else { return nil }
        var cursor = index + 2
        while cursor < scalars.count, scalars[cursor] == " " || scalars[cursor] == "\t" { cursor += 1 }
        guard cursor < scalars.count, scalars[cursor] != "\n" else { return nil }
        var end = cursor
        while end < scalars.count, scalars[end] != "\n" { end += 1 }
        while end > cursor, scalars[end - 1] == " " { end -= 1 }
        var destination = cursor..<end
        if scalars[cursor] == "<", end > cursor + 1, scalars[end - 1] == ">" {
            destination = (cursor + 1)..<(end - 1)
        }
        guard !destination.isEmpty else { return nil }
        return MarkdownSpan(range: destination, kind: .destination)
    }

    // MARK: - Context representations

    /// Percent-encoding for link destinations: keeps the URI-reserved
    /// characters that must survive (`mailto:user@domain`, `http://…`) and
    /// encodes everything that would break the construct — whitespace,
    /// parentheses, non-ASCII and control characters.
    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'*+,;=:@/?#%[]")
        allowed.remove(charactersIn: "()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func escapeLinkText(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            if character == "\\" || character == "[" || character == "]" { result.append("\\") }
            result.append(character)
        }
    }

    // MARK: - Assembly

    /// Assembles the generated text. Replacements must be pairwise disjoint
    /// and sorted; each representation is chosen by its Markdown context.
    static func assemble(scalars: [Unicode.Scalar], replacements: [AnonymizationAssemblyReplacement],
                         format: AnonymizationSourceFormat) throws -> AnonymizationAssemblyOutput {
        let spans = markdownSpans(in: scalars, format: format)
        var prepared: [AnonymizationAssemblyReplacement] = []
        prepared.reserveCapacity(replacements.count)
        for replacement in replacements {
            var representation: String?
            for span in spans where span.range.overlaps(replacement.range) {
                let spanSwallowed = span.range.lowerBound >= replacement.range.lowerBound
                    && span.range.upperBound <= replacement.range.upperBound
                if spanSwallowed { continue } // the whole construct is replaced
                let insideSpan = replacement.range.lowerBound >= span.range.lowerBound
                    && replacement.range.upperBound <= span.range.upperBound
                guard insideSpan, representation == nil else { throw AnonymizationAssemblyError.unrepresentable }
                representation = span.kind == .destination ? percentEncode(replacement.text) : escapeLinkText(replacement.text)
            }
            prepared.append(AnonymizationAssemblyReplacement(range: replacement.range, text: representation ?? replacement.text))
        }
        var output = String.UnicodeScalarView()
        var replacementRanges: [Range<Int>] = []
        var mapping = [Int](repeating: 0, count: scalars.count)
        var cursor = 0
        for replacement in prepared {
            for index in cursor..<replacement.range.lowerBound {
                mapping[index] = output.count
                output.append(scalars[index])
            }
            let start = output.count
            output.append(contentsOf: replacement.text.unicodeScalars)
            for index in replacement.range { mapping[index] = start }
            replacementRanges.append(start..<(start + replacement.text.unicodeScalars.count))
            cursor = replacement.range.upperBound
        }
        for index in cursor..<scalars.count {
            mapping[index] = output.count
            output.append(scalars[index])
        }
        try verifyStructure(generated: Array(output), originalRanges: prepared.map(\.range),
                            generatedRanges: replacementRanges, spans: spans)
        return AnonymizationAssemblyOutput(text: String(output), replacementRanges: replacementRanges, sourceToGenerated: mapping)
    }

    /// Re-checks every Markdown construct that survived with a substitution
    /// inside: a destination must stay free of whitespace and bare
    /// parentheses, a link text must not introduce unbalanced brackets.
    private static func verifyStructure(generated: [Unicode.Scalar], originalRanges: [Range<Int>],
                                        generatedRanges: [Range<Int>], spans: [MarkdownSpan]) throws {
        for span in spans {
            let touched = originalRanges.contains { $0.overlaps(span.range) }
            guard touched else { continue }
            let swallowed = originalRanges.contains { replacement in
                span.range.lowerBound >= replacement.lowerBound && span.range.upperBound <= replacement.upperBound
            }
            guard !swallowed else { continue } // the construct itself was replaced
            let start = generatedBoundary(span.range.lowerBound, originalRanges: originalRanges, generatedRanges: generatedRanges)
            let end = generatedBoundary(span.range.upperBound, originalRanges: originalRanges, generatedRanges: generatedRanges)
            guard start < end, end <= generated.count else { throw AnonymizationAssemblyError.unrepresentable }
            let slice = generated[start..<end]
            switch span.kind {
            case .destination:
                if slice.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "(" || $0 == ")" }) {
                    throw AnonymizationAssemblyError.unrepresentable
                }
            case .linkText:
                var depth = 0
                for scalar in slice {
                    if scalar == "[" { depth += 1 }
                    if scalar == "]" { depth -= 1 }
                    if depth < 0 { throw AnonymizationAssemblyError.unrepresentable }
                }
                if depth != 0 { throw AnonymizationAssemblyError.unrepresentable }
            }
        }
    }

    /// Maps a source boundary that never lies strictly inside a replacement to
    /// its offset in the generated text.
    private static func generatedBoundary(_ boundary: Int, originalRanges: [Range<Int>], generatedRanges: [Range<Int>]) -> Int {
        var shift = 0
        for (original, generated) in zip(originalRanges, generatedRanges) {
            if boundary <= original.lowerBound { return boundary + shift }
            shift += generated.count - original.count
        }
        return boundary + shift
    }
}
