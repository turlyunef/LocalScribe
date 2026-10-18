import Foundation
import Synchronization
import XCTest
@testable import LocalScribeCore
@testable import LocalScribe

@MainActor
final class ArchiveResponsivenessTests: XCTestCase {
    private struct IOCounts: Sendable {
        var reads = 0, scans = 0, writes = 0, indexWrites = 0, mainThreadOperations = 0
    }
    func testRecoveryAndSnapshotReloadOf1000RecordingsKeepMainActorResponsive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var repo = try RecordingRepository(root: root)
        for number in 0..<1000 {
            var m = Manifest(sourceType: "import", title: "Recording \(number)", filename: "a.wav")
            m.state = .transcribing
            try repo.save(m)
        }
        let counts = Mutex(IOCounts())
        repo.observeIO = { operation in
            counts.withLock { value in
                if Thread.isMainThread { value.mainThreadOperations += 1 }
                switch operation {
                case .manifestRead: value.reads += 1
                case .manifestWrite: value.writes += 1
                case .archiveScan: value.scans += 1
                case .indexWrite: value.indexWrites += 1
                }
            }
        }
        var ticks = 0, maxGap = Duration.zero
        let ticker = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
                let now = ContinuousClock.now
                maxGap = max(maxGap, previous.duration(to: now)); previous = now; ticks += 1
            }
        }
        await Task.yield()
        let start = ContinuousClock.now
        let model = AppModel(repository: repo, catalog: ModelCatalog(models: []))
        while model.preparingStorage { try await Task.sleep(for: .milliseconds(1)) }
        let recoveryTime = start.duration(to: .now)
        XCTAssertEqual(model.recordings.count, 1000)
        XCTAssertTrue(model.recordings.allSatisfy { $0.state == .interrupted })
        let beforeReloads = counts.withLock { $0 }
        XCTAssertEqual(beforeReloads.reads, 1000)
        XCTAssertEqual(beforeReloads.scans, 1)
        XCTAssertEqual(beforeReloads.writes, 1000)
        XCTAssertEqual(beforeReloads.indexWrites, 1)
        let reloadStart = ContinuousClock.now
        for _ in 0..<100 { await model.reload() }
        let reloadTime = reloadStart.duration(to: .now)
        XCTAssertEqual(counts.withLock { $0.reads }, beforeReloads.reads)
        XCTAssertEqual(counts.withLock { $0.scans }, beforeReloads.scans)
        let archive = try XCTUnwrap(model.archive)
        let changedID = try XCTUnwrap(model.recordings.first?.id)
        let changesStart = ContinuousClock.now
        for number in 0..<100 {
            try await archive.update(changedID) { $0.warnings.append("Warning \(number)") }
            await model.reload()
        }
        let changesTime = changesStart.duration(to: .now)
        XCTAssertEqual(counts.withLock { $0.reads }, 1100)
        XCTAssertEqual(counts.withLock { $0.writes }, 1100)
        XCTAssertEqual(counts.withLock { $0.scans }, 1)
        XCTAssertEqual(model.recordings.first { $0.id == changedID }?.warnings.count, 100)
        XCTAssertEqual(counts.withLock { $0.mainThreadOperations }, 0)
        XCTAssertGreaterThan(ticks, 0)
        print("R12 UI n=1000: recovery=\(recoveryTime), 100 reloads=\(reloadTime), 100 changes+reloads=\(changesTime), MainActor max gap=\(maxGap), ticks=\(ticks)")
        ticker.cancel(); await ticker.value
        await model.shutdown()
    }
}
