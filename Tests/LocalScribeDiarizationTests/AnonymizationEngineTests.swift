import CryptoKit
import Synchronization
import XCTest
@testable import LocalScribeCore
@testable import LocalScribeWorker

private func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Append-only event log shared with the engine's emit closure.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Recognizer fake without weights: locates every occurrence of each marker
/// value of the requested data type in the analyzed text by scalar range and
/// reports it verbatim. The engine's contract under test is the per-type
/// pass, so the fake answers only the requested wording; values of other
/// types are never returned. A marker may be limited to one 1-based
/// occurrence so overlapping scenarios stay precise.
private final class ScriptedRecognizer: AnonymizationRecognizing, @unchecked Sendable {
    struct Marker {
        let dataType: String
        let value: String
        let doubtful: Bool
        let occurrence: Int?
        init(_ dataType: String, _ value: String, doubtful: Bool = false, occurrence: Int? = nil) {
            self.dataType = dataType; self.value = value; self.doubtful = doubtful; self.occurrence = occurrence
        }
    }
    let markers: [Marker]
    var uninterpretedTypes: [String] = []
    /// 1-based call number that starts throwing; nil disables failures.
    var failFromCall: Int?
    /// Reports a match of the requested type the anchor would reject: the
    /// fake answers with `hasUnanchoredMatches` plus the numeric line range
    /// of `line` (mirroring the recognizer's parse), or without ranges when
    /// the line is outside the window — the non-narrowable case.
    var unanchoredReport: (dataType: String, line: Int)?
    /// Reports a fragment that does not match the located range.
    var corruptFragments = false
    private let calls = Mutex(0)
    var callCount: Int { calls.withLock { $0 } }
    init(markers: [Marker], uninterpretedTypes: [String] = []) {
        self.markers = markers; self.uninterpretedTypes = uninterpretedTypes
    }
    func detect(text: String, dataType: String) async throws -> AnonymizationWindowAnswer {
        let call = calls.withLock { $0 += 1; return $0 }
        if let first = failFromCall, call >= first { throw ScribeError.message("Ошибка части входа") }
        let scalars = Array(text.unicodeScalars)
        var candidates: [AnonymizationCandidate] = []
        for marker in markers where marker.dataType == dataType {
            var seen = 0
            var searchStart = 0
            while let range = Self.scalarRange(of: marker.value, in: scalars, from: searchStart) {
                seen += 1
                if marker.occurrence == nil || marker.occurrence == seen {
                    candidates.append(AnonymizationCandidate(dataType: marker.dataType,
                        start: UInt(range.lowerBound), end: UInt(range.upperBound),
                        fragment: corruptFragments ? "испорченный фрагмент" : marker.value,
                        doubtful: marker.doubtful))
                }
                searchStart = range.lowerBound + 1
            }
        }
        let uninterpreted = uninterpretedTypes.contains(dataType) ? [dataType] : []
        var answer = AnonymizationWindowAnswer(candidates: candidates, uninterpretedTypes: uninterpreted)
        if let report = unanchoredReport, report.dataType == dataType {
            answer.hasUnanchoredMatches = true
            let lineStarts = [0] + scalars.indices.compactMap { scalars[$0] == "\n" ? $0 + 1 : nil }
            if report.line > 0, report.line <= lineStarts.count {
                let start = lineStarts[report.line - 1]
                let end = report.line < lineStarts.count ? lineStarts[report.line] - 1 : scalars.count
                answer.unanchoredLineRanges = [start..<end]
            }
        }
        return answer
    }

    /// Scalar-subsequence search of `needle` in `haystack` from an offset.
    static func scalarRange(of needle: String, in haystack: [Unicode.Scalar], from: Int) -> Range<Int>? {
        let target = Array(needle.unicodeScalars)
        guard !target.isEmpty, haystack.count >= target.count else { return nil }
        var start = from
        while start + target.count <= haystack.count {
            if (start..<(start + target.count)).allSatisfy({ haystack[$0] == target[$0 - start] }) {
                return start..<(start + target.count)
            }
            start += 1
        }
        return nil
    }
}

/// Scripted substitution source: returns the prepared values in order.
private final class ScriptedValueSource: AnonymizationValueSourcing, @unchecked Sendable {
    let values: [String]
    private let state = Mutex(0)
    private let logged = Mutex<[(source: String, occupiedCount: Int)]>([])
    var requests: [(source: String, occupiedCount: Int)] { logged.withLock { $0 } }
    init(values: [String]) { self.values = values }
    func value(for source: String, shape: AnonymizationValueShape, occupied: Set<String>) -> String {
        logged.withLock { $0.append((source, occupied.count)) }
        return state.withLock { (index: inout Int) -> String in
            let value = values[index % values.count]
            index += 1
            return value
        }
    }
}

final class AnonymizationEngineTests: XCTestCase {
    func testModelFragmentsResolveToExactOccurrencesAndMultilineRanges() throws {
        let source = "👩‍💻 Роман прочитал «Роман».\r\nАдрес: North\nMain Street"
        let response = #"{"schemaVersion":1,"status":"ok","matches":[{"line":1,"fragment":"Роман","occurrence":1,"doubtful":false},{"line":2,"fragment":"North\nMain Street","doubtful":true}]}"#
        let answer = try MLXAnonymizationRecognizer.parse(response, text: source, dataType: "name")
        let scalars = Array(source.unicodeScalars)
        XCTAssertEqual(answer.candidates.map(\.fragment), ["Роман", "North\nMain Street"])
        XCTAssertEqual(answer.candidates.first?.start, 4)
        XCTAssertEqual(answer.candidates.map(\.dataType), ["name", "name"])
        XCTAssertEqual(answer.candidates.map(\.doubtful), [false, true])
        XCTAssertFalse(answer.hasUnanchoredMatches)
        for candidate in answer.candidates {
            let slice = scalars[Int(candidate.start)..<Int(candidate.end)]
            XCTAssertEqual(String(String.UnicodeScalarView(slice)), candidate.fragment)
        }
    }

    func testModelResponseDistinguishesEmptyUnknownAndUnverified() throws {
        let text = "Роман прочитал «Роман»."
        XCTAssertThrowsError(try MLXAnonymizationRecognizer.parse("{}", text: text, dataType: "name"))
        let empty = #"{"schemaVersion":1,"status":"ok","matches":[]}"#
        XCTAssertEqual(try MLXAnonymizationRecognizer.parse(empty, text: text, dataType: "name"), .init())
        let unknown = #"{"schemaVersion":1,"status":"unknown_type","matches":[]}"#
        XCTAssertEqual(try MLXAnonymizationRecognizer.parse(unknown, text: text, dataType: "name").uninterpretedTypes, ["name"])

        let badMatches = [
            #"{"line":1,"fragment":"Роман","doubtful":false}"#,
            #"{"line":1,"fragment":"Роман","occurrence":3,"doubtful":false}"#,
            #"{"line":0,"fragment":"Роман","doubtful":false}"#,
            #"{"line":1,"fragment":"Иван","doubtful":false}"#,
        ]
        for match in badMatches {
            let response = #"{"schemaVersion":1,"status":"ok","matches":["# + match + "]}"
            let answer = try MLXAnonymizationRecognizer.parse(response, text: text, dataType: "name")
            XCTAssertTrue(answer.candidates.isEmpty)
            XCTAssertTrue(answer.hasUnanchoredMatches)
        }
    }

