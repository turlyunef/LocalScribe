import Foundation

/// Text-edit engine of the anonymization card. Replacing a scalar span of one
/// panel with new text produces the next versioned document with transformed
/// highlight pairs and warning review positions. Everything here is pure: no
/// files, actors or shared state, so the editor can build drafts off the main
/// actor while `AnonymizationCoordinator` commits the result as one atomic
/// document write — the same discipline as `ResultEditing`.

/// One text edit: the half-open scalar span `[start, end)` of one concrete
/// version is replaced by `replacement`. An empty span is a pure insertion, an
/// empty replacement is a deletion; an empty span with an empty replacement
/// changes nothing and is rejected.
public struct ScalarEdit: Equatable, Sendable {
    public var start: UInt
    public var end: UInt
    public var replacement: String
    public init(start: UInt, end: UInt, replacement: String) {
        self.start = start; self.end = end; self.replacement = replacement
    }
    public var replacementScalarCount: Int { replacement.unicodeScalars.count }
    public func validate(scalarCount: Int) throws {
        guard start <= end, let count = UInt(exactly: scalarCount), end <= count else {
            throw ScribeError.message("Диапазон правки выходит за границы текущей версии")
        }
        guard !(start == end && replacement.isEmpty) else {
            throw ScribeError.message("Правка не меняет текст")
        }
    }
}

/// Result of mapping one anchored range through an edit of its own version.
public enum ScalarRangeEditOutcome: Equatable, Sendable {
    case kept(TextRange)
    case removed
}

/// The pair- and warning-transformation rules of the technical design:
/// - an edit before a range leaves it in place, an edit after it shifts it;
///   an insertion at an outer boundary counts as an edit outside the range;
/// - an interior edit, or a full replacement of one fragment with non-empty
///   text, keeps the link with adjusted boundaries;
/// - a partial deletion keeps the link with the surviving text;
/// - a full deletion of the fragment removes it;
/// - an edit wholly covering several fragments drops every fully covered
///   pair; partially covered fragments keep their surviving text.
public enum AnonymizationEditing {

    // MARK: - Range geometry

    /// Maps one anchored range of the edited version through an edit.
    /// `anchoredRangesFullyCaptured` is the number of anchored ranges of the
    /// same kind wholly covered by the edit, this one included: at least two
    /// means a multi-fragment edit that drops every fully covered pair, while
    /// a single warning review position always passes `1`.
    public static func outcome(of range: TextRange, edit: ScalarEdit,
                               anchoredRangesFullyCaptured: Int) -> ScalarRangeEditOutcome {
        let s = Int(edit.start), e = Int(edit.end), length = edit.replacementScalarCount
        let rs = Int(range.start), re = Int(range.end)
        func kept(_ start: Int, _ end: Int) -> ScalarRangeEditOutcome {
            .kept(TextRange(start: UInt(start), end: UInt(end)))
        }
        // Entirely before the edit — including an insertion at the range end
        // (outer boundary): untouched.
        if re <= s { return .kept(range) }
        // Entirely after the edit — including an insertion at the range start
        // (outer boundary): shifted by the net length change.
        if rs >= e { return kept(rs + length - (e - s), re + length - (e - s)) }
        let editInsideRange = rs <= s && e <= re
        let rangeInsideEdit = s <= rs && re <= e
        if editInsideRange {
            if length > 0 { return kept(rs, re - (e - s) + length) }
            if rangeInsideEdit { return .removed }
            // Partial deletion of the fragment: the remaining text keeps the link.
            return kept(rs, re - (e - s))
        }
        if rangeInsideEdit {
            if anchoredRangesFullyCaptured >= 2 { return .removed }
            if length > 0 { return kept(s, s + length) }
            // The fragment text is deleted entirely.
            return .removed
        }
        // Partial overlap without containment: the surviving text keeps the
        // link; the inserted text never joins the anchored range.
        if s < rs { return kept(s + length, s + length + (re - e)) }
        return kept(rs, s)
    }

    // MARK: - Pairs and warnings

