import XCTest
import LocalScribeCore

/// Wire contracts of the local anonymization JSONL v1 extension: the new
/// command kind and attempt artifacts must not change the historical audio or
/// diagram formats, and events must echo the job kind.
final class AnonymizationContractsTests: XCTestCase {
    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testAudioCommandKeepsHistoricalKindlessWireFormat() throws {
        let command = WorkerCommand(jobId: UUID().uuidString, runId: UUID().uuidString, stage: .transcribing,
                                    recordingPath: "/tmp/recording", modelsPath: "/tmp/models", toolsPath: "/tmp/tools")
        XCTAssertFalse(command.isDiagram)
        XCTAssertFalse(command.isAnonymization)
        let json = try jsonObject(command)
        XCTAssertFalse(json.keys.contains("kind"))
        XCTAssertFalse(json.keys.contains("diagramPath"))
        XCTAssertFalse(json.keys.contains("anonymizationPath"))
    }

    func testDiagramCommandKeepsItsOwnWireFormat() throws {
        let command = WorkerCommand(diagramJobId: UUID().uuidString, runId: UUID().uuidString,
                                    diagramPath: "/tmp/item", modelsPath: "/tmp/models")
        XCTAssertTrue(command.isDiagram)
        XCTAssertFalse(command.isAnonymization)
        let json = try jsonObject(command)
        XCTAssertEqual(json["kind"] as? String, "diagram")
        XCTAssertNil(json["anonymizationPath"])
        XCTAssertNil(json["stage"])
        XCTAssertNil(json["recordingPath"])
    }

