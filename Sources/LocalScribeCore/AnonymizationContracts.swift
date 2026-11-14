import CryptoKit
import Foundation

/// Wire artifacts of one local text-anonymization attempt. The document text
/// and the complete result pass between the app and the worker only through
/// these files; the JSONL protocol channel carries identifiers, progress and
/// safe statuses, never document text, substitutions or names.
///
/// This file also fixes the domain values of the text archive: cards,
/// attempts, results, substitution history and warning/range coordinates.
/// Group organization and file transactions live in
/// `AnonymizationArchiveCatalog` and `AnonymizationRepository`.

/// Immutable import format of a text card.
public enum AnonymizationSourceFormat: String, Codable, Sendable {
    case txt = "TXT"
    case markdown = "MARKDOWN"
}

/// One frozen version of a text: a unique revision identity plus the full
/// content. The identity lets a result or attempt name the exact version it
/// was built from.
public struct TextRevision: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

/// The input frozen for one anonymization attempt when it is admitted to the
/// worker. Written by the app as `input.json` into the attempt workspace named
/// by the command's `anonymizationPath`; the worker validates it against the
/// command's identifiers before any processing.
public struct AnonymizationAttemptInput: Codable, Sendable, Equatable {
    public static let filename = "input.json"
    public var schemaVersion = 1
    /// Card (anonymization file) UUID; must equal the command's jobId.
    public var fileId: String
    /// Attempt UUID; must equal the command's runId.
    public var attemptId: String
    /// The source version admitted for this attempt.
    public var source: TextRevision
    /// Import name without extension; the name is processed in the same run.
    public var importedNameStem: String
    public var sourceFormat: AnonymizationSourceFormat
    /// Exact saved data-type wordings fixed for this run.
    public var dataTypes: [String]
    /// Model pinning frozen at admission, like audio and diagram runs.
    public var profileID: String
    public var packageID: String
    /// The card's accumulated automatic-substitution history before this run.
    /// Absent on inputs written before the processing stage: treated as empty.
    /// The worker reuses prior substitutions for returning values, including
    /// values that temporarily disappeared from the source.
    public var automaticSubstitutions: [AutomaticSubstitution]?
    public init(fileId: String, attemptId: String, source: TextRevision, importedNameStem: String,
                sourceFormat: AnonymizationSourceFormat, dataTypes: [String], profileID: String, packageID: String,
                automaticSubstitutions: [AutomaticSubstitution]? = nil) {
        self.fileId = fileId; self.attemptId = attemptId; self.source = source
        self.importedNameStem = importedNameStem; self.sourceFormat = sourceFormat
        self.dataTypes = dataTypes; self.profileID = profileID; self.packageID = packageID
        self.automaticSubstitutions = automaticSubstitutions
    }
    /// All failures are safe machine messages: they never quote the document,
    /// its name, the data types or any substitution.
    public func validate() throws {
        guard schemaVersion == 1, UUID(uuidString: fileId) != nil, UUID(uuidString: attemptId) != nil,
              UUID(uuidString: source.id) != nil else {
            throw ScribeError.message("Некорректная версия или идентификаторы входа обезличивания")
        }
        guard !importedNameStem.isEmpty, importedNameStem != ".", importedNameStem != "..",
              !importedNameStem.contains("/"), !importedNameStem.contains("\0") else {
            throw ScribeError.message("Некорректное имя импорта во входе обезличивания")
        }
        guard source.text.contains(where: { !$0.isWhitespace }) else {
            throw ScribeError.message("Исходный текст обезличивания пуст")
        }
        guard !dataTypes.isEmpty,
              dataTypes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ScribeError.message("Некорректный список типов данных обезличивания")
        }
        guard ModelProfile.safeComponent(profileID), ModelProfile.safeComponent(packageID) else {
            throw ScribeError.message("Некорректное назначение модели во входе обезличивания")
        }
        if let automaticSubstitutions { try AnonymizationCardDocument.validateSubstitutions(automaticSubstitutions) }
    }
    /// The artifact must belong to the command's exact card and attempt. Equal
    /// UUIDs of two different archives never mix because the job kind travels
    /// with the command and is echoed by every event.
    public func matches(command: WorkerCommand) -> Bool {
        fileId == command.jobId && attemptId == command.runId
    }
}

