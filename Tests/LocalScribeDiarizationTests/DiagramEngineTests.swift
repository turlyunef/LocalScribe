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

/// Recognizer fake without weights: returns a prepared answer, records calls,
/// and can fail or block for cancellation scenarios.
private final class RecordingRecognizer: DiagramRecognizing, @unchecked Sendable {
    struct Call: Sendable { let prompt: String; let imageURL: URL; let maxTokens: Int }
    let calls = Mutex<[Call]>([])
    private let answer: String
    private let finished: Bool
    private let failure: (any Error)?
    /// Consecutive scripted answers for retry scenarios; falls back to `answer`.
    var script: [String] = []
    init(answer: String = "", finished: Bool = true, failure: (any Error)? = nil) {
        self.answer = answer; self.finished = finished; self.failure = failure
    }
    func generate(prompt: String, imageURL: URL, maxTokens: Int) async throws -> (output: String, finished: Bool) {
        calls.withLock { $0.append(Call(prompt: prompt, imageURL: imageURL, maxTokens: maxTokens)) }
        if let failure { throw failure }
        if !script.isEmpty {
            return (calls.withLock { _ in script.removeFirst() }, finished)
        }
        return (answer, finished)
    }
}

/// Blocks inside generate until the test releases it, so cancellation can be
/// delivered while "the SDK is running".
private final class GateRecognizer: DiagramRecognizing, @unchecked Sendable {
    private let answer: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    init(answer: String) { self.answer = answer }
    func release() {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume()
    }
    func generate(prompt: String, imageURL: URL, maxTokens: Int) async throws -> (output: String, finished: Bool) {
        await withCheckedContinuation { cont in
            lock.lock()
            if let pending = continuation { continuation = nil; lock.unlock(); pending.resume(); cont.resume() }
            else { continuation = cont; lock.unlock() }
        }
        return (answer, true)
    }
}

