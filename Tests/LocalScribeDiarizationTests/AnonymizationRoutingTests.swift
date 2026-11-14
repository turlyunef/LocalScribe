import XCTest
@testable import LocalScribeCore

/// End-to-end routing of the anonymization command over the real built worker
/// binary: strict kind/field validation on stdin, the handler's safe failure
/// path and the confidentiality of the protocol channel. Audio and diagram
/// routes are covered by DiagramRoutingTests.
final class AnonymizationRoutingTests: XCTestCase {
    private struct WorkerRun {
        let code: Int32
        let events: [WorkerEvent]
        let stdoutText: String
        let stderrText: String
    }

    private static let binary: URL? = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var packageRoot: URL?
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { packageRoot = dir; break }
            dir = dir.deletingLastPathComponent()
        }
        guard let packageRoot else { return nil }
        for sub in ["out/Products/Release", "out/Products/Debug", "release", "debug"] {
            let candidate = packageRoot.appendingPathComponent(".build/\(sub)/LocalScribeWorker")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }()

    /// Marker strings that must never appear in the protocol channel or logs.
    private static let textMarker = "МаркерныйТекстДокумента7f3a"
    private static let nameMarker = "МаркерноеИмяФайла9b2c"

    /// Spawns the worker, sends exactly one command line and keeps stdin open
    /// until the process exits (EOF would read as a user cancellation).
    private func runWorker(binary: URL, command: WorkerCommand) throws -> WorkerRun {
        let process = Process()
        process.executableURL = binary
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // The worker holds its own copies; ours would keep the pipes alive.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        try stdin.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(command) + Data([10]))
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("Worker не завершился самостоятельно")
        }
        let code = process.terminationStatus
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try? stdin.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        let events = output.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(WorkerEvent.self, from: Data($0)) }
        return WorkerRun(code: code, events: events,
                         stdoutText: String(decoding: output, as: UTF8.self), stderrText: stderrText)
    }

    private func attemptWorkspace(command: WorkerCommand, input: AnonymizationAttemptInput?) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("attempts/\(command.runId)")
        try Disk.directory(workspace)
        if let input { try Disk.write(input, to: workspace.appendingPathComponent(AnonymizationAttemptInput.filename)) }
        return workspace
    }

    private func validInput(command: WorkerCommand) -> AnonymizationAttemptInput {
        AnonymizationAttemptInput(fileId: command.jobId, attemptId: command.runId,
            source: TextRevision(id: UUID().uuidString, text: "Отчёт \(Self.textMarker) команды"),
            importedNameStem: Self.nameMarker, sourceFormat: .markdown,
            dataTypes: ["Имена и фамилии"], profileID: "shared-profile", packageID: "shared-package")
    }

    private func command(path: String) -> WorkerCommand {
        WorkerCommand(anonymizationJobId: UUID().uuidString, runId: UUID().uuidString,
                      anonymizationPath: path, modelsPath: "/tmp/models")
    }

    func testAnonymizationKindWithoutAttemptPathExits64() throws {
        let binary = try XCTUnwrap(Self.binary, "Соберите worker: swift build -c release -j 4 --force-resolved-versions")
        var command = command(path: "/tmp/attempt")
        command.anonymizationPath = nil
        let run = try runWorker(binary: binary, command: command)
        XCTAssertEqual(run.code, 64)
        XCTAssertTrue(run.events.isEmpty, "невалидная команда не должна публиковать события")
    }

    func testAnonymizationCommandWithAudioFieldsExits64() throws {
        let binary = try XCTUnwrap(Self.binary)
        var command = command(path: "/tmp/attempt")
        command.stage = .transcribing
        let run = try runWorker(binary: binary, command: command)
        XCTAssertEqual(run.code, 64)
        XCTAssertTrue(run.events.isEmpty)
    }

    func testAnonymizationCommandWithDiagramPathExits64() throws {
        let binary = try XCTUnwrap(Self.binary)
        var command = command(path: "/tmp/attempt")
        command.diagramPath = "/tmp/item"
        let run = try runWorker(binary: binary, command: command)
        XCTAssertEqual(run.code, 64)
        XCTAssertTrue(run.events.isEmpty)
    }

    func testAudioCommandWithAttemptPathExits64() throws {
        let binary = try XCTUnwrap(Self.binary)
        // The kindless audio route keeps its exclusive field set: an attempt
        // workspace on an audio command is a protocol violation.
        var command = WorkerCommand(jobId: UUID().uuidString, runId: UUID().uuidString, stage: .transcribing,
            recordingPath: "/tmp/recording", modelsPath: "/tmp/models", toolsPath: "/tmp/tools")
        command.anonymizationPath = "/tmp/attempt"
        let run = try runWorker(binary: binary, command: command)
        XCTAssertEqual(run.code, 64)
        XCTAssertTrue(run.events.isEmpty)
    }

    func testValidInputRoutesToPipelineAndFailsSafelyWithoutCatalog() throws {
        let binary = try XCTUnwrap(Self.binary)
        let provisional = command(path: "/tmp/attempt")
        let workspace = try attemptWorkspace(command: provisional, input: validInput(command: provisional))
        // The processing stage is real now: a valid input proceeds to model
        // resolution. Without a model catalog next to the isolated models
        // root the attempt fails safely and publishes nothing.
        let modelsRoot = workspace.deletingLastPathComponent().appendingPathComponent("models")
        let command = WorkerCommand(anonymizationJobId: provisional.jobId, runId: provisional.runId,
                                    anonymizationPath: workspace.path, modelsPath: modelsRoot.path)
        let run = try runWorker(binary: binary, command: command)
        XCTAssertEqual(run.code, 1)
        XCTAssertEqual(run.events.map(\.type), ["started", "progress", "failed"])
        for event in run.events {
            XCTAssertEqual(event.kind, "anonymization", "событие должно различать вид задания")
            XCTAssertEqual(event.jobId, command.jobId)
            XCTAssertEqual(event.runId, command.runId)
        }
        let failure = try XCTUnwrap(run.events.last)
        XCTAssertEqual(failure.message, "Не найден каталог моделей для обезличивания")
        XCTAssertFalse(run.events.contains { $0.type == "completed" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("result.json").path))
        // The protocol channel carries identifiers and safe statuses only.
        XCTAssertFalse(run.stdoutText.contains(Self.textMarker), "текст документа не должен попадать в протокол")
        XCTAssertFalse(run.stdoutText.contains(Self.nameMarker), "имя импорта не должно попадать в протокол")
        XCTAssertFalse(run.stderrText.contains(Self.textMarker))
        XCTAssertFalse(run.stderrText.contains(command.jobId), "stderr не должен раскрывать пути задания")
    }

    func testInputOfAnotherAttemptFailsSafely() throws {
        let binary = try XCTUnwrap(Self.binary)
        let provisional = command(path: "/tmp/attempt")
        var input = validInput(command: provisional)
        input.attemptId = UUID().uuidString
        let workspace = try attemptWorkspace(command: provisional, input: input)
        let command = WorkerCommand(anonymizationJobId: provisional.jobId, runId: provisional.runId,
                                    anonymizationPath: workspace.path, modelsPath: "/tmp/models")
        let run = try runWorker(binary: binary, command: command)
        XCTAssertEqual(run.code, 1)
        XCTAssertEqual(run.events.map(\.type), ["started", "failed"])
        XCTAssertEqual(run.events.last?.kind, "anonymization")
        XCTAssertEqual(run.events.last?.message, "Вход обезличивания не соответствует заданию")
        XCTAssertFalse(run.stdoutText.contains(Self.textMarker))
        XCTAssertFalse(run.stderrText.contains(Self.textMarker))
    }

    func testMissingInputFailsSafely() throws {
        let binary = try XCTUnwrap(Self.binary)
        let provisional = command(path: "/tmp/attempt")
        let workspace = try attemptWorkspace(command: provisional, input: nil)
        let command = WorkerCommand(anonymizationJobId: provisional.jobId, runId: provisional.runId,
                                    anonymizationPath: workspace.path, modelsPath: "/tmp/models")
        let run = try runWorker(binary: binary, command: command)
        XCTAssertEqual(run.code, 1)
        XCTAssertEqual(run.events.map(\.type), ["started", "failed"])
        XCTAssertEqual(run.events.last?.message, "Не удалось прочитать вход обезличивания")
        XCTAssertFalse(run.stderrText.contains(workspace.path), "ошибка чтения не должна раскрывать путь")
    }

    // MARK: - Qualification probe (--probe-anonymization)

    /// Spawns the worker in the probe mode with explicit arguments; the probe
    /// never reads stdin, so the pipe is closed right after the launch.
    private func runProbe(binary: URL, arguments: [String]) throws -> WorkerRun {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try? stdin.fileHandleForWriting.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("Проба не завершилась самостоятельно")
        }
        let code = process.terminationStatus
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        return WorkerRun(code: code, events: [], stdoutText: String(decoding: output, as: UTF8.self), stderrText: stderrText)
    }

    private func probeInput() throws -> (input: AnonymizationAttemptInput, url: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("attempts")
        try Disk.directory(workspace)
        let input = AnonymizationAttemptInput(fileId: UUID().uuidString, attemptId: UUID().uuidString,
            source: TextRevision(id: UUID().uuidString, text: "Отчёт \(Self.textMarker) команды"),
            importedNameStem: Self.nameMarker, sourceFormat: .txt, dataTypes: ["Имена и фамилии"],
            profileID: "candidate", packageID: "pkg-fixture")
        let url = workspace.appendingPathComponent(AnonymizationAttemptInput.filename)
        try Disk.write(input, to: url)
        return (input, url, root)
    }

    func testProbeAnonymizationWithoutCatalogFailsSafely() throws {
        let binary = try XCTUnwrap(Self.binary)
        let (_, inputURL, root) = try probeInput()
        let run = try runProbe(binary: binary, arguments: ["--probe-anonymization",
                                                           root.appendingPathComponent("models").path, inputURL.path])
        XCTAssertEqual(run.code, 1)
        // The probe reports the raw failure as one JSON line on the protocol
        // output, without the neutral production wrapper.
        let line = run.stdoutText.split(separator: "\n").first.map(String.init) ?? ""
        let report = try XCTUnwrap(try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        XCTAssertEqual(report["status"], "failed")
        XCTAssertTrue(report["error"]?.contains("каталог") ?? false, "отчёт: \(line)")
        XCTAssertNil(report["result"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: inputURL.deletingLastPathComponent()
            .appendingPathComponent("result.json").path))
        XCTAssertFalse(run.stdoutText.contains(Self.textMarker), "текст документа не должен попадать в отчёт пробы")
        XCTAssertFalse(run.stderrText.contains(Self.textMarker))
    }

    func testProbeAnonymizationBypassesTaskGateButKeepsFileVerification() throws {
        let binary = try XCTUnwrap(Self.binary)
        let (_, inputURL, root) = try probeInput()
        // A catalog profile without the ANONYMIZATION stamp: the probe must
        // resolve it (qualification runs before the stamp) and still fail on
        // the full size/SHA verification of the missing weights.
        let files = [ModelFile(path: "weights.bin", localPath: "weights.bin", size: 8, sha256: String(repeating: "0", count: 64))]
        let profile = ModelProfile(id: "candidate", repository: "fixture/llm", revision: "fixture-rev",
                                   license: "test", files: files, role: .summary, supportedTasks: [.summary])
        try Disk.directory(root.appendingPathComponent("models"))
        try Disk.write(ModelCatalog(models: [profile]), to: root.appendingPathComponent("tools/models.lock.json"))
        var input = try Disk.read(AnonymizationAttemptInput.self, at: inputURL)
        input.packageID = ModelPackage.identity(ofFiles: files)
        try Disk.write(input, to: inputURL)
        let run = try runProbe(binary: binary, arguments: ["--probe-anonymization",
                                                           root.appendingPathComponent("models").path, inputURL.path])
        XCTAssertEqual(run.code, 1)
        let line = run.stdoutText.split(separator: "\n").first.map(String.init) ?? ""
        let report = try XCTUnwrap(try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
        XCTAssertEqual(report["status"], "failed")
        XCTAssertFalse(report["error"]?.contains("недоступна в каталоге") ?? true,
                       "проба обязана обходить шлюз задачи: \(line)")
        XCTAssertTrue(report["error"]?.contains("повреждён") ?? false, "проверка файлов должна остаться: \(line)")
        XCTAssertFalse(run.stdoutText.contains(Self.textMarker))
        XCTAssertFalse(run.stderrText.contains(Self.textMarker))
    }
}