/// The successful-run artifact the worker writes as `result.json` next to
/// `input.json` in the attempt workspace. `substitutions` is the card's full
/// accumulated history after this run — prior entries (including values that
/// are absent from the current text) plus this run's new keys — so the
/// coordinator can publish the result and the updated history in one
/// transaction. The JSONL protocol channel never carries any of this content.
public struct AnonymizationRunArtifact: Codable, Equatable, Sendable {
    public static let filename = "result.json"
    public var schemaVersion = 1
    public var result: AnonymizationResult
    public var substitutions: [AutomaticSubstitution]
    public init(result: AnonymizationResult, substitutions: [AutomaticSubstitution]) {
        self.result = result; self.substitutions = substitutions
    }
    public func validate(sourceScalarCount: Int, importedNameScalarCount: Int) throws {
        guard schemaVersion == 1 else { throw ScribeError.message("Некорректная версия результата обезличивания") }
        try result.validate(sourceScalarCount: sourceScalarCount, importedNameScalarCount: importedNameScalarCount)
        try AnonymizationCardDocument.validateSubstitutions(substitutions)
    }
}

// MARK: - Domain values of the text archive

/// Non-empty half-open range `[start, end)` in Unicode scalar values counted
/// from zero of a named version (a text revision or an imported name stem).
public struct TextRange: Codable, Equatable, Hashable, Sendable {
    public var start: UInt
    public var end: UInt
    public init(start: UInt, end: UInt) { self.start = start; self.end = end }
    public var isEmpty: Bool { start >= end }
    public func isValid(withinScalarCount scalarCount: Int) -> Bool {
        guard !isEmpty, let count = UInt(exactly: scalarCount) else { return false }
        return end <= count
    }
}

/// Immutable identity of the original import bytes, including the BOM. Two
/// cards are byte-identical iff their archived byte sequences are equal; the
/// length and SHA-256 are index hints and are always checked against the bytes.
public struct ByteContentIdentity: Codable, Equatable, Sendable {
    public var bytesBase64: String
    public var byteLength: UInt
    public var sha256: String
    public init(bytes: Data) {
        bytesBase64 = bytes.base64EncodedString()
        byteLength = UInt(bytes.count)
        sha256 = Self.sha256Hex(bytes)
    }
    public var bytes: Data? { Data(base64Encoded: bytesBase64) }
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The input frozen for one anonymization attempt when it is admitted to the
/// worker: the source version, model pinning and the exact saved data-type
/// wordings. Stored with the attempt and its successful result as a historical
/// reference, even after the pinned package is removed.
public struct RunInput: Codable, Equatable, Sendable {
    public var source: TextRevision
    public var profileID: String
    public var packageID: String
    public var dataTypes: [String]
    public init(source: TextRevision, profileID: String, packageID: String, dataTypes: [String]) {
        self.source = source; self.profileID = profileID; self.packageID = packageID; self.dataTypes = dataTypes
    }
    public func validate() throws {
        guard UUID(uuidString: source.id) != nil else {
            throw ScribeError.message("Некорректная версия исходника во входе обезличивания")
        }
        guard !dataTypes.isEmpty,
              dataTypes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ScribeError.message("Некорректный список типов данных во входе обезличивания")
        }
        guard ModelProfile.safeComponent(profileID), ModelProfile.safeComponent(packageID) else {
            throw ScribeError.message("Некорректное назначение модели во входе обезличивания")
        }
    }
}

/// State of the latest attempt of a card. `WAITING_MODEL` lives outside the
/// common FIFO; after a restart `QUEUED` and `RUNNING` become `INTERRUPTED`.
public enum AnonymizationAttemptState: String, Codable, CaseIterable, Sendable {
    case waitingModel = "WAITING_MODEL"
    case queued = "QUEUED"
    case running = "RUNNING"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
    case interrupted = "INTERRUPTED"
}

