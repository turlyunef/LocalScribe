import Foundation
import LocalScribeCore

/// Local text-anonymization boundary. The engine loads the attempt's frozen
/// input, verifies it against the command, resolves the pinned qualified
/// profile against the model catalog, detects candidates over bounded windows
/// of the whole input (body and imported name), resolves them document-wide,
/// reuses and extends the card's substitution history deterministically, and
/// assembles the full result with Markdown-aware representations. The result
/// is written as `result.json` next to `input.json`; document text,
/// substitutions and names never enter the protocol channel or logs.
actor AnonymizationEngine {
    typealias Emit = @Sendable (String, String, String?) -> Void

    struct Outcome: Sendable {
        var artifact: AnonymizationRunArtifact
        /// Limited numeric diagnostics only — no text, values or paths.
        var metrics: [String: Double]
    }

    /// Keyed rendering info of one substitution: the fictional base value and
    /// how it must be declined per occurrence.
    private struct KeyInfo {
        var substitute: String
        var feminine: Bool
        var isRussianName: Bool
    }

    let attemptURL: URL
    let input: AnonymizationAttemptInput
    private let recognizer: AnonymizationRecognizing
    private let valueSource: AnonymizationValueSourcing
    private let emit: Emit

    init(command: WorkerCommand, emit: @escaping Emit) throws {
        try self.init(command: command,
            makeRecognizer: { MLXAnonymizationRecognizer(folder: $0) },
            makeValueSource: { SeededAnonymizationValueSource(seed: Self.substitutionSeed(input: $0)) },
            emit: emit)
    }

    /// Diagnostic and test factory: recognizer and value source are injected,
    /// every constructor check still applies (like `DiagramEngine`).
    init(command: WorkerCommand, recognizer: AnonymizationRecognizing,
         valueSource: AnonymizationValueSourcing, emit: @escaping Emit) throws {
        try self.init(command: command, makeRecognizer: { _ in recognizer },
            makeValueSource: { _ in valueSource }, emit: emit)
    }

    /// Production path with an already-validated input: the protocol route
    /// loads the attempt input before any progress event, so validation
    /// failures keep the point-1 event contract (started → failed).
    init(command: WorkerCommand, input: AnonymizationAttemptInput, emit: @escaping Emit) throws {
        try self.init(command: command, input: input,
            makeRecognizer: { MLXAnonymizationRecognizer(folder: $0) },
            makeValueSource: { SeededAnonymizationValueSource(seed: Self.substitutionSeed(input: $0)) },
            emit: emit)
    }

    /// Qualification runs before the catalog stamps ANONYMIZATION. Only the
    /// production task gate is skipped, while all integrity checks still apply.
    init(probing command: WorkerCommand, input: AnonymizationAttemptInput, emit: @escaping Emit) throws {
        let models = URL(fileURLWithPath: command.modelsPath)
        let folder = try Self.resolvePinnedModelFolder(models: models, toolsPath: command.toolsPath, input: input, task: nil)
        try self.init(command: command, input: input, modelFolder: folder,
            makeRecognizer: { MLXAnonymizationRecognizer(folder: $0) },
            makeValueSource: { SeededAnonymizationValueSource(seed: Self.substitutionSeed(input: $0)) },
            emit: emit)
    }

    private init(command: WorkerCommand,
                 makeRecognizer: @escaping (URL) -> AnonymizationRecognizing,
                 makeValueSource: @escaping (AnonymizationAttemptInput) -> AnonymizationValueSourcing,
                 emit: @escaping Emit) throws {
        try self.init(command: command, input: Self.loadInput(command: command),
                      makeRecognizer: makeRecognizer, makeValueSource: makeValueSource, emit: emit)
    }

    private init(command: WorkerCommand, input: AnonymizationAttemptInput,
                 makeRecognizer: @escaping (URL) -> AnonymizationRecognizing,
                 makeValueSource: @escaping (AnonymizationAttemptInput) -> AnonymizationValueSourcing,
                 emit: @escaping Emit) throws {
        let models = URL(fileURLWithPath: command.modelsPath)
        let folder = try Self.resolvePinnedModelFolder(models: models, toolsPath: command.toolsPath, input: input, task: .anonymization)
        try self.init(command: command, input: input, modelFolder: folder,
                      makeRecognizer: makeRecognizer, makeValueSource: makeValueSource, emit: emit)
    }

    private init(command: WorkerCommand, input: AnonymizationAttemptInput, modelFolder: URL,
                 makeRecognizer: @escaping (URL) -> AnonymizationRecognizing,
                 makeValueSource: @escaping (AnonymizationAttemptInput) -> AnonymizationValueSourcing,
                 emit: @escaping Emit) throws {
        guard let path = command.anonymizationPath else { throw ScribeError.message("Некорректная команда обезличивания") }
        guard input.matches(command: command) else { throw ScribeError.message("Вход обезличивания не соответствует заданию") }
        self.attemptURL = URL(fileURLWithPath: path)
        self.input = input
        self.recognizer = makeRecognizer(modelFolder)
        self.valueSource = makeValueSource(input)
        self.emit = emit
    }

    /// Loads `input.json` from the attempt workspace named by the command and
    /// validates it against the command's identifiers.
    static func loadInput(command: WorkerCommand) throws -> AnonymizationAttemptInput {
        guard let path = command.anonymizationPath else { throw ScribeError.message("Некорректная команда обезличивания") }
        let url = URL(fileURLWithPath: path).appendingPathComponent(AnonymizationAttemptInput.filename)
        let input: AnonymizationAttemptInput
        do { input = try Disk.read(AnonymizationAttemptInput.self, at: url) }
        // Disk size limits are already safe messages; raw I/O errors may carry
        // paths and must stay wrapped.
        catch let error as ScribeError { throw error }
        catch { throw ScribeError.message("Не удалось прочитать вход обезличивания") }
        try input.validate()
        guard input.matches(command: command) else { throw ScribeError.message("Вход обезличивания не соответствует заданию") }
        return input
    }

    /// Deterministic seed of the card's substitution draws: the card identity,
    /// the exact saved type wordings and the incoming history. Identical
    /// inputs and history produce identical substitutions; different cards
    /// diverge. The attempt id is deliberately excluded — a retry of the same
    /// input draws the same values.
    static func substitutionSeed(input: AnonymizationAttemptInput) -> UInt64 {
        let history = (input.automaticSubstitutions ?? [])
            .map { "\($0.dataType)\u{2}\($0.sourceValue)\u{2}\($0.substituteValue)" }
            .sorted()
            .joined(separator: "\u{3}")
        let material = input.fileId + "\u{3}" + input.dataTypes.joined(separator: "\u{2}") + "\u{3}" + history
        let hex = Disk.fingerprint(material)
        return UInt64(hex.prefix(16), radix: 16) ?? 0
    }

    /// Resolves the run's pinned profile like the audio and diagram
    /// pipelines: exact identity, task support, package identity, hardware
    /// compatibility and full size/SHA verification before any SDK load.
    private static func resolvePinnedModelFolder(models: URL, toolsPath: String?, input: AnonymizationAttemptInput,
                                                 task: ModelTask?) throws -> URL {
        guard let catalogURL = Self.catalogURL(for: models, toolsPath: toolsPath) else {
            throw ScribeError.message("Не найден каталог моделей для обезличивания")
        }
        let catalog: ModelCatalog
        do { catalog = try Disk.read(ModelCatalog.self, at: catalogURL) }
        catch { throw ScribeError.message("Не удалось прочитать каталог моделей") }
        guard catalog.schemaVersion == 1 else { throw ScribeError.message("Несовместимая версия каталога моделей") }
        let matches = catalog.models.filter { $0.id == input.profileID }
        guard matches.count == 1, let profile = matches.first, task.map({ profile.supports($0) }) != false else {
            throw ScribeError.message("Закреплённая модель обезличивания недоступна в каталоге")
        }
        guard profile.effectivePackageID == input.packageID else {
            throw ScribeError.message("Комплект модели обезличивания не совпадает с заданием")
        }
        try ModelHardware.current.requireCompatibility(for: profile)
        return try catalog.verifiedModelFolder(for: profile, at: models)
    }

    /// The pinned catalog is resolved the way the audio and diagram pipelines
    /// do: next to the tools folder of the passed toolsPath first (the app
    /// bundle layout), then next to the tools folder of the models root, then
    /// beside that root.
    private static func catalogURL(for models: URL, toolsPath: String?) -> URL? {
        var candidates: [URL] = []
        if let toolsPath, !toolsPath.isEmpty {
            candidates.append(URL(fileURLWithPath: toolsPath).deletingLastPathComponent().appendingPathComponent("models.lock.json"))
        }
        let parent = models.deletingLastPathComponent()
        candidates.append(parent.appendingPathComponent("tools/models.lock.json"))
        candidates.append(parent.appendingPathComponent("models.lock.json"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Processing

    func run() async throws -> Outcome {
        try Task.checkCancellation()
        let types = input.dataTypes
        let sourceScalars = Array(input.source.text.unicodeScalars)
        let nameScalars = Array(input.importedNameStem.unicodeScalars)

        // 1. Detection over bounded windows; a failed window fails the whole
        //    attempt — a partial result must never be published.
        var bodyCandidates: [AnonymizationSpanCandidate] = []
        var reportedUninterpreted = Set<String>()
        let bodyWindows = AnonymizationWindows.ranges(in: sourceScalars)
        for (index, window) in bodyWindows.enumerated() {
            try Task.checkCancellation()
            if index == 0 { emit("progress", "Загружаем модель…", nil) }
            emit("progress", "Обезличиваем текст — часть \(index + 1) из \(bodyWindows.count)", nil)
            let verified = try await detect(in: window, scalars: sourceScalars, types: types)
            bodyCandidates.append(contentsOf: verified.candidates)
            reportedUninterpreted.formUnion(verified.uninterpreted)
        }
        emit("progress", "Обрабатываем имя файла…", nil)
        var nameCandidates: [AnonymizationSpanCandidate] = []
        for window in AnonymizationWindows.ranges(in: nameScalars) {
            try Task.checkCancellation()
            let verified = try await detect(in: window, scalars: nameScalars, types: types)
            nameCandidates.append(contentsOf: verified.candidates)
            reportedUninterpreted.formUnion(verified.uninterpreted)
        }
        try Task.checkCancellation()

        // 2. Document-wide resolution of overlaps, doubts and repeats.
        let bodyPlan = AnonymizationResolution.resolve(candidates: bodyCandidates)
        let namePlan = AnonymizationResolution.resolve(candidates: nameCandidates)

        // 3. Substitution assignment over history with deterministic draws.
        var historyByKey: [String: AutomaticSubstitution] = [:]
        var substitutesByType: [String: Set<String>] = [:]
        for entry in input.automaticSubstitutions ?? [] {
            historyByKey[Self.key(dataType: entry.dataType, canonical: entry.sourceValue)] = entry
            substitutesByType[entry.dataType, default: []].insert(entry.substituteValue)
        }
        var keyInfo: [String: KeyInfo] = [:]
        var newSubstitutions: [AutomaticSubstitution] = []
        func prepared(_ items: [AnonymizationReplacementPlan.Item]) throws -> [AnonymizationAssemblyReplacement] {
            var assembled: [AnonymizationAssemblyReplacement] = []
            for item in items {
                let analysis = AnonymizationNames.analyze(item.value)
                let canonical = analysis?.canonical ?? item.value
                let key = Self.key(dataType: item.dataType, canonical: canonical)
                let info: KeyInfo
                if let existing = keyInfo[key] {
                    info = existing
                } else if let history = historyByKey[key] {
                    let canonicalAnalysis = AnonymizationNames.analyze(history.sourceValue)
                    info = KeyInfo(substitute: history.substituteValue,
                                   feminine: canonicalAnalysis?.feminine ?? analysis?.feminine ?? false,
                                   isRussianName: canonicalAnalysis != nil)
                    keyInfo[key] = info
                } else {
                    let shape: AnonymizationValueShape = analysis
                        .map { AnonymizationValueShape.russianName(feminine: $0.feminine) }
                        ?? .of(item.value)
                    // The value source already regenerates on collisions; the
                    // bounded retry keeps the contract enforced even for an
                    // injected source that returns an occupied value.
                    let occupied = substitutesByType[item.dataType] ?? []
                    var base: String?
                    for _ in 0..<8 {
                        let candidate = valueSource.value(for: canonical, shape: shape, occupied: occupied)
                        if candidate != canonical, !occupied.contains(candidate) { base = candidate; break }
                    }
                    guard let base else { throw ScribeError.message("Не удалось подобрать уникальную подстановку") }
                    substitutesByType[item.dataType, default: []].insert(base)
                    newSubstitutions.append(AutomaticSubstitution(dataType: item.dataType,
                                                                  sourceValue: canonical, substituteValue: base))
                    info = KeyInfo(substitute: base, feminine: analysis?.feminine ?? false, isRussianName: analysis != nil)
                    keyInfo[key] = info
                }
                let rendered: String
                if let analysis, info.isRussianName {
                    rendered = AnonymizationNames.decline(base: info.substitute, feminine: info.feminine, to: analysis.nameCase)
                } else {
                    rendered = info.substitute
                }
                assembled.append(AnonymizationAssemblyReplacement(range: item.range, text: rendered))
            }
            return assembled
        }
        let bodyReplacements = try prepared(bodyPlan.replacements)
        let nameReplacements = try prepared(namePlan.replacements)

        // 4. Assembly of body and name from the original scalar slices.
        let bodyOutput: AnonymizationAssemblyOutput
        let nameOutput: AnonymizationAssemblyOutput
        do {
            bodyOutput = try AnonymizationAssembly.assemble(scalars: sourceScalars, replacements: bodyReplacements,
                                                            format: input.sourceFormat)
            nameOutput = try AnonymizationAssembly.assemble(scalars: nameScalars, replacements: nameReplacements,
                                                            format: .txt)
        } catch AnonymizationAssemblyError.unrepresentable {
            throw ScribeError.message("Не удалось корректно представить замену в разметке документа")
        }

        // 5. Warnings: disputed body spans, disputed name spans, then the
        //    uninterpreted wordings in their saved order.
        var warnings: [AnonymizationWarning] = []
        for range in bodyPlan.doubtfulRanges {
            let generated = Self.generatedRange(of: range, mapping: bodyOutput.sourceToGenerated)
            warnings.append(AnonymizationWarning(kind: .doubtfulFragment, target: .body,
                inputRange: Self.textRange(range), generatedRange: generated))
        }
        for range in namePlan.doubtfulRanges {
            let generated = Self.generatedRange(of: range, mapping: nameOutput.sourceToGenerated)
            warnings.append(AnonymizationWarning(kind: .doubtfulFragment, target: .importedName,
                inputRange: Self.textRange(range), generatedRange: generated))
        }
        let interpretedTypes = Set(bodyCandidates.map(\.dataType)).union(nameCandidates.map(\.dataType))
        let uninterpreted = types.filter { reportedUninterpreted.contains($0) && !interpretedTypes.contains($0) }
        for wording in uninterpreted {
            warnings.append(AnonymizationWarning(kind: .uninterpretedType, dataType: wording))
        }

        // 6. Result identity, download stem, validation, artifacts.
        let revisionID = UUID().uuidString
        let stem = nameReplacements.isEmpty ? input.importedNameStem : nameOutput.text
        do { try AnonymizationCardDocument.validateFileStem(stem) }
        catch { throw ScribeError.message("Недопустимое имя файла результата обезличивания") }
        var pairs: [ReplacementPair] = []
        for (item, range) in zip(bodyPlan.replacements, bodyOutput.replacementRanges) {
            pairs.append(ReplacementPair(sourceRange: Self.textRange(item.range), resultRange: Self.textRange(range)))
        }
        let result = AnonymizationResult(
            input: RunInput(source: input.source, profileID: input.profileID,
                            packageID: input.packageID, dataTypes: types),
            generatedText: TextRevision(id: revisionID, text: bodyOutput.text),
            text: TextRevision(id: revisionID, text: bodyOutput.text),
            downloadNameStem: stem,
            bodyReplacementCount: UInt(bodyReplacements.count),
            pairs: pairs,
            warnings: warnings)
        let substitutions = (input.automaticSubstitutions ?? []) + newSubstitutions
        let artifact = AnonymizationRunArtifact(result: result, substitutions: substitutions)
        try artifact.validate(sourceScalarCount: sourceScalars.count, importedNameScalarCount: nameScalars.count)
        try Disk.write(artifact, to: attemptURL.appendingPathComponent(AnonymizationRunArtifact.filename))
        if !warnings.isEmpty {
            let doubtful = warnings.filter { $0.kind == .doubtfulFragment }.count
            let unknown = warnings.count - doubtful
            emit("warning", "Проверьте предупреждения обезличивания: сомнительных мест \(doubtful), непонятых типов \(unknown)", nil)
        }
        return Outcome(artifact: artifact, metrics: [
            "windowCount": Double(bodyWindows.count),
            "bodyCandidateCount": Double(bodyCandidates.count),
            "nameCandidateCount": Double(nameCandidates.count),
            "bodyReplacementCount": Double(bodyReplacements.count),
            "nameReplacementCount": Double(nameReplacements.count),
            "doubtfulCount": Double(bodyPlan.doubtfulRanges.count + namePlan.doubtfulRanges.count),
            "uninterpretedTypeCount": Double(uninterpreted.count),
            "newSubstitutionCount": Double(newSubstitutions.count),
        ])
    }

    private static func key(dataType: String, canonical: String) -> String {
        dataType + "\u{1}" + canonical
    }

    private static func textRange(_ range: Range<Int>) -> LocalScribeCore.TextRange {
        LocalScribeCore.TextRange(start: UInt(range.lowerBound), end: UInt(range.upperBound))
    }

    private static func generatedRange(of range: Range<Int>, mapping: [Int]) -> LocalScribeCore.TextRange {
        let start = mapping[range.lowerBound]
        let end = mapping[range.upperBound - 1] + 1
        return LocalScribeCore.TextRange(start: UInt(start), end: UInt(end))
    }

    /// One window through the recognizer with local verification: exact type
    /// wordings, scalar bounds and the verbatim fragment check. Candidates
    /// failing verification are dropped as recognition noise; a thrown error
    /// propagates and fails the attempt.
    private func detect(in window: Range<Int>, scalars: [Unicode.Scalar], types: [String]) async throws
        -> (candidates: [AnonymizationSpanCandidate], uninterpreted: Set<String>) {
        let windowText = String(String.UnicodeScalarView(scalars[window]))
        let answer = try await recognizer.detect(text: windowText, dataTypes: types)
        try Task.checkCancellation()
        let allowed = Set(types)
        var verified: [AnonymizationSpanCandidate] = []
        for candidate in answer.candidates {
            guard allowed.contains(candidate.dataType) else { continue }
            let start = Int(candidate.start), end = Int(candidate.end)
            guard start >= 0, start < end, end <= window.count else { continue }
            let lower = window.lowerBound + start, upper = window.lowerBound + end
            let fragment = String(String.UnicodeScalarView(scalars[lower..<upper]))
            guard !fragment.isEmpty, fragment == candidate.fragment else { continue }
            verified.append(AnonymizationSpanCandidate(dataType: candidate.dataType,
                range: lower..<upper, value: fragment, doubtful: candidate.doubtful))
        }
        return (verified, Set(answer.uninterpretedTypes.filter { allowed.contains($0) }))
    }
}
