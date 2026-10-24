import Foundation
import Synchronization
import XCTest
@testable import LocalScribeCore

final class RepositoryPerformanceTests: XCTestCase {
    private final class Counts: Sendable {
        private let counts = Mutex<[RecordingRepository.IOOperation: Int]>([:])
        func record(_ operation: RecordingRepository.IOOperation) { counts.withLock { $0[operation, default: 0] += 1 } }
        func count(_ operation: RecordingRepository.IOOperation) -> Int { counts.withLock { $0[operation, default: 0] } }
    }
    private func encoded(_ manifests: [Manifest]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifests.sorted { $0.id < $1.id })
    }
    func testBatchImportDeduplicatesAgainstSnapshotWithoutRepeatedArchiveScans() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var repo = try RecordingRepository(root: root)
        let counts = Counts(); repo.observeIO = { counts.record($0) }
        let archive = RecordingCoordinator(repository: repo, indexDelay: .seconds(60), importProbe: { _, _ in
            AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le")
        })
        var imported: [Manifest] = []
        for index in 0..<12 {
            let source = root.appendingPathComponent("input-\(index).wav")
            try Data("unique-\(index)".utf8).write(to: source)
            let manifest = try await archive.importFile(source, tools: root)
            imported.append(manifest)
            do { _ = try await archive.importFile(source, tools: root); XCTFail("Duplicate was imported") }
            catch let duplicate as DuplicateRecording { XCTAssertEqual(duplicate.id, manifest.id) }
            let repeated = try await archive.importFile(source, tools: root, allowDuplicate: true)
            XCTAssertEqual(repeated.sha256, manifest.sha256)
            XCTAssertNotEqual(repeated.id, manifest.id)
        }
        XCTAssertEqual(counts.count(.archiveScan), 1)
        XCTAssertEqual(counts.count(.manifestRead), 0)
        let snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.manifests.count, 24)
        // A newly constructed coordinator also recognizes existing duplicates.
        let reopened = RecordingCoordinator(repository: repo, importProbe: { _, _ in
            AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le")
        })
        do { _ = try await reopened.importFile(root.appendingPathComponent("input-0.wav"), tools: root); XCTFail() }
        catch is DuplicateRecording { }
        await archive.flushIndex()
    }

    func testGroupDeletionWritesOneIndexForSuccessAndPartialFailure() async throws {
        for fail in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var repo = try RecordingRepository(root: root)
            for index in 0..<20 {
                var manifest = Manifest(sourceType: "import", title: "meeting-\(index)", filename: "a.wav")
                manifest.createdAt = Date(timeIntervalSince1970: Double(index))
                try repo.save(manifest)
            }
            let counts = Counts(); repo.observeIO = { counts.record($0) }
            let archive = RecordingCoordinator(repository: repo, indexDelay: .seconds(60), removeRecording: { repository, manifest in
                if fail && manifest.displayTitle == "meeting-10" { throw ScribeError.message("fixture failure") }
                try repository.delete(manifest)
            })
            try await archive.editGroups { try $0.create(name: "Batch") }
            let initial = await archive.snapshot(), group = initial.groups.defaultID
            try await archive.moveRecordings(Set(initial.manifests.map(\.id)), to: group)
            _ = try await archive.prepareGroupDeletion(group)
            do { try await archive.finishGroupDeletion(group, deleteRecordings: true); XCTAssertFalse(fail) }
            catch { XCTAssertTrue(fail) }
            XCTAssertEqual(counts.count(.indexWrite), 1)
            let after = await archive.snapshot()
            let saved = try Disk.read([Manifest].self, at: root.appendingPathComponent("index.json"))
            XCTAssertEqual(saved.map(\.id), after.manifests.map(\.id))
            XCTAssertEqual(after.manifests.count, fail ? 11 : 0)
            XCTAssertEqual(after.groups.groups.contains { $0.id == group }, fail)
            await archive.flushIndex()
            XCTAssertEqual(counts.count(.indexWrite), 1)
        }
    }

    func testArchiveDiagnosticsDistinguishDamagedRecordingsFromGarbageWithoutChangingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var repo = try RecordingRepository(root: root)
        let healthy = Manifest(sourceType: "import", title: "Healthy", filename: "a.wav")
        try repo.save(healthy)
        var damaged: [String] = []
        var preserved: [URL: Data] = [:]
        for kind in 0..<3 {
            var item = healthy; item.id = UUID().uuidString
            try repo.save(item)
            let manifest = repo.folder(item.id).appendingPathComponent("manifest.json")
            let audio = repo.folder(item.id).appendingPathComponent("source/original.wav")
            try Disk.directory(audio.deletingLastPathComponent()); try Data("keep audio".utf8).write(to: audio)
            if kind == 0 { try Data("broken".utf8).write(to: manifest) }
            if kind == 1 { try FileManager.default.removeItem(at: manifest) }
            if kind == 2 { var wrong = healthy; wrong.id = UUID().uuidString; try Disk.write(wrong, to: manifest) }
            preserved[audio] = try Data(contentsOf: audio)
            if kind != 1 { preserved[manifest] = try Data(contentsOf: manifest) }
            damaged.append(item.id)
        }
        for name in ["unrelated", UUID().uuidString] { try Disk.directory(root.appendingPathComponent("recordings/" + name)) }
        var invalid: [String] = []
        XCTAssertEqual(repo.list(reportInvalid: { invalid.append($0) }).map(\.id), [healthy.id])
        XCTAssertEqual(invalid.sorted(), damaged.sorted())
        let counts = Counts(); repo.observeIO = { counts.record($0) }
        let coordinator = RecordingCoordinator(repository: repo)
        let snapshot = try await coordinator.recover()
        XCTAssertEqual(snapshot.unreadableRecordingIDs, damaged.sorted())
        XCTAssertEqual(snapshot.manifests.map(\.id), [healthy.id])
        XCTAssertEqual(counts.count(.archiveScan), 1)
        for (url, bytes) in preserved { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        _ = await coordinator.snapshot()
        XCTAssertEqual(counts.count(.archiveScan), 1)
    }

    func testRecoveryReadsEachOf1000ManifestsOnceAndPublishesOneIndex() throws {
        for size in [250, 1000] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var repo = try RecordingRepository(root: root)
            for index in 0..<size {
                var m = Manifest(sourceType: "microphone", title: "Recovery \(index)", filename: "original.caf")
                m.createdAt = Date(timeIntervalSince1970: Double(index))
                m.state = index.isMultiple(of: 2) ? .recording : .transcribing
                m.captureProcessing = .transcribing
                m.activeRunId = UUID().uuidString; m.pendingRunId = UUID().uuidString
                try repo.save(m)
            }
            // Invalid derived data must never be a prerequisite for recovery.
            try Data("broken index".utf8).write(to: root.appendingPathComponent("index.json"))
            let counts = Counts(); repo.observeIO = { counts.record($0) }
            let start = ContinuousClock.now
            let recovered = try repo.recover()
            let elapsed = start.duration(to: .now)
            XCTAssertEqual(counts.count(.manifestRead), size)
            XCTAssertEqual(counts.count(.manifestWrite), size) // including both capture states
            XCTAssertEqual(counts.count(.archiveScan), 1)
            XCTAssertEqual(counts.count(.indexWrite), 1)
            XCTAssertEqual(recovered.count, size)
            XCTAssertTrue(recovered.allSatisfy { $0.state == .interrupted && $0.captureProcessing == .interrupted && $0.activeRunId != nil && $0.pendingRunId != nil })
            let index = try Disk.read([Manifest].self, at: root.appendingPathComponent("index.json"))
            XCTAssertEqual(try encoded(index), try encoded(repo.list()))
            XCTAssertEqual(try encoded(recovered), try encoded(index))
            let writes = counts.count(.manifestWrite)
            _ = try repo.recover()
            XCTAssertEqual(counts.count(.manifestWrite), writes) // idempotent, including warning
            print("R12 recovery n=\(size): \(elapsed), reads=\(size), writes=\(size), scans=1, indexWrites=1")
        }
    }
    func testCrashBetweenManifestAndIndexKeepsNewAndUpdatedRecordings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var old = Manifest(sourceType: "import", title: "Old title", filename: "old.wav")
        try repo.save(old); try repo.writeIndex(repo.list())
        let staleIndex = try Data(contentsOf: root.appendingPathComponent("index.json"))
        old.displayTitle = "Latest title"; old.state = .transcribing
        let new = Manifest(sourceType: "import", title: "New recording", filename: "new.wav")
        try repo.save(old); try repo.save(new)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.json")), staleIndex)
        let reopened = try RecordingRepository(root: root)
        let recovered = try reopened.recover()
        XCTAssertEqual(Set(recovered.map(\.id)), Set([old.id, new.id]))
        XCTAssertEqual(try reopened.load(old.id).displayTitle, old.displayTitle)
        XCTAssertEqual(try reopened.load(old.id).state, .interrupted)
        XCTAssertEqual(try encoded(Disk.read([Manifest].self, at: root.appendingPathComponent("index.json"))), try encoded(reopened.list()))
    }
    func testIndexWriteFailureDoesNotPreventSavingOrRecoveringManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let index = root.appendingPathComponent("index.json")
        try Disk.directory(index)
        let coordinator = RecordingCoordinator(repository: repo)
        var m = Manifest(sourceType: "import", title: "Keep", filename: "a.wav"); m.state = .queued
        try await coordinator.save(m)
        await coordinator.flushIndex()
        let snapshot = try await coordinator.recover()
        XCTAssertEqual(snapshot.manifests.map(\.id), [m.id])
        XCTAssertEqual(try repo.load(m.id).state, .interrupted)
        try FileManager.default.removeItem(at: index)
        _ = try await coordinator.recover()
        XCTAssertEqual(try Disk.read([Manifest].self, at: index).map(\.id), [m.id])
    }
    func testCoordinatorUpdatesOnlyChangedEntryAndCoalescesIndexWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var repo = try RecordingRepository(root: root)
        let m = Manifest(sourceType: "import", title: "Keep", filename: "a.wav")
        try repo.save(m)
        let counts = Counts(); repo.observeIO = { counts.record($0) }
        let coordinator = RecordingCoordinator(repository: repo, indexDelay: .seconds(60))
        _ = await coordinator.snapshot()
        // Explicit flush makes coalescing deterministic even on a slow test machine.
        for number in 0..<20 {
            try await coordinator.update(m.id) { $0.warnings.append("Warning \(number)") }
            _ = await coordinator.snapshot()
        }
        XCTAssertEqual(counts.count(.archiveScan), 1)
        XCTAssertEqual(counts.count(.manifestRead), 21)
        XCTAssertEqual(counts.count(.manifestWrite), 20)
        XCTAssertEqual(counts.count(.indexWrite), 0)
        await coordinator.flushIndex()
        XCTAssertEqual(counts.count(.indexWrite), 1)
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.manifests.first?.warnings.count, 20)
        XCTAssertEqual(try encoded(snapshot.manifests), try encoded(repo.list()))
        XCTAssertEqual(try encoded(Disk.read([Manifest].self, at: root.appendingPathComponent("index.json"))), try encoded(snapshot.manifests))
    }
    func testFailedManifestWriteDoesNotPublishSnapshotOrChangeIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let m = Manifest(sourceType: "import", title: "Before", filename: "a.wav")
        let coordinator = RecordingCoordinator(repository: repo)
        try await coordinator.save(m); await coordinator.flushIndex()
        let before = await coordinator.snapshot()
        let indexBefore = try Data(contentsOf: root.appendingPathComponent("index.json"))
        let manifestFile = repo.folder(m.id).appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifestFile)
        try Disk.directory(manifestFile) // an unwritable destination for atomic file replacement
        var changed = m; changed.displayTitle = "Must not appear"
        do { try await coordinator.save(changed); XCTFail("Manifest write unexpectedly succeeded") } catch { }
        let after = await coordinator.snapshot()
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(try encoded(after.manifests), try encoded(before.manifests))
        await coordinator.flushIndex()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.json")), indexBefore)
    }
    func testConcurrentTransactionsPreserveRenameWarningsAndOtherEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let m = Manifest(sourceType: "import", title: "Before", filename: "a.wav")
        let other = Manifest(sourceType: "import", title: "Other", filename: "b.wav")
        let coordinator = RecordingCoordinator(repository: repo)
        try await coordinator.save(m); try await coordinator.save(other)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0..<100 {
                group.addTask { try await coordinator.update(m.id) { $0.warnings.append("Warning \(number)") } }
            }
            group.addTask { try await coordinator.rename(m.id, title: "After") }
            try await group.waitForAll()
        }
        await coordinator.flushIndex()
        let saved = try repo.load(m.id)
        XCTAssertEqual(saved.displayTitle, "After"); XCTAssertEqual(Set(saved.warnings).count, 100)
        XCTAssertEqual(try repo.load(other.id).displayTitle, other.displayTitle)
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(try encoded(snapshot.manifests), try encoded(repo.list()))
        XCTAssertEqual(try encoded(Disk.read([Manifest].self, at: root.appendingPathComponent("index.json"))), try encoded(snapshot.manifests))
    }
}
