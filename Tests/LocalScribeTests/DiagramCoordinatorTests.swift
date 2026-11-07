import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import XCTest
@testable import LocalScribeCore

final class DiagramCoordinatorTests: XCTestCase {
    private func makeRepository() throws -> DiagramRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try DiagramRepository(root: root)
    }

    @discardableResult
    private func pngSource(name: String = "схема.png") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Disk.directory(directory)
        guard let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                      bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw ScribeError.message("Тестовое изображение") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { throw ScribeError.message("Тестовое изображение") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScribeError.message("Тестовое изображение") }
        try (output as Data).write(to: directory.appendingPathComponent(name))
        return directory.appendingPathComponent(name)
    }

    private func profile() -> ModelProfile {
        ModelProfile(id: "qwen2.5-vl-7b", repository: "org/diagram", revision: "rev1", license: "apache-2.0",
                     files: [ModelFile(path: "m.bin", localPath: "m.bin", size: 10, sha256: "00")], role: .diagram)
    }

    @discardableResult
    private func seed(_ repo: DiagramRepository, date: Double, state: DiagramState = .completed) throws -> DiagramManifest {
        var manifest = DiagramManifest(title: "item", filename: "pic.png", ext: "png", uti: "public.png")
        manifest.createdAt = Date(timeIntervalSince1970: date)
        manifest.state = state
        manifest.byteSize = 1; manifest.pixelWidth = 1; manifest.pixelHeight = 1; manifest.sha256 = "00"
        try Disk.directory(repo.folder(manifest.id))
        try Data("png".utf8).write(to: repo.originalURL(manifest))
        try repo.save(manifest)
        return manifest
    }

    private func resultData(fingerprint: String) throws -> Data {
        try JSONEncoder().encode(DiagramResult(fingerprint: fingerprint,
                                               nodes: [DiagramNode(id: "a", label: "Узел A")], edges: []))
    }

    private func runFingerprint(_ repo: DiagramRepository, _ id: String, _ runId: String) throws -> String {
        try Disk.read(DiagramRunInfo.self, at: repo.run(id, runId).appendingPathComponent("run.json")).fingerprint
    }

    private func create(_ archive: DiagramCoordinator, _ name: String) async throws -> RecordingGroup {
        try await archive.editGroups { try $0.create(name: name) }
        return await archive.snapshot().groups.defaultGroup
    }

    // MARK: - Groups

    func testImportReservesGroupAndVanishedDestinationFallsBackToUngrouped() async throws {
        let repo = try makeRepository()
        let archive = DiagramCoordinator(repository: repo)
        let group = try await create(archive, "Проекты")
        let source = try pngSource()
        let manifest = try await archive.importImage(source, groupID: group.id)
        var catalog = try RecordingGroups.loadCatalog(at: repo.groupsURL)
        XCTAssertEqual(catalog.groupID(for: manifest.id), group.id)
        // Deleting a user group moves its diagrams to «Без темы» and keeps artifacts.
        try await archive.editGroups { try $0.remove(group.id) }
        catalog = try RecordingGroups.loadCatalog(at: repo.groupsURL)
        XCTAssertEqual(catalog.groupID(for: manifest.id), RecordingGroup.ungroupedID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.originalURL(manifest).path))
        // A destination that no longer exists resolves to the system group.
        let second = try await archive.importImage(try pngSource(), groupID: group.id)
        XCTAssertEqual(try RecordingGroups.loadCatalog(at: repo.groupsURL).groupID(for: second.id), RecordingGroup.ungroupedID)
    }

    func testDiagramGroupsAreIsolatedFromRecordingGroups() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let audioRepo = try RecordingRepository(root: base.appendingPathComponent("audio"))
        let diagramRepo = try makeRepository()
        let audio = RecordingCoordinator(repository: audioRepo)
        let diagrams = DiagramCoordinator(repository: diagramRepo)
        try await audio.editGroups { try $0.create(name: "Аудио") }
        _ = try await create(diagrams, "Схемы")
        let audioGroups = try audioRepo.loadGroups()
        let diagramGroups = try RecordingGroups.loadCatalog(at: diagramRepo.groupsURL)
        XCTAssertTrue(audioGroups.groups.contains { $0.name == "Аудио" })
        XCTAssertFalse(audioGroups.groups.contains { $0.name == "Схемы" })
        XCTAssertTrue(diagramGroups.groups.contains { $0.name == "Схемы" })
        XCTAssertFalse(diagramGroups.groups.contains { $0.name == "Аудио" })
    }

    func testSnapshotOrderAndMonotonicRevision() async throws {
        let repo = try makeRepository()
        let old = try seed(repo, date: 1)
        let newer = try seed(repo, date: 9)
        let sameDate = try seed(repo, date: 9)
        let archive = DiagramCoordinator(repository: repo)
        let expected = [newer.id, sameDate.id].sorted() + [old.id]
        var snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.manifests.map(\.id), expected)
        _ = try await archive.editGroups { try $0.create(name: "G") }
        try await archive.rename(old.id, title: "Переименовано")
        snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.revision, 3)
        // A no-op edit neither writes the catalog nor bumps the revision.
        let catalogBefore = try Data(contentsOf: repo.groupsURL)
        try await archive.editGroups { $0.setAllExpanded(true) }
        snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.revision, 3)
        XCTAssertEqual(try Data(contentsOf: repo.groupsURL), catalogBefore)
        XCTAssertEqual(try repo.load(old.id).displayTitle, "Переименовано")
    }

    func testBatchMoveValidatesAllMembersBeforeSingleSave() async throws {
        let repo = try makeRepository()
        let archive = DiagramCoordinator(repository: repo)
        let a = try seed(repo, date: 1)
        let b = try seed(repo, date: 2)
        let target = try await create(archive, "Цель")
        let before = await archive.snapshot()
        do {
            try await archive.moveDiagrams([a.id, b.id, UUID().uuidString], to: target.id)
            XCTFail("Missing member must reject the entire move")
        } catch {}
        let failed = await archive.snapshot()
        XCTAssertEqual(failed.groups, before.groups)
        XCTAssertEqual(failed.revision, before.revision)
        try await archive.moveDiagrams([a.id, b.id], to: target.id)
        let moved = await archive.snapshot()
        XCTAssertEqual(moved.revision, before.revision + 1)
        let catalog = try RecordingGroups.loadCatalog(at: repo.groupsURL)
        XCTAssertEqual(catalog.groupID(for: a.id), target.id)
        XCTAssertEqual(catalog.groupID(for: b.id), target.id)
    }

    func testCorruptGroupsCatalogBlocksEditsImportAndIsNeverOverwritten() async throws {
        let repo = try makeRepository()
        let broken = Data("broken groups".utf8)
        try broken.write(to: repo.groupsURL)
        let archive = DiagramCoordinator(repository: repo)
        let snapshot = await archive.snapshot()
        XCTAssertNotNil(snapshot.groupsError)
        do { try await archive.editGroups { try $0.create(name: "A") }; XCTFail() } catch {}
        do { _ = try await archive.importImage(try pngSource()); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: repo.groupsURL), broken)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.itemsURL.path), [])
        _ = try await archive.recover()
        XCTAssertEqual(try Data(contentsOf: repo.groupsURL), broken)
    }

    func testRecoverInterruptsRunsAndPrunesOnlyConfirmedMissingMembership() async throws {
        let repo = try makeRepository()
        let archive = DiagramCoordinator(repository: repo)
        let group = try await create(archive, "Группа")
        let queued = try seed(repo, date: 1, state: .queued)
        let damaged = try seed(repo, date: 2)
        let removed = try seed(repo, date: 3)
        try await archive.moveDiagrams([queued.id, damaged.id, removed.id], to: group.id)
        try repo.delete(removed.id)
        try Data("broken".utf8).write(to: repo.folder(damaged.id).appendingPathComponent("manifest.json"))
        let snapshot = try await archive.recover()
        XCTAssertEqual(try repo.load(queued.id).state, .interrupted)
        XCTAssertEqual(snapshot.unreadableDiagramIDs, [damaged.id])
        let catalog = try RecordingGroups.loadCatalog(at: repo.groupsURL)
        XCTAssertNil(catalog.membership[removed.id])
        // Damaged archive entries keep their assignment.
        XCTAssertEqual(catalog.groupID(for: damaged.id), group.id)
    }

    // MARK: - Runs

    func testCompleteRunSwitchesActiveOnlyAfterValidatedResult() async throws {
        let repo = try makeRepository()
        let archive = DiagramCoordinator(repository: repo)
        let manifest = try await archive.importImage(try pngSource())
        _ = try await archive.beginRun(manifest.id, profile: profile())
        let first = try repo.load(manifest.id).pendingRunId!
        // No published result yet: the manifest must stay untouched.
        do { _ = try await archive.completeRun(manifest.id, runId: first); XCTFail() } catch {}
        var current = try repo.load(manifest.id)
        XCTAssertEqual(current.state, .queued)
        XCTAssertNil(current.activeRunId)
        XCTAssertEqual(current.pendingRunId, first)
        try repo.publishResult(manifest.id, runId: first, data: try resultData(fingerprint: runFingerprint(repo, manifest.id, first)))
        _ = try await archive.completeRun(manifest.id, runId: first)
        current = try repo.load(manifest.id)
        XCTAssertEqual(current.activeRunId, first)
        XCTAssertNil(current.pendingRunId)
        XCTAssertEqual(current.state, .completed)
        // A retry keeps the previous result until the new run validates.
        _ = try await archive.beginRun(manifest.id, profile: profile())
        let second = try repo.load(manifest.id).pendingRunId!
        try repo.publishResult(manifest.id, runId: second, data: try resultData(fingerprint: "несовпадающий"))
        do { _ = try await archive.completeRun(manifest.id, runId: second, warnings: []); XCTFail() } catch {}
        current = try repo.load(manifest.id)
        XCTAssertEqual(current.activeRunId, first)
        XCTAssertEqual(current.pendingRunId, second)
        // beginRun legitimately queued the retry; only the active result is preserved.
        XCTAssertEqual(current.state, .queued)
        // A stale worker event cannot replace a newer job.
        do { _ = try await archive.completeRun(manifest.id, runId: first); XCTFail() } catch {}
        try repo.publishResult(manifest.id, runId: second, data: try resultData(fingerprint: runFingerprint(repo, manifest.id, second)))
        _ = try await archive.completeRun(manifest.id, runId: second, warnings: ["неточная подпись"])
        current = try repo.load(manifest.id)
        XCTAssertEqual(current.activeRunId, second)
        XCTAssertEqual(current.state, .completedWithWarnings)
        XCTAssertEqual(current.warnings, ["неточная подпись"])
    }

    func testFailRunKeepsActiveResultAndCancelKeepsPendingRun() async throws {
        let repo = try makeRepository()
        let archive = DiagramCoordinator(repository: repo)
        let manifest = try await archive.importImage(try pngSource())
        _ = try await archive.beginRun(manifest.id, profile: profile())
        let first = try repo.load(manifest.id).pendingRunId!
        try repo.publishResult(manifest.id, runId: first, data: try resultData(fingerprint: runFingerprint(repo, manifest.id, first)))
        _ = try await archive.completeRun(manifest.id, runId: first)
        // Failed retry: previous result survives, both runs stay referenceable.
        _ = try await archive.beginRun(manifest.id, profile: profile())
        var current = try repo.load(manifest.id)
        let second = current.pendingRunId!
        _ = try await archive.failRun(manifest.id, message: "модель недоступна")
        current = try repo.load(manifest.id)
        XCTAssertEqual(current.state, .failed)
        XCTAssertEqual(current.lastError, "модель недоступна")
        XCTAssertEqual(current.activeRunId, first)
        XCTAssertEqual(current.pendingRunId, second)
        XCTAssertEqual(try repo.results(manifest.id, runId: first).nodes.count, 1)
        // Cancellation keeps the pending run; a retry creates a new one.
        _ = try await archive.cancel(manifest.id)
        current = try repo.load(manifest.id)
        XCTAssertEqual(current.state, .cancelled)
        XCTAssertEqual(current.pendingRunId, second)
        _ = try await archive.beginRun(manifest.id, profile: profile())
        current = try repo.load(manifest.id)
        XCTAssertEqual(current.activeRunId, first)
        XCTAssertNotEqual(current.pendingRunId, second)
    }

    func testUpdateRenameAndResumeRunThroughCoordinator() async throws {
        let repo = try makeRepository()
        let archive = DiagramCoordinator(repository: repo)
        let manifest = try await archive.importImage(try pngSource())
        try await archive.update(manifest.id) { $0.state = .waitingForModels }
        XCTAssertEqual(try repo.load(manifest.id).state, .waitingForModels)
        do { try await archive.update(manifest.id) { $0.id = UUID().uuidString }; XCTFail() } catch {}
        do { try await archive.rename(manifest.id, title: "  "); XCTFail() } catch {}
        try await archive.rename(manifest.id, title: " Блок-схема ")
        XCTAssertEqual(try repo.load(manifest.id).displayTitle, "Блок-схема")
        _ = try await archive.beginRun(manifest.id, profile: profile())
        let pending = try repo.load(manifest.id).pendingRunId!
        let resumed = try await archive.resumeRun(manifest.id)
        XCTAssertEqual(resumed.id, pending)
        var old = resumed
        old.promptVersion = "old-prompt"
        try Disk.write(old, to: repo.run(manifest.id, pending).appendingPathComponent("run.json"))
        do { _ = try await archive.resumeRun(manifest.id); XCTFail() } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.run(manifest.id, pending).appendingPathComponent("run.json").path))
    }

    func testDeletePublishesActuallyRemainingArchive() async throws {
        let repo = try makeRepository()
        let fail = Mutex<String?>(nil)
        let archive = DiagramCoordinator(repository: repo, removeItem: { repository, id in
            if id == fail.withLock({ $0 }) { throw ScribeError.message("test deletion failure") }
            try repository.delete(id)
        })
        let a = try seed(repo, date: 3)
        let b = try seed(repo, date: 2)
        let c = try seed(repo, date: 1)
        fail.withLock { $0 = c.id }
        do { try await archive.delete([c.id]); XCTFail() } catch {}
        var snapshot = await archive.snapshot()
        XCTAssertEqual(Set(snapshot.manifests.map(\.id)), Set([a.id, b.id, c.id]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.folder(c.id).path))
        fail.withLock { $0 = nil }
        try await archive.delete([a.id])
        snapshot = await archive.snapshot()
        XCTAssertEqual(Set(snapshot.manifests.map(\.id)), Set([b.id, c.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.folder(a.id).path))
        try await archive.delete([c.id])
        snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.manifests.map(\.id), [b.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.folder(c.id).path))
    }

    func testImportFailureLeavesNoItemAndGroupsUntouched() async throws {
        let repo = try makeRepository()
        let archive = DiagramCoordinator(repository: repo)
        let group = try await create(archive, "Проекты")
        let catalogBefore = try Data(contentsOf: repo.groupsURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Disk.directory(directory)
        let source = directory.appendingPathComponent("fake.png")
        try Data("not a real image".utf8).write(to: source)
        do { _ = try await archive.importImage(source, groupID: group.id); XCTFail() } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.itemsURL.path), [])
        XCTAssertEqual(try Data(contentsOf: repo.groupsURL), catalogBefore)
        XCTAssertEqual(try Data(contentsOf: source), Data("not a real image".utf8))
    }
}
