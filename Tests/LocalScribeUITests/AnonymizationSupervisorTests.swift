import XCTest
import LocalScribeCore
@testable import LocalScribe

/// The supervisor encodes the anonymization command and decodes its events,
/// distinguishing the job kind and the attempt; an event of a foreign kind
/// must be rejected as a protocol violation.
@MainActor
final class AnonymizationSupervisorTests: XCTestCase {
    private func fixture(_ root: URL, body: (WorkerCommand) throws -> String) throws -> (URL, WorkerCommand) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let command = WorkerCommand(anonymizationJobId: UUID().uuidString, runId: UUID().uuidString,
            anonymizationPath: root.path, modelsPath: root.path, toolsPath: root.path)
        let executable = root.appendingPathComponent("worker.sh")
        try ("#!/bin/sh\nIFS= read -r command\n" + body(command)).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, command)
    }

    private func event(_ command: WorkerCommand, type: String) throws -> String {
        // Protocol fields contain no shell quotes.
        let json = String(decoding: try JSONEncoder().encode(WorkerEvent(command: command, type: type)), as: UTF8.self)
        return "printf '%s\\n' '\(json)'\n"
    }

    /// An event line without the command's kind discriminator, like a worker
    /// of a foreign job kind would emit.
    private func kindlessEvent(_ command: WorkerCommand, type: String) throws -> String {
        let encoded = try JSONEncoder().encode(WorkerEvent(command: command, type: type))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "kind")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return "printf '%s\\n' '\(json)'\n"
    }

    func testSupervisorRunsAnonymizationCommandAndDecodesKindAndAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = WorkerSupervisor()
        let (executable, command) = try fixture(root) { command in
            var lines = ""
            for type in ["started", "progress", "completed"] { lines += try event(command, type: type) }
            return lines
        }
        var received: [WorkerEvent] = []
        try await supervisor.run(command, executable: executable) { event in received.append(event) }
        XCTAssertEqual(received.map(\.type), ["started", "progress", "completed"])
        for event in received {
            XCTAssertEqual(event.kind, "anonymization")
            XCTAssertTrue(event.isAnonymization)
            XCTAssertFalse(event.isDiagram)
            XCTAssertEqual(event.jobId, command.jobId)
            XCTAssertEqual(event.runId, command.runId)
        }
        XCTAssertFalse(supervisor.running)
    }

    func testSupervisorRejectsEventWithoutCommandKind() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = WorkerSupervisor()
        let (executable, command) = try fixture(root) { command in
            var lines = ""
            for type in ["started", "completed"] { lines += try kindlessEvent(command, type: type) }
            return lines
        }
        do { try await supervisor.run(command, executable: executable) { _ in }; XCTFail("Событие чужого вида принято") }
        catch { XCTAssertTrue(error.localizedDescription.contains("протокол"), "неожиданная ошибка: \(error)") }
        XCTAssertFalse(supervisor.running)
    }

    func testSupervisorRejectsEventOfForeignAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = WorkerSupervisor()
        let (executable, command) = try fixture(root) { command in
            var other = command
            other.runId = UUID().uuidString
            return try event(other, type: "completed")
        }
        do { try await supervisor.run(command, executable: executable) { _ in }; XCTFail("Чужая попытка принята") }
        catch { XCTAssertTrue(error.localizedDescription.contains("протокол"), "неожиданная ошибка: \(error)") }
        XCTAssertFalse(supervisor.running)
    }
}
