import Foundation
import XCTest
import LocalScribeCore

/// File storage and document validation of the text-anonymization archive:
/// the versioned catalog, per-card documents, service journals and the full
/// domain validation of every stored value.
final class AnonymizationRepositoryTests: XCTestCase {
    private func makeRepository() throws -> AnonymizationRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try AnonymizationRepository(root: root)
    }

    private func makeCard(order: UInt = 1, text: String = "Анна позвонила",
                          stem: String = "отчёт") -> AnonymizationCardDocument {
        AnonymizationCardDocument(
            id: UUID().uuidString, importOrder: order,
            importContentIdentity: ByteContentIdentity(bytes: Data(text.utf8)),
            importedNameStem: stem, sourceFormat: .markdown,
            displayName: stem, source: TextRevision(id: UUID().uuidString, text: text),
            latestAttempt: AnonymizationAttempt(state: .waitingModel))
    }

    private func makeResult(for card: AnonymizationCardDocument,
                            source: TextRevision? = nil) -> AnonymizationResult {
        let inputSource = source ?? card.source
        let input = RunInput(source: inputSource, profileID: "shared-profile",
                             packageID: "shared-package", dataTypes: ["Имена и фамилии", "Телефоны"])
        let generated = TextRevision(id: UUID().uuidString, text: "Мария позвонила")
        return AnonymizationResult(
            input: input, generatedText: generated, text: generated,
            downloadNameStem: "имя", bodyReplacementCount: 1,
            pairs: [ReplacementPair(sourceRange: TextRange(start: 0, end: 4),
                                    resultRange: TextRange(start: 0, end: 5))],
            warnings: [AnonymizationWarning(kind: .uninterpretedType, dataType: "Телефоны")])
    }

    // MARK: - Catalog

    func testFirstOpenCreatesEmptyCatalogWithSystemGroup() throws {
        let repo = try makeRepository()
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.catalogURL.path))
        let catalog = try repo.loadCatalog()
        XCTAssertEqual(catalog.groups.map(\.id), [AnonymizationGroup.systemID])
        XCTAssertEqual(catalog.groups.first?.name, AnonymizationGroup.systemName)
        XCTAssertEqual(catalog.defaultGroupID, AnonymizationGroup.systemID)
        XCTAssertTrue(catalog.membership.isEmpty)
        XCTAssertEqual(catalog.nextImportPosition, 1)
        // The system group is exposed last and reads as the default group.
        XCTAssertEqual(catalog.defaultGroup?.isSystem, true)
    }

    func testCorruptCatalogIsNeverReplacedAndLoadFails() throws {
        let repo = try makeRepository()
        let broken = Data("broken catalog".utf8)
        try broken.write(to: repo.catalogURL)
        // Re-opening the same root must not repair or replace the catalog.
        _ = try AnonymizationRepository(root: repo.root)
        XCTAssertEqual(try Data(contentsOf: repo.catalogURL), broken)
        XCTAssertThrowsError(try repo.loadCatalog())
        // An invalid catalog never reaches the disk through saveCatalog.
        var invalid = AnonymizationArchiveCatalog()
        invalid.schemaVersion = 2
        XCTAssertThrowsError(try repo.saveCatalog(invalid))
        XCTAssertEqual(try Data(contentsOf: repo.catalogURL), broken)
    }

    func testCatalogValidationRejectsDamagedVariants() throws {
        // A damaged catalog can only arrive from disk, so variants are built
        // by tampering with the JSON representation, never via public API.
        func damaged(_ mutate: (inout [String: Any]) -> Void) throws -> AnonymizationArchiveCatalog {
            var base = AnonymizationArchiveCatalog()
            let group = try base.create(name: "Проекты")
            try base.assign(UUID().uuidString, to: group.id)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
            mutate(&json)
            return try JSONDecoder().decode(AnonymizationArchiveCatalog.self,
                                            from: JSONSerialization.data(withJSONObject: json))
        }
        func withGroups(_ mutate: @escaping (inout [[String: Any]]) -> Void) -> (inout [String: Any]) -> Void {
            { json in
                var groups = json["groups"] as? [[String: Any]] ?? []
                mutate(&groups)
                json["groups"] = groups
            }
        }
        XCTAssertThrowsError(try damaged { $0["schemaVersion"] = 2 }.validate())
        XCTAssertThrowsError(try damaged(withGroups { $0[0]["name"] = "без темы" }).validate(),
                             "имена уникальны без учёта регистра")
        XCTAssertThrowsError(try damaged(withGroups { $0[1]["name"] = "Другое" }).validate(),
                             "имя системной группы закреплено")
        XCTAssertThrowsError(try damaged(withGroups { $0[1]["kind"] = "USER" }).validate(),
                             "ровно одна системная группа")
        XCTAssertThrowsError(try damaged(withGroups { $0.swapAt(0, 1) }).validate(),
                             "системная группа всегда последняя")
        XCTAssertThrowsError(try damaged(withGroups { $0[0]["id"] = AnonymizationGroup.systemID }).validate(),
                             "пользовательская группа не может нести системный ID")
        XCTAssertThrowsError(try damaged { $0["defaultGroupID"] = UUID().uuidString }.validate())
        XCTAssertThrowsError(try damaged { $0["membership"] = [UUID().uuidString: UUID().uuidString] }.validate(),
                             "принадлежность ссылается на существующую группу")
        XCTAssertThrowsError(try damaged { $0["membership"] = ["not-an-uuid": AnonymizationGroup.systemID] }.validate())
        XCTAssertThrowsError(try damaged { $0["nextImportPosition"] = 0 }.validate())
        XCTAssertThrowsError(try damaged(withGroups { $0.removeAll() }).validate())
        XCTAssertNoThrow(try damaged { _ in () }.validate())
    }

    func testCatalogOperationsKeepSystemGroupProtected() throws {
        var catalog = AnonymizationArchiveCatalog()
        XCTAssertThrowsError(try catalog.rename(AnonymizationGroup.systemID, name: "Другое"))
        XCTAssertThrowsError(try catalog.remove(AnonymizationGroup.systemID))
        XCTAssertThrowsError(try catalog.move(AnonymizationGroup.systemID, before: "x"))
        XCTAssertThrowsError(try catalog.rename(UUID().uuidString, name: "нет"))
        let first = try catalog.create(name: "Первая")
        let second = try catalog.create(name: "Вторая")
        XCTAssertEqual(catalog.groups.map(\.name), ["Вторая", "Первая", AnonymizationGroup.systemName])
        XCTAssertEqual(catalog.defaultGroupID, second.id)
        try catalog.move(first.id, before: second.id)
        XCTAssertEqual(catalog.groups.map(\.name), ["Первая", "Вторая", AnonymizationGroup.systemName])
        try catalog.setDefault(AnonymizationGroup.systemID)
        try catalog.rename(second.id, name: "вторая")
        XCTAssertEqual(catalog.groups[1].name, "вторая")
        try catalog.remove(second.id)
        XCTAssertEqual(catalog.groups.map(\.id), [first.id, AnonymizationGroup.systemID])
        XCTAssertEqual(catalog.defaultGroupID, AnonymizationGroup.systemID)
        XCTAssertNoThrow(try catalog.validate())
    }

    // MARK: - Cards

    func testCardRoundTripRequiresMatchingFolderIdentity() throws {
        let repo = try makeRepository()
        let card = makeCard(order: 3)
        try repo.saveCard(card)
        let read = try repo.loadCard(card.id)
        XCTAssertEqual(read, card)
        XCTAssertEqual(read.importContentIdentity.bytes, Data("Анна позвонила".utf8))
        // A document copied into a foreign folder no longer matches its directory.
        let foreign = makeCard()
        try Disk.write(card, to: repo.cardURL(foreign.id))
        XCTAssertThrowsError(try repo.loadCard(foreign.id))
    }

    func testCardValidationRejectsDamagedDocuments() throws {
        let card = makeCard()
        let result = makeResult(for: card)
        func check(_ mutate: (inout AnonymizationCardDocument) -> Void,
                   _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
            var copy = card
            mutate(&copy)
            XCTAssertThrowsError(try copy.validate(), message, file: file, line: line)
        }
        try check({ $0.schemaVersion = 2 }, "версия схемы документа должна проверяться")
        try check({ $0.id = "not-an-uuid" }, "UUID карточки должен проверяться")
        try check({ $0.importOrder = 0 }, "позиция импорта начинается с единицы")
        try check({ $0.importContentIdentity.bytesBase64 = "###" }, "байты должны декодироваться")
        try check({ $0.importContentIdentity.byteLength += 1 }, "длина байтов должна совпадать")
        try check({ $0.importContentIdentity.sha256 = "00" }, "SHA байтов должен совпадать")
        try check({ $0.importedNameStem = "" }, "пустое имя импорта отклоняется")
        try check({ $0.importedNameStem = "a/b" }, "имя импорта без разделителей")
        try check({ $0.displayName = "   " }, "пустое название отклоняется")
        try check({ $0.source.id = "not-an-uuid" }, "идентификатор версии исходника")
        try check({ $0.latestAttempt.state = .failed }, "неудачная попытка требует причину")
        try check({ $0.latestAttempt.state = .succeeded }, "успех требует опубликованный результат")
        try check({ $0.latestAttempt.input = makeResult(for: card).input; $0.latestAttempt.state = .queued },
                  "ожидающая попытка не имеет входа")
        try check({ $0.latestAttempt.state = .running }, "запущенная попытка требует вход")
        try check({ $0.latestAttempt.expectedResultRevisionID = UUID().uuidString },
                  "согласованная версия требует результата")
        try check({ $0.latestAttempt.failure = .processing("причина"); $0.latestAttempt.state = .cancelled },
                  "причина есть только у неудачной попытки")
        try check({ var failed = $0.latestAttempt; failed.state = .failed; failed.failure = .sizeLimit(actualBytes: 10, limitBytes: 0); $0.latestAttempt = failed },
                  "нулевая граница размера отклоняется")
        // Полный результат с попыткой SUCCEEDED валиден; отдельные повреждения результата отклоняются.
        var valid = card
        valid.publishedResult = result
        valid.latestAttempt = AnonymizationAttempt(state: .succeeded,
                                                   expectedResultRevisionID: result.text.id,
                                                   input: result.input)
        XCTAssertNoThrow(try valid.validate())
        func checkResult(_ mutate: (inout AnonymizationResult) -> Void,
                         _ message: String, file: StaticString = #filePath, line: UInt = #line) {
            var copy = valid
            mutate(&copy.publishedResult!)
            XCTAssertThrowsError(try copy.validate(), message, file: file, line: line)
        }
        checkResult({ $0.schemaVersion = 2 }, "версия схемы результата")
        checkResult({ $0.pairs[0].sourceRange = TextRange(start: 0, end: 999) }, "диапазон в границах исходника")
        checkResult({ $0.pairs[0].resultRange = TextRange(start: 0, end: 999) }, "диапазон в границах результата")
        checkResult({ $0.pairs[0].sourceRange = TextRange(start: 2, end: 4)
                      $0.pairs.append(ReplacementPair(sourceRange: TextRange(start: 3, end: 6),
                                                      resultRange: TextRange(start: 0, end: 2))) },
                    "пары не пересекаются в исходнике")
        checkResult({ $0.downloadNameStem = "" }, "пустое имя скачивания")
        checkResult({ $0.warnings[0] = AnonymizationWarning(kind: .doubtfulFragment) },
                    "сомнительный фрагмент требует цель и диапазоны")
        checkResult({ $0.warnings[0] = AnonymizationWarning(kind: .uninterpretedType, dataType: "Нет такого типа") },
                    "непонятый тип берётся из входа")
        checkResult({ $0.warnings[0] = AnonymizationWarning(kind: .uninterpretedType,
                                                             generatedRange: TextRange(start: 0, end: 1),
                                                             dataType: "Телефоны") },
                    "у непонятого типа нет диапазонов")
        checkResult({ $0.warnings.append(AnonymizationWarning(kind: .doubtfulFragment, target: .body,
                                                               inputRange: TextRange(start: 0, end: 999),
                                                               generatedRange: TextRange(start: 0, end: 5))) },
                    "диапазон предупреждения в границах версии")
        checkResult({ $0.warnings.append(AnonymizationWarning(kind: .doubtfulFragment, target: .importedName,
                                                               inputRange: TextRange(start: 0, end: 999),
                                                               generatedRange: TextRange(start: 0, end: 1))) },
                    "диапазон имени в границах имени")
        // История подстановок.
        var substitutions = valid
        substitutions.automaticSubstitutions = [
            AutomaticSubstitution(dataType: "Имена и фамилии", sourceValue: "Анна", substituteValue: "Мария"),
            AutomaticSubstitution(dataType: "Имена и фамилии", sourceValue: "Анне", substituteValue: "Марии")]
        XCTAssertNoThrow(try substitutions.validate())
        for damaged in [
            [AutomaticSubstitution(dataType: "Имена и фамилии", sourceValue: "Анна", substituteValue: "Ольга"),
             AutomaticSubstitution(dataType: "Имена и фамилии", sourceValue: "Анна", substituteValue: "Мария")],
            [AutomaticSubstitution(dataType: "Имена и фамилии", sourceValue: "Анна", substituteValue: "Анна")],
            [AutomaticSubstitution(dataType: "Имена и фамилии", sourceValue: "Анна", substituteValue: "Ольга"),
             AutomaticSubstitution(dataType: "Имена и фамилии", sourceValue: "Мария", substituteValue: "Ольга")],
            [AutomaticSubstitution(dataType: " ", sourceValue: "Анна", substituteValue: "Мария")],
            [AutomaticSubstitution(dataType: "Имена и фамилии", sourceValue: "", substituteValue: "Мария")]
        ] {
            var copy = valid
            copy.automaticSubstitutions = damaged
            XCTAssertThrowsError(try copy.validate())
        }
    }

    func testListCardsIgnoresUnrelatedFoldersAndReportsDamaged() throws {
        let repo = try makeRepository()
        let healthy = makeCard()
        try repo.saveCard(healthy)
        var catalog = try repo.loadCatalog()
        try catalog.assign(healthy.id, to: AnonymizationGroup.systemID)
        try repo.saveCatalog(catalog)
        // Unrelated entries never appear as cards.
        try Disk.directory(repo.itemsURL.appendingPathComponent("not-an-uuid"))
        try Disk.directory(repo.itemsURL.appendingPathComponent(UUID().uuidString))
        var invalid: [String] = []
        let listed = repo.listCards(reportInvalid: { invalid.append($0) })
        XCTAssertEqual(listed.map(\.id), [healthy.id])
        XCTAssertTrue(invalid.isEmpty)
        try Data("broken".utf8).write(to: repo.cardURL(healthy.id))
        invalid.removeAll()
        XCTAssertTrue(repo.listCards(reportInvalid: { invalid.append($0) }).isEmpty)
        XCTAssertEqual(invalid, [healthy.id])
        // The damaged document stays on disk, untouched.
        XCTAssertEqual(try Data(contentsOf: repo.cardURL(healthy.id)), Data("broken".utf8))
    }

    // MARK: - Service journals

    func testImportJournalsRoundTripAndDeriveCardIDFromBrokenFile() throws {
        let repo = try makeRepository()
        let cardID = UUID().uuidString
        try repo.writeImportIntention(.init(cardID: cardID, targetGroupID: AnonymizationGroup.systemID))
        XCTAssertEqual(repo.pendingImportIntentions().map(\.cardID), [cardID])
        XCTAssertEqual(repo.pendingImportIntentions().first?.targetGroupID, AnonymizationGroup.systemID)
        try repo.removeImportIntention(cardID)
        XCTAssertTrue(repo.pendingImportIntentions().isEmpty)
        try repo.removeImportIntention(cardID) // removal is idempotent
        // An undecodable journal still names its card in the file name.
        try Data("broken".utf8).write(to: repo.importIntentionURL(cardID))
        let derived = repo.pendingImportIntentions()
        XCTAssertEqual(derived.map(\.cardID), [cardID])
        XCTAssertEqual(derived.first?.targetGroupID, AnonymizationGroup.systemID)
    }

    func testDeletionJournalRoundTripTreatsUndecodableAsAbsent() throws {
        let repo = try makeRepository()
        XCTAssertNil(repo.loadDeletionIntention())
        let ids = Set([UUID().uuidString, UUID().uuidString])
        try repo.writeDeletionIntention(.init(confirmedCardIDs: ids))
        XCTAssertEqual(Set(repo.loadDeletionIntention()?.confirmedCardIDs ?? []), ids)
        try repo.removeDeletionIntention()
        XCTAssertNil(repo.loadDeletionIntention())
        try repo.removeDeletionIntention() // idempotent
        try Data("broken".utf8).write(to: repo.deletionIntentionURL)
        XCTAssertNil(repo.loadDeletionIntention())
    }

    func testCardFolderStatusDistinguishesAbsentFromPresent() throws {
        let repo = try makeRepository()
        let id = UUID().uuidString
        XCTAssertEqual(repo.cardFolderStatus(id), .absent)
        try Disk.directory(repo.folder(id))
        XCTAssertEqual(repo.cardFolderStatus(id), .present)
    }
}