    func testAnonymizationCommandRoundTrip() throws {
        let jobId = UUID().uuidString, runId = UUID().uuidString
        let command = WorkerCommand(anonymizationJobId: jobId, runId: runId,
                                    anonymizationPath: "/tmp/attempt", modelsPath: "/tmp/models")
        XCTAssertTrue(command.isAnonymization)
        XCTAssertFalse(command.isDiagram)
        let json = try jsonObject(command)
        XCTAssertEqual(json["kind"] as? String, "anonymization")
        XCTAssertEqual(json["anonymizationPath"] as? String, "/tmp/attempt")
        XCTAssertEqual(json["jobId"] as? String, jobId)
        XCTAssertEqual(json["runId"] as? String, runId)
        XCTAssertNil(json["stage"])
        XCTAssertNil(json["recordingPath"])
        XCTAssertNil(json["diagramPath"])
        XCTAssertNil(json["liveCapture"])
        let decoded = try JSONDecoder().decode(WorkerCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(decoded.kind, "anonymization")
        XCTAssertEqual(decoded.anonymizationPath, "/tmp/attempt")
        XCTAssertEqual(decoded.jobId, jobId)
        XCTAssertEqual(decoded.runId, runId)
        // Unknown kinds stay decodable as raw strings; the worker rejects them by value.
        var unknown = command
        unknown.kind = "foo"
        XCTAssertFalse(unknown.isAnonymization)
        XCTAssertNoThrow(try JSONDecoder().decode(WorkerCommand.self, from: JSONEncoder().encode(unknown)))
    }

    func testEventEchoesCommandKindAndDecodesHistoricalFormat() throws {
        let audio = WorkerCommand(jobId: UUID().uuidString, runId: UUID().uuidString, stage: .preparingAudio,
                                  recordingPath: "/tmp/r", modelsPath: "/tmp/m", toolsPath: "/tmp/t")
        XCTAssertNil(WorkerEvent(command: audio, type: "started").kind)
        let diagram = WorkerCommand(diagramJobId: UUID().uuidString, runId: UUID().uuidString,
                                    diagramPath: "/tmp/item", modelsPath: "/tmp/m")
        let diagramEvent = WorkerEvent(command: diagram, type: "started")
        XCTAssertEqual(diagramEvent.kind, "diagram")
        XCTAssertTrue(diagramEvent.isDiagram)
        XCTAssertFalse(diagramEvent.isAnonymization)
        let anonymization = WorkerCommand(anonymizationJobId: UUID().uuidString, runId: UUID().uuidString,
                                          anonymizationPath: "/tmp/attempt", modelsPath: "/tmp/m")
        let event = WorkerEvent(command: anonymization, type: "progress", message: "Проверяем задание обезличивания…")
        XCTAssertEqual(event.kind, "anonymization")
        XCTAssertTrue(event.isAnonymization)
        XCTAssertEqual(event.jobId, anonymization.jobId)
        XCTAssertEqual(event.runId, anonymization.runId)
        let json = try jsonObject(event)
        XCTAssertEqual(json["kind"] as? String, "anonymization")
        XCTAssertEqual(json["type"] as? String, "progress")
        // Kindless audio events written before the extension still decode.
        let legacy = try JSONDecoder().decode(WorkerEvent.self, from: Data(
            #"{"version":1,"jobId":"j","runId":"r","type":"started","message":""}"#.utf8))
        XCTAssertNil(legacy.kind)
        XCTAssertFalse(legacy.isAnonymization)
        XCTAssertFalse(legacy.isDiagram)
    }

    func testAttemptInputRoundTripAndIdentityLink() throws {
        let fileId = UUID().uuidString, attemptId = UUID().uuidString
        let input = AnonymizationAttemptInput(fileId: fileId, attemptId: attemptId,
            source: TextRevision(id: UUID().uuidString, text: "Отчёт встречи"),
            importedNameStem: "Отчёт", sourceFormat: .markdown,
            dataTypes: ["Имена и фамилии"], profileID: "shared-profile", packageID: "shared-package")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("attempts/\(attemptId)")
        try Disk.write(input, to: workspace.appendingPathComponent(AnonymizationAttemptInput.filename))
        let read = try Disk.read(AnonymizationAttemptInput.self, at: workspace.appendingPathComponent(AnonymizationAttemptInput.filename))
        XCTAssertEqual(read, input)
        XCTAssertNoThrow(try read.validate())
        let command = WorkerCommand(anonymizationJobId: fileId, runId: attemptId,
                                    anonymizationPath: workspace.path, modelsPath: root.path)
        XCTAssertTrue(read.matches(command: command))
        var foreignCard = command
        foreignCard.jobId = UUID().uuidString
        XCTAssertFalse(read.matches(command: foreignCard))
        var foreignAttempt = command
        foreignAttempt.runId = UUID().uuidString
        XCTAssertFalse(read.matches(command: foreignAttempt))
    }

    func testAttemptInputValidationFailures() throws {
        let valid = AnonymizationAttemptInput(fileId: UUID().uuidString, attemptId: UUID().uuidString,
            source: TextRevision(id: UUID().uuidString, text: "Текст"), importedNameStem: "Имя",
            sourceFormat: .txt, dataTypes: ["Тип"], profileID: "profile", packageID: "package")
        func check(_ mutate: (inout AnonymizationAttemptInput) -> Void, _ message: String,
                   file: StaticString = #filePath, line: UInt = #line) {
            var input = valid
            mutate(&input)
            XCTAssertThrowsError(try input.validate(), message, file: file, line: line)
        }
        check({ $0.schemaVersion = 2 }, "версия схемы должна проверяться")
        check({ $0.fileId = "not-an-uuid" }, "UUID карточки должен проверяться")
        check({ $0.attemptId = "" }, "UUID попытки должен проверяться")
        check({ $0.source.id = "not-an-uuid" }, "идентификатор версии исходника должен проверяться")
        check({ $0.source.text = " \n\t" }, "пробельный текст должен отклоняться")
        check({ $0.importedNameStem = "" }, "пустое имя импорта должно отклоняться")
        check({ $0.importedNameStem = "a/b" }, "имя импорта с путём должно отклоняться")
        check({ $0.dataTypes = [] }, "пустой список типов должен отклоняться")
        check({ $0.dataTypes = ["Тип", "  "] }, "пробельный тип должен отклоняться")
        check({ $0.profileID = "" }, "пустой профиль должен отклоняться")
        check({ $0.packageID = "a/b" }, "пакет с путём должен отклоняться")
        XCTAssertNoThrow(try valid.validate())
    }

    func testSourceFormatRawValuesMatchArchiveContract() {
        // The stored format strings are machine values; keep them verbatim.
        XCTAssertEqual(AnonymizationSourceFormat.txt.rawValue, "TXT")
        XCTAssertEqual(AnonymizationSourceFormat.markdown.rawValue, "MARKDOWN")
        XCTAssertEqual(AnonymizationSourceFormat(rawValue: "TXT"), .txt)
        XCTAssertNil(AnonymizationSourceFormat(rawValue: "txt"))
    }

    func testAttemptInputCarriesSubstitutionHistoryAdditively() throws {
        let fileId = UUID().uuidString, attemptId = UUID().uuidString
        let history = [
            AutomaticSubstitution(dataType: "Имена и фамилии", sourceValue: "Анна Петрова", substituteValue: "Вера Соколова"),
        ]
        let input = AnonymizationAttemptInput(fileId: fileId, attemptId: attemptId,
            source: TextRevision(id: UUID().uuidString, text: "Отчёт"),
            importedNameStem: "Отчёт", sourceFormat: .txt,
            dataTypes: ["Имена и фамилии"], profileID: "profile", packageID: "package",
            automaticSubstitutions: history)
        XCTAssertNoThrow(try input.validate())
        XCTAssertEqual(input.automaticSubstitutions, history)
        // Old inputs without the field decode as absent history.
        var legacy = input
        legacy.automaticSubstitutions = nil
        let decoded = try JSONDecoder().decode(AnonymizationAttemptInput.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.automaticSubstitutions)
        // Broken history fails validation safely: duplicate keys and values
        // equal to their source must never enter a run.
        var duplicateKey = input
        duplicateKey.automaticSubstitutions = history + history
        XCTAssertThrowsError(try duplicateKey.validate())
        var selfSubstitution = input
        selfSubstitution.automaticSubstitutions = [
            AutomaticSubstitution(dataType: "Тип", sourceValue: "Значение", substituteValue: "Значение"),
        ]
        XCTAssertThrowsError(try selfSubstitution.validate())
    }

    func testRunArtifactRoundTripAndValidation() throws {
        let source = TextRevision(id: UUID().uuidString, text: "Отчёт: Анна Петрова.")
        let run = RunInput(source: source, profileID: "profile", packageID: "package", dataTypes: ["Имена и фамилии"])
        let revision = TextRevision(id: UUID().uuidString, text: "Отчёт: Вера Соколова.")
        let result = AnonymizationResult(input: run, generatedText: revision, text: revision,
            downloadNameStem: "Отчёт", bodyReplacementCount: 1,
            pairs: [ReplacementPair(sourceRange: TextRange(start: 8, end: 20),
                                    resultRange: TextRange(start: 8, end: 20))],
            warnings: [AnonymizationWarning(kind: .uninterpretedType, dataType: "Имена и фамилии")])
        var artifact = AnonymizationRunArtifact(result: result,
            substitutions: [AutomaticSubstitution(dataType: "Имена и фамилии",
                                                  sourceValue: "Анна Петрова", substituteValue: "Вера Соколова")])
        XCTAssertEqual(AnonymizationRunArtifact.filename, "result.json")
        XCTAssertNoThrow(try artifact.validate(sourceScalarCount: source.text.unicodeScalars.count,
                                               importedNameScalarCount: "Отчёт".unicodeScalars.count))
        let decoded = try JSONDecoder().decode(AnonymizationRunArtifact.self, from: JSONEncoder().encode(artifact))
        XCTAssertEqual(decoded, artifact)
        // Out-of-bounds pairs and broken substitution history fail the artifact.
        var invalid = artifact
        invalid.result.pairs[0].sourceRange = TextRange(start: 0, end: 999)
        XCTAssertThrowsError(try invalid.validate(sourceScalarCount: source.text.unicodeScalars.count,
                                                  importedNameScalarCount: "Отчёт".unicodeScalars.count))
        var duplicateHistory = artifact
        duplicateHistory.substitutions += duplicateHistory.substitutions
        XCTAssertThrowsError(try duplicateHistory.validate(sourceScalarCount: source.text.unicodeScalars.count,
                                                           importedNameScalarCount: "Отчёт".unicodeScalars.count))
    }
}