public enum AnonymizationFailureKind: String, Codable, Sendable {
    case sizeLimit = "SIZE_LIMIT"
    case processing = "PROCESSING"
}

/// Safe failure reason of an attempt: `SIZE_LIMIT` carries both measured byte
/// sizes, `PROCESSING` carries a non-empty neutral message. Failures never
/// quote document text, names or substitutions.
public struct AnonymizationAttemptFailure: Codable, Equatable, Sendable {
    public var kind: AnonymizationFailureKind
    public var actualBytes: UInt?
    public var limitBytes: UInt?
    public var reason: String?
    public init(kind: AnonymizationFailureKind, actualBytes: UInt? = nil, limitBytes: UInt? = nil, reason: String? = nil) {
        self.kind = kind; self.actualBytes = actualBytes; self.limitBytes = limitBytes; self.reason = reason
    }
    public static func sizeLimit(actualBytes: UInt, limitBytes: UInt) -> AnonymizationAttemptFailure {
        AnonymizationAttemptFailure(kind: .sizeLimit, actualBytes: actualBytes, limitBytes: limitBytes)
    }
    public static func processing(_ reason: String) -> AnonymizationAttemptFailure {
        AnonymizationAttemptFailure(kind: .processing, reason: reason)
    }
    public func validate() throws {
        switch kind {
        case .sizeLimit:
            guard let actual = actualBytes, let limit = limitBytes, actual >= 1, limit >= 1, reason == nil else {
                throw ScribeError.message("Некорректная причина отказа по размеру")
            }
        case .processing:
            guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  actualBytes == nil, limitBytes == nil else {
                throw ScribeError.message("Некорректная причина ошибки обработки")
            }
        }
    }
}

/// The latest attempt of a card. Every retry receives a new identity; the
/// input is fixed when the attempt enters `RUNNING` and is preserved until the
/// attempt ends.
public struct AnonymizationAttempt: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var state: AnonymizationAttemptState
    /// Snapshot of the source frozen by an explicit retry command; cleared
    /// when the retry returns to `WAITING_MODEL`.
    public var requestedSource: TextRevision?
    /// The right-panel version a retry is allowed to replace on success; nil
    /// while the card has no published result.
    public var expectedResultRevisionID: String?
    /// Fixed when admitted to `RUNNING`; never present on a `WAITING_MODEL` or
    /// `QUEUED` attempt.
    public var input: RunInput?
    public var failure: AnonymizationAttemptFailure?
    public init(id: String = UUID().uuidString, state: AnonymizationAttemptState,
                requestedSource: TextRevision? = nil, expectedResultRevisionID: String? = nil,
                input: RunInput? = nil, failure: AnonymizationAttemptFailure? = nil) {
        self.id = id; self.state = state; self.requestedSource = requestedSource
        self.expectedResultRevisionID = expectedResultRevisionID
        self.input = input; self.failure = failure
    }
    public func validate(hasPublishedResult: Bool) throws {
        guard schemaVersion == 1, UUID(uuidString: id) != nil else {
            throw ScribeError.message("Некорректная версия или идентификатор попытки обезличивания")
        }
        if state == .failed {
            guard let failure else { throw ScribeError.message("Неудачная попытка обезличивания без причины") }
            try failure.validate()
        } else if failure != nil {
            throw ScribeError.message("Причина ошибки есть только у неудачной попытки обезличивания")
        }
        if let input { try input.validate() }
        if state == .waitingModel || state == .queued, input != nil {
            throw ScribeError.message("Вход есть только у запущенной попытки обезличивания")
        }
        if state == .running, input == nil {
            throw ScribeError.message("Запущенная попытка обезличивания без зафиксированного входа")
        }
        if state == .succeeded, !hasPublishedResult {
            throw ScribeError.message("Успешная попытка обезличивания без опубликованного результата")
        }
        if let expected = expectedResultRevisionID {
            guard UUID(uuidString: expected) != nil, hasPublishedResult else {
                throw ScribeError.message("Некорректная согласованная версия результата")
            }
        }
        if let requestedSource, UUID(uuidString: requestedSource.id) == nil {
            throw ScribeError.message("Некорректный снимок исходника повтора")
        }
    }
}