    func testQuoteStrippedFragmentRecoversActualSpanOnReportedLine() throws {
        let source = "ООО Ромашка\nООО «Ромашка»\nОООО «Ромашка»"
        let response = """
        {"schemaVersion":1,"status":"ok","matches":[
            {"line":1,"fragment":"ООО Ромашка","doubtful":false},
            {"line":2,"fragment":"ООО Ромашка","doubtful":false},
            {"line":3,"fragment":"ООО Ромашка","doubtful":false}
        ]}
        """
        let answer = try MLXAnonymizationRecognizer.parse(response, text: source, dataType: "company")
        XCTAssertEqual(answer.candidates.map(\.fragment), ["ООО Ромашка", "ООО «Ромашка»"])
        XCTAssertTrue(answer.hasUnanchoredMatches)
    }

    /// The prompt keeps line breaks inside values, so a fragment may span
    /// lines while the model reports the line of a later portion of the
    /// value: the exact copy is still anchored across the window, an
    /// occurrence number disambiguates repeats on the reported line, and a
    /// repeat without an occurrence stays unanchored.
    func testMultilineFragmentAnchorsFromLateReportedLineAndRepeatsNeedOccurrence() throws {
        let value = "ул. Кедровая,\nд. 7"
        let source = "Первый адрес:\n\(value)\nВторой адрес:\n\(value)\nКонец"
        let single = "Адрес:\n\(value)\nКонец"

        // `single` puts the value on lines 2–3; the model reported line 3 —
        // the last line of the value, not its start. The exact copy is still
        // found across the window and anchored.
        let late = #"{"schemaVersion":1,"status":"ok","matches":[{"line":3,"fragment":"ул. Кедровая,\nд. 7","doubtful":false}]}"#
        let answer = try MLXAnonymizationRecognizer.parse(late, text: single, dataType: "Почтовые адреса")
        XCTAssertEqual(answer.candidates.count, 1, "многострочная копия находится по всему окну")
        XCTAssertEqual(answer.candidates.first?.fragment, value)
        XCTAssertFalse(answer.hasUnanchoredMatches)

        // Two copies in the window without an occurrence number stay unanchored.
        let twice = #"{"schemaVersion":1,"status":"ok","matches":[{"line":2,"fragment":"ул. Кедровая,\nд. 7","doubtful":false}]}"#
        let ambiguous = try MLXAnonymizationRecognizer.parse(twice, text: source, dataType: "Почтовые адреса")
        XCTAssertTrue(ambiguous.hasUnanchoredMatches)
        XCTAssertTrue(ambiguous.candidates.isEmpty)

        // The occurrence counts copies starting on the reported line only.
        let withOccurrence = #"{"schemaVersion":1,"status":"ok","matches":[{"line":2,"fragment":"ул. Кедровая,\nд. 7","occurrence":1,"doubtful":false}]}"#
        let resolved = try MLXAnonymizationRecognizer.parse(withOccurrence, text: source, dataType: "Почтовые адреса")
        XCTAssertEqual(resolved.candidates.count, 1)
        let scalars = Array(source.unicodeScalars)
        let secondLineStart = scalars.firstIndex(of: "\n")! + 1
        XCTAssertEqual(Int(resolved.candidates.first!.start), secondLineStart, "выбрана копия на заявленной строке")
    }

    /// A match that failed anchoring narrows the engine's doubt warning to
    /// the reported line — numeric ranges only, never text; an unusable line
    /// leaves no ranges and the engine doubts the whole window.
    func testUnanchoredMatchReportsItsLineRangeOnly() throws {
        let text = "Первая строка\nВторая строка со значением\nТретья строка"
        let response = #"{"schemaVersion":1,"status":"ok","matches":[{"line":2,"fragment":"нет такого фрагмента","doubtful":false}]}"#
        let answer = try MLXAnonymizationRecognizer.parse(response, text: text, dataType: "Почтовые адреса")
        XCTAssertTrue(answer.hasUnanchoredMatches)
        XCTAssertTrue(answer.candidates.isEmpty)
        let scalars = Array(text.unicodeScalars)
        let secondLineStart = scalars.firstIndex(of: "\n")! + 1
        let secondLineEnd = scalars.lastIndex(of: "\n")!
        XCTAssertEqual(answer.unanchoredLineRanges, [secondLineStart..<secondLineEnd])

        let brokenLine = #"{"schemaVersion":1,"status":"ok","matches":[{"line":9,"fragment":"нет такого фрагмента","doubtful":false}]}"#
        let outside = try MLXAnonymizationRecognizer.parse(brokenLine, text: text, dataType: "Почтовые адреса")
        XCTAssertTrue(outside.hasUnanchoredMatches)
        XCTAssertTrue(outside.unanchoredLineRanges.isEmpty, "строка вне окна не сужает предупреждение")
    }

    /// SDK error tracing keeps the SummaryEngine double lock: the developer
    /// flag alone never unlocks the raw error, and the production recognizer
    /// is never constructed for the technical-probe route.
    func testSDKErrorTracingRequiresBothLocks() {
        XCTAssertFalse(MLXAnonymizationRecognizer.sdkErrorTracingEnabled(technicalProbe: false, traceFlag: false))
        XCTAssertFalse(MLXAnonymizationRecognizer.sdkErrorTracingEnabled(technicalProbe: false, traceFlag: true),
                       "продовый распознаватель не раскрывает текст ошибки SDK ни при каких флагах процесса")
        XCTAssertFalse(MLXAnonymizationRecognizer.sdkErrorTracingEnabled(technicalProbe: true, traceFlag: false),
                       "техпробе нужен и явный флаг разработчика")
        XCTAssertTrue(MLXAnonymizationRecognizer.sdkErrorTracingEnabled(technicalProbe: true, traceFlag: true))
    }

    func testStructuredDetectionDistinguishesVerifiedAndAmbiguousMatches() throws {
        let email = try XCTUnwrap(AnonymizationStructuredDetection.scan(
            text: "🧪 [Почта](mailto:anna.p+tag@example.org), a@b@c.de", dataType: Names.emailType))
        XCTAssertEqual(email.candidates.map(\.fragment), ["anna.p+tag@example.org"])
        XCTAssertEqual(email.candidates.first?.start, 17)
        XCTAssertTrue(email.needsModel)
        XCTAssertNil(AnonymizationStructuredDetection.scan(text: "anna@example.org", dataType: "Рабочие email"))

        let text = "Телефон: +7 (900) 555-01-02\nЗаказ: 1234567890\nДата: 12.11.2026\n<a href=\"tel:5550102\">"
        let phones = try XCTUnwrap(AnonymizationStructuredDetection.scan(text: text, dataType: "Телефоны"))
        XCTAssertEqual(phones.candidates.map(\.fragment), ["+7 (900) 555-01-02", "5550102"])
        XCTAssertFalse(phones.needsModel)
        let ambiguous = try XCTUnwrap(AnonymizationStructuredDetection.scan(text: "9005550102", dataType: "Телефоны"))
        XCTAssertTrue(ambiguous.candidates.isEmpty)
        XCTAssertTrue(ambiguous.needsModel)
    }

    private enum Names {
        static let personType = "Имена и фамилии"
        static let emailType = "Адреса электронной почты"
        static let caseType = "внутренние номера заявок"
    }

    private struct Fixture {
        let root: URL
        let workspace: URL
        let events: EventLog
        var resultURL: URL { workspace.appendingPathComponent(AnonymizationRunArtifact.filename) }
    }

