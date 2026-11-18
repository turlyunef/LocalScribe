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
    init(command: WorkerCommand, input: AnonymizationAttemptInput, diagnosticPhase: WorkerDiagnostics.PhaseReporter? = nil, emit: @escaping Emit) throws {
        try self.init(command: command, input: input,
            makeRecognizer: { MLXAnonymizationRecognizer(folder: $0, diagnosticPhase: diagnosticPhase) },
            makeValueSource: { SeededAnonymizationValueSource(seed: Self.substitutionSeed(input: $0)) },
            emit: emit)
    }

    /// Qualification runs before the catalog stamps ANONYMIZATION. Only the
    /// production task gate is skipped, while all integrity checks still
    /// apply. The recognizer is constructed for the technical-probe route —
    /// the sole unlock of SDK-error tracing, the anonymization analogue of
    /// the audio pipeline's technical-probe manifest check.
    init(probing command: WorkerCommand, input: AnonymizationAttemptInput, emit: @escaping Emit) throws {
        let models = URL(fileURLWithPath: command.modelsPath)
        let folder = try Self.resolvePinnedModelFolder(models: models, toolsPath: command.toolsPath, input: input, task: nil)
        try self.init(command: command, input: input, modelFolder: folder,
            makeRecognizer: { MLXAnonymizationRecognizer(folder: $0, technicalProbe: true) },
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
        var unverifiedBody: [Range<Int>] = []
        var unverifiedName: [Range<Int>] = []
        var modelCallCount = 0
        var reportedUninterpreted = Set<String>()
        let bodyWindows = AnonymizationWindows.ranges(in: sourceScalars)
        for (index, window) in bodyWindows.enumerated() {
            try Task.checkCancellation()
            emit("progress", "Обезличиваем текст — часть \(index + 1) из \(bodyWindows.count)", nil)
            let verified = try await detect(in: window, scalars: sourceScalars, types: types)
            bodyCandidates.append(contentsOf: verified.candidates)
            unverifiedBody.append(contentsOf: verified.unverifiedSpans)
            modelCallCount += verified.modelCallCount
            reportedUninterpreted.formUnion(verified.uninterpreted)
        }
        emit("progress", "Обрабатываем имя файла…", nil)
        var nameCandidates: [AnonymizationSpanCandidate] = []
        for window in AnonymizationWindows.ranges(in: nameScalars) {
            try Task.checkCancellation()
            let verified = try await detect(in: window, scalars: nameScalars, types: types)
            nameCandidates.append(contentsOf: verified.candidates)
            unverifiedName.append(contentsOf: verified.unverifiedSpans)
            modelCallCount += verified.modelCallCount
            reportedUninterpreted.formUnion(verified.uninterpreted)
        }
        try Task.checkCancellation()

        // 2. Document-wide resolution of overlaps, doubts and repeats.
        let bodyPlan = AnonymizationResolution.resolve(candidates: bodyCandidates)
        let namePlan = AnonymizationResolution.resolve(candidates: nameCandidates)

        // 3. Substitution assignment over history with deterministic draws.
        // The body-side standalone check goes through a word-run index built
        // once per run: every candidate draw previously re-scanned the whole
        // document, which was quadratic in items × draws × document length.
        var standaloneBody: StandaloneTextIndex? = nil
        func standaloneIndex() -> StandaloneTextIndex {
            if let cached = standaloneBody { return cached }
            let index = StandaloneTextIndex(scalars: sourceScalars)
            standaloneBody = index
            return index
        }
        var historyByKey: [String: AutomaticSubstitution] = [:]
        var legacyMarkerKeys = Set<String>()
        var occupiedSubstitutes = Set<String>()
        let history = input.automaticSubstitutions ?? []
        for entry in history {
            let key = Self.key(dataType: entry.dataType, canonical: entry.sourceValue)
            if SeededAnonymizationValueSource.isLegacyMarker(entry.substituteValue) {
                legacyMarkerKeys.insert(key)
            } else {
                historyByKey[key] = entry
                occupiedSubstitutes.insert(entry.substituteValue)
            }
        }
        let allItems = (bodyPlan.replacements + namePlan.replacements).map { item in
            (item: item, name: Self.nameAnalysis(item))
        }
        let itemsByKey = Dictionary(grouping: allItems) { entry in
            Self.key(dataType: entry.item.dataType, canonical: entry.name?.canonical ?? entry.item.value)
        }
        occupiedSubstitutes.formUnion(allItems.map { $0.name?.canonical ?? $0.item.value })
        var replacedLegacyKeys = Set<String>()
        var assigned: [String: String] = [:]
        var newSubstitutions: [AutomaticSubstitution] = []
        func prepared(_ items: [AnonymizationReplacementPlan.Item]) throws -> [AnonymizationAssemblyReplacement] {
            var assembled: [AnonymizationAssemblyReplacement] = []
            for item in items {
                let analysis = Self.nameAnalysis(item)
                let canonical = analysis?.canonical ?? item.value
                let key = Self.key(dataType: item.dataType, canonical: canonical)
                let base: String
                if let existing = assigned[key] {
                    base = existing
                } else {
                    let forms = itemsByKey[key] ?? []
                    // Old runs may have stored an inflected surname in the key.
                    let previousKeys = [key] + forms.flatMap { form in
                        let raw = Self.key(dataType: item.dataType, canonical: form.item.value)
                        let legacy = form.name.flatMap { _ in AnonymizationNames.analyze(form.item.value, legacy: true) }
                        return [raw, Self.key(dataType: item.dataType, canonical: legacy?.canonical ?? form.item.value)]
                    }
                    let previous = previousKeys.lazy.compactMap { historyByKey[$0] }.first
                    replacedLegacyKeys.formUnion(previousKeys.filter { legacyMarkerKeys.contains($0) })
                    func differsFromSource(_ candidate: String) -> Bool {
                        forms.allSatisfy { Self.render(candidate, for: $0.name) != $0.item.value }
                    }
                    if let previous {
                        guard differsFromSource(previous.substituteValue) else {
                            throw ScribeError.message("Не удалось подобрать уникальную подстановку")
                        }
                        base = previous.substituteValue
                    } else {
                        let kind = AnonymizationValueShape.DataKind(wording: item.dataType)
                        let shape = analysis.map(AnonymizationValueShape.name) ?? .of(item.value, kind: kind)
                        var occupied = occupiedSubstitutes
                        var usable: String?
                        for _ in 0..<32 {
                            let candidate = try valueSource.value(for: canonical, shape: shape, occupied: occupied)
                            if candidate != canonical, !occupied.contains(candidate), differsFromSource(candidate),
                               forms.allSatisfy({ form in
                                   let rendered = Self.render(candidate, for: form.name)
                                   return !occupiedSubstitutes.contains(rendered)
                                       && !standaloneIndex().contains(rendered)
                                       && !Self.containsStandalone(rendered, in: input.importedNameStem)
                               }) {
                                usable = candidate
                                break
                            }
                            occupied.insert(candidate)
                        }
                        guard let usable else { throw ScribeError.message("Не удалось подобрать уникальную подстановку") }
                        base = usable
                        newSubstitutions.append(AutomaticSubstitution(dataType: item.dataType,
                                                                      sourceValue: canonical, substituteValue: base))
                    }
                    assigned[key] = base
                    occupiedSubstitutes.insert(base)
                    occupiedSubstitutes.formUnion(forms.map { Self.render(base, for: $0.name) })
                }
                assembled.append(AnonymizationAssemblyReplacement(range: item.range, text: Self.render(base, for: analysis)))
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
        //    uninterpreted wordings in their saved order. Doubt spans of
        //    several type passes and overlapping context windows are merged
        //    so one location carries one warning.
        let unverifiedBodySpans = Self.mergedSpans(unverifiedBody)
        let unverifiedNameSpans = Self.mergedSpans(unverifiedName)
        var warnings: [AnonymizationWarning] = []
        for range in bodyPlan.doubtfulRanges + unverifiedBodySpans {
            let generated = Self.generatedRange(of: range, output: bodyOutput)
            warnings.append(AnonymizationWarning(kind: .doubtfulFragment, target: .body,
                inputRange: Self.textRange(range), generatedRange: generated))
        }
        for range in namePlan.doubtfulRanges + unverifiedNameSpans {
            let generated = Self.generatedRange(of: range, output: nameOutput)
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
        let substitutions = history.filter {
            !replacedLegacyKeys.contains(Self.key(dataType: $0.dataType, canonical: $0.sourceValue))
        } + newSubstitutions
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
            "modelCallCount": Double(modelCallCount),
            "unverifiedSpanCount": Double(unverifiedBodySpans.count + unverifiedNameSpans.count),
            "bodyCandidateCount": Double(bodyCandidates.count),
            "nameCandidateCount": Double(nameCandidates.count),
            "bodyReplacementCount": Double(bodyReplacements.count),
            "nameReplacementCount": Double(nameReplacements.count),
            "doubtfulCount": Double(bodyPlan.doubtfulRanges.count + namePlan.doubtfulRanges.count),
            "uninterpretedTypeCount": Double(uninterpreted.count),
            "newSubstitutionCount": Double(newSubstitutions.count),
        ])
    }

    /// Doubt spans of several type passes and overlapping context windows are
    /// merged (overlapping or touching) so one location carries one warning.
    private static func mergedSpans(_ spans: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<Swift.max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private static func nameAnalysis(_ item: AnonymizationReplacementPlan.Item) -> AnonymizationNames.Analysis? {
        switch AnonymizationValueShape.DataKind(wording: item.dataType) {
        case .person:
            return AnonymizationNames.analyze(item.value)
        case .custom:
            return AnonymizationCompany(item.value).hasLegalForm ? nil : AnonymizationNames.analyze(item.value)
        default:
            return nil
        }
    }

    /// Avoid substitutions the reverse transform could mistake for unchanged
    /// source text. Match the restore path's scalar word boundaries.
    static func containsStandalone(_ value: String, in text: String) -> Bool {
        guard let first = value.unicodeScalars.first, let last = value.unicodeScalars.last else { return false }
        let scalars = text.unicodeScalars
        let word = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        var start = text.startIndex
        while let range = text.range(of: value, options: .literal, range: start..<text.endIndex) {
            let continuesLeft = range.lowerBound > scalars.startIndex && word.contains(first)
                && word.contains(scalars[scalars.index(before: range.lowerBound)])
            let continuesRight = range.upperBound < scalars.endIndex && word.contains(last)
                && word.contains(scalars[range.upperBound])
            if !continuesLeft, !continuesRight { return true }
            start = scalars.index(after: range.lowerBound)
        }
        return false
    }

    private static func render(_ base: String, for name: AnonymizationNames.Analysis?) -> String {
        guard let name else { return base }
        return AnonymizationNames.decline(base: base, for: name)
    }

    private static func key(dataType: String, canonical: String) -> String {
        dataType + "\u{1}" + canonical
    }

    private static func textRange(_ range: Range<Int>) -> LocalScribeCore.TextRange {
        LocalScribeCore.TextRange(start: UInt(range.lowerBound), end: UInt(range.upperBound))
    }

    private static func generatedRange(of range: Range<Int>, output: AnonymizationAssemblyOutput) -> LocalScribeCore.TextRange {
        let start = output.sourceToGenerated[range.lowerBound]
        let last = output.sourceToGenerated[range.upperBound - 1]
        let end = output.replacementRanges.first { $0.lowerBound == last }?.upperBound ?? last + 1
        return LocalScribeCore.TextRange(start: UInt(start), end: UInt(end))
    }

    /// One window through the recognizer, one saved type wording per call:
    /// the qualified model silently drops whole types from multi-type
    /// answers, so each wording gets a dedicated pass and the answers merge
    /// here. Local verification still checks exact type wordings, scalar
    /// bounds and the verbatim fragment check. Candidates failing
    /// verification are dropped as recognition noise; a thrown error
    /// propagates and fails the attempt. Unanchored values are never
    /// substituted: the recognizer reports their lines as numeric ranges and
    /// only those source spans stay doubtful; without usable lines the whole
    /// core window does (the previous fail-safe).
    private func detect(in window: Range<Int>, scalars: [Unicode.Scalar], types: [String]) async throws
        -> (candidates: [AnonymizationSpanCandidate], uninterpreted: Set<String>, unverifiedSpans: [Range<Int>], modelCallCount: Int) {
        let core = window
        let window = AnonymizationWindows.withContext(core, scalarCount: scalars.count)
        let windowText = String(String.UnicodeScalarView(scalars[window]))
        var verified: [AnonymizationSpanCandidate] = []
        var uninterpreted: Set<String> = []
        var seenTypes = Set<String>()
        var unverifiedSpans: [Range<Int>] = []
        var modelCallCount = 0
        for type in types where seenTypes.insert(type).inserted {
            let answer = try await recognizer.detect(text: windowText, dataType: type)
            try Task.checkCancellation()
            if answer.hasUnanchoredMatches {
                if answer.unanchoredLineRanges.isEmpty {
                    unverifiedSpans.append(core)
                } else {
                    for range in answer.unanchoredLineRanges {
                        let span = (window.lowerBound + range.lowerBound)..<(window.lowerBound + range.upperBound)
                        // Context padding belongs to the neighbouring core; a line wholly inside
                        // it is reported by that window. The empty intersection is skipped before
                        // the clamp: max..<min of disjoint ranges would build an inverted Range
                        // and trap the worker.
                        guard span.lowerBound < core.upperBound, span.upperBound > core.lowerBound else { continue }
                        let clamped = Swift.max(core.lowerBound, span.lowerBound)..<Swift.min(core.upperBound, span.upperBound)
                        if !clamped.isEmpty { unverifiedSpans.append(clamped) }
                    }
                }
            }
            modelCallCount += answer.modelCallCount
            for candidate in answer.candidates {
                guard candidate.dataType == type else { continue }
                guard candidate.start < candidate.end, candidate.end <= window.count else { continue }
                let lower = window.lowerBound + Int(candidate.start), upper = window.lowerBound + Int(candidate.end)
                guard core.contains(lower) else { continue }
                let fragment = String(String.UnicodeScalarView(scalars[lower..<upper]))
                guard !fragment.isEmpty, fragment == candidate.fragment else { continue }
                verified.append(AnonymizationSpanCandidate(dataType: candidate.dataType,
                    range: lower..<upper, value: fragment, doubtful: candidate.doubtful))
            }
            if answer.uninterpretedTypes.contains(type) { uninterpreted.insert(type) }
        }
        return (verified, uninterpreted, unverifiedSpans, modelCallCount)
    }
}

/// Word-run index answering the same question as
/// `AnonymizationEngine.containsStandalone(_:in:)` without re-scanning the
/// whole document for every substitution candidate. A literal occurrence of
/// a value whose first scalar is a word scalar can only be standalone when it
/// starts exactly at a maximal word run (and symmetrically at the end), so
/// the index stores every maximal run of word scalars with its start and
/// verifies only the occurrences aligned with runs of the value's first word
/// run — semantics identical to the previous full scan.
struct StandaloneTextIndex {
    private static let word = CharacterSet.alphanumerics.union(.nonBaseCharacters)
    private let scalars: [Unicode.Scalar]
    private var runs: [String: [Int]] = [:]

    init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
        var index = 0
        while index < scalars.count {
            guard Self.word.contains(scalars[index]) else { index += 1; continue }
            let start = index
            while index < scalars.count && Self.word.contains(scalars[index]) { index += 1 }
            runs[String(String.UnicodeScalarView(scalars[start..<index])), default: []].append(start)
        }
    }

    /// True when `value` occurs in the indexed text with word boundaries on
    /// both sides — exactly `containsStandalone(value, in:)` over the same
    /// scalars.
    func contains(_ value: String) -> Bool {
        let needle = Array(value.unicodeScalars)
        guard let first = needle.first, let last = needle.last else { return false }
        // The first word run of the value: any standalone occurrence must
        // align exactly this run with a maximal run of the text.
        var runStart: Int? = nil
        for (offset, scalar) in needle.enumerated() where Self.word.contains(scalar) { runStart = offset; break }
        guard let valueRunStart = runStart else { return literalStandalone(needle, first: first, last: last) }
        var runEnd = valueRunStart
        while runEnd < needle.count, Self.word.contains(needle[runEnd]) { runEnd += 1 }
        let leading = String(String.UnicodeScalarView(needle[valueRunStart..<runEnd]))
        for start in runs[leading] ?? [] {
            let occurrence = start - valueRunStart
            guard occurrence >= 0, occurrence + needle.count <= scalars.count,
                  (0..<needle.count).allSatisfy({ scalars[occurrence + $0] == needle[$0] }) else { continue }
            // A word-scalar prefix is aligned with the run start, so the left
            // side cannot continue a word; a non-word prefix never continues.
            guard Self.word.contains(last), occurrence + needle.count < scalars.count,
                  Self.word.contains(scalars[occurrence + needle.count]) else { return true }
        }
        return false
    }

    /// Values without any word scalar are standalone at every occurrence;
    /// both boundary checks are trivially satisfied for them.
    private func literalStandalone(_ needle: [Unicode.Scalar], first: Unicode.Scalar, last: Unicode.Scalar) -> Bool {
        guard !needle.isEmpty, scalars.count >= needle.count else { return false }
        var start = 0
        while start + needle.count <= scalars.count {
            if (0..<needle.count).allSatisfy({ scalars[start + $0] == needle[$0] }) {
                let continuesLeft = start > 0 && Self.word.contains(first) && Self.word.contains(scalars[start - 1])
                let continuesRight = start + needle.count < scalars.count
                    && Self.word.contains(last) && Self.word.contains(scalars[start + needle.count])
                if !continuesLeft, !continuesRight { return true }
            }
            start += 1
        }
        return false
    }
}