/// One actual replacement of the published result: paired non-empty ranges in
/// the current left (`AnonymizationCardDocument.source`) and right
/// (`AnonymizationResult.text`) versions.
public struct ReplacementPair: Codable, Equatable, Sendable {
    public var sourceRange: TextRange
    public var resultRange: TextRange
    public init(sourceRange: TextRange, resultRange: TextRange) {
        self.sourceRange = sourceRange; self.resultRange = resultRange
    }
}

public enum AnonymizationWarningKind: String, Codable, Sendable {
    case doubtfulFragment = "DOUBTFUL_FRAGMENT"
    case uninterpretedType = "UNINTERPRETED_TYPE"
}

public enum AnonymizationWarningTarget: String, Codable, Sendable {
    case body = "BODY"
    case importedName = "IMPORTED_NAME"
}

/// One observation of a successful run. A doubtful fragment carries target and
/// ranges (input/generated, plus a traceable review position in the current
/// right text); an uninterpreted type carries the exact wording from the run
/// input and no ranges.
public struct AnonymizationWarning: Codable, Equatable, Sendable {
    public var kind: AnonymizationWarningKind
    public var target: AnonymizationWarningTarget?
    public var inputRange: TextRange?
    public var generatedRange: TextRange?
    public var reviewRange: TextRange?
    public var dataType: String?
    public init(kind: AnonymizationWarningKind, target: AnonymizationWarningTarget? = nil,
                inputRange: TextRange? = nil, generatedRange: TextRange? = nil,
                reviewRange: TextRange? = nil, dataType: String? = nil) {
        self.kind = kind; self.target = target; self.inputRange = inputRange
        self.generatedRange = generatedRange; self.reviewRange = reviewRange; self.dataType = dataType
    }
}

/// The published automatic result of one successful run plus its editable
/// representation. `generatedText` and `text` share an identity at publication;
/// a manual edit creates a new `text.id`.
public struct AnonymizationResult: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var input: RunInput
    public var generatedText: TextRevision
    public var text: TextRevision
    public var downloadNameStem: String
    public var bodyReplacementCount: UInt
    public var pairs: [ReplacementPair]
    public var warnings: [AnonymizationWarning]
    public init(input: RunInput, generatedText: TextRevision, text: TextRevision,
                downloadNameStem: String, bodyReplacementCount: UInt,
                pairs: [ReplacementPair] = [], warnings: [AnonymizationWarning] = []) {
        self.input = input; self.generatedText = generatedText; self.text = text
        self.downloadNameStem = downloadNameStem; self.bodyReplacementCount = bodyReplacementCount
        self.pairs = pairs; self.warnings = warnings
    }
}

/// One accumulated automatic substitution of a card, keyed by the exact saved
/// type wording and the confirmed source value. History survives the value
/// temporarily disappearing from the source.
public struct AutomaticSubstitution: Codable, Equatable, Sendable {
    public var dataType: String
    public var sourceValue: String
    public var substituteValue: String
    public init(dataType: String, sourceValue: String, substituteValue: String) {
        self.dataType = dataType; self.sourceValue = sourceValue; self.substituteValue = substituteValue
    }
}

