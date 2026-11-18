import Foundation
import Synchronization
import XCTest
@testable import LocalScribeCore

/// Transactions of the text-anonymization archive actor: monotone snapshot
/// revisions, visibility only after commit, byte-exact duplicates, batch
/// moves, deletion intentions and recovery of interrupted imports, deletions
/// and attempts.
final class AnonymizationCoordinatorTests: XCTestCase {
    private func makeRepository() throws -> AnonymizationRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try AnonymizationRepository(root: root)
    }

    private func draft(name: String = "отчёт", text: String = "Отчёт команды",
                       bytes: Data? = nil,
                       format: AnonymizationSourceFormat = .txt) -> AnonymizationCoordinator.ImportDraft {
        .init(bytes: bytes ?? Data(text.utf8), importedNameStem: name, sourceFormat: format,
              source: TextRevision(id: UUID().uuidString, text: text))
    }

    @discardableResult
    private func importCard(_ archive: AnonymizationCoordinator, name: String = "отчёт",
                            bytes: Data? = nil, groupID: String = AnonymizationGroup.systemID) async throws -> AnonymizationCardSummary {
        try await archive.importCard(draft(name: name, bytes: bytes), groupID: groupID)
    }

    @discardableResult
    private func createGroup(_ archive: AnonymizationCoordinator, _ name: String) async throws -> AnonymizationGroup {
        try await archive.editGroups { try $0.create(name: name) }
        let snapshot = await archive.snapshot()
        return try XCTUnwrap(snapshot.catalog.defaultGroup)
    }

    // MARK: - Revisions and visibility

    func testSnapshotRevisionMonotonicAndNoOpKeepsRevision() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        var snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertTrue(snapshot.cards.isEmpty)
        XCTAssertEqual(snapshot.catalog.groups.map(\.id), [AnonymizationGroup.systemID])
        let card = try await importCard(archive)
        snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.revision, 3) // catalog commit + publication
        XCTAssertEqual(snapshot.cards.map(\.id), [card.id])
        try await archive.rename(card.id, to: "Переименован")
        let renamed = await archive.snapshot()
        XCTAssertEqual(renamed.revision, 4)
        // A no-op group edit neither writes the catalog nor bumps the revision.
        let catalogBefore = try Data(contentsOf: repo.catalogURL)
        try await archive.editGroups { $0.setAllExpanded(true) }
        snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.revision, 4)
        XCTAssertEqual(try Data(contentsOf: repo.catalogURL), catalogBefore)
        // A failed import leaves no document, journal or visible change.
        do { _ = try await archive.importCard(draft(text: "   \t ")); XCTFail("Whitespace text must fail") } catch {}
        do { _ = try await archive.importCard(draft(bytes: Data())); XCTFail("Empty file must fail") } catch {}
        snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.cards.count, 1)
        XCTAssertEqual(snapshot.revision, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.itemsURL.path), [card.id])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: repo.pendingURL.path).isEmpty)
    }

    func testImportCommitsMembershipOrderAndJournals() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let group = try await createGroup(archive, "Проекты")
        let first = try await importCard(archive, name: "первый")
        let second = try await importCard(archive, name: "второй", groupID: group.id)
        // An unknown destination resolves to the system group, never a default.
        let third = try await importCard(archive, name: "третий", groupID: UUID().uuidString)
        var snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.cards.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(snapshot.cards.map(\.importOrder), [1, 2, 3])
        XCTAssertTrue(snapshot.cards.allSatisfy { $0.attemptState == .waitingModel && !$0.hasPublishedResult })
        XCTAssertEqual(snapshot.catalog.groupID(for: second.id), group.id)
        XCTAssertEqual(snapshot.catalog.groupID(for: third.id), AnonymizationGroup.systemID)
        XCTAssertEqual(snapshot.catalog.nextImportPosition, 4)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: repo.pendingURL.path).isEmpty)
        let stored = try await archive.loadCard(second.id)
        XCTAssertEqual(stored.displayName, "второй")
        XCTAssertEqual(stored.importContentIdentity.bytes, Data("Отчёт команды".utf8))
        // The summary is a projection without document payloads.
        snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.cards.first?.displayName, "первый")
    }

    /// Pre-commit size gate (review C7): the card document embeds the import
    /// bytes base64-encoded next to the decoded text, so an input whose
    /// projected document exceeds the JSON ceiling is rejected before the
    /// intention journal or `card.json` is ever written.
    func testOversizedImportRejectedBeforeAnyDiskWrite() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        // ~49 MiB of ASCII sits above the base64-derived card ceiling of the
        // JSON limit: no such file can ever be committed.
        let huge = Data(repeating: 0x41, count: 49 * 1024 * 1024)
        let text = String(decoding: huge, as: UTF8.self)
        do {
            _ = try await archive.importCard(draft(name: "огромный", text: text, bytes: huge))
            XCTFail("Слишком большой импорт обязан быть отклонён")
        } catch let error as ScribeError {
            XCTAssertTrue(error.localizedDescription.contains("слишком большой"))
            XCTAssertTrue(error.localizedDescription.contains("\(Disk.maximumJSONBytes) байт"),
                          "сообщение несёт оба числа: \(error.localizedDescription)")
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: repo.itemsURL.path).isEmpty,
                      "card.json не создаётся")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: repo.pendingURL.path).isEmpty,
                      "журнал намерений не пишется")
        let snapshot = await archive.snapshot()
        XCTAssertTrue(snapshot.cards.isEmpty)
        XCTAssertEqual(snapshot.catalog.nextImportPosition, 1, "позиция импорта не расходуется")
    }

    func testImportPositionNeverReusedAfterDeletion() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let first = try await importCard(archive, name: "первый")
        _ = try await importCard(archive, name: "второй")
        _ = try await archive.prepareCardDeletion([first.id])
        try await archive.finishCardDeletion()
        let third = try await importCard(archive, name: "третий")
        XCTAssertEqual(third.importOrder, 3)
        XCTAssertEqual(try repo.loadCard(third.id).importOrder, 3)
        XCTAssertEqual(try repo.loadCatalog().nextImportPosition, 4)
    }

    // MARK: - Duplicates

    func testDuplicateByExactBytesPrefersLatestImportAndBOMMatters() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let bytes = Data("Отчёт команды".utf8)
        let first = try await importCard(archive, name: "один", bytes: bytes)
        // Editing the first card does not affect byte identity.
        _ = try await archive.updateCard(first.id) { card in
            card.source = TextRevision(id: UUID().uuidString, text: "Изменённый текст")
        }
        try await archive.rename(first.id, to: "Переименованный")
        let second = try await importCard(archive, name: "два", bytes: bytes)
        let duplicate = await archive.findDuplicate(of: bytes)
        XCTAssertEqual(duplicate, second.id)
        // A BOM prefix is a different import even when the decoded text matches.
        let bom = Data([0xEF, 0xBB, 0xBF]) + bytes
        let bomCard = try await importCard(archive, name: "три", bytes: bom)
        let bomDuplicate = await archive.findDuplicate(of: bom)
        XCTAssertEqual(bomDuplicate, bomCard.id)
        let plainDuplicate = await archive.findDuplicate(of: bytes)
        XCTAssertEqual(plainDuplicate, second.id)
        let none = await archive.findDuplicate(of: Data("другие байты".utf8))
        XCTAssertNil(none)
        // Deleting the latest duplicate falls back to the previous survivor.
        _ = try await archive.prepareCardDeletion([second.id])
        try await archive.finishCardDeletion()
        let survivor = await archive.findDuplicate(of: bytes)
        XCTAssertEqual(survivor, first.id)
    }

    func testFindDuplicateUsesScanIndexForExternallySeededCard() async throws {
        let repo = try makeRepository()
        let card = AnonymizationCardDocument(
            id: UUID().uuidString, importOrder: 1,
            importContentIdentity: ByteContentIdentity(bytes: Data("seed".utf8)),
            importedNameStem: "seed", sourceFormat: .txt, displayName: "seed",
            source: TextRevision(id: UUID().uuidString, text: "Текст"),
            latestAttempt: AnonymizationAttempt(state: .waitingModel))
        try repo.saveCard(card)
        var catalog = try repo.loadCatalog()
        try catalog.assign(card.id, to: AnonymizationGroup.systemID)
        try repo.saveCatalog(catalog)
        let archive = AnonymizationCoordinator(repository: repo)
        let seeded = await archive.findDuplicate(of: Data("seed".utf8))
        XCTAssertEqual(seeded, card.id)
    }

    // MARK: - Recovery

    func testRecoveryRemovesUnfinishedImportAndKeepsCounter() async throws {
        let repo = try makeRepository()
        // Simulate a crash between the card document write and the catalog commit.
        let card = AnonymizationCardDocument(
            id: UUID().uuidString, importOrder: 1,
            importContentIdentity: ByteContentIdentity(bytes: Data("байты".utf8)),
            importedNameStem: "черновик", sourceFormat: .txt, displayName: "черновик",
            source: TextRevision(id: UUID().uuidString, text: "Текст"),
            latestAttempt: AnonymizationAttempt(state: .waitingModel))
        try repo.saveCard(card)
        try repo.writeImportIntention(.init(cardID: card.id, targetGroupID: AnonymizationGroup.systemID))
        let archive = AnonymizationCoordinator(repository: repo)
        let snapshot = try await archive.recover()
        XCTAssertTrue(snapshot.cards.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.folder(card.id).path))
        XCTAssertTrue(repo.pendingImportIntentions().isEmpty)
        XCTAssertEqual(try repo.loadCatalog().nextImportPosition, 1)
        // A committed import with a leftover journal survives recovery.
        let committed = try await importCard(archive, name: "готовый")
        try repo.writeImportIntention(.init(cardID: committed.id, targetGroupID: AnonymizationGroup.systemID))
        let second = AnonymizationCoordinator(repository: repo)
        let recovered = try await second.recover()
        XCTAssertEqual(recovered.cards.map(\.id), [committed.id])
        XCTAssertTrue(repo.pendingImportIntentions().isEmpty)
    }

    func testRecoveryFinalizesConfirmedDeletionAndReportsUnexpectedMissing() async throws {
        let repo = try makeRepository()
        let seeder = AnonymizationCoordinator(repository: repo)
        let first = try await importCard(seeder, name: "первый")
        let second = try await importCard(seeder, name: "второй")
        // Confirmation journaled; one folder already removed by its worker.
        let confirmed = try await seeder.prepareCardDeletion([first.id, second.id])
        XCTAssertEqual(confirmed, [first.id, second.id])
        try FileManager.default.removeItem(at: repo.folder(first.id))
        let archive = AnonymizationCoordinator(repository: repo)
        var snapshot = try await archive.recover()
        XCTAssertEqual(snapshot.cards.map(\.id), [second.id])
        XCTAssertNil(snapshot.catalog.membership[first.id])
        XCTAssertNil(repo.loadDeletionIntention())
        // A folder that disappears without a confirmation is an error, never a
        // silent prune; its membership stays.
        try FileManager.default.removeItem(at: repo.folder(second.id))
        let unexpected = AnonymizationCoordinator(repository: repo)
        snapshot = try await unexpected.recover()
        XCTAssertEqual(snapshot.unreadableCardIDs, [second.id])
        XCTAssertTrue(snapshot.cards.isEmpty)
        XCTAssertEqual(snapshot.catalog.membership[second.id], AnonymizationGroup.systemID)
    }

    func testRecoveryInterruptsQueuedAndRunningAttempts() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let queued = try await importCard(archive, name: "в очереди")
        let running = try await importCard(archive, name: "в работе")
        let waiting = try await importCard(archive, name: "ждёт модель")
        try await archive.updateCard(queued.id) { $0.latestAttempt.state = .queued }
        try await archive.updateCard(running.id) { card in
            card.latestAttempt.state = .running
            card.latestAttempt.input = RunInput(source: card.source, profileID: "profile",
                                                packageID: "package", dataTypes: ["Имена и фамилии"])
        }
        let restarted = AnonymizationCoordinator(repository: repo)
        let snapshot = try await restarted.recover()
        XCTAssertEqual(try repo.loadCard(queued.id).latestAttempt.state, .interrupted)
        XCTAssertEqual(try repo.loadCard(running.id).latestAttempt.state, .interrupted)
        XCTAssertEqual(try repo.loadCard(waiting.id).latestAttempt.state, .waitingModel)
        XCTAssertEqual(snapshot.cards.map(\.id), [queued.id, running.id, waiting.id])
        XCTAssertTrue(snapshot.unreadableCardIDs.isEmpty)
    }

    func testRecoveryReportsDamagedDocumentWithoutDeletingIt() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let healthy = try await importCard(archive, name: "здоровый")
        let damaged = try await importCard(archive, name: "повреждённый")
        try Data("broken".utf8).write(to: repo.cardURL(damaged.id))
        let restarted = AnonymizationCoordinator(repository: repo)
        let snapshot = try await restarted.recover()
        XCTAssertEqual(snapshot.cards.map(\.id), [healthy.id])
        XCTAssertEqual(snapshot.unreadableCardIDs, [damaged.id])
        XCTAssertEqual(snapshot.catalog.groupID(for: damaged.id), AnonymizationGroup.systemID)
        XCTAssertEqual(try Data(contentsOf: repo.cardURL(damaged.id)), Data("broken".utf8))
    }

    // MARK: - Moves and groups

    func testBatchMoveValidatesAllMembersBeforeSingleSave() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let first = try await importCard(archive, name: "первый")
        let second = try await importCard(archive, name: "второй")
        let target = try await createGroup(archive, "Цель")
        let before = await archive.snapshot()
        let catalogBefore = try Data(contentsOf: repo.catalogURL)
        do {
            try await archive.moveCards([first.id, second.id, UUID().uuidString], to: target.id)
            XCTFail("Missing member must reject the entire move")
        } catch {}
        let failed = await archive.snapshot()
        XCTAssertEqual(failed.catalog, before.catalog)
        XCTAssertEqual(failed.revision, before.revision)
        XCTAssertEqual(try Data(contentsOf: repo.catalogURL), catalogBefore)
        try await archive.moveCards([first.id, second.id], to: target.id)
        let moved = await archive.snapshot()
        XCTAssertEqual(moved.revision, before.revision + 1)
        XCTAssertEqual(moved.catalog.groupID(for: first.id), target.id)
        XCTAssertEqual(moved.catalog.groupID(for: second.id), target.id)
        XCTAssertEqual(try repo.loadCatalog(), moved.catalog)
    }

    func testGroupEditsCommitThroughCoordinatorAndProtectSystemGroup() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let first = try await createGroup(archive, "Первая")
        XCTAssertEqual(first.isExpanded, true)
        var snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.catalog.groups.map(\.name), ["Первая", AnonymizationGroup.systemName])
        XCTAssertEqual(snapshot.catalog.defaultGroupID, first.id)
        do { try await archive.editGroups { try $0.create(name: "ПЕРВАЯ") }; XCTFail("Case-insensitive duplicate") } catch {}
        do { try await archive.editGroups { try $0.create(name: "  ") }; XCTFail("Empty name") } catch {}
        do { try await archive.editGroups { try $0.rename(AnonymizationGroup.systemID, name: "Другое") }; XCTFail("System rename") } catch {}
        let second = try await createGroup(archive, "Вторая")
        snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.catalog.groups.map(\.name), ["Вторая", "Первая", AnonymizationGroup.systemName])
        // Removing the default group falls back to «Без темы».
        try await archive.editGroups { try $0.setDefault(second.id) }
        try await archive.editGroups { try $0.remove(second.id) }
        snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.catalog.groups.map(\.name), ["Первая", AnonymizationGroup.systemName])
        XCTAssertEqual(snapshot.catalog.defaultGroupID, AnonymizationGroup.systemID)
        XCTAssertEqual(try repo.loadCatalog(), snapshot.catalog)
    }

    // MARK: - Deletion

    func testGroupDeletionMoveOnlyMovesMembersToUngroupedInOneWrite() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let group = try await createGroup(archive, "Проекты")
        let first = try await importCard(archive, name: "первый", groupID: group.id)
        let second = try await importCard(archive, name: "второй", groupID: group.id)
        let outside = try await importCard(archive, name: "вне")
        let prepared = try await archive.prepareGroupDeletion(group.id)
        XCTAssertEqual(prepared, [first.id, second.id])
        let revisionBefore = await archive.snapshot().revision
        try await archive.finishGroupDeletion(group.id, deleteFiles: false)
        let snapshot = await archive.snapshot()
        XCTAssertEqual(Set(snapshot.cards.map(\.id)), [first.id, second.id, outside.id])
        XCTAssertEqual(snapshot.catalog.groupID(for: first.id), AnonymizationGroup.systemID)
        XCTAssertEqual(snapshot.catalog.groups.map(\.id), [AnonymizationGroup.systemID])
        XCTAssertEqual(snapshot.revision, revisionBefore + 1)
        XCTAssertNil(repo.loadDeletionIntention())
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.folder(first.id).path))
    }

    func testGroupDeletionWithFilesKeepsGroupForRemainderOnPartialFailure() async throws {
        let repo = try makeRepository()
        let group = try await createGroup(AnonymizationCoordinator(repository: repo), "Проекты")
        let fail = Mutex<String?>(nil)
        let archive = AnonymizationCoordinator(repository: repo, removeCard: { repository, id in
            if id == fail.withLock({ $0 }) { throw ScribeError.message("test deletion failure") }
            try repository.deleteCard(id)
        })
        let first = try await importCard(archive, name: "первый", groupID: group.id)
        let second = try await importCard(archive, name: "второй", groupID: group.id)
        _ = try await archive.prepareGroupDeletion(group.id)
        fail.withLock { $0 = second.id }
        do { try await archive.finishGroupDeletion(group.id, deleteFiles: true); XCTFail("Partial failure expected") } catch {}
        var snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.cards.map(\.id), [second.id])
        XCTAssertEqual(snapshot.catalog.groupID(for: second.id), group.id)
        XCTAssertEqual(snapshot.catalog.groups.map(\.name), ["Проекты", AnonymizationGroup.systemName])
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.folder(second.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.folder(first.id).path))
        // Retrying with the failure cleared removes the remainder and the group.
        fail.withLock { $0 = nil }
        _ = try await archive.prepareGroupDeletion(group.id)
        try await archive.finishGroupDeletion(group.id, deleteFiles: true)
        snapshot = await archive.snapshot()
        XCTAssertTrue(snapshot.cards.isEmpty)
        XCTAssertEqual(snapshot.catalog.groups.map(\.id), [AnonymizationGroup.systemID])
        XCTAssertNil(repo.loadDeletionIntention())
    }

    func testFinishCardDeletionPublishesActualRemainder() async throws {
        let repo = try makeRepository()
        let fail = Mutex<String?>(nil)
        let archive = AnonymizationCoordinator(repository: repo, removeCard: { repository, id in
            if id == fail.withLock({ $0 }) { throw ScribeError.message("test deletion failure") }
            try repository.deleteCard(id)
        })
        let first = try await importCard(archive, name: "первый")
        let second = try await importCard(archive, name: "второй")
        fail.withLock { $0 = second.id }
        _ = try await archive.prepareCardDeletion([first.id, second.id])
        do { try await archive.finishCardDeletion(); XCTFail("Partial failure expected") } catch {}
        var snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.cards.map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.folder(second.id).path))
        // The journal was consumed: a restart keeps the remainder visible.
        XCTAssertNil(repo.loadDeletionIntention())
        let restarted = AnonymizationCoordinator(repository: repo)
        snapshot = try await restarted.recover()
        XCTAssertEqual(snapshot.cards.map(\.id), [second.id])
        fail.withLock { $0 = nil }
        _ = try await archive.prepareCardDeletion([second.id])
        try await archive.finishCardDeletion()
        snapshot = await archive.snapshot()
        XCTAssertTrue(snapshot.cards.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.folder(second.id).path))
    }

    func testImportDuringGroupDeletionFallsBackToUngroupedAndBlocksMoves() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let group = try await createGroup(archive, "Проекты")
        let member = try await importCard(archive, name: "участник", groupID: group.id)
        _ = try await archive.prepareGroupDeletion(group.id)
        // A late import aimed at the frozen group lands in «Без темы».
        let late = try await importCard(archive, name: "поздний", groupID: group.id)
        var snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.catalog.groupID(for: late.id), AnonymizationGroup.systemID)
        do { try await archive.moveCards([member.id], to: AnonymizationGroup.systemID); XCTFail("Frozen member") } catch {}
        do { try await archive.moveCards([late.id], to: group.id); XCTFail("Frozen group") } catch {}
        do { try await archive.editGroups { try $0.create(name: "Ещё") }; XCTFail("Group edits blocked") } catch {}
        await archive.cancelDeletion()
        XCTAssertNil(repo.loadDeletionIntention())
        try await archive.moveCards([member.id], to: AnonymizationGroup.systemID)
        snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.catalog.groupID(for: member.id), AnonymizationGroup.systemID)
    }

    // MARK: - Damaged catalog

    func testCorruptCatalogBlocksChangesAndIsNeverOverwritten() async throws {
        let repo = try makeRepository()
        let broken = Data("broken catalog".utf8)
        try broken.write(to: repo.catalogURL)
        let archive = AnonymizationCoordinator(repository: repo)
        var snapshot = await archive.snapshot()
        XCTAssertNotNil(snapshot.catalogError)
        XCTAssertTrue(snapshot.cards.isEmpty)
        do { try await archive.editGroups { try $0.create(name: "Группа") }; XCTFail() } catch {}
        do { _ = try await archive.importCard(draft()); XCTFail() } catch {}
        do { try await archive.moveCards([UUID().uuidString], to: AnonymizationGroup.systemID); XCTFail() } catch {}
        do { _ = try await archive.prepareCardDeletion([UUID().uuidString]); XCTFail() } catch {}
        do { _ = try await archive.prepareGroupDeletion(UUID().uuidString); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: repo.catalogURL), broken)
        snapshot = try await archive.recover()
        XCTAssertNotNil(snapshot.catalogError)
        XCTAssertEqual(try Data(contentsOf: repo.catalogURL), broken)
    }

    // MARK: - Card updates

    func testUpdateCardPublishesAndProtectsIdentity() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let card = try await importCard(archive, name: "отчёт")
        let revision = TextRevision(id: UUID().uuidString, text: "Правленый текст")
        let updated = try await archive.updateCard(card.id) { $0.source = revision }
        XCTAssertEqual(updated.source, revision)
        XCTAssertEqual(try repo.loadCard(card.id).source, revision)
        let document = try Data(contentsOf: repo.cardURL(card.id))
        do { _ = try await archive.updateCard(card.id) { $0.importOrder = 99 }; XCTFail() } catch {}
        do { _ = try await archive.updateCard(card.id) { $0.id = UUID().uuidString }; XCTFail() } catch {}
        do { _ = try await archive.updateCard(card.id) { $0.sourceFormat = .markdown }; XCTFail() } catch {}
        do {
            _ = try await archive.updateCard(card.id) {
                $0.importContentIdentity = ByteContentIdentity(bytes: Data("x".utf8))
            }
            XCTFail()
        } catch {}
        XCTAssertEqual(try Data(contentsOf: repo.cardURL(card.id)), document)
        do { try await archive.rename(card.id, to: "  "); XCTFail() } catch {}
        try await archive.rename(card.id, to: " Новое название ")
        XCTAssertEqual(try repo.loadCard(card.id).displayName, "Новое название")
    }

    /// The coordinator keeps the decoded document of the active card keyed by
    /// the file's size and modification date: an unchanged file is not
    /// decoded again, while any external write misses the cache and is read.
    func testCoordinatorCachesDecodedActiveCardUntilTheFileChanges() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let card = try await importCard(archive, name: "кэш")
        let initial = try await archive.loadCard(card.id)
        XCTAssertEqual(initial.displayName, "кэш")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: repo.cardURL(card.id).path)
        // The stamp is unchanged, so the cached document answers without
        // opening the (now unreadable) file.
        let cached = try await archive.loadCard(card.id)
        XCTAssertEqual(cached.displayName, "кэш")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: repo.cardURL(card.id).path)
        var external = try repo.loadCard(card.id)
        external.displayName = "изменён снаружи"
        try repo.saveCard(external)
        // The write changed the file: the next load must observe it.
        let reloaded = try await archive.loadCard(card.id)
        XCTAssertEqual(reloaded.displayName, "изменён снаружи")
    }

    /// The redundant byte re-hash skip changes no rule: a transaction whose
    /// mutation breaks a non-identity field still fails validation and keeps
    /// the previous document on disk.
    func testUpdateCardStillValidatesNonIdentityFieldsWhenReusingVerifiedBytes() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let card = try await importCard(archive, name: "отчёт")
        try await archive.rename(card.id, to: "Новое название")
        let document = try Data(contentsOf: repo.cardURL(card.id))
        do {
            _ = try await archive.updateCard(card.id) { $0.displayName = " \t " }
            XCTFail("Валидация обязана отклонить пробельное название")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: repo.cardURL(card.id)), document)
        let reloaded = try await archive.loadCard(card.id)
        XCTAssertEqual(reloaded.displayName, "Новое название")
    }

    // MARK: - Editing during a live attempt

    /// A live QUEUED/RUNNING attempt freezes its run input, and publication
    /// validates the artifact against the current source: a source edit would
    /// fail or misalign that attempt. The editor locks the panels (AC-38);
    /// the coordinator enforces the same rule for direct callers and stale
    /// UI snapshots. A restart interrupts the attempt and frees the editor.
    func testEditSourceRejectedWhileAttemptIsQueuedOrRunning() async throws {
        let repo = try makeRepository()
        let archive = AnonymizationCoordinator(repository: repo)
        let card = try await importCard(archive, name: "отчёт")
        let original = try repo.loadCard(card.id)
        try await archive.updateCard(card.id) { $0.latestAttempt.state = .queued }
        do {
            _ = try await archive.editSource(card.id, ScalarEdit(start: 0, end: 1, replacement: "X"))
            XCTFail("Правка исходника при живой QUEUED-попытке обязана быть отклонена")
        } catch {}
        try await archive.updateCard(card.id) { card in
            card.latestAttempt.state = .running
            card.latestAttempt.input = RunInput(source: card.source, profileID: "profile",
                                                packageID: "package", dataTypes: ["Имена и фамилии"])
        }
        do {
            _ = try await archive.editSource(card.id, ScalarEdit(start: 0, end: 1, replacement: "X"))
            XCTFail("Правка исходника при живой RUNNING-попытке обязана быть отклонена")
        } catch {}
        XCTAssertEqual(try repo.loadCard(card.id).source, original.source, "отклонённые правки не меняют документ")
        // After a restart the live attempt is interrupted and the source is
        // editable again, like after any finished outcome.
        let restarted = AnonymizationCoordinator(repository: repo)
        _ = try await restarted.recover()
        XCTAssertEqual(try repo.loadCard(card.id).latestAttempt.state, .interrupted)
        _ = try await restarted.editSource(card.id, ScalarEdit(start: 0, end: 1, replacement: "X"))
        XCTAssertEqual(try repo.loadCard(card.id).source.text, "Xтчёт команды")
    }
}
