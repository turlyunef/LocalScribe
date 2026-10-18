import XCTest
import LocalScribeCore
@testable import LocalScribe

@MainActor
final class WorkerSupervisorTests: XCTestCase {
    private func fixture(_ root: URL, body: (WorkerCommand) throws -> String) throws -> (URL, WorkerCommand) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let command = WorkerCommand(jobId: UUID().uuidString, runId: UUID().uuidString, stage: .preparingAudio,
                                    recordingPath: root.path, modelsPath: root.path, toolsPath: root.path)
        let executable = root.appendingPathComponent("worker.sh")
        try ("#!/bin/sh\nIFS= read -r command\n" + body(command)).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, command)
    }
    private func event(_ command: WorkerCommand, type: String) throws -> String {
        // UUIDs and protocol fields contain no shell quotes.
        let json = String(decoding: try JSONEncoder().encode(WorkerEvent(command: command, type: type)), as: UTF8.self)
        return "printf '%s\\n' '\(json)'\n"
    }

    func testTaskCancellationWaitsForWorkerAndAllowsAnotherRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = WorkerSupervisor()
        let (executable, command) = try fixture(root) { command in
            try event(command, type: "started") + "while IFS= read -r extra; do :; done\n"
        }
        var started = false
        let task = Task { try await supervisor.run(command, executable: executable) { _ in started = true } }
        let deadline = Date().addingTimeInterval(3)
        while !started && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(started)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled worker succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(supervisor.running)
        let (nextExecutable, nextCommand) = try fixture(root) { try event($0, type: "completed") }
        try await supervisor.run(nextCommand, executable: nextExecutable) { _ in }
        XCTAssertFalse(supervisor.running)
    }

    func testProtocolFailureDrainsPipesAndDoesNotRetainSupervisor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (executable, command) = try fixture(root) { _ in "printf 'invalid protocol\\n'\n" }
        var supervisor: WorkerSupervisor? = WorkerSupervisor()
        weak var released = supervisor
        do { try await supervisor!.run(command, executable: executable) { _ in }; XCTFail("Invalid protocol succeeded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("протокол")) }
        XCTAssertFalse(supervisor!.running)
        supervisor = nil
        XCTAssertNil(released)
    }
}