    /// Builds the model root (qualified profile with verified weights), the
    /// attempt workspace with `input.json` and the engine with injected seams.
    private func makeEngine(
        text: String,
        dataTypes: [String] = [Names.personType, Names.emailType],
        importedNameStem: String = "Отчёт",
        format: AnonymizationSourceFormat = .markdown,
        fileId: String = UUID().uuidString,
        history: [AutomaticSubstitution]? = nil,
        recognizer: ScriptedRecognizer,
        valueSource: AnonymizationValueSourcing? = nil
    ) throws -> (engine: AnonymizationEngine, fixture: Fixture) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let attemptID = UUID().uuidString
        let models = root.appendingPathComponent("models")
        let profileID = "anon-test", packageID = "anon-package"
        let weightsBytes = Data("fixture-weights".utf8)
        try Disk.directory(models.appendingPathComponent(profileID))
        try weightsBytes.write(to: models.appendingPathComponent("\(profileID)/weights.bin"))
        let profile = ModelProfile(id: profileID, repository: "fixture/llm", revision: "fixture-rev", license: "test",
            files: [ModelFile(path: "weights.bin", localPath: "weights.bin", size: Int64(weightsBytes.count), sha256: sha(weightsBytes))],
            supportedTasks: [.anonymization], packageID: packageID)
        try Disk.write(ModelCatalog(models: [profile]), to: root.appendingPathComponent("tools/models.lock.json"))
        let workspace = root.appendingPathComponent("attempts/\(attemptID)")
        let input = AnonymizationAttemptInput(fileId: fileId, attemptId: attemptID,
            source: TextRevision(id: UUID().uuidString, text: text),
            importedNameStem: importedNameStem, sourceFormat: format, dataTypes: dataTypes,
            profileID: profileID, packageID: packageID, automaticSubstitutions: history)
        try Disk.write(input, to: workspace.appendingPathComponent(AnonymizationAttemptInput.filename))
        let events = EventLog()
        let command = WorkerCommand(anonymizationJobId: fileId, runId: attemptID,
                                    anonymizationPath: workspace.path, modelsPath: models.path,
                                    toolsPath: root.appendingPathComponent("tools").path)
        let source = valueSource ?? SeededAnonymizationValueSource(
            seed: AnonymizationEngine.substitutionSeed(input: input))
        let engine = try AnonymizationEngine(command: command, recognizer: recognizer, valueSource: source) { type, message, _ in
            events.append("\(type)|\(message)")
        }
        return (engine, Fixture(root: root, workspace: workspace, events: events))
    }

    private func expectFailure(_ error: (any Error)?, containing fragment: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let error else { return XCTFail("Ожидалась ошибка", file: file, line: line) }
        XCTAssertTrue(error.localizedDescription.contains(fragment),
                      "«\(error.localizedDescription)» не содержит «\(fragment)»", file: file, line: line)
    }

    // MARK: - AC-12: one repeated value, one fictional substitute

    func testRepeatedValueAcrossParagraphsGetsOneSubstitution() async throws {
        let text = "Отчёт подготовила Анна Петрова.\n\nИтог: Анна Петрова."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова")])
        let (engine, fixture) = try makeEngine(text: text, recognizer: recognizer)
        let outcome = try await engine.run()
        let result = outcome.artifact.result
        XCTAssertEqual(result.bodyReplacementCount, 2)
        XCTAssertEqual(result.pairs.count, 2)
        XCTAssertEqual(outcome.artifact.substitutions.count, 1)
        let substitution = try XCTUnwrap(outcome.artifact.substitutions.first)
        XCTAssertEqual(substitution.sourceValue, "Анна Петрова")
        XCTAssertNotEqual(substitution.substituteValue, "Анна Петрова")
        // Both standalone occurrences received one and the same value.
        let occurrences = result.text.text.components(separatedBy: substitution.substituteValue).count - 1
        XCTAssertEqual(occurrences, 2)
        XCTAssertFalse(result.text.text.contains("Анна Петрова"))
        // Original slices survive verbatim.
        XCTAssertTrue(result.text.text.hasPrefix("Отчёт подготовила "))
        XCTAssertTrue(result.text.text.contains(".\n\nИтог: "))
        XCTAssertTrue(result.text.text.hasSuffix("."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.resultURL.path))
        XCTAssertFalse(fixture.events.all.contains { $0.contains("Анна") }, "значения не должны попадать в события")
    }

    func testDifferentFileCardsDrawDifferentSubstitutes() async throws {
        let text = "Контакт: Анна Петрова."
        func run(fileId: String) async throws -> String {
            let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова")])
            let (engine, _) = try makeEngine(text: text, fileId: fileId, recognizer: recognizer)
            return try await engine.run().artifact.substitutions[0].substituteValue
        }
        let first = try await run(fileId: UUID().uuidString)
        let second = try await run(fileId: UUID().uuidString)
        XCTAssertNotEqual(first, second, "разные карточки дают разные подстановки")
    }

    // MARK: - AC-13: Russian case forms, independent English spelling

    func testCaseFormsShareKeyAndDeclineToOccurrenceCase() async throws {
        let text = "Анна Петрова пришла. Документ передан Анне Петровой. Отчёт подписан Анной Петровой."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова"),
                                                      .init(Names.personType, "Анне Петровой"),
                                                      .init(Names.personType, "Анной Петровой")])
        let (engine, _) = try makeEngine(text: text, recognizer: recognizer)
        let outcome = try await engine.run()
        XCTAssertEqual(outcome.artifact.substitutions.count, 1, "падежные формы образуют один ключ")
        let base = try XCTUnwrap(outcome.artifact.substitutions.first).substituteValue
        XCTAssertNotEqual(base, "Анна Петрова")
        let expectedDative = AnonymizationNames.decline(base: base, feminine: true, to: .dative)
        let expectedInstrumental = AnonymizationNames.decline(base: base, feminine: true, to: .instrumental)
        let generated = outcome.artifact.result.text.text
        XCTAssertTrue(generated.contains("\(base) пришла"), "именительная форма: \(generated)")
        XCTAssertTrue(generated.contains("передан \(expectedDative)"), "дательная форма: \(generated)")
        XCTAssertTrue(generated.contains("подписан \(expectedInstrumental)"), "творительная форма: \(generated)")
        XCTAssertFalse(generated.contains("Петров"), "исходная фамилия не должна сохраниться")
    }

    func testEnglishSpellingGetsIndependentSubstitution() async throws {
        let text = "Anna Petrova и Анна Петрова — один человек."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Anna Petrova"),
                                                      .init(Names.personType, "Анна Петрова")])
        let (engine, _) = try makeEngine(text: text, recognizer: recognizer)
        let outcome = try await engine.run()
        XCTAssertEqual(outcome.artifact.substitutions.count, 2)
        let values = outcome.artifact.substitutions.map(\.substituteValue)
        XCTAssertEqual(Set(values).count, 2)
        let english = outcome.artifact.substitutions.first { $0.sourceValue == "Anna Petrova" }
        XCTAssertNotNil(english)
        XCTAssertFalse(outcome.artifact.result.text.text.contains("Petrova"))
    }

    // MARK: - AC-14: untouched slices, no matches, name-only

    func testUnmatchedFragmentCandidatesAreDroppedAndPublished() async throws {
        let text = "Обычный текст без совпадений."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "нет такого значения")])
        let (engine, fixture) = try makeEngine(text: text, recognizer: recognizer)
        let outcome = try await engine.run()
        XCTAssertEqual(outcome.artifact.result.bodyReplacementCount, 0)
        XCTAssertTrue(outcome.artifact.result.warnings.isEmpty)
        XCTAssertEqual(outcome.artifact.result.text.text, text)
        XCTAssertEqual(outcome.artifact.result.downloadNameStem, "Отчёт")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    func testReplacementOnlyInImportedNameYieldsZeroBodyReplacements() async throws {
        let text = "Технический отчёт без персональных данных."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова")])
        let (engine, _) = try makeEngine(text: text, dataTypes: [Names.personType],
                                         importedNameStem: "Анна Петрова — отчёт", format: .txt, recognizer: recognizer)
        let outcome = try await engine.run()
        let result = outcome.artifact.result
        // AC-14: zero body replacements without warnings mean no body matches,
        // even though the name was anonymized.
        XCTAssertEqual(result.bodyReplacementCount, 0)
        XCTAssertEqual(result.pairs.count, 0)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.text.text, text)
        XCTAssertNotEqual(result.downloadNameStem, "Анна Петрова — отчёт")
        XCTAssertFalse(result.downloadNameStem.contains("/"), "имя должно остаться одним файловым компонентом")
        XCTAssertFalse(result.downloadNameStem.contains("Петрова"))
    }

    // MARK: - AC-33: Markdown consistency, mailto, metadata

    func testMarkdownEmailConsistentInSignatureMailtoAutolinkAndComment() async throws {
        let email = "ivan.ivanov@example.org"
        let text = """
        ---
        authors: \(email)
        ---
        # Отчёт
        Связь: [Иван Иванов](mailto:\(email)) и копия <\(email)>.
        <!-- контакт: \(email) -->
        Подпись: \(email)
        """
        let recognizer = ScriptedRecognizer(markers: [.init(Names.emailType, email)])
        let (engine, _) = try makeEngine(text: text, recognizer: recognizer)
        let outcome = try await engine.run()
        let result = outcome.artifact.result
        XCTAssertEqual(result.bodyReplacementCount, 5, "все вхождения адреса заменяются")
        XCTAssertEqual(outcome.artifact.substitutions.count, 1)
        let substitute = try XCTUnwrap(outcome.artifact.substitutions.first).substituteValue
        XCTAssertTrue(substitute.contains("@"), "подстановка адреса остаётся адресом")
        XCTAssertNotEqual(substitute, email)
        // The percent-encoded form of an ASCII address is the address itself,
        // so the whole document equals a plain replacement of every occurrence.
        let expected = text.replacingOccurrences(of: email, with: substitute)
        XCTAssertEqual(result.text.text, expected)
        XCTAssertTrue(result.text.text.contains("](mailto:\(substitute))"), "ссылка mailto остаётся рабочей")
        XCTAssertTrue(result.text.text.contains("<\(substitute)>"))
    }

    func testRussianNameInMailtoDestinationIsPercentEncoded() async throws {
        let text = "[подпись](mailto:Анна Петрова) и текст: Анна Петрова."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова")])
        let (engine, _) = try makeEngine(text: text, recognizer: recognizer)
        let outcome = try await engine.run()
        let base = try XCTUnwrap(outcome.artifact.substitutions.first).substituteValue
        let encoded = AnonymizationAssembly.percentEncode(base)
        let generated = outcome.artifact.result.text.text
        XCTAssertTrue(generated.contains("(mailto:\(encoded))"), "в адресе применено percent-кодирование: \(generated)")
        XCTAssertTrue(generated.contains("текст: \(base)"), "в обычном тексте кодирования нет: \(generated)")
        XCTAssertFalse(generated.contains("mailto:Анна"))
    }

    // MARK: - AC-45: nesting, outer doubt, conflicts

    func testConfirmedOuterRangeAbsorbsNestedDoubtAndStandaloneNestedValue() async throws {
        let text = "Пишите на ivan.ivanov@example.org, логин ivan.ivanov сохранён."
        let recognizer = ScriptedRecognizer(markers: [
            .init(Names.emailType, "ivan.ivanov@example.org"),
            .init(Names.personType, "ivan.ivanov", doubtful: true, occurrence: 1),
            .init(Names.personType, "ivan.ivanov", occurrence: 2),
        ])
        let (engine, _) = try makeEngine(text: text, recognizer: recognizer)
        let outcome = try await engine.run()
        let result = outcome.artifact.result
        // The confirmed outer address replaces the whole range including the
        // nested doubt; the standalone occurrence of the nested value gets
        // its own replacement. No dispute warnings remain.
        XCTAssertTrue(result.warnings.isEmpty, "вложенное сомнение поглощено: \(result.warnings)")
        XCTAssertEqual(result.bodyReplacementCount, 2)
        XCTAssertEqual(outcome.artifact.substitutions.count, 2)
        // The substitute address keeps a safe reserved domain, while the
        // original local part must disappear everywhere.
        XCTAssertTrue(result.text.text.contains("@example.org"), "подстановка адреса остаётся адресом")
        XCTAssertFalse(result.text.text.contains("ivan.ivanov"))
        XCTAssertFalse(result.text.text.contains("ivan.ivanov@example.org"))
    }

    func testCorruptedFragmentsAreDroppedAsNoise() async throws {
        let text = "Совещание вела Анна Петрова."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова")])
        recognizer.corruptFragments = true
        let (engine, fixture) = try makeEngine(text: text, recognizer: recognizer)
        let outcome = try await engine.run()
        XCTAssertEqual(outcome.artifact.result.bodyReplacementCount, 0, "неподтверждённый кандидат отброшен")
        XCTAssertEqual(outcome.artifact.result.text.text, text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    // MARK: - Multiline values and the doubt blast radius (review C4)

    /// A multiline postal value is anchored, substituted as a whole and
    /// leaves no warning: line breaks inside a value must not send it to
    /// the unanchored path.
    func testMultilineValueIsAnchoredAndSubstituted() async throws {
        let address = "г. Москва, ул. Кедровая,\nд. 7, кв. 34"
        let text = "Адрес регистрации:\n\(address)\nКонец письма."
        let recognizer = ScriptedRecognizer(markers: [.init(AnonymizationStructuredDetection.addresses, address)])
        let (engine, _) = try makeEngine(text: text, dataTypes: [AnonymizationStructuredDetection.addresses],
                                         format: .txt, recognizer: recognizer)
        let outcome = try await engine.run()
        let result = outcome.artifact.result
        XCTAssertEqual(result.bodyReplacementCount, 1, "многострочное значение привязывается и подставляется")
        XCTAssertFalse(result.text.text.contains("Кедровая"))
        XCTAssertFalse(result.text.text.contains("кв. 34"), "исходное значение исчезает целиком")
        XCTAssertTrue(result.text.text.contains("Адрес регистрации:"), "текст вокруг сохранён")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    /// One unanchored report doubts exactly its own line, not the whole
    /// window core: the anchored value on the first line is still replaced.
    func testUnanchoredMatchDoubtsOnlyItsLineNotTheWholeWindow() async throws {
        let text = "Совещание вела Анна Петрова.\nВторой участник скрыт.\nТретья строка протокола.\nЧетвёртая строка протокола."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова")])
        recognizer.unanchoredReport = (Names.personType, 3)
        let (engine, _) = try makeEngine(text: text, recognizer: recognizer)
        let outcome = try await engine.run()
        let result = outcome.artifact.result
        XCTAssertEqual(result.bodyReplacementCount, 1, "привязанное значение заменяется как обычно")
        let doubtful = result.warnings.filter { $0.kind == .doubtfulFragment && $0.target == .body }
        XCTAssertEqual(doubtful.count, 1)
        let scalars = Array(text.unicodeScalars)
        let lineStarts = [0] + scalars.indices.compactMap { scalars[$0] == "\n" ? $0 + 1 : nil }
        XCTAssertEqual(doubtful.first?.inputRange,
                       TextRange(start: UInt(lineStarts[2]), end: UInt(lineStarts[3] - 1)),
                       "сомнительна только заявленная строка, а не всё окно")
        XCTAssertTrue(result.text.text.contains("Четвёртая строка протокола."))
    }

    /// Without a usable reported line the fail-safe keeps the whole core
    /// window doubtful — unanchored values are never substituted either way.
    func testUnanchoredWithoutUsableLineDoubtsWholeWindow() async throws {
        let text = "Первая строка протокола.\nВторая строка протокола."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "нет такого значения")])
        recognizer.unanchoredReport = (Names.personType, 99)
        let (engine, _) = try makeEngine(text: text, recognizer: recognizer)
        let outcome = try await engine.run()
        let result = outcome.artifact.result
        XCTAssertEqual(result.bodyReplacementCount, 0, "непривязанное значение не подставляется")
        let doubtful = result.warnings.filter { $0.kind == .doubtfulFragment && $0.target == .body }
        XCTAssertEqual(doubtful.count, 1)
        XCTAssertEqual(doubtful.first?.inputRange, TextRange(start: 0, end: UInt(text.unicodeScalars.count)),
                       "без пригодной строки сомнительно всё окно целиком")
    }

    func testOuterDoubtPartialOverlapAndTypeConflictPreservedWithWarnings() async throws {
        let text = """
        Пишите на ivan.ivanov@example.org.
        Иван Петров Иван.
        Номер AB-2741 подтверждён.
        """
        let recognizer = ScriptedRecognizer(markers: [
            .init(Names.emailType, "ivan.ivanov@example.org", doubtful: true),
            .init(Names.personType, "ivan.ivanov"),
            .init(Names.personType, "Иван Петров"),
            .init(Names.personType, "Петров Иван"),
            .init(Names.caseType, "AB-2741"),
            .init(Names.emailType, "AB-2741"),
        ])
        let (engine, _) = try makeEngine(text: text, dataTypes: [Names.personType, Names.emailType, Names.caseType],
                                         recognizer: recognizer)
        let outcome = try await engine.run()
        let result = outcome.artifact.result
        // Outer doubt keeps the address verbatim (with the nested name
        // untouched); the partial overlap and the same-range type conflict
        // keep their disputed spans too. Everything disputed carries a warning.
        XCTAssertEqual(result.warnings.count, 3)
        XCTAssertEqual(result.warnings.filter { $0.kind == .doubtfulFragment && $0.target == .body }.count, 3)
        XCTAssertTrue(result.text.text.contains("ivan.ivanov@example.org"), "внешнее сомнение сохранено целиком")
        XCTAssertTrue(result.text.text.contains("Иван Петров Иван"), "пересечение без внешнего диапазона сохранено")
        XCTAssertTrue(result.text.text.contains("AB-2741"), "конфликт типов сохраняет спорный текст")
        XCTAssertEqual(result.bodyReplacementCount, 0)
        XCTAssertEqual(result.pairs.count, 0)
        // No substitution history was consumed for disputed spans.
        XCTAssertTrue(outcome.artifact.substitutions.isEmpty)
    }

    func testIndependentConfirmedRangesProcessedAlongsideDisputes() async throws {
        let text = "Анна Петрова и ivan@example.org и Иван Петров Иван."
        let recognizer = ScriptedRecognizer(markers: [
            .init(Names.personType, "Анна Петрова"),
            .init(Names.emailType, "ivan@example.org"),
            .init(Names.personType, "Иван Петров"),
            .init(Names.personType, "Петров Иван"),
        ])
        let (engine, _) = try makeEngine(text: text, recognizer: recognizer)
        let outcome = try await engine.run()
        XCTAssertEqual(outcome.artifact.result.bodyReplacementCount, 2, "независимые подтверждённые участки обработаны")
        XCTAssertEqual(outcome.artifact.result.warnings.count, 1)
    }

    // MARK: - AC-47: uninterpreted type wordings

    func testUninterpretedTypeWarningCarriesExactWording() async throws {
        let wording = "внутренние номера заявок"
        let text = "Сотрудник Анна Петрова."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова")],
                                            uninterpretedTypes: [wording])
        let (engine, _) = try makeEngine(text: text, dataTypes: [Names.personType, wording], recognizer: recognizer)
        let outcome = try await engine.run()
        XCTAssertEqual(outcome.artifact.result.bodyReplacementCount, 1)
        let warning = try XCTUnwrap(outcome.artifact.result.warnings.first)
        XCTAssertEqual(warning.kind, .uninterpretedType)
        XCTAssertEqual(warning.dataType, wording, "формулировка сохранена дословно")
        XCTAssertNil(warning.inputRange)
        XCTAssertNil(warning.target)
    }

    func testTypeWithCandidatesNeverReportedUninterpreted() async throws {
        let text = "Номер AB-2741."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.caseType, "AB-2741")],
                                            uninterpretedTypes: [Names.caseType, "почтовые адреса"])
        let (engine, _) = try makeEngine(text: text, dataTypes: [Names.caseType, "почтовые адреса"],
                                         recognizer: recognizer)
        let outcome = try await engine.run()
        let uninterpreted = outcome.artifact.result.warnings.filter { $0.kind == .uninterpretedType }
        XCTAssertEqual(uninterpreted.map(\.dataType), ["почтовые адреса"], "тип с кандидатами не считается непонятым")
    }

    // MARK: - AC-41: only the configured exact type wording

    func testOnlyConfiguredTypeReplacedAndUnknownWordingsDropped() async throws {
        let text = "Номер внутренней заявки AB-2741, сотрудник Анна Петрова."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.caseType, "AB-2741"),
                                                      .init(Names.personType, "Анна Петрова")])
        let (engine, _) = try makeEngine(text: text, dataTypes: [Names.caseType], recognizer: recognizer)
        let outcome = try await engine.run()
        let result = outcome.artifact.result
        XCTAssertEqual(result.bodyReplacementCount, 1)
        XCTAssertTrue(result.text.text.contains("сотрудник Анна Петрова"), "имя вне списка типов сохранено")
        XCTAssertFalse(result.text.text.contains("AB-2741"))
        let replacement = try XCTUnwrap(outcome.artifact.substitutions.first?.substituteValue)
        XCTAssertNotNil(replacement.range(of: #"^[A-Z]{2}-[0-9]{4}$"#, options: .regularExpression))
        XCTAssertTrue(result.text.text.contains(replacement))
    }

    // MARK: - AC-44/48: history reuse, keys, collisions

    func testHistoryReusedAndDisappearedValuePreservedInArtifact() async throws {
        let text = "Анна Петрова встретила Бориса Козлова."
        let history = [
            AutomaticSubstitution(dataType: Names.personType, sourceValue: "Анна Петрова", substituteValue: "Вера Соколова"),
            AutomaticSubstitution(dataType: Names.personType, sourceValue: "Мария Иванова", substituteValue: "Галина Морозова"),
        ]
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова"),
                                                      .init(Names.personType, "Бориса Козлова")])
        let (engine, _) = try makeEngine(text: text, dataTypes: [Names.personType], history: history, recognizer: recognizer)
        let outcome = try await engine.run()
        let generated = outcome.artifact.result.text.text
        XCTAssertTrue(generated.contains("Вера Соколова"), "возвращённое значение использует прежнюю подстановку")
        XCTAssertEqual(outcome.artifact.substitutions.count, 3, "исчезнувшее значение остаётся в истории")
        XCTAssertTrue(outcome.artifact.substitutions.contains {
            $0.sourceValue == "Мария Иванова" && $0.substituteValue == "Галина Морозова"
        })
        // The genitive surface form keys by its canonical nominative.
        let boris = try XCTUnwrap(outcome.artifact.substitutions.first { $0.sourceValue == "Борис Козлов" })
        XCTAssertNotEqual(boris.substituteValue, "Вера Соколова")
        XCTAssertNotEqual(boris.substituteValue, "Галина Морозова")
    }

    func testSameValueUnderDifferentTypeWordingsUsesIndependentKeys() async throws {
        let text = "Первый: AB-2741. Второй: AB-2741."
        let recognizer = ScriptedRecognizer(markers: [
            .init("журнал один", "AB-2741", occurrence: 1),
            .init("журнал два", "AB-2741", occurrence: 2),
        ])
        let (engine, _) = try makeEngine(text: text, dataTypes: ["журнал один", "журнал два"],
                                         format: .txt, recognizer: recognizer)
        let outcome = try await engine.run()
        XCTAssertEqual(outcome.artifact.result.bodyReplacementCount, 2)
        XCTAssertEqual(outcome.artifact.substitutions.count, 2)
        let first = try XCTUnwrap(outcome.artifact.substitutions.first { $0.dataType == "журнал один" })
        let second = try XCTUnwrap(outcome.artifact.substitutions.first { $0.dataType == "журнал два" })
        XCTAssertEqual(first.sourceValue, "AB-2741")
        XCTAssertEqual(second.sourceValue, "AB-2741")
        XCTAssertNotEqual(first.substituteValue, second.substituteValue, "смена точной формулировки типа образует независимый ключ")
    }

    func testSubstituteCollisionRegenerates() async throws {
        let text = "Встреча с Анной Петровой и Марией Ивановой."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анной Петровой"),
                                                      .init(Names.personType, "Марией Ивановой")])
        // The first draw is fine, the second proposes the same occupied value
        // once, then yields a fresh one.
        let source = ScriptedValueSource(values: ["Вера Соколова", "Вера Соколова", "Галина Морозова"])
        let (engine, _) = try makeEngine(text: text, dataTypes: [Names.personType], recognizer: recognizer, valueSource: source)
        let outcome = try await engine.run()
        let substitutes = outcome.artifact.substitutions.map(\.substituteValue)
        XCTAssertEqual(Set(substitutes).count, 2, "коллизия перегенерирована: \(substitutes)")
        XCTAssertEqual(substitutes, ["Вера Соколова", "Галина Морозова"])
    }

    func testSeedDeterminismForIdenticalInputsAndHistory() async throws {
        let text = "Анна Петрова написала Марии Ивановой."
        let history = [AutomaticSubstitution(dataType: Names.personType, sourceValue: "Анна Петрова", substituteValue: "Вера Соколова")]
        func run() async throws -> (String, [AutomaticSubstitution]) {
            let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова"),
                                                          .init(Names.personType, "Марией Ивановой")])
            let fileId = "11111111-1111-1111-1111-111111111111"
            let (engine, _) = try makeEngine(text: text, dataTypes: [Names.personType], fileId: fileId,
                                             history: history, recognizer: recognizer)
            let outcome = try await engine.run()
            return (outcome.artifact.result.text.text, outcome.artifact.substitutions)
        }
        let first = try await run()
        let second = try await run()
        XCTAssertEqual(first.0, second.0, "детерминированные входы дают одинаковый текст")
        XCTAssertEqual(first.1, second.1, "детерминированные входы дают одинаковую историю")
    }

    // MARK: - AC-34: name and body share the substitution

    func testImportedNameAndBodyShareSubstitutionAndStemIsValid() async throws {
        let text = "Отчёт подготовила Анна Петрова."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова")])
        let (engine, _) = try makeEngine(text: text, importedNameStem: "Анна Петрова",
                                         recognizer: recognizer)
        let outcome = try await engine.run()
        let result = outcome.artifact.result
        XCTAssertEqual(outcome.artifact.substitutions.count, 1, "имя и тело делят одну подстановку")
        let base = try XCTUnwrap(outcome.artifact.substitutions.first).substituteValue
        XCTAssertTrue(result.text.text.contains(base), "в теле использована та же подстановка")
        XCTAssertEqual(result.downloadNameStem, base, "имя скачивания построено из обезличенного имени")
        XCTAssertEqual(result.bodyReplacementCount, 1)
        XCTAssertFalse(result.downloadNameStem.contains("/"))
    }

    // MARK: - Partial-input failure and unrepresentable replacements

    func testWindowErrorFailsWholeAttemptWithoutPublishing() async throws {
        let paragraph = String(repeating: "Строка данных для окна. ", count: 700) // ≈ 25k scalars → several windows
        let text = "Начало: Анна Петрова.\n\n\(paragraph)\n\nКонец: Анна Петрова."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова")])
        recognizer.failFromCall = 2
        let (engine, fixture) = try makeEngine(text: text, recognizer: recognizer)
        do {
            _ = try await engine.run()
            XCTFail("Ошибка части входа обязана завершить попытку")
        } catch {
            XCTAssertEqual((error as? ScribeError)?.localizedDescription, "Ошибка части входа")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path),
                       "частичный результат не публикуется")
    }

    func testUnrepresentableReplacementFailsWholeAttempt() async throws {
        // The value starts inside the link text and covers only part of the
        // destination: the surviving link construct cannot stay valid.
        let text = "[Иван](mailto:x@y.org) подписался."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Иван](mailto:x@y")])
        let (engine, fixture) = try makeEngine(text: text, recognizer: recognizer)
        do {
            _ = try await engine.run()
            XCTFail("Непредставимая замена обязана завершить попытку")
        } catch {
            expectFailure(error, containing: "Не удалось корректно представить замену")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    func testArtifactPassesFullContractValidation() async throws {
        let text = "Отчёт: Анна Петрова, копия — ivan@example.org.\n\nКонец: Анна Петрова."
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова"),
                                                      .init(Names.emailType, "ivan@example.org")])
        let (engine, fixture) = try makeEngine(text: text, importedNameStem: "Данные иван@example.org",
                                               recognizer: recognizer)
        _ = try await engine.run()
        let artifact = try Disk.read(AnonymizationRunArtifact.self, at: fixture.resultURL)
        XCTAssertNoThrow(try artifact.validate(sourceScalarCount: text.unicodeScalars.count,
                                               importedNameScalarCount: "Данные иван@example.org".unicodeScalars.count))
        XCTAssertNotEqual(artifact.result.text.id, UUID().uuidString)
        XCTAssertEqual(artifact.result.generatedText.id, artifact.result.text.id, "при публикации один идентификатор версий")
        XCTAssertEqual(artifact.result.input.dataTypes, [Names.personType, Names.emailType])
        XCTAssertEqual(artifact.result.input.profileID, "anon-test")
    }

    // MARK: - Pure helpers

    func testWindowSplittingCoversOnceWithinBudget() {
        let paragraphs = ["Первая часть текста.", String(repeating: "Средний абзац. ", count: 700), "Последняя часть."]
        let text = paragraphs.joined(separator: "\n\n")
        let scalars = Array(text.unicodeScalars)
        let windows = AnonymizationWindows.ranges(in: scalars, budget: 1000)
        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertEqual(windows.first?.lowerBound, 0)
        XCTAssertEqual(windows.last?.upperBound, scalars.count)
        for (index, window) in windows.enumerated() {
            XCTAssertLessThanOrEqual(window.count, 1000, "окно укладывается в бюджет")
            if index > 0 {
                XCTAssertEqual(window.lowerBound, windows[index - 1].upperBound, "без наложений и разрывов")
                // A cut may fall right before a space (the space opens the
                // next window) or right after whitespace — never mid-word.
                let previous = scalars[window.lowerBound - 1]
                let next = scalars[window.lowerBound]
                let atWhitespace = previous == "\n" || previous == " " || previous == "\t" || next == " " || next == "\t"
                XCTAssertTrue(atWhitespace, "разрез проходит по границе слов")
            }
        }
        XCTAssertGreaterThanOrEqual(windows[0].count, 800, "ранний абзац не создаёт короткое окно")
        let first = AnonymizationWindows.withContext(windows[0], scalarCount: scalars.count)
        XCTAssertGreaterThan(first.upperBound, windows[1].lowerBound)
    }

    func testWindowContextKeepsNameAcrossABoundary() async throws {
        let prefix = String(repeating: "Материал ", count: 162) + String(repeating: " ", count: 37)
        let text = prefix + "Анна Петрова. " + String(repeating: "Продолжение ", count: 30)
        let recognizer = ScriptedRecognizer(markers: [.init(Names.personType, "Анна Петрова")])
        let (engine, _) = try makeEngine(text: text, recognizer: recognizer)
        let outcome = try await engine.run()
        XCTAssertEqual(outcome.artifact.result.bodyReplacementCount, 1)
        XCTAssertFalse(outcome.artifact.result.text.text.contains("Анна Петрова"))
    }

    func testMaleObliqueFormsAndCompanyUseAppropriateSubstitutions() async throws {
        let type = "Названия компаний"
        let text = "Алексей Соколов и Алексея Соколова. Михаил Соколов и Михаилом Соколовым. Компания Северный Ветер."
        let recognizer = ScriptedRecognizer(markers: [
            .init(Names.personType, "Алексей Соколов"), .init(Names.personType, "Алексея Соколова"),
            .init(Names.personType, "Михаил Соколов"), .init(Names.personType, "Михаилом Соколовым"),
            .init(type, "Северный Ветер"),
        ])
        let (engine, _) = try makeEngine(text: text, dataTypes: [Names.personType, type], recognizer: recognizer)
        let outcome = try await engine.run()
        XCTAssertEqual(outcome.artifact.result.bodyReplacementCount, 5)
        XCTAssertEqual(outcome.artifact.substitutions.count, 3)
        let company = try XCTUnwrap(outcome.artifact.substitutions.first { $0.dataType == type })
        XCTAssertEqual(company.sourceValue, "Северный Ветер")
        XCTAssertNotNil(company.substituteValue.range(of: #"^[А-ЯЁ][а-яё]+ [А-ЯЁ][а-яё]+$"#, options: .regularExpression))
        XCTAssertNotEqual(company.substituteValue, company.sourceValue)
    }

    func testRerunReplacesMarkersAndKeepsNamesSharedByBodyAndFilename() async throws {
        let companyType = "  Наименования организаций "
        let company = "ООО «Ромашка»"
        let name = "Петрова Анна Ивановна"
        let inflected = "Анной Ивановной Петровой"
        let personType = "ФИО"
        let history = [
            AutomaticSubstitution(dataType: companyType, sourceValue: company, substituteValue: "X-4500"),
            AutomaticSubstitution(dataType: personType, sourceValue: name, substituteValue: "X-4567"),
            AutomaticSubstitution(dataType: personType, sourceValue: inflected, substituteValue: "X-10001"),
            AutomaticSubstitution(dataType: personType, sourceValue: "Андрей Иванов", substituteValue: "Борис Соколов")
        ]
        let recognizer = ScriptedRecognizer(markers: [
            .init(companyType, company), .init(personType, name), .init(personType, inflected)
        ])
        let (engine, _) = try makeEngine(text: "\(company). Докладчик \(name). Работа согласована с \(inflected). \(company).",
                                        dataTypes: [companyType, personType], importedNameStem: company,
                                        history: history, recognizer: recognizer)
        let artifact = try await engine.run().artifact
        let fakeCompany = try XCTUnwrap(artifact.substitutions.first { $0.dataType == companyType }?.substituteValue)
        XCTAssertTrue(fakeCompany.hasPrefix("ООО «"))
        XCTAssertTrue(fakeCompany.hasSuffix("»"))
        XCTAssertNotEqual(fakeCompany, company)
        XCTAssertEqual(artifact.result.downloadNameStem, fakeCompany)
        XCTAssertEqual(artifact.result.text.text.components(separatedBy: fakeCompany).count, 3)
        let fakeName = try XCTUnwrap(artifact.substitutions.first { $0.sourceValue == "Анна Ивановна Петрова" }?.substituteValue)
        let nominative = try XCTUnwrap(AnonymizationNames.analyze(name))
        let instrumental = try XCTUnwrap(AnonymizationNames.analyze(inflected))
        XCTAssertTrue(artifact.result.text.text.contains(AnonymizationNames.decline(base: fakeName, for: nominative)))
        XCTAssertTrue(artifact.result.text.text.contains(AnonymizationNames.decline(base: fakeName, for: instrumental)))
        XCTAssertEqual(artifact.substitutions.count, 3)
        XCTAssertTrue(artifact.substitutions.contains(history[3]))
        XCTAssertFalse(artifact.result.text.text.contains("X-"))
    }

    func testWholeMarkdownDestinationEncodesPhoneReplacement() throws {
        let source = "[Позвонить](+79001234567)"
        let scalars = Array(source.unicodeScalars)
        let start = try XCTUnwrap(scalars.firstIndex(of: "+"))
        let output = try AnonymizationAssembly.assemble(scalars: scalars,
            replacements: [.init(range: start..<(scalars.count - 1), text: "+7 900 555-01-02")], format: .markdown)
        XCTAssertEqual(output.text, "[Позвонить](+7%20900%20555-01-02)")
    }

    func testRussianNameAnalysisAndDeclension() {
        let nominative = AnonymizationNames.analyze("Анна Петрова")
        XCTAssertEqual(nominative?.canonical, "Анна Петрова")
        XCTAssertEqual(nominative?.nameCase, .nominative)
        XCTAssertEqual(nominative?.feminine, true)
        XCTAssertEqual(AnonymizationNames.analyze("Анне Петровой")?.canonical, "Анна Петрова")
        XCTAssertEqual(AnonymizationNames.analyze("Анне Петровой")?.nameCase, .dative)
        XCTAssertEqual(AnonymizationNames.analyze("Анны Петровой")?.nameCase, .genitive)
        XCTAssertEqual(AnonymizationNames.analyze("Анной Петровой")?.nameCase, .instrumental)
        XCTAssertEqual(AnonymizationNames.analyze("Анну Петрову")?.nameCase, .accusative)
        XCTAssertEqual(AnonymizationNames.analyze("Иван Соколов")?.canonical, "Иван Соколов")
        XCTAssertEqual(AnonymizationNames.analyze("Ивана Соколова")?.canonical, "Иван Соколов")
        XCTAssertEqual(AnonymizationNames.analyze("Ивана Соколова")?.nameCase, .genitive)
        XCTAssertEqual(AnonymizationNames.analyze("Ивану Соколову")?.nameCase, .dative)
        XCTAssertEqual(AnonymizationNames.analyze("Иваном Соколовым")?.nameCase, .instrumental)
        XCTAssertEqual(AnonymizationNames.analyze("Иване Соколове")?.nameCase, .prepositional)
        // «Никита»-тип: именительный на «а» и винительный с фамилией на «а».
        XCTAssertEqual(AnonymizationNames.analyze("Никита Соколов")?.canonical, "Никита Соколов")
        XCTAssertEqual(AnonymizationNames.analyze("Никита Соколов")?.nameCase, .nominative)
        XCTAssertEqual(AnonymizationNames.analyze("Никиту Соколова")?.nameCase, .accusative)
        XCTAssertEqual(AnonymizationNames.analyze("Никиты Соколова")?.canonical, "Никита Соколов")
        // Мягкая женская фамилия сводится к одному ключу.
        XCTAssertEqual(AnonymizationNames.analyze("Дарья Заречная")?.canonical,
                       AnonymizationNames.analyze("Дарьей Заречной")?.canonical)
        // Не имя — ключ не строится.
        XCTAssertNil(AnonymizationNames.analyze("Anna Petrova"))
        XCTAssertNil(AnonymizationNames.analyze("Иван"))
        XCTAssertNil(AnonymizationNames.analyze("Иван Петров Сидоров"))
        // Склонение вымышленных значений.
        XCTAssertEqual(AnonymizationNames.decline(base: "Вера Соколова", feminine: true, to: .dative), "Вере Соколовой")
        XCTAssertEqual(AnonymizationNames.decline(base: "Вера Соколова", feminine: true, to: .instrumental), "Верой Соколовой")
        XCTAssertEqual(AnonymizationNames.decline(base: "Вера Соколова", feminine: true, to: .genitive), "Веры Соколовой")
        XCTAssertEqual(AnonymizationNames.decline(base: "Вера Соколова", feminine: true, to: .accusative), "Веру Соколову")
        XCTAssertEqual(AnonymizationNames.decline(base: "Дарья Заречна", feminine: true, to: .instrumental), "Дарьей Заречной")
        XCTAssertEqual(AnonymizationNames.decline(base: "Борис Соколов", feminine: false, to: .genitive), "Бориса Соколова")
        XCTAssertEqual(AnonymizationNames.decline(base: "Борис Соколов", feminine: false, to: .instrumental), "Борисом Соколовым")
        XCTAssertEqual(AnonymizationNames.decline(base: "Борис Соколов", feminine: false, to: .prepositional), "Борисе Соколове")
    }

    func testValueShapes() {
        if case .emailAddress = AnonymizationValueShape.of("a.b@example.org") {} else { XCTFail("email") }
        if case .phone = AnonymizationValueShape.of("+7 916 254-83-19") {} else { XCTFail("phone") }
        if case .russianName(let feminine) = AnonymizationValueShape.of("Анна Петрова") {
            XCTAssertTrue(feminine)
        } else { XCTFail("ru name") }
        if case .englishName = AnonymizationValueShape.of("Anna Petrova") {} else { XCTFail("en name") }
        if case .identifier = AnonymizationValueShape.of("AB-2741") {} else { XCTFail("identifier") }
        if case .postalAddress = AnonymizationValueShape.of("ул. Лесная, д. 12") {} else { XCTFail("address") }
    }

    /// Dates are classified before phones: an eight-digit dotted value like
    /// «12.11.2026» used to draw a phone-number substitute. Month ranges keep
    /// numeric IDs out of the date shape.
    func testDateValueShapeAndSubstitutes() {
        guard case .date(let order, let separator) = AnonymizationValueShape.of("12.11.2026") else {
            return XCTFail("дата день.месяц.год не распознана")
        }
        XCTAssertEqual(order, .dayMonthYear)
        XCTAssertEqual(separator, ".")
        guard case .date(let monthYear, let slash) = AnonymizationValueShape.of("10/2021") else {
            return XCTFail("дата месяц/год не распознана")
        }
        XCTAssertEqual(monthYear, .monthYear)
        XCTAssertEqual(slash, "/")
        guard case .date(let isoOrder, _) = AnonymizationValueShape.of("2026-11-14") else {
            return XCTFail("ISO-дата не распознана")
        }
        XCTAssertEqual(isoOrder, .yearMonthDay)
        if case .phone = AnonymizationValueShape.of("12.11.2026") { XCTFail("дата не является телефоном") }
        if case .phone = AnonymizationValueShape.of("+7 916 254-83-19") {} else { XCTFail("телефон остаётся телефоном") }
        if case .date = AnonymizationValueShape.of("1234.5678.90") { XCTFail("числовой ID не является датой") }
        // A drawn substitute keeps the source format and stays a valid date.
        for (source, order) in [("12.11.2026", AnonymizationValueShape.DateOrder.dayMonthYear),
                                ("10/2021", .monthYear), ("2026-11-14", .yearMonthDay)] {
            let shape = AnonymizationValueShape.of(source)
            var rng = SplitMix64(seed: 7)
            for _ in 0..<32 {
                let value = AnonymizationValueFactory.draw(for: source, shape: shape, using: &rng)
                let parts = value.components(separatedBy: order == .monthYear ? "/" : (source.contains(".") ? "." : "-"))
                    .compactMap(Int.init)
            if order == .monthYear {
                XCTAssertEqual(parts.count, 2, value)
                XCTAssertTrue((1...12).contains(parts[0]), "месяц корректен: \(value)")
                XCTAssertTrue((1990...2035).contains(parts[1]), "год корректен: \(value)")
            } else {
                XCTAssertEqual(parts.count, 3, value)
                let dayIndex = order == .yearMonthDay ? 2 : 0
                let yearIndex = order == .yearMonthDay ? 0 : 2
                XCTAssertTrue((1...28).contains(parts[dayIndex]), "день корректен: \(value)")
                XCTAssertTrue((1...12).contains(parts[1]), "месяц корректен: \(value)")
                XCTAssertTrue((1990...2035).contains(parts[yearIndex]), "год корректен: \(value)")
            }
                XCTAssertFalse(value.contains("X-"), "дата не получает маркерное значение")
                XCTAssertFalse(value.contains("@"), "дата не получает адрес")
            }
        }
    }

    /// Regression of the user report: types added to the saved settings list
    /// (company names, dates) get their own recognition pass and are
    /// substituted even when other types find nothing in the same window.
    func testAddedTypesGetTheirOwnPassAndSubstitution() async throws {
        let text = "Период 10/2021 - 12/2023, работодатель ООО «Ромашка»,руководитель Анна Петрова."
        let company = "Названия компаний", date = "Даты"
        let recognizer = ScriptedRecognizer(markers: [
            .init(company, "ООО «Ромашка»"),
            .init(date, "10/2021"), .init(date, "12/2023"),
            .init(Names.personType, "Анна Петрова"),
        ])
        let (engine, _) = try makeEngine(text: text,
            dataTypes: [Names.personType, company, date, Names.emailType],
            recognizer: recognizer)
        let outcome = try await engine.run()
        let result = outcome.artifact.result
        XCTAssertFalse(result.text.text.contains("Ромашка"), "компания заменена")
        XCTAssertFalse(result.text.text.contains("10/2021"), "дата заменена")
        XCTAssertFalse(result.text.text.contains("12/2023"), "дата заменена")
        XCTAssertFalse(result.text.text.contains("Анна Петрова"), "имя заменено")
        XCTAssertTrue(result.text.text.contains("Период "), "текст между заменами сохранён")
        let types = Set(outcome.artifact.substitutions.map(\.dataType))
        XCTAssertEqual(types, [Names.personType, company, date])
        // A date substitute stays a plausible date, never a phone number.
        for substitution in outcome.artifact.substitutions where substitution.dataType == date {
            XCTAssertFalse(substitution.substituteValue.contains("@"), "не адрес")
            XCTAssertTrue(substitution.substituteValue.contains("/") || substitution.substituteValue.contains("."),
                          "формат даты сохранён: \(substitution.substituteValue)")
        }
    }

    func testSeededSourceRegeneratesOnCollision() throws {
        let source = SeededAnonymizationValueSource(seed: 42)
        let first = try source.value(for: "AB-1000", shape: .identifier, occupied: [])
        let repeatedSource = SeededAnonymizationValueSource(seed: 42)
        let second = try repeatedSource.value(for: "AB-1000", shape: .identifier, occupied: [first])
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, "AB-1000")
    }

    func testWrittenDatesAndShortNamesKeepTheirForm() throws {
        let generator = SeededAnonymizationValueSource(seed: 4)
        let russianDate = "15 ноября 2026"
        let englishDate = "November 15, 2026"
        for (source, pattern) in [
            (russianDate, #"^[0-9]{2} (января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря) [0-9]{4}$"#),
            (englishDate, #"^(January|February|March|April|May|June|July|August|September|October|November|December) [0-9]{2}, [0-9]{4}$"#)
        ] {
            let value = try generator.value(for: source, shape: .of(source, kind: .date), occupied: [])
            XCTAssertNotEqual(value, source)
            XCTAssertNotNil(value.range(of: pattern, options: .regularExpression))
        }
        let source = "Иванов И.И."
        let name = try generator.value(for: source, shape: .of(source, kind: .person), occupied: [])
        XCTAssertNotEqual(name, source)
        XCTAssertNotNil(name.range(of: #"^[А-ЯЁ][а-яё]+ [А-ЯЁ]\.[А-ЯЁ]\.$"#, options: .regularExpression))
    }
}
