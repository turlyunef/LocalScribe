import Foundation

/// One shared hint list of product names, abbreviations and participant names
/// for the ASR backends that accept a vocabulary hint. The saved list is
/// normalized once, pinned verbatim into `RunInfo.recognitionTerms` and applied
/// identically to primary and recovery passes. Backends without hint support
/// never see the list, and it never reaches logs, metrics or worker events.
public enum RecognitionDictionary {
    /// `ModelProfile.resolvedASRBackend` values that consume the hint.
    public static let supportedBackends: Set<String> = ["whisper", "qwen3"]

    /// Structural caps of the saved list. The exact token budget of a loaded
    /// model is checked by the engine with its own tokenizer; these caps only
    /// bound the settings record and the engine context.
    public static let maximumTerms = 100
    public static let maximumTermCharacters = 64
    public static let maximumTotalCharacters = 1000

    /// Trim each line, drop empty lines and exact duplicates, preserving the
    /// first occurrence, the order, the case and the script of every term.
    /// This step never throws and never drops a non-empty line silently beyond
    /// deduplication; use it for previews and change detection.
    public static func sanitized(_ lines: [String]) -> [String] {
        var seen: Set<String> = []
        var terms: [String] = []
        for line in lines {
            let term = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term).inserted else { continue }
            terms.append(term)
        }
        return terms
    }

    /// Validate the structural caps of an already sanitized list. Oversized
    /// lists are rejected with an actionable message instead of being trimmed.
    public static func validate(_ terms: [String]) throws {
        guard terms.count <= maximumTerms else {
            throw ScribeError.message("Словарь распознавания превышает \(maximumTerms) терминов. Удалите лишние строки.")
        }
        for term in terms where term.count > maximumTermCharacters {
            throw ScribeError.message("Термин словаря распознавания длиннее \(maximumTermCharacters) символов. Разбейте или сократите его.")
        }
        let total = terms.reduce(0) { $0 + $1.count }
        guard total <= maximumTotalCharacters else {
            throw ScribeError.message("Словарь распознавания превышает бюджет контекста: \(total) символов из \(maximumTotalCharacters) доступных. Сократите список.")
        }
    }

    /// Sanitize and validate in one step for saving the settings record.
    public static func normalize(_ lines: [String]) throws -> [String] {
        let terms = sanitized(lines)
        try validate(terms)
        return terms
    }

    /// A pinned snapshot is meaningful only for the supported backends.
    public static func supportsHint(backend: String?) -> Bool {
        guard let backend else { return false }
        return supportedBackends.contains(backend)
    }
}
