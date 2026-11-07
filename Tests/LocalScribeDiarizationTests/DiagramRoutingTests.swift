import XCTest
import LocalScribeCore
@testable import LocalScribeWorker

/// End-to-end routing over the real built worker binary: strict kind/field
/// validation on stdin and the diagram failure path with a protocol event.
final class DiagramRoutingTests: XCTestCase {
    private struct WorkerRun {
        let code: Int32
        let events: [WorkerEvent]
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

    /// Spawns the worker, sends exactly one command line and keeps stdin open
    /// until the process exits (EOF would read as a user cancellation).
    private func runWorker(binary: URL, command: WorkerCommand? = nil, line: String? = nil) throws -> WorkerRun {
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
        let payload: String
        if let line { payload = line }
        else { payload = String(decoding: try JSONEncoder().encode(try XCTUnwrap(command)), as: UTF8.self) }
        try stdin.fileHandleForWriting.write(contentsOf: Data((payload + "\n").utf8))
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("Worker не завершился самостоятельно: \(payload.prefix(120))")
        }
        let code = process.terminationStatus
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try? stdin.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        let events = output.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(WorkerEvent.self, from: Data($0)) }
        return WorkerRun(code: code, events: events, stderrText: stderrText)
    }

    func testDiagramKindWithoutDiagramPathExits64() throws {
        let binary = try XCTUnwrap(Self.binary, "Соберите worker: swift build -c release -j 4 --force-resolved-versions")
        var command = WorkerCommand(diagramJobId: UUID().uuidString, runId: UUID().uuidString,
            diagramPath: "/nonexistent/item", modelsPath: "/tmp/models")
        command.diagramPath = nil
        let run = try runWorker(binary: binary, command: command)
        XCTAssertEqual(run.code, 64)
        XCTAssertTrue(run.events.isEmpty, "невалидная команда не должна публиковать события")
    }

    func testUnknownKindExits64() throws {
        let binary = try XCTUnwrap(Self.binary)
        var command = WorkerCommand(jobId: UUID().uuidString, runId: UUID().uuidString, stage: .transcribing,
            recordingPath: "/tmp/recording", modelsPath: "/tmp/models", toolsPath: "/tmp/tools")
        command.kind = "foo"
        let run = try runWorker(binary: binary, command: command)
        XCTAssertEqual(run.code, 64)
        XCTAssertTrue(run.events.isEmpty)
    }

    func testKindlessAudioWithoutRecordingPathExits64() throws {
        let binary = try XCTUnwrap(Self.binary)
        var command = WorkerCommand(jobId: UUID().uuidString, runId: UUID().uuidString, stage: .transcribing,
            recordingPath: "/tmp/recording", modelsPath: "/tmp/models", toolsPath: "/tmp/tools")
        command.recordingPath = nil
        let run = try runWorker(binary: binary, command: command)
        XCTAssertEqual(run.code, 64)
        XCTAssertTrue(run.events.isEmpty)
    }

    func testDiagramCommandWithMissingModelFailsWithNeutralEvent() throws {
        let binary = try XCTUnwrap(Self.binary)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let jobID = UUID().uuidString, runID = UUID().uuidString
        // Valid item structure, but the catalog has no diagram profile: the
        // engine must fail before any model load, with a protocol event.
        try Disk.write(ModelCatalog(models: []), to: root.appendingPathComponent("tools/models.lock.json"))
        try Disk.directory(root.appendingPathComponent("models"))
        let item = root.appendingPathComponent("items/\(jobID)")
        let original = item.appendingPathComponent("original.png")
        try Disk.directory(original.deletingLastPathComponent())
        let bytes = Data("not-really-png-but-unread-by-this-path".utf8)
        try bytes.write(to: original)
        var manifest = DiagramManifest(title: "Схема", filename: "Схема.png", ext: "png", uti: "public.png")
        manifest.id = jobID
        manifest.sha256 = try Disk.hash(original)
        try Disk.write(manifest, to: item.appendingPathComponent("manifest.json"))
        let info = DiagramRunInfo(id: runID, sourceHash: manifest.sha256, modelID: "diagram-missing", profileHash: "0")
        let runURL = item.appendingPathComponent("runs/\(runID)")
        try Disk.directory(runURL)
        try Disk.write(info, to: runURL.appendingPathComponent("run.json"))
        let command = WorkerCommand(diagramJobId: jobID, runId: runID, diagramPath: item.path,
            modelsPath: root.appendingPathComponent("models").path)
        let run = try runWorker(binary: binary, command: command)
        XCTAssertEqual(run.code, 1)
        XCTAssertNotEqual(run.code, 64)
        XCTAssertEqual(run.events.map(\.type), ["started", "failed"])
        let failure = try XCTUnwrap(run.events.last)
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertTrue(failure.message.contains("модель"), "сообщение \(failure.message) должно объяснять отсутствие модели")
        XCTAssertFalse(run.events.contains { $0.type == "completed" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: runURL.appendingPathComponent("result.json").path))
        XCTAssertFalse(run.stderrText.contains(jobID), "stderr не должен раскрывать пути задания")
    }
}
