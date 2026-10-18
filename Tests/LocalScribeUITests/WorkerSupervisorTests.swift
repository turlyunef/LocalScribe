import XCTest
import LocalScribeCore
import Darwin
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

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func pipeDescriptors() throws -> Set<Int32> {
        Set(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap { name in
            guard let fd = Int32(name) else { return nil }
            var info = stat()
            return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO ? fd : nil
        })
    }

    func testCancellationKillsStubbornChildAfterLeaderExits() async throws {
        try await checkStubbornChild(leaderExitsOnEOF: false)
    }

    func testTaskCancellationKillsStubbornChildWhenLeaderExitsOnEOF() async throws {
        try await checkStubbornChild(leaderExitsOnEOF: true)
    }

    private func checkStubbornChild(leaderExitsOnEOF: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = WorkerSupervisor()
        // Warm up Foundation's process monitor before measuring our pipe ownership.
        let (warmup, warmupCommand) = try fixture(root) { try event($0, type: "completed") }
        try await supervisor.run(warmupCommand, executable: warmup) { _ in }
        let originalPipes = try pipeDescriptors()

        let (executable, command) = try fixture(root) { command in
            let path = "'" + root.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return """
            printf '%s' "$$" > \(path)/leader.pid
            /bin/sh -c 'trap "" TERM; printf "%s" "$$" > "$1/child.pid"; exec /bin/sleep 60' fixture \(path) < /dev/null &
            while [ ! -s \(path)/child.pid ]; do /bin/sleep 0.01; done
            \(try event(command, type: "started"))
            \(leaderExitsOnEOF ? "while IFS= read -r extra; do :; done" : "exit 0")
            """
        }
        var started = false, finished = false
        var outcome: Result<Void, Error>?
        let task = Task {
            do {
                try await supervisor.run(command, executable: executable) { _ in started = true }
                outcome = .success(())
            } catch { outcome = .failure(error) }
            finished = true
        }
        defer { task.cancel() }
        let ready = try await waitUntil { started }
        XCTAssertTrue(ready)
        let child = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("child.pid"), encoding: .utf8)))
        let leader = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("leader.pid"), encoding: .utf8)))
        defer {
            // Fail-safe for a regression: do not leave the fixture or test hung.
            if kill(child, 0) == 0 { kill(child, SIGKILL) }
        }
        XCTAssertEqual(getpgid(child), leader)
        if !leaderExitsOnEOF {
            let exited = try await waitUntil { !supervisor.running }
            XCTAssertTrue(exited, "Leader must exit while its child still holds stdout/stderr")
        }
        XCTAssertFalse(finished)
        XCTAssertEqual(kill(child, 0), 0)

        // This unrelated group must survive all cancellation paths.
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["60"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }

        let start = Date()
        if leaderExitsOnEOF { task.cancel() }
        var firstCancelled = false, secondCancelled = false
        let first = Task { await supervisor.cancel(); firstCancelled = true }
        let second = Task { await supervisor.cancel(); secondCancelled = true }
        let completed = try await waitUntil(timeout: 5) { finished && firstCancelled && secondCancelled }
        XCTAssertTrue(completed, "run and concurrent cancel calls must finish within 5 seconds")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        if !completed { kill(child, SIGKILL) }
        await first.value; await second.value; await task.value
        switch outcome {
        case .failure(let error) where leaderExitsOnEOF: XCTAssertTrue(error is CancellationError)
        case .failure: break
        default: XCTFail("Incomplete/cancelled worker must fail")
        }
        XCTAssertFalse(supervisor.running)
        let childGone = try await waitUntil { kill(child, 0) == -1 && errno == ESRCH }
        XCTAssertTrue(childGone, "Stubborn orphan must be killed and reaped")
        XCTAssertEqual(try pipeDescriptors(), originalPipes, "All worker pipe ends must close after readers join")
        XCTAssertTrue(unrelated.isRunning)

        let (nextExecutable, nextCommand) = try fixture(root) { try event($0, type: "completed") }
        try await supervisor.run(nextCommand, executable: nextExecutable) { _ in }
        await supervisor.cancel()
        XCTAssertFalse(supervisor.running)
        XCTAssertTrue(unrelated.isRunning)
        XCTAssertEqual(try pipeDescriptors(), originalPipes)
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