/// The versioned document of one text card. The archive catalog owns group
/// membership and allocates import positions; this document owns the content
/// and everything derived from it. A card that fails `validate()` is an
/// archive error and is never partially presented.
public struct AnonymizationCardDocument: Codable, Identifiable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: String
    /// Unique increasing position of the successful import; never reused after
    /// a card is deleted.
    public var importOrder: UInt
    public var importContentIdentity: ByteContentIdentity
    public var importedNameStem: String
    public var sourceFormat: AnonymizationSourceFormat
    public var displayName: String
    /// The current left-panel version.
    public var source: TextRevision
    public var latestAttempt: AnonymizationAttempt
    /// Nil until the first successful publication.
    public var publishedResult: AnonymizationResult?
    public var automaticSubstitutions: [AutomaticSubstitution] = []
    /// Optional for documents written before reverse transformations existed.
    public var restoration: AnonymizationRestoration?
    public init(id: String, importOrder: UInt, importContentIdentity: ByteContentIdentity,
                importedNameStem: String, sourceFormat: AnonymizationSourceFormat,
                displayName: String, source: TextRevision, latestAttempt: AnonymizationAttempt,
                publishedResult: AnonymizationResult? = nil,
                automaticSubstitutions: [AutomaticSubstitution] = [],
                restoration: AnonymizationRestoration? = nil) {
        self.id = id; self.importOrder = importOrder; self.importContentIdentity = importContentIdentity
        self.importedNameStem = importedNameStem; self.sourceFormat = sourceFormat
        self.displayName = displayName; self.source = source; self.latestAttempt = latestAttempt
        self.publishedResult = publishedResult; self.automaticSubstitutions = automaticSubstitutions
        self.restoration = restoration
    }
}

/// Lightweight snapshot projection of a card: no document text, archived bytes
/// or results are carried, so search and status updates never read files.
public struct AnonymizationCardSummary: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var importOrder: UInt
    public var displayName: String
    public var sourceFormat: AnonymizationSourceFormat
    public var attemptState: AnonymizationAttemptState
    public var hasPublishedResult: Bool
    public var resultWarningCount: Int
    public var bodyReplacementCount: UInt?
    public var restorationResultRevisionID: String?
    public init(document: AnonymizationCardDocument) {
        id = document.id; importOrder = document.importOrder; displayName = document.displayName
        sourceFormat = document.sourceFormat; attemptState = document.latestAttempt.state
        hasPublishedResult = document.publishedResult != nil
        resultWarningCount = document.publishedResult?.warnings.count ?? 0
        bodyReplacementCount = document.publishedResult?.bodyReplacementCount
        restorationResultRevisionID = document.restoration?.result.id
    }
}

// MARK: - Full-document validation

extension AnonymizationCardDocument {
    /// Shared rule for import and download stems: a single path component
    /// without extension, never empty, "." or "..", without separators or NUL.
    public static func validateFileStem(_ stem: String) throws {
        guard !stem.isEmpty, stem != ".", stem != "..",
              !stem.contains("/"), !stem.contains("\0") else {
            throw ScribeError.message("Недопустимое имя файла карточки обезличивания")
        }
    }

    /// The whole document is checked at once: schema version, UUIDs, byte
    /// identity consistency, conditional obligation of attempt and result
    /// fields, range bounds and pairwise disjointness, and substitution keys.
    public func validate() throws {
        guard schemaVersion == 1, UUID(uuidString: id) != nil, UUID(uuidString: source.id) != nil,
              UUID(uuidString: latestAttempt.id) != nil, importOrder >= 1 else {
            throw ScribeError.message("Некорректная версия или идентификаторы карточки обезличивания")
        }
        guard let bytes = importContentIdentity.bytes, importContentIdentity.byteLength >= 1,
              UInt(bytes.count) == importContentIdentity.byteLength,
              importContentIdentity.sha256 == ByteContentIdentity.sha256Hex(bytes) else {
            throw ScribeError.message("Нарушена целостность исходных байтов карточки обезличивания")
        }
        try Self.validateFileStem(importedNameStem)
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScribeError.message("Название карточки обезличивания не может быть пустым")
        }
        try latestAttempt.validate(hasPublishedResult: publishedResult != nil)
        if let publishedResult {
            try publishedResult.validate(sourceScalarCount: source.text.unicodeScalars.count,
                                         importedNameScalarCount: importedNameStem.unicodeScalars.count)
        }
        if let restoration {
            guard publishedResult != nil else {
                throw ScribeError.message("Некорректный результат обратного преобразования")
            }
            try restoration.validate()
        }
        try Self.validateSubstitutions(automaticSubstitutions)
    }

    public static func validateSubstitutions(_ substitutions: [AutomaticSubstitution]) throws {
        var keys = Set<[String]>()
        var substitutesByType = [String: Set<String>]()
        for substitution in substitutions {
            guard !substitution.dataType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !substitution.sourceValue.isEmpty, !substitution.substituteValue.isEmpty,
                  substitution.substituteValue != substitution.sourceValue else {
                throw ScribeError.message("Некорректная история подстановок карточки")
            }
            guard keys.insert([substitution.dataType, substitution.sourceValue]).inserted else {
                throw ScribeError.message("Повторяющийся ключ в истории подстановок карточки")
            }
            guard substitutesByType[substitution.dataType, default: []].insert(substitution.substituteValue).inserted else {
                throw ScribeError.message("Повторяющееся вымышленное значение в истории подстановок карточки")
            }
        }
    }
}