    /// Transforms the pairs of one panel under an edit of that panel. The
    /// opposite-side ranges are untouched except that a removed pair disappears
    /// from both sides together. Order is preserved and the ranges of each side
    /// stay pairwise disjoint and within the new version.
    public static func transformedPairs(_ pairs: [ReplacementPair], editingSource: Bool,
                                        edit: ScalarEdit, scalarCount: Int) throws -> [ReplacementPair] {
        try edit.validate(scalarCount: scalarCount)
        func anchored(_ pair: ReplacementPair) -> TextRange { editingSource ? pair.sourceRange : pair.resultRange }
        let fullyCaptured = pairs.filter { pair in
            edit.start <= anchored(pair).start && anchored(pair).end <= edit.end
        }.count
        var transformed: [ReplacementPair] = []
        for pair in pairs {
            switch outcome(of: anchored(pair), edit: edit, anchoredRangesFullyCaptured: fullyCaptured) {
            case .kept(let range):
                var updated = pair
                if editingSource { updated.sourceRange = range } else { updated.resultRange = range }
                transformed.append(updated)
            case .removed:
                continue
            }
        }
        return transformed
    }

    /// Transforms doubtful-fragment review positions under an edit of the right
    /// text: a traceable position is recalculated, a lost trace clears
    /// `reviewRange`. The historical `inputRange` (run input) and
    /// `generatedRange` (automatic result) coordinates never change. Warnings
    /// about the imported name and uninterpreted-type warnings carry no review
    /// position and pass through unchanged.
    public static func transformedWarnings(_ warnings: [AnonymizationWarning],
                                           edit: ScalarEdit, scalarCount: Int) throws -> [AnonymizationWarning] {
        try edit.validate(scalarCount: scalarCount)
        return warnings.map { warning in
            guard warning.kind == .doubtfulFragment, warning.target == .body,
                  let reviewRange = warning.reviewRange else { return warning }
            var next = warning
            switch outcome(of: reviewRange, edit: edit, anchoredRangesFullyCaptured: 1) {
            case .kept(let range): next.reviewRange = range
            case .removed: next.reviewRange = nil
            }
            return next
        }
    }

    // MARK: - Document operations

    /// Applies an edit to the left (source) panel: a new source revision,
    /// source-side pair transformation, warnings and substitution history
    /// untouched. The published result keeps its own version, so the document
    /// afterwards reports `resultBuiltFromEarlierSource`. An edit never starts
    /// or changes an attempt by itself.
    public static func editSource(_ card: AnonymizationCardDocument,
                                  _ edit: ScalarEdit) throws -> AnonymizationCardDocument {
        let scalars = Array(card.source.text.unicodeScalars)
        try edit.validate(scalarCount: scalars.count)
        var next = card
        next.source = TextRevision(id: UUID().uuidString, text: replacedText(scalars, edit))
        if var result = next.publishedResult {
            result.pairs = try transformedPairs(result.pairs, editingSource: true,
                                                edit: edit, scalarCount: scalars.count)
            next.publishedResult = result
        }
        try next.validate()
        return next
    }

    /// Applies an edit to the right (result) panel. Requires a published
    /// result; the manual edit creates a new right revision while the automatic
    /// revision, run input, download name and counters stay historical. Pairs
    /// and warning review positions follow the same edit in one transaction.
    public static func editResult(_ card: AnonymizationCardDocument,
                                  _ edit: ScalarEdit) throws -> AnonymizationCardDocument {
        guard var result = card.publishedResult else {
            throw ScribeError.message("Результат ещё не опубликован")
        }
        let scalars = Array(result.text.text.unicodeScalars)
        try edit.validate(scalarCount: scalars.count)
        result.text = TextRevision(id: UUID().uuidString, text: replacedText(scalars, edit))
        result.pairs = try transformedPairs(result.pairs, editingSource: false,
                                            edit: edit, scalarCount: scalars.count)
        result.warnings = try transformedWarnings(result.warnings, edit: edit, scalarCount: scalars.count)
        var next = card
        next.publishedResult = result
        try next.validate()
        return next
    }

    private static func replacedText(_ scalars: [Unicode.Scalar], _ edit: ScalarEdit) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[..<Int(edit.start)])
        view.append(contentsOf: edit.replacement.unicodeScalars)
        view.append(contentsOf: scalars[Int(edit.end)...])
        return String(view)
    }
}

extension AnonymizationCardDocument {
    /// True when the published result was built from an earlier source revision
    /// than the current left panel — compared by revision ids, never by content
    /// (domain invariant 7).
    public var resultBuiltFromEarlierSource: Bool {
        guard let result = publishedResult else { return false }
        return result.input.source.id != source.id
    }

