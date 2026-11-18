import AppKit
import Darwin
import Synchronization
import XCTest
@testable import LocalScribe
@testable import LocalScribeCore

@MainActor
final class ImportQueueTests: XCTestCase {
    func testSubmissionDuringCancellationUnwindReportsErrorAndSlotCanBeReused() async throws {
        let queue = ImportQueue()
        let started = expectation(description: "Active import is waiting")
        var release: CheckedContinuation<Void, Never>?
        var exited = false, rejectedRan = false, nextRan = false
        try queue.enqueue {
            await withCheckedContinuation { continuation in release = continuation; started.fulfill() }
            exited = true
        }
        await fulfillment(of: [started], timeout: 2)
        queue.cancel()
        XCTAssertThrowsError(try queue.enqueue { rejectedRan = true }) {
            XCTAssertTrue($0.localizedDescription.contains("Импорт отменяется"))
        }
        XCTAssertFalse(exited)
        release?.resume(); release = nil
        await queue.waitUntilIdle()
        XCTAssertTrue(exited); XCTAssertFalse(rejectedRan)
        try queue.enqueue { nextRan = true }
        await queue.waitUntilIdle()
        XCTAssertTrue(nextRan)
    }

    private struct Counts {
        var active = 0, maximum = 0, providers = 0, probes = 0
        var order: [String] = []
        mutating func enter() { active += 1; maximum = max(maximum, active) }
    }
    private func source(_ root: URL, _ name: String) throws -> URL {
        try Disk.directory(root)
        let url = root.appendingPathComponent(name + ".wav")
        try Data(name.utf8).write(to: url)
        return url
    }
    private func defaults() -> UserDefaults {
        let suite = "ImportQueueTests." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    func testFiftyProvidersAndSeparateURLCallsShareOneFIFOImportSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let counts = Mutex(Counts())
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults(), importProbe: { url, _ in
            counts.withLock { $0.enter(); $0.probes += 1; $0.order.append(url.lastPathComponent) }
            defer { counts.withLock { $0.active -= 1 } }
            Thread.sleep(forTimeInterval: 0.003)
            return AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le")
        })
        var expected: [String] = []
        for index in 0..<50 {
            let url = try source(root, "drop-\(index)")
            expected.append(contentsOf: [url.lastPathComponent, "original.wav"])
            let provider = NSItemProvider()
            provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
                counts.withLock { $0.providers += 1 }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.003) {
                    completion(url as NSURL, nil)
                }
                return Progress(totalUnitCount: 1)
            }
            // Provider loads resolve eagerly in the drop callback, outside the
            // queue slot (as for diagrams); only the import itself is serialized.
            model.importProviders([provider])
            if index == 24 {
                let dialogURL = try source(root, "dialog")
                expected.append(contentsOf: [dialogURL.lastPathComponent, "original.wav"])
                model.importURLs([dialogURL])
            }
        }
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(counts.withLock { $0.maximum }, 1)
        XCTAssertEqual(counts.withLock { $0.active }, 0)
        XCTAssertEqual(counts.withLock { $0.providers }, 50)
        XCTAssertEqual(counts.withLock { $0.probes }, 102)
        XCTAssertEqual(counts.withLock { $0.order }, expected)
        XCTAssertEqual(model.recordings.count, 51)
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
        for manifest in repo.list() {
            XCTAssertEqual(try Disk.hash(repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)), manifest.sha256)
            XCTAssertEqual(manifest.state, .waitingForModels)
        }
        await model.shutdown()
    }

    func testDuplicateOpenRetryAndCancelStayInQueueAndNextFileStillImports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let url = try source(root, "duplicate")
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults(), importProbe: { _, _ in
            AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le")
        })
        model.importURLs([url])
        await model.importQueue.waitUntilIdle()
        let original = try XCTUnwrap(model.recordings.first)
        var duplicates = 0
        model.resolveDuplicateImport = { duplicate in
            duplicates += 1
            XCTAssertEqual(duplicate.id, original.id)
            return .openExisting
        }
        model.importURLs([url])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.selection, original.id)
        model.resolveDuplicateImport = { _ in duplicates += 1; return .importAgain }
        model.importURLs([url])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.recordings.count, 2)
        model.resolveDuplicateImport = { _ in duplicates += 1; return .cancel }
        model.importURLs([url, try source(root, "next")])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(duplicates, 3)
        XCTAssertEqual(model.recordings.count, 3)
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
        await model.shutdown()
    }

    func testProviderAndProbeFailuresDoNotStopFollowingImports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults(), importProbe: { url, _ in
            if url.lastPathComponent == "bad.wav" { throw ScribeError.message("Тестовая ошибка probe") }
            return AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le")
        })
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
            completion(nil, ScribeError.message("Тестовая ошибка provider"))
            return nil
        }
        model.importProviders([provider])
        model.importURLs([try source(root, "bad"), try source(root, "good")])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.recordings.map(\.displayTitle), ["good"])
        XCTAssertEqual(model.errorHandler.messages.count, 2)
        XCTAssertTrue(model.errorHandler.messages.contains { $0.contains("probe") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.root.appendingPathComponent("recordings").path).count, 1)
        await model.shutdown()
    }

    func testShutdownCancelsProviderWithoutCallbackAndIgnoresLateURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let url = try source(root, "late")
        let callback = Mutex<(@Sendable (URL?, Error?) -> Void)?>(nil)
        let progress = Progress(totalUnitCount: 1)
        let cancelled = Mutex(false)
        progress.cancellationHandler = { cancelled.withLock { $0 = true } }
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
            callback.withLock { $0 = { url, error in completion(url as NSURL?, error) } }
            return progress
        }
        let probes = Mutex(0)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults(), importProbe: { _, _ in
            probes.withLock { $0 += 1 }
            return AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le")
        })
        model.importProviders([provider])
        model.importURLs([url])
        try await waitUntil { callback.withLock { $0 != nil } }
        await model.shutdown()
        try await waitUntil { cancelled.withLock { $0 } }
        callback.withLock { $0 }?(url, nil)
        model.importURLs([url])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(probes.withLock { $0 }, 0)
        XCTAssertTrue(repo.list().isEmpty)
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
    }

    func testCancellingDiagramDropCancelsStartedProvidersWaitingForQueueSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults())
        let workspace = DiagramWorkspaceModel(model: model)
        let callback = Mutex<(@Sendable (URL) -> Void)?>(nil)
        let progress = Progress(totalUnitCount: 1)
        let cancelled = Mutex(false)
        progress.cancellationHandler = { cancelled.withLock { $0 = true } }
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
            callback.withLock { $0 = { completion($0 as NSURL, nil) } }
            return progress
        }
        var release: CheckedContinuation<Void, Never>?
        try model.importQueue.enqueue {
            await withCheckedContinuation { release = $0 }
        }
        try await waitUntil { release != nil }
        XCTAssertTrue(workspace.importProviders([provider]))
        try await waitUntil { callback.withLock { $0 != nil } }

        model.importQueue.cancel()
        release?.resume()
        await model.importQueue.waitUntilIdle()
        try await waitUntil { cancelled.withLock { $0 } }
        callback.withLock { $0 }?(root.appendingPathComponent("late.png"))
        await model.importQueue.waitUntilIdle()
        XCTAssertTrue(model.diagrams.isEmpty)
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
        await model.shutdown()
    }

    func testCancelAndShutdownReapActiveProbeAndDiscardPendingImports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let tools = root.appendingPathComponent("tools")
        try Disk.directory(tools)
        let executable = tools.appendingPathComponent("ffprobe")
        try #"""
        #!/bin/sh
        for source in "$@"; do :; done
        echo $$ > "$source.pid"
        exec /bin/sleep 60
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults(), importProbe: { url, _ in
            try Media.probe(url, tools: tools, cancellable: true)
        })
        // Cancellation alone must release the slot for a subsequent submission;
        // shutdown performs the same cancellation and awaits its cleanup barrier.
        for shutdown in [false, true] {
            let url = try source(root, shutdown ? "shutdown" : "cancel")
            let pending = try source(root, shutdown ? "pending-shutdown" : "pending-cancel")
            let pidFile = url.appendingPathExtension("pid")
            model.importURLs([url, pending])
            try await waitUntil { FileManager.default.fileExists(atPath: pidFile.path) }
            let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            defer { kill(pid, SIGKILL) }
            let started = ContinuousClock.now
            if shutdown { await model.shutdown() }
            else { model.importQueue.cancel(); await model.importQueue.waitUntilIdle() }
            XCTAssertLessThan(started.duration(to: .now), .seconds(3))
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
            XCTAssertFalse(FileManager.default.fileExists(atPath: pending.appendingPathExtension("pid").path))
            XCTAssertTrue(repo.list().isEmpty)
            XCTAssertTrue(model.errorHandler.messages.isEmpty)
        }
    }

    func testBatchImportPublishesFewSnapshotsAndSameFinalState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults(), importProbe: { _, _ in
            AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le")
        })
        var urls: [URL] = []
        for index in 0..<12 { urls.append(try source(root, "batch-\(index)")) }
        let corpusBefore = model.recordingSearch.corpusRevision
        model.importURLs(urls)
        await model.importQueue.waitUntilIdle()
        // The batch applied a bounded number of corpus updates (one per file
        // would be 12+); the final state is identical either way. The exact
        // order is not compared against the on-disk listing: manifest dates
        // round-trip through ISO 8601 without sub-second precision, so a
        // same-second import pair legitimately orders by id on reload.
        XCTAssertLessThanOrEqual(model.recordingSearch.corpusRevision - corpusBefore, 4)
        XCTAssertEqual(model.recordings.count, 12)
        XCTAssertEqual(Set(model.recordings.map(\.id)), Set(repo.list().map(\.id)))
        XCTAssertTrue(model.errorHandler.messages.isEmpty)
        for manifest in repo.list() {
            XCTAssertEqual(manifest.state, .waitingForModels)
        }
        await model.shutdown()
    }

    func testBatchImportFlushesSnapshotWhenLastFileFailsOrIsCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults(), importProbe: { url, _ in
            if url.lastPathComponent == "bad.wav" { throw ScribeError.message("Тестовая ошибка probe") }
            return AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le")
        })
        // Earlier files must stay published even when the batch's final entry
        // fails after them.
        model.importURLs([try source(root, "good-a"), try source(root, "good-b"), try source(root, "bad")])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(Set(model.recordings.map(\.displayTitle)), ["good-a", "good-b"])
        XCTAssertEqual(model.recordings.count, repo.list().count)
        // A non-importing last entry (a cancelled duplicate) ends the batch
        // and must still publish the file imported before it.
        model.resolveDuplicateImport = { _ in .cancel }
        model.importURLs([try source(root, "good-c"), try source(root, "good-a")])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(Set(model.recordings.map(\.displayTitle)), ["good-a", "good-b", "good-c"])
        XCTAssertEqual(model.recordings.count, repo.list().count)
        XCTAssertEqual(model.errorHandler.messages.count, 1)
        await model.shutdown()
    }
}
