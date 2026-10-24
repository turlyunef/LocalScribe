import Foundation
import Synchronization
import XCTest
@testable import LocalScribeCore

final class RecordingGroupsTests: XCTestCase {
    private func fixture() throws -> RecordingRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try RecordingRepository(root: root)
    }
    private func recording(_ repo: RecordingRepository, date: Double = 1) throws -> Manifest {
        var m = Manifest(sourceType: "import", title: "Meeting", filename: "original.wav")
        m.createdAt = Date(timeIntervalSince1970: date); m.sourceComplete = true
        m.activeRunId = UUID().uuidString; m.pendingRunId = UUID().uuidString
        try Disk.directory(repo.folder(m.id).appendingPathComponent("source"))
        try Data("original".utf8).write(to: repo.folder(m.id).appendingPathComponent(m.originalRelativePath))
        try Disk.directory(repo.run(m.id, m.activeRunId!))
        try Data("result".utf8).write(to: repo.run(m.id, m.activeRunId!).appendingPathComponent("result.txt"))
        try repo.save(m)
        return m
    }
    private func create(_ archive: RecordingCoordinator, _ name: String) async throws -> RecordingGroup {
        try await archive.editGroups { try $0.create(name: name) }
        return await archive.snapshot().groups.defaultGroup
    }

    func testRecoveryPrunesDeletedMembershipButPreservesDamagedArchiveAndGroupSettings() async throws {
        let repo = try fixture(), removed = try recording(repo), damaged = try recording(repo), healthy = try recording(repo)
        let archive = RecordingCoordinator(repository: repo)
        let group = try await create(archive, "Keep group")
        try await archive.moveRecordings([removed.id, damaged.id, healthy.id], to: group.id)
        try await archive.editGroups { try $0.setExpanded(group.id, false) }
        try await archive.delete(removed)
        let damagedFile = repo.folder(damaged.id).appendingPathComponent("manifest.json")
        let corrupt = Data("broken".utf8); try corrupt.write(to: damagedFile)
        let orphan = UUID().uuidString
        var saved = try repo.loadGroups(); try saved.assign(orphan, to: group.id); try repo.saveGroups(saved)
        let reopened = RecordingCoordinator(repository: repo)
        let snapshot = try await reopened.recover()
        XCTAssertNil(snapshot.groups.membership[removed.id])
        XCTAssertNil(snapshot.groups.membership[orphan])
        XCTAssertEqual(snapshot.groups.membership[damaged.id], group.id)
        XCTAssertEqual(snapshot.groups.membership[healthy.id], group.id)
        XCTAssertEqual(snapshot.groups.defaultID, group.id)
        XCTAssertEqual(snapshot.groups.groups.first?.expanded, false)
        XCTAssertEqual(try repo.loadGroups(), snapshot.groups)
        XCTAssertEqual(try Data(contentsOf: damagedFile), corrupt)
        let before = try Data(contentsOf: repo.root.appendingPathComponent("groups.json"))
        _ = try await reopened.recover()
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("groups.json")), before)
    }

    func testBatchMoveValidatesAllMembersBeforePublishingAndPreservesManifests() async throws {
        let repo = try fixture(), a = try recording(repo), b = try recording(repo)
        let archive = RecordingCoordinator(repository: repo)
        let source = try await create(archive, "Source"), target = try await create(archive, "Target")
        try await archive.moveRecording(a.id, to: source.id)
        let before = await archive.snapshot()
        do {
            try await archive.moveRecordings([a.id, b.id, UUID().uuidString], to: target.id)
            XCTFail("Missing member must reject the entire move")
        } catch {}
        let failed = await archive.snapshot()
        XCTAssertEqual(failed.groups, before.groups)
        XCTAssertEqual(failed.revision, before.revision)
        try await archive.moveRecordings([a.id, b.id], to: target.id)
        let moved = await archive.snapshot()
        XCTAssertEqual(moved.revision, before.revision + 1)
        XCTAssertEqual(try repo.loadGroups().groupID(for: a.id), target.id)
        XCTAssertEqual(try repo.loadGroups().groupID(for: b.id), target.id)
        XCTAssertEqual(try repo.load(a.id).activeRunId, a.activeRunId)
        XCTAssertEqual(try repo.load(b.id).pendingRunId, b.pendingRunId)
    }

    func testLegacyArchiveUsesSystemGroupWithoutChangingFilesOrManifests() async throws {
        let repo = try fixture(), m = try recording(repo)
        let path = repo.folder(m.id).appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: path)
        try Data("invalid".utf8).write(to: repo.root.appendingPathComponent("index.json"))
        let archive = RecordingCoordinator(repository: repo)
        let snapshot = await archive.snapshot()
        XCTAssertNil(snapshot.groupsError)
        XCTAssertEqual(snapshot.groups.groups.map(\.name), ["Без темы"])
        XCTAssertEqual(snapshot.groups.defaultID, RecordingGroup.ungroupedID)
        XCTAssertEqual(snapshot.groups.groupID(for: m.id), RecordingGroup.ungroupedID)
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.folder(m.id).appendingPathComponent(m.originalRelativePath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("groups.json").path))
    }

    func testNamesOrderingExpansionDefaultAndMembershipSurviveRestartWithoutIndex() async throws {
        let repo = try fixture(), m = try recording(repo)
        let archive = RecordingCoordinator(repository: repo)
        let a = try await create(archive, "  Работа \n"), b = try await create(archive, "Учёба")
        try await archive.moveRecording(m.id, to: a.id)
        try await archive.editGroups { groups in
            try groups.rename(a.id, name: "Рабочие встречи")
            try groups.setExpanded(a.id, false)
            try groups.move(a.id, before: b.id)
        }
        await archive.flushIndex()
        try? FileManager.default.removeItem(at: repo.root.appendingPathComponent("index.json"))
        let reopened = await RecordingCoordinator(repository: repo).snapshot()
        XCTAssertEqual(reopened.groups.groups.map(\.id), [a.id, b.id, RecordingGroup.ungroupedID])
        XCTAssertEqual(reopened.groups.groups.first?.name, "Рабочие встречи")
        XCTAssertEqual(reopened.groups.groups.first?.expanded, false)
        XCTAssertEqual(reopened.groups.defaultID, b.id)
        XCTAssertEqual(reopened.groups.groupID(for: m.id), a.id)
        XCTAssertEqual(try repo.load(m.id).activeRunId, m.activeRunId)
    }

    func testBulkExpansionPersistsMixedGroupsAndRepeatedActionIsNoOp() async throws {
        let repo = try fixture(), m = try recording(repo)
        let archive = RecordingCoordinator(repository: repo)
        let a = try await create(archive, "A"), b = try await create(archive, "B")
        try await archive.moveRecording(m.id, to: a.id)
        let manifestURL = repo.folder(m.id).appendingPathComponent("manifest.json")
        let manifestBefore = try Data(contentsOf: manifestURL)
        for expanded in [false, true] {
            try await archive.editGroups { groups in
                try groups.setExpanded(a.id, expanded)
                try groups.setExpanded(b.id, !expanded)
                try groups.setExpanded(RecordingGroup.ungroupedID, !expanded)
            }
            let before = await archive.snapshot()
            try await archive.editGroups { $0.setAllExpanded(expanded) }
            let after = await archive.snapshot()
            XCTAssertEqual(after.revision, before.revision + 1)
            XCTAssertTrue(after.groups.groups.allSatisfy { $0.expanded == expanded })
            XCTAssertEqual(after.groups.groups.map(\.id), before.groups.groups.map(\.id))
            XCTAssertEqual(after.groups.groups.map(\.name), before.groups.groups.map(\.name))
            XCTAssertEqual(after.groups.defaultID, before.groups.defaultID)
            XCTAssertEqual(after.groups.membership, before.groups.membership)
            let reopened = await RecordingCoordinator(repository: repo).snapshot()
            XCTAssertEqual(reopened.groups, after.groups)
            try await archive.editGroups { $0.setAllExpanded(expanded) }
            let repeated = await archive.snapshot()
            XCTAssertEqual(repeated.revision, after.revision)
            XCTAssertEqual(repeated.groups, after.groups)
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
    }

    func testBulkExpansionWorksWithOnlySystemGroup() async throws {
        let repo = try fixture()
        let archive = RecordingCoordinator(repository: repo)
        for expanded in [false, true] {
            try await archive.editGroups { $0.setAllExpanded(expanded) }
            let groups = try repo.loadGroups()
            XCTAssertEqual(groups.groups.map(\.id), [RecordingGroup.ungroupedID])
            XCTAssertEqual(groups.groups.first?.expanded, expanded)
        }
    }

    func testBulkExpansionWriteFailureDoesNotPublishPartialChanges() async throws {
        let repo = try fixture()
        let archive = RecordingCoordinator(repository: repo)
        let a = try await create(archive, "A")
        try await archive.editGroups { try $0.setExpanded(a.id, false) }
        let before = await archive.snapshot()
        let path = repo.root.appendingPathComponent("groups.json")
        try FileManager.default.removeItem(at: path)
        try Disk.directory(path)
        for expanded in [false, true] {
            do {
                try await archive.editGroups { $0.setAllExpanded(expanded) }
                XCTFail("Saving to a directory must fail")
            } catch {}
            let after = await archive.snapshot()
            XCTAssertEqual(after.groups, before.groups)
            XCTAssertEqual(after.revision, before.revision)
        }
    }

    func testInvalidNamesAndSystemOperationsAreRejectedWithoutChangingDefault() throws {
        var groups = RecordingGroups()
        let a = try groups.create(name: "Работа")
        let baseline = groups
        for name in ["", " \n ", " работа ", "БЕЗ ТЕМЫ"] {
            XCTAssertThrowsError(try groups.create(name: name))
            XCTAssertEqual(groups, baseline)
        }
        XCTAssertThrowsError(try groups.rename(a.id, name: "Без темы"))
        XCTAssertThrowsError(try groups.rename(RecordingGroup.ungroupedID, name: "Другое"))
        XCTAssertThrowsError(try groups.remove(RecordingGroup.ungroupedID))
        XCTAssertThrowsError(try groups.move(RecordingGroup.ungroupedID, before: a.id))
        XCTAssertEqual(groups, baseline)
        try groups.rename(a.id, name: "РАБОТА")
        XCTAssertEqual(groups.defaultID, a.id)
        try groups.setDefault(RecordingGroup.ungroupedID)
        XCTAssertEqual(groups.defaultID, RecordingGroup.ungroupedID)
    }

    func testMoveOnlyChangesMembershipAndSameGroupIsNoOp() async throws {
        let repo = try fixture(), m = try recording(repo)
        let manifestURL = repo.folder(m.id).appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestURL)
        let archive = RecordingCoordinator(repository: repo)
        let a = try await create(archive, "A"), b = try await create(archive, "B")
        try await archive.editGroups { try $0.setExpanded(b.id, false) }
        try await archive.moveRecording(m.id, to: a.id)
        let before = await archive.snapshot()
        try await archive.moveRecording(m.id, to: a.id)
        let unchanged = await archive.snapshot()
        XCTAssertEqual(before.revision, unchanged.revision)
        try await archive.moveRecording(m.id, to: b.id)
        let after = await archive.snapshot()
        XCTAssertEqual(after.groups.groups, before.groups.groups)
        XCTAssertEqual(after.groups.defaultID, before.groups.defaultID)
        XCTAssertEqual(after.groups.groupID(for: m.id), b.id)
        XCTAssertEqual(try Data(contentsOf: manifestURL), original)
    }

    func testWriteFailureDoesNotPublishCreateRenameMoveOrDefault() async throws {
        let repo = try fixture(), m = try recording(repo)
        let archive = RecordingCoordinator(repository: repo)
        let a = try await create(archive, "A")
        let before = await archive.snapshot()
        let path = repo.root.appendingPathComponent("groups.json")
        try FileManager.default.removeItem(at: path)
        try Disk.directory(path)
        do { try await archive.editGroups { try $0.create(name: "B") }; XCTFail() } catch {}
        do { try await archive.editGroups { try $0.rename(a.id, name: "C") }; XCTFail() } catch {}
        do { try await archive.editGroups { try $0.setDefault(RecordingGroup.ungroupedID) }; XCTFail() } catch {}
        do { try await archive.moveRecording(m.id, to: a.id); XCTFail() } catch {}
        let after = await archive.snapshot()
        XCTAssertEqual(after.groups, before.groups)
        XCTAssertEqual(after.revision, before.revision)
    }

    func testCorruptCatalogIsReportedAndNeverOverwritten() async throws {
        let repo = try fixture()
        let path = repo.root.appendingPathComponent("groups.json"), broken = Data("broken groups".utf8)
        try broken.write(to: path)
        let archive = RecordingCoordinator(repository: repo)
        let snapshot = await archive.snapshot()
        XCTAssertNotNil(snapshot.groupsError)
        do { try await archive.editGroups { try $0.create(name: "A") }; XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: path), broken)
        var invalid = RecordingGroups(); invalid.schemaVersion = 999
        try Disk.write(invalid, to: path)
        XCTAssertThrowsError(try repo.loadGroups())
    }

    func testDeleteOnlyGroupAtomicallyMovesMembersAndRetainsTheirData() async throws {
        let repo = try fixture(), m = try recording(repo)
        let archive = RecordingCoordinator(repository: repo)
        let a = try await create(archive, "A"), b = try await create(archive, "B")
        try await archive.moveRecording(m.id, to: a.id)
        let before = try Data(contentsOf: repo.folder(m.id).appendingPathComponent("manifest.json"))
        _ = try await archive.prepareGroupDeletion(a.id)
        try await archive.finishGroupDeletion(a.id, deleteRecordings: false)
        let after = await archive.snapshot()
        XCTAssertEqual(after.groups.defaultID, b.id)
        XCTAssertEqual(after.groups.groupID(for: m.id), RecordingGroup.ungroupedID)
        XCTAssertEqual(try Data(contentsOf: repo.folder(m.id).appendingPathComponent("manifest.json")), before)
        _ = try await archive.prepareGroupDeletion(b.id)
        try await archive.finishGroupDeletion(b.id, deleteRecordings: false)
        XCTAssertEqual(try repo.loadGroups().defaultID, RecordingGroup.ungroupedID)
    }

    func testDeletionLeaseRejectsMovesAndCancellationLeavesGroupIntact() async throws {
        let repo = try fixture(), m = try recording(repo)
        let archive = RecordingCoordinator(repository: repo)
        let a = try await create(archive, "A")
        try await archive.moveRecording(m.id, to: a.id)
        let before = await archive.snapshot()
        let members = try await archive.prepareGroupDeletion(a.id)
        XCTAssertEqual(members, [m.id])
        do { try await archive.moveRecording(m.id, to: RecordingGroup.ungroupedID); XCTFail() } catch {}
        await archive.cancelGroupDeletion(a.id)
        let after = await archive.snapshot()
        XCTAssertEqual(after.groups, before.groups)
        XCTAssertEqual(after.revision, before.revision)
    }

    func testPartialDeletionPublishesProgressAndPreservesRemainingGroupAndExternalFiles() async throws {
        let repo = try fixture(), first = try recording(repo, date: 3), second = try recording(repo, date: 2), other = try recording(repo, date: 1)
        let external = repo.root.appendingPathComponent("external.wav"), exported = repo.root.appendingPathComponent("export.txt")
        try Data("external".utf8).write(to: external); try Data("export".utf8).write(to: exported)
        let fail = Mutex(true)
        let archive = RecordingCoordinator(repository: repo, removeRecording: { repository, manifest in
            if manifest.id == second.id && fail.withLock({ $0 }) { throw ScribeError.message("test deletion failure") }
            try repository.delete(manifest)
        })
        let a = try await create(archive, "A")
        for id in [first.id, second.id] { try await archive.moveRecording(id, to: a.id) }
        _ = try await archive.prepareGroupDeletion(a.id)
        do { try await archive.finishGroupDeletion(a.id, deleteRecordings: true); XCTFail() } catch {}
        let partial = await archive.snapshot()
        XCTAssertEqual(Set(partial.manifests.map(\.id)), Set([second.id, other.id]))
        XCTAssertTrue(partial.groups.groups.contains { $0.id == a.id })
        XCTAssertEqual(partial.groups.defaultID, a.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.folder(first.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.run(second.id, second.activeRunId!).path))
        let restart = await RecordingCoordinator(repository: repo).snapshot()
        XCTAssertEqual(Set(restart.manifests.map(\.id)), Set([second.id, other.id]))
        fail.withLock { $0 = false }
        _ = try await archive.prepareGroupDeletion(a.id)
        try await archive.finishGroupDeletion(a.id, deleteRecordings: true)
        XCTAssertEqual(try repo.loadGroups().defaultID, RecordingGroup.ungroupedID)
        XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
        XCTAssertEqual(try Data(contentsOf: exported), Data("export".utf8))
        XCTAssertNotNil(try repo.load(other.id))
    }

    func testNewRecordingUsesFrozenDestinationAndDeletedDestinationFallsBackToSystem() async throws {
        let repo = try fixture(), archive = RecordingCoordinator(repository: repo)
        let a = try await create(archive, "A")
        _ = try await create(archive, "B")
        let first = Manifest(sourceType: "microphone", title: "first", filename: "original.caf")
        try await archive.createRecording(first, groupID: a.id)
        XCTAssertEqual(try repo.loadGroups().groupID(for: first.id), a.id)
        _ = try await archive.prepareGroupDeletion(a.id)
        try await archive.finishGroupDeletion(a.id, deleteRecordings: false)
        let second = Manifest(sourceType: "microphone", title: "second", filename: "original.caf")
        try await archive.createRecording(second, groupID: a.id)
        XCTAssertEqual(try repo.loadGroups().groupID(for: second.id), RecordingGroup.ungroupedID)
    }
    func testImportFailureToSaveDestinationDoesNotPublishUngroupedRecording() async throws {
        let repo = try fixture()
        let archive = RecordingCoordinator(repository: repo, importProbe: { _, _ in
            AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le")
        })
        let a = try await create(archive, "A")
        let source = repo.root.appendingPathComponent("outside.wav")
        try Data("audio".utf8).write(to: source)
        let path = repo.root.appendingPathComponent("groups.json")
        try FileManager.default.removeItem(at: path); try Disk.directory(path)
        do { _ = try await archive.importFile(source, tools: repo.root, groupID: a.id); XCTFail() } catch {}
        let snapshot = await archive.snapshot()
        XCTAssertTrue(snapshot.manifests.isEmpty)
        XCTAssertTrue(repo.list().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.root.appendingPathComponent("recordings").path), [])
        XCTAssertEqual(try Data(contentsOf: source), Data("audio".utf8))
        XCTAssertEqual(snapshot.groups.defaultID, a.id)
    }

    func testGroupMetadataFailureAfterDeletionKeepsEmptyGroupWithoutRestoringRows() async throws {
        let repo = try fixture(), m = try recording(repo)
        let archive = RecordingCoordinator(repository: repo)
        let a = try await create(archive, "A")
        try await archive.moveRecording(m.id, to: a.id)
        _ = try await archive.prepareGroupDeletion(a.id)
        let path = repo.root.appendingPathComponent("groups.json")
        try FileManager.default.removeItem(at: path); try Disk.directory(path)
        do { try await archive.finishGroupDeletion(a.id, deleteRecordings: true); XCTFail() } catch {}
        let snapshot = await archive.snapshot()
        XCTAssertTrue(snapshot.manifests.isEmpty)
        XCTAssertTrue(snapshot.groups.groups.contains { $0.id == a.id })
        XCTAssertEqual(snapshot.groups.defaultID, a.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.folder(m.id).path))
    }

    func testDeletionErrorAfterRemovingDirectoryReconcilesSnapshot() async throws {
        let repo = try fixture(), m = try recording(repo)
        let archive = RecordingCoordinator(repository: repo, removeRecording: { repository, manifest in
            try repository.delete(manifest)
            throw ScribeError.message("Failure after removal")
        })
        let a = try await create(archive, "A")
        try await archive.moveRecording(m.id, to: a.id)
        _ = try await archive.prepareGroupDeletion(a.id)
        do { try await archive.finishGroupDeletion(a.id, deleteRecordings: true); XCTFail() } catch {}
        let snapshot = await archive.snapshot()
        XCTAssertTrue(snapshot.manifests.isEmpty)
        XCTAssertTrue(snapshot.groups.groups.contains { $0.id == a.id })
    }

    func testCorruptMemberIsNotSilentlyDroppedWithItsGroup() async throws {
        let repo = try fixture(), m = try recording(repo)
        let archive = RecordingCoordinator(repository: repo)
        let a = try await create(archive, "A")
        try await archive.moveRecording(m.id, to: a.id)
        try Data("broken manifest".utf8).write(to: repo.folder(m.id).appendingPathComponent("manifest.json"))
        let reopened = RecordingCoordinator(repository: repo)
        _ = try await reopened.prepareGroupDeletion(a.id)
        do { try await reopened.finishGroupDeletion(a.id, deleteRecordings: true); XCTFail() } catch {}
        XCTAssertTrue(try repo.loadGroups().groups.contains { $0.id == a.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.folder(m.id).appendingPathComponent(m.originalRelativePath).path))
    }

}
