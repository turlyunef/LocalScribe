import Darwin
import Synchronization
import XCTest
import LocalScribeCore
@testable import LocalScribeWorker

private final class CallbackToken: Sendable {
    let calls = Mutex(0)
    func call() { calls.withLock { $0 += 1 } }
}

final class WorkerLifecycleTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    func testCommandReaderConsumesOneLineAndPreservesUnicode() throws {
        let command = WorkerCommand(jobId: UUID().uuidString, runId: UUID().uuidString, stage: .transcribing,
            recordingPath: "/tmp/Запись 🎙️", modelsPath: "/tmp/models", toolsPath: "/tmp/tools")
        let line = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        var reads = 0
        let decoded = try XCTUnwrap(Worker.readCommand { reads += 1; return line })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(decoded.jobId, command.jobId)
        XCTAssertEqual(decoded.runId, command.runId)
        XCTAssertEqual(decoded.recordingPath, command.recordingPath)
        XCTAssertEqual(decoded.stage, command.stage)
    }

    func testCommandReaderRejectsEOFInvalidJSONAndUnsupportedVersion() throws {
        XCTAssertNil(Worker.readCommand { nil })
        XCTAssertNil(Worker.readCommand { "{" })
        XCTAssertNil(Worker.readCommand { "{}" })
        var command = WorkerCommand(jobId: UUID().uuidString, runId: UUID().uuidString, stage: .transcribing,
            recordingPath: "/tmp/recording", modelsPath: "/tmp/models", toolsPath: "/tmp/tools")
        command.version = 2
        let line = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        XCTAssertNil(Worker.readCommand { line })
    }

    func testStopReleasesBothCallbacksAndKeepsBorrowedDescriptorOpen() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        var token: CallbackToken? = CallbackToken()
        weak var retained = token
        let control = WorkerControl(parent: getppid(), onParentExit: { [token = token!] in token.call() })
        await control.watchInput(descriptor: pipe.fileHandleForReading.fileDescriptor) { [token = token!] in token.call() }
        token = nil
        XCTAssertNotNil(retained)
        await control.stop()
        XCTAssertNil(retained, "stop must release the watchdog and input callbacks before returning")
        XCTAssertGreaterThanOrEqual(fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFD), 0)
        await control.stop() // Joining an already stopped control is safe.
    }

    func testInputDrainsAdditionalBytesAndCancelsOnlyAtEOF() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let calls = Mutex(0)
        let control = WorkerControl(parent: getppid())
        await control.watchInput(descriptor: pipe.fileHandleForReading.fileDescriptor) { calls.withLock { $0 += 1 } }
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 42, count: 8192))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.withLock { $0 }, 0)
        try pipe.fileHandleForWriting.close()
        let sawEOF = try await waitUntil { calls.withLock { $0 > 0 } }
        await control.stop()
        XCTAssertTrue(sawEOF)
        let finalCalls = calls.withLock { $0 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.withLock { $0 }, finalCalls)
    }

    func testStopWaitsForAnExecutingInputCallback() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let entered = Mutex(false), stopped = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let control = WorkerControl(parent: getppid())
        await control.watchInput(descriptor: pipe.fileHandleForReading.fileDescriptor) {
            entered.withLock { $0 = true }
            release.wait()
        }
        try pipe.fileHandleForWriting.close()
        guard try await waitUntil({ entered.withLock { $0 } }) else {
            release.signal(); await control.stop()
            return XCTFail("Input callback did not start")
        }
        let stop = Task { await control.stop(); stopped.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(stopped.withLock { $0 }, "stop must join an in-flight callback")
        release.signal()
        await stop.value
        XCTAssertTrue(stopped.withLock { $0 })
    }
}