    /// True when the right panel was manually edited after publication
    /// (domain invariant 7: mismatching `text` and `generatedText` ids).
    public var resultManuallyEdited: Bool {
        guard let result = publishedResult else { return false }
        return result.text.id != result.generatedText.id
    }
}

/// Scalar↔UTF-16 coordinate bridge over one concrete text version. The editor
/// speaks NSRange (UTF-16), the archive speaks `TextRange` (Unicode scalars).
/// Conversion is exact: boundaries never fall inside a surrogate pair, and an
/// emoji beyond the BMP counts as one scalar and two UTF-16 units. Build the
/// bridge off the main actor for a loaded version, like `ResultPresentation`
/// prepares text, and discard it when the revision changes.
public struct TextUTF16Bridge: Sendable {
    public let scalarCount: Int
    public let utf16Length: Int
    /// Sorted scalar indices of the scalars above U+FFFF (two UTF-16 units).
    private let astralScalarIndices: [Int]

    public init(text: String) {
        var astral: [Int] = []
        var total = 0
        for (index, scalar) in text.unicodeScalars.enumerated() {
            if scalar.value > 0xFFFF { astral.append(index) }
            total += 1
        }
        astralScalarIndices = astral
        scalarCount = total
        utf16Length = total + astral.count
    }

    /// UTF-16 offset of the scalar boundary `scalarIndex` (`0...scalarCount`).
    public func utf16Offset(ofScalarBoundary scalarIndex: Int) -> Int? {
        guard scalarIndex >= 0, scalarIndex <= scalarCount else { return nil }
        return scalarIndex + astralBefore(scalarIndex)
    }

    /// Scalar boundary at `utf16Offset` (`0...utf16Length`); nil when the offset
    /// falls inside a surrogate pair or outside the text.
    public func scalarBoundary(atUTF16Offset offset: Int) -> Int? {
        guard offset >= 0, offset <= utf16Length else { return nil }
        var low = 0
        var high = scalarCount
        while low < high {
            let mid = low + (high - low) / 2
            if mid + astralBefore(mid) < offset { low = mid + 1 } else { high = mid }
        }
        guard low + astralBefore(low) == offset else { return nil }
        return low
    }

    /// Exact NSRange of a scalar range, or nil when the range is empty or out
    /// of bounds.
    public func nsRange(from range: TextRange) -> NSRange? {
        guard let location = utf16Offset(ofScalarBoundary: Int(range.start)),
              let end = utf16Offset(ofScalarBoundary: Int(range.end)),
              location < end else { return nil }
        return NSRange(location: location, length: end - location)
    }

    /// Exact scalar range of a non-empty editor NSRange, or nil when it is out
    /// of bounds or an edge splits a surrogate pair. Editor selections sit on
    /// grapheme boundaries, which are always scalar boundaries.
    public func textRange(from range: NSRange) -> TextRange? {
        guard range.length > 0,
              let start = scalarBoundary(atUTF16Offset: range.location),
              let end = scalarBoundary(atUTF16Offset: range.location + range.length),
              start < end else { return nil }
        return TextRange(start: UInt(start), end: UInt(end))
    }

    /// Builds an edit from one editor replacement: a non-empty selection is
    /// replaced (possibly with empty text — a deletion), an empty selection is
    /// a pure insertion at the caret. Nil when the coordinates are invalid or
    /// the operation would change nothing.
    public func edit(fromSelectedRange range: NSRange, replacement: String) -> ScalarEdit? {
        if range.length == 0 {
            guard !replacement.isEmpty,
                  let scalar = scalarBoundary(atUTF16Offset: range.location) else { return nil }
            return ScalarEdit(start: UInt(scalar), end: UInt(scalar), replacement: replacement)
        }
        guard let text = textRange(from: range) else { return nil }
        return ScalarEdit(start: text.start, end: text.end, replacement: replacement)
    }

    /// Number of astral scalars with a scalar index below `scalarIndex`.
    private func astralBefore(_ scalarIndex: Int) -> Int {
        var low = 0
        var high = astralScalarIndices.count
        while low < high {
            let mid = low + (high - low) / 2
            if astralScalarIndices[mid] < scalarIndex { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