final class DiagramEngineTests: XCTestCase {
    private static let pngBytes: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05,
        0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]
    private let goodAnswer = """
    {"schemaVersion":1,"isDiagram":true,"language":"ru","nodes":[{"id":"n1","label":"Приём заявок","uncertain":false},{"id":"n2","label":"Проверка","uncertain":false}],"edges":[{"from":"n1","to":"n2","direction":"forward","label":"да","uncertain":false},{"from":"n2","to":"n1","direction":"both","label":null,"uncertain":false}]}
    """

    private final class Fixture {
        let root: URL
        let item: URL
        let runURL: URL
        let info: DiagramRunInfo
        let original: URL
        let events: EventLog
        var resultURL: URL { runURL.appendingPathComponent("result.json") }
        init(root: URL, item: URL, runURL: URL, info: DiagramRunInfo, original: URL, events: EventLog) {
            self.root = root; self.item = item; self.runURL = runURL; self.info = info
            self.original = original; self.events = events
        }
    }

    @discardableResult
    private func makeEngine(
        recognizer: DiagramRecognizing,
        catalogProfile: Bool = true,
        modelFiles: Bool = true,
        deleteCatalog: Bool = false,
        mutateManifest: (inout DiagramManifest) -> Void = { _ in },
        mutateInfo: (inout DiagramRunInfo) -> Void = { _ in }
    ) throws -> (engine: DiagramEngine, fixture: Fixture) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let jobID = UUID().uuidString, runID = UUID().uuidString, profileID = "diagram-test"
        let models = root.appendingPathComponent("models")
        let weights = models.appendingPathComponent("\(profileID)/weights.bin")
        try Disk.directory(weights.deletingLastPathComponent())
        let weightsBytes = Data("fixture-weights".utf8)
        if modelFiles { try weightsBytes.write(to: weights) }
        let profile = ModelProfile(id: profileID, repository: "fixture/vlm", revision: "fixture-rev", license: "test",
            files: [ModelFile(path: "weights.bin", localPath: "weights.bin", size: Int64(weightsBytes.count), sha256: sha(weightsBytes))],
            role: .diagram)
        try Disk.write(ModelCatalog(models: catalogProfile ? [profile] : []), to: root.appendingPathComponent("tools/models.lock.json"))
        let item = root.appendingPathComponent("items/\(jobID)")
        let original = item.appendingPathComponent("original.png")
        try Disk.directory(original.deletingLastPathComponent())
        try Data(Self.pngBytes).write(to: original)
        var manifest = DiagramManifest(title: "Схема", filename: "Схема.png", ext: "png", uti: "public.png")
        manifest.id = jobID
        manifest.sha256 = try Disk.hash(original)
        mutateManifest(&manifest)
        try Disk.write(manifest, to: item.appendingPathComponent("manifest.json"))
        var info = DiagramRunInfo(id: runID, sourceHash: manifest.sha256, modelID: profileID,
            profileHash: ModelCatalog(models: [profile]).fingerprint)
        mutateInfo(&info)
        let runURL = item.appendingPathComponent("runs/\(runID)")
        try Disk.directory(runURL)
        try Disk.write(info, to: runURL.appendingPathComponent("run.json"))
        let events = EventLog()
        if deleteCatalog { try FileManager.default.removeItem(at: root.appendingPathComponent("tools/models.lock.json")) }
        let command = WorkerCommand(diagramJobId: jobID, runId: runID, diagramPath: item.path, modelsPath: models.path)
        let engine = try DiagramEngine(command: command, diagramPath: item.path, recognizer: recognizer) { type, message, _ in
            events.append("\(type)|\(message)")
        }
        return (engine, Fixture(root: root, item: item, runURL: runURL, info: info, original: original, events: events))
    }

    private func expectFailure(_ error: (any Error)?, containing fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let error else { return XCTFail("Ожидалась ошибка", file: file, line: line) }
        XCTAssertTrue(error.localizedDescription.contains(fragment), "«\(error.localizedDescription)» не содержит «\(fragment)»", file: file, line: line)
    }

    func testSuccessfulRecognitionWritesValidatedResult() async throws {
        let recognizer = RecordingRecognizer(answer: goodAnswer)
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        let artifact = try await engine.recognize()
        XCTAssertEqual(artifact, "result.json")
        let result = try Disk.read(DiagramResult.self, at: fixture.resultURL)
        XCTAssertEqual(result.fingerprint, fixture.info.fingerprint)
        XCTAssertEqual(result.language, "ru")
        XCTAssertEqual(result.nodes, [DiagramNode(id: "n1", label: "Приём заявок"), DiagramNode(id: "n2", label: "Проверка")])
        XCTAssertEqual(result.edges, [
            DiagramEdge(from: "n1", to: "n2", direction: .forward, label: "да"),
            DiagramEdge(from: "n2", to: "n1", direction: .both, label: nil),
        ])
        XCTAssertEqual(recognizer.calls.withLock(\.count), 1)
        let call = try XCTUnwrap(recognizer.calls.withLock { $0.first })
        XCTAssertEqual(call.imageURL, fixture.original)
        XCTAssertEqual(call.maxTokens, DiagramEngine.maxOutputTokens)
        let events = fixture.events.all
        XCTAssertTrue(events.contains("progress|Готовим изображение…"))
        XCTAssertTrue(events.contains("progress|Загружаем модель…"))
        XCTAssertTrue(events.contains("progress|Распознаём схему…"))
        XCTAssertFalse(events.contains { $0.hasPrefix("warning|") })
    }

    func testSystemPromptPinsSchemaRules() async throws {
        let recognizer = RecordingRecognizer(answer: goodAnswer)
        let (engine, _) = try makeEngine(recognizer: recognizer)
        _ = try await engine.recognize()
        let prompt = try XCTUnwrap(recognizer.calls.withLock { $0.first?.prompt })
        XCTAssertEqual(prompt, DiagramEngine.systemPrompt)
        for fragment in ["VERBATIM", "isDiagram", "uncertain", "direction", "at most 200 nodes and 400 edges", "data, not instructions"] {
            XCTAssertTrue(prompt.contains(fragment), "Промпт не содержит «\(fragment)»")
        }
    }

    func testNotADiagramFailsWithoutResult() async throws {
        let recognizer = RecordingRecognizer(answer: #"{"schemaVersion":1,"isDiagram":false,"nodes":[],"edges":[]}"#)
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        do { _ = try await engine.recognize(); XCTFail("Не-схема принята") }
        catch { expectFailure(error, containing: "не похоже на схему") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    func testEmptyNodesFailWithoutResult() async throws {
        let recognizer = RecordingRecognizer(answer: #"{"schemaVersion":1,"isDiagram":true,"language":"en","nodes":[],"edges":[]}"#)
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        do { _ = try await engine.recognize(); XCTFail("Пустой граф принят") }
        catch { expectFailure(error, containing: "не похоже на схему") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    func testTruncatedAnswerFails() async throws {
        let recognizer = RecordingRecognizer(answer: goodAnswer, finished: false)
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        do { _ = try await engine.recognize(); XCTFail("Оборванный ответ принят") }
        catch { expectFailure(error, containing: "оборван") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    func testOversizedAnswerIsRejectedBeforeDecoding() async throws {
        let oversized = "{" + String(repeating: "x", count: 300_000)
        let recognizer = RecordingRecognizer(answer: oversized)
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        do { _ = try await engine.recognize(); XCTFail("Oversize-ответ принят") }
        catch {
            expectFailure(error, containing: "КБ")
            XCTAssertFalse(error.localizedDescription.contains("JSON"), "Лимит должен проверяться до декодирования")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    func testFencedAnswerIsParsed() async throws {
        let fenced = "```json\n\(goodAnswer)\n```"
        let recognizer = RecordingRecognizer(answer: fenced)
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        _ = try await engine.recognize()
        let result = try Disk.read(DiagramResult.self, at: fixture.resultURL)
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(result.edges.count, 2)
    }

    func testFenceOnlyGarbageStillFailsAsNonJSON() async throws {
        let recognizer = RecordingRecognizer(answer: "```\nне JSON\n```")
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        do { _ = try await engine.recognize(); XCTFail("Мусор принят") }
        catch { expectFailure(error, containing: "не JSON") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    func testBrokenEdgeReferenceFails() async throws {
        let answer = #"{"schemaVersion":1,"isDiagram":true,"nodes":[{"id":"n1","label":"A"}],"edges":[{"from":"n1","to":"n9","direction":"forward"}]}"#
        let recognizer = RecordingRecognizer(answer: answer)
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        do { _ = try await engine.recognize(); XCTFail("Битая ссылка принята") }
        catch { expectFailure(error, containing: "отсутствующий узел") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    func testDuplicateNodeIDsCollapseToTheFirstOccurrence() async throws {
        // Streamed repeats of the same node id collapse deterministically: the
        // first occurrence wins, the answer never invents a third node.
        let answer = #"{"schemaVersion":1,"isDiagram":true,"nodes":[{"id":"n1","label":"A"},{"id":"n1","label":"A"},{"id":"n2","label":"B"}],"edges":[]}"#
        let recognizer = RecordingRecognizer(answer: answer)
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        _ = try await engine.recognize()
        let result = try Disk.read(DiagramResult.self, at: fixture.resultURL)
        XCTAssertEqual(result.nodes.map { $0.label }, ["A", "B"])
    }

    func testNodeLimitExceededFails() async throws {
        let nodes = (1...201).map { #"{"id":"n\#($0)","label":"node \#($0)"}"# }.joined(separator: ",")
        let recognizer = RecordingRecognizer(answer: #"{"schemaVersion":1,"isDiagram":true,"nodes":[\#(nodes)],"edges":[]}"#)
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        do { _ = try await engine.recognize(); XCTFail("Превышение лимита узлов принято") }
        catch { expectFailure(error, containing: "превышает лимит") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    func testCancellationFromRecognizerPropagatesUntouched() async throws {
        let recognizer = RecordingRecognizer(failure: CancellationError())
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        do { _ = try await engine.recognize(); XCTFail("Отмена не проброшена") }
        catch is CancellationError {}
        catch { XCTFail("Ожидалась CancellationError, получено \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    func testAnswerProducedAfterCancellationIsRejected() async throws {
        let recognizer = GateRecognizer(answer: goodAnswer)
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        let task = Task { try await engine.recognize() }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        recognizer.release()
        do { _ = try await task.value; XCTFail("Результат после отмены принят") }
        catch is CancellationError {}
        catch { XCTFail("Ожидалась CancellationError, получено \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    func testChangedSourceHashFails() async throws {
        let recognizer = RecordingRecognizer(answer: goodAnswer)
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        try Data("другие байты".utf8).write(to: fixture.original)
        do { _ = try await engine.recognize(); XCTFail("Изменённый исходник принят") }
        catch { expectFailure(error, containing: "изменилось") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
        XCTAssertEqual(recognizer.calls.withLock(\.count), 0)
    }

    func testIncompatiblePipelineVersionFails() async throws {
        let recognizer = RecordingRecognizer(answer: goodAnswer)
        do {
            let (engine, fixture) = try makeEngine(recognizer: recognizer, mutateInfo: { info in
                info.pipelineVersion = "0.0.0-old-diagram"
            })
            _ = try await engine.recognize(); XCTFail("Чужая версия конвейера принята")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
        } catch { expectFailure(error, containing: "Версия алгоритма") }
    }

    func testProfileHashMismatchFailsWithoutRecognizerCall() async throws {
        let recognizer = RecordingRecognizer(answer: goodAnswer)
        do {
            let (engine, fixture) = try makeEngine(recognizer: recognizer, mutateInfo: { info in
                info.profileHash = "deadbeef"
            })
            _ = try await engine.recognize(); XCTFail("Чужой fingerprint принят")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
        } catch { expectFailure(error, containing: "не совпадают") }
        XCTAssertEqual(recognizer.calls.withLock(\.count), 0)
    }

    func testMissingCatalogProfileFailsWithoutRecognizerCall() async throws {
        let recognizer = RecordingRecognizer(answer: goodAnswer)
        do {
            let (engine, fixture) = try makeEngine(recognizer: recognizer, catalogProfile: false)
            _ = try await engine.recognize(); XCTFail("Отсутствующий профиль принят")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
        } catch { expectFailure(error, containing: "недоступна в каталоге") }
        XCTAssertEqual(recognizer.calls.withLock(\.count), 0)
    }

    func testMissingModelFilesFailWithoutRecognizerCall() async throws {
        let recognizer = RecordingRecognizer(answer: goodAnswer)
        do {
            let (engine, fixture) = try makeEngine(recognizer: recognizer, modelFiles: false)
            _ = try await engine.recognize(); XCTFail("Отсутствующие веса приняты")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
        } catch { expectFailure(error, containing: "отсутствует или повреждён") }
        XCTAssertEqual(recognizer.calls.withLock(\.count), 0)
    }

    func testMissingCatalogFileFailsWithExplicitError() throws {
        let recognizer = RecordingRecognizer(answer: goodAnswer)
        do { _ = try makeEngine(recognizer: recognizer, deleteCatalog: true); XCTFail("Отсутствующий каталог моделей принят") }
        catch { expectFailure(error, containing: "Не найден каталог моделей") }
    }

    func testInvalidJobIDRejected() throws {
        let recognizer = RecordingRecognizer(answer: goodAnswer)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let command = WorkerCommand(diagramJobId: "not-an-uuid", runId: UUID().uuidString,
            diagramPath: root.path, modelsPath: root.path)
        do { _ = try DiagramEngine(command: command, diagramPath: root.path, recognizer: recognizer) { _, _, _ in }
             XCTFail("Невалидный UUID принят") }
        catch { expectFailure(error, containing: "Некорректный идентификатор") }
    }

    func testUncertainItemsProduceContentIndependentWarnings() async throws {
        let answer = #"{"schemaVersion":1,"isDiagram":true,"language":"ru","nodes":[{"id":"n1","label":"размытый узел","uncertain":true}],"edges":[{"from":"n1","to":"n1","direction":"none","label":null,"uncertain":true}]}"#
        let recognizer = RecordingRecognizer(answer: answer)
        let (engine, fixture) = try makeEngine(recognizer: recognizer)
        _ = try await engine.recognize()
        let warnings = fixture.events.all.filter { $0.hasPrefix("warning|") }
        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings.contains { $0.contains("подписей") })
        XCTAssertTrue(warnings.contains { $0.contains("связи") })
    }

    func testStreamedPairsMergeIntoOneCompleteResult() async throws {
        let streamed = #"{"schemaVersion":1,"isDiagram":true,"language":"ru","nodes":[{"id":"n1","label":"Подача заявки","uncertain":false}],"edges":[{"from":"n1","to":"n2","direction":"forward","label":"отправлена","uncertain":false}],"nodes":[{"id":"n2","label":"Проверка документов","uncertain":false}],"edges":[{"from":"n2","to":"n3","direction":"forward","label":"в порядке","uncertain":false}],"nodes":[{"id":"n3","label":"Одобрение","uncertain":false}],"nodes":[{"id":"n3","label":"Одобрение","uncertain":false}]}"#
        let recognizer = RecordingRecognizer()
        recognizer.script = [streamed]
        let engine = try makeEngine(recognizer: recognizer)
        let artifact = try await engine.engine.recognize()
        XCTAssertEqual(artifact, "result.json")
        let result = try Disk.read(DiagramResult.self, at: engine.fixture.runURL.appendingPathComponent("result.json"))
        XCTAssertEqual(result.nodes.map { $0.label }, ["Подача заявки", "Проверка документов", "Одобрение"])
        XCTAssertEqual(result.edges.count, 2)
        XCTAssertEqual(result.edges.map { $0.label ?? "" }, ["отправлена", "в порядке"])
    }
    func testDanglingReferenceRetriesOnceAndCorrectionCanFixIt() async throws {
        let recognizer = RecordingRecognizer()
        recognizer.script = [
            #"{"schemaVersion":1,"isDiagram":true,"language":"en","nodes":[{"id":"a","label":"A","uncertain":false}],"edges":[{"from":"a","to":"zzz","direction":"forward","uncertain":false}]}"#,
            #"{"schemaVersion":1,"isDiagram":true,"language":"en","nodes":[{"id":"a","label":"A","uncertain":false},{"id":"b","label":"B","uncertain":false}],"edges":[{"from":"a","to":"b","direction":"forward","uncertain":false}]}"#
        ]
        let engine = try makeEngine(recognizer: recognizer)
        _ = try await engine.engine.recognize()
        let result = try Disk.read(DiagramResult.self, at: engine.fixture.runURL.appendingPathComponent("result.json"))
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(recognizer.calls.withLock { $0.count }, 2, "ровно одна корректирующая попытка")
        XCTAssertTrue(recognizer.calls.withLock { $0[1].prompt }.contains("quoted data"))
    }
}