extension AnonymizationResult {
    /// Bounds, conditional obligation and pairwise disjointness of the result
    /// against the card's current versions. Pairs and warnings are maintained
    /// by the editing layer, so both are re-checked on every read.
    public func validate(sourceScalarCount: Int, importedNameScalarCount: Int) throws {
        guard schemaVersion == 1, UUID(uuidString: generatedText.id) != nil, UUID(uuidString: text.id) != nil else {
            throw ScribeError.message("Некорректная версия или идентификаторы результата обезличивания")
        }
        // Same revision identity means the unedited automatic result: manual
        // edits must carry their own `text` id.
        if text.id == generatedText.id, text.text != generatedText.text {
            throw ScribeError.message("Версия результата с тем же идентификатором обязана совпадать с автоматической")
        }
        try input.validate()
        try AnonymizationCardDocument.validateFileStem(downloadNameStem)
        let generatedScalars = generatedText.text.unicodeScalars.count
        let currentScalars = text.text.unicodeScalars.count
        for pair in pairs {
            guard pair.sourceRange.isValid(withinScalarCount: sourceScalarCount),
                  pair.resultRange.isValid(withinScalarCount: currentScalars) else {
                throw ScribeError.message("Диапазон пары выходит за границы текущих версий")
            }
        }
        try Self.requireDisjoint(pairs.map(\.sourceRange))
        try Self.requireDisjoint(pairs.map(\.resultRange))
        for warning in warnings {
            try warning.validate(input: input, generatedScalarCount: generatedScalars,
                                 importedNameScalarCount: importedNameScalarCount,
                                 generatedNameScalarCount: downloadNameStem.unicodeScalars.count,
                                 currentTextScalarCount: currentScalars)
        }
    }

    private static func requireDisjoint(_ ranges: [TextRange]) throws {
        let sorted = ranges.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        // zip keeps an empty or single-range list valid without building 1..<0.
        for (previous, current) in zip(sorted, sorted.dropFirst()) where current.start < previous.end {
            throw ScribeError.message("Пересекающиеся диапазоны результата обезличивания")
        }
    }
}

extension AnonymizationWarning {
    func validate(input: RunInput, generatedScalarCount: Int, importedNameScalarCount: Int,
                  generatedNameScalarCount: Int, currentTextScalarCount: Int) throws {
        switch kind {
        case .doubtfulFragment:
            guard let target, let inputRange, let generatedRange, dataType == nil else {
                throw ScribeError.message("Неполное предупреждение о сомнительном фрагменте")
            }
            switch target {
            case .body:
                guard inputRange.isValid(withinScalarCount: input.source.text.unicodeScalars.count),
                      generatedRange.isValid(withinScalarCount: generatedScalarCount),
                      reviewRange == nil || reviewRange!.isValid(withinScalarCount: currentTextScalarCount) else {
                    throw ScribeError.message("Диапазон предупреждения выходит за границы версий")
                }
            case .importedName:
                guard inputRange.isValid(withinScalarCount: importedNameScalarCount),
                      generatedRange.isValid(withinScalarCount: generatedNameScalarCount),
                      reviewRange == nil else {
                    throw ScribeError.message("Диапазон предупреждения имени выходит за границы имени")
                }
            }
        case .uninterpretedType:
            guard let dataType, input.dataTypes.contains(dataType),
                  target == nil, inputRange == nil, generatedRange == nil, reviewRange == nil else {
                throw ScribeError.message("Некорректное предупреждение о непонятой формулировке")
            }
        }
    }
}
