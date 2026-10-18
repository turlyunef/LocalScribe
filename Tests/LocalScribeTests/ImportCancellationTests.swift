import Darwin
import XCTest
@testable import LocalScribeCore

@MainActor
final class ImportCancellationTests: XCTestCase {
    func testCancelledHashAndCopyRemovePartialAndCloseDescriptors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Disk.directory(root)
        let source = root.appendingPathComponent("source.wav")
        let partial = root.appendingPathComponent("copy.partial")
        try Data(repeating: 42, count: 8 * 1024 * 1024).write(to: source)
        let digest = try Disk.hash(source)
        try await Task.detached {
            let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
            do {
                let input = try ImportSource(source)
                defer { input.close() }
                withUnsafeCurrentTask { $0?.cancel() }
                XCTAssertThrowsError(try input.hash()) { XCTAssertTrue($0 is CancellationError) }
                XCTAssertThrowsError(try input.copy(to: partial, verifying: digest)) { XCTAssertTrue($0 is CancellationError) }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, before)
            XCTAssertEqual(try Disk.hash(source), digest)
        }.value
    }

    func testCancellationAfterHashRollsBackUnpublishedRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Disk.directory(root)
        let source = root.appendingPathComponent("source.wav")
        try Data("keep external source".utf8).write(to: source)
        var repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        // Duplicate lookup occurs after hashing, before the first copy chunk.
        repo.observeIO = { operation in
            if operation == .archiveScan { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let repository = repo
        try await Task.detached {
            let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
            XCTAssertThrowsError(try repository.importFile(source, info: AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le"))) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, before)
        }.value
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.root.appendingPathComponent("recordings").path), [])
        XCTAssertEqual(try Data(contentsOf: source), Data("keep external source".utf8))
    }

    func testProbeCancellationAfterLeaderExitOrStdoutEOFKillsProcessesWithoutLeakingDescriptors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Disk.directory(root)
        let shell = URL(fileURLWithPath: "/bin/sh")
        // Warm up the cancellable pipe path before measuring descriptors.
        _ = try Media.execute(shell, ["-c", "printf ok"], cancellable: true)
        let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for index in 0..<4 {
            let pidFile = root.appendingPathComponent("child-\(index).pid")
            // Cover both a descendant retaining stdout after the leader exits,
            // and a live leader after stdout EOF (the cancellable waitpid path).
            let script = index.isMultiple(of: 2)
                ? "/bin/sleep 60 & echo $! > \"$1\"; exit 0"
                : "exec 1>/dev/null; echo $$ > \"$1\"; exec /bin/sleep 60"
            let task = Task.detached {
                try Media.execute(shell, ["-c", script, "fixture", pidFile.path], cancellable: true)
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled probe succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            defer { kill(pid, SIGKILL) }
            let stopped = ContinuousClock.now + .seconds(3)
            while kill(pid, 0) == 0, ContinuousClock.now < stopped { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, before)
    }
}
