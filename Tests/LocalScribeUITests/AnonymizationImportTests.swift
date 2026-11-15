import AppKit
import Synchronization
import UniformTypeIdentifiers
import XCTest
@testable import LocalScribe
@testable import LocalScribeCore

/// The text-import pipeline of work 6: one shared flow for the system panel,
/// Finder drops on the workspace area and explicit group drops. The group is
/// pinned before any NSItemProvider wait, candidates run sequentially, a
/// rejection or cancellation skips one file, duplicates resolve to the latest
/// surviving card, ambiguous encodings need a confirmed preview, the shown
/// limit equals the acting `AnonymizationInputLimit`, and auto-opening stops
/// on explicit navigation (AC-7–9, 30, 35–37, 49).
@MainActor
final class AnonymizationImportTests: XCTestCase {
    private let hardware = ModelHardware(chip: "Fixture M1", memoryBytes: 16 * 1_073_741_824, cpuCores: 8,
                                         gpuWorkingSetBytes: 12 * 1_073_741_824, appleSilicon: true, supportsMetal: true)

    private var root: URL = FileManager.default.temporaryDirectory

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    /// A plain model without a catalog: no anonymization profile is assigned,
    /// so the size check stays deferred (AC-37).
    private func makeModel() throws -> (RecordingRepository, AppModel) {
        let repo = try RecordingRepository(root: root)
        let model = AppModel(repository: repo, startServices: false, userDefaults: try makeDefaults())
        return (repo, model)
    }
    /// A model with two qualified anonymization profiles whose catalog limits
    /// (16 and 24 bytes) sit far below the hardware ceiling.
    private func makeModelWithProfiles() throws -> (repo: RecordingRepository, model: AppModel,
                                                    small: ModelProfile, large: ModelProfile) {
        let repo = try RecordingRepository(root: root)
        func profile(_ id: String, limit: Int64) throws -> ModelProfile {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("payload".utf8).write(to: temp)
            defer { try? FileManager.default.removeItem(at: temp) }
            let payload = Data("payload".utf8)
            let file = ModelFile(path: "weights.bin", localPath: "weights.bin",
                                 size: Int64(payload.count), sha256: try Disk.hash(temp))
            return ModelProfile(id: id, repository: "test/\(id)", revision: "pinned", license: "test",
                                files: [file], role: nil, supportedTasks: [.anonymization],
                                anonymizationInputLimitBytes: limit)
        }
        let small = try profile("anon-small", limit: 16)
        let large = try profile("anon-large", limit: 24)
        let model = AppModel(repository: repo, startServices: false, userDefaults: try makeDefaults(),
                             catalog: ModelCatalog(models: [small, large]), hardware: hardware)
        return (repo, model, small, large)
    }
    /// Assign a profile to the anonymization slot through the real settings
    /// record and refresh the model state.
    private func assign(_ profile: ModelProfile, of model: AppModel, in repo: RecordingRepository) async throws {
        let store = AnonymizationSettingsStore(root: repo.root)
        var settings = AnonymizationSettings()
        settings.setProfile(profile.id, for: .anonymization)
        try store.save(settings)
        await model.reloadAnonymizationState()
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .anonymization), profile.id)
    }

    private func writeFile(_ name: String, _ bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    /// Russian UTF-8 without a BOM is legitimately ambiguous (AC-49) and
    /// would open the confirmation window; tests that do not exercise the
    /// confirmation itself resolve it to UTF-8 through the seam.
    private func makeWorkspace(_ model: AppModel) -> AnonymizationWorkspaceModel {
        let workspace = AnonymizationWorkspaceModel(model: model)
        workspace.resolveAmbiguousEncoding = { _, _ in .utf8 }
        return workspace
    }
    private func formatted(_ bytes: UInt) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(L10n.locale))
    }
    private typealias DelayedCallbacks = Mutex<[Int: @Sendable (URL?) -> Void]>

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }

    /// Waits until `count` delayed providers have registered their callbacks
    /// and delivers one URL — helpers over the method-local callback map the
    /// registration closures borrow (the ImportQueue test pattern).
    private func waitRegistered(_ callbacks: borrowing DelayedCallbacks, count: Int) async throws {
        try await waitUntil { callbacks.withLock { $0.count == count } }
    }
    private func deliver(_ callbacks: borrowing DelayedCallbacks, index: Int, url: URL?) {
        callbacks.withLock { $0[index] }?(url)
    }

    // MARK: - Batch order, pinned group, deleted destination (criterion 36)

    func testBatchPinsGroupBeforeProvidersAndFallsBackToUngroupedWhenDeleted() async throws {
        let (_, model) = try makeModel()
        let workspace = makeWorkspace(model)
        try await model.changeTextGroups { try $0.create(name: "Пакет") }
        let destination = model.textGroups.defaultID
        let first = try writeFile("first.txt", Data("Первый текст".utf8))
        let second = try writeFile("second.md", Data("Второй текст".utf8))
        let callbacks = DelayedCallbacks([:])
        var providers: [NSItemProvider] = []
        for index in 0..<2 {
            let provider = NSItemProvider()
            provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
                callbacks.withLock {
                    $0[index] = { url in
                        if let url { completion(url as NSURL, nil) } else { completion(nil, nil) }
                    }
                }
                return Progress(totalUnitCount: 1)
            }
            providers.append(provider)
        }
        XCTAssertTrue(workspace.importProviders(providers, groupID: destination))

        try await waitRegistered(callbacks, count: 2)
        // The second file answers first, but the queue slot order — and the
        // import positions — follow the drop order of the whole set.
        deliver(callbacks, index: 1, url: second)
        try await model.changeTextGroups { try $0.remove(destination) }
        try await model.changeTextGroups { try $0.create(name: "Новая по умолчанию") }
        XCTAssertNotEqual(model.textGroups.defaultID, destination)
        deliver(callbacks, index: 0, url: first)
        await model.importQueue.waitUntilIdle()

        XCTAssertEqual(model.textCards.count, 2)
        XCTAssertEqual(model.textCards.map(\.displayName), ["first", "second"], "import positions follow the drop order")
        for card in model.textCards {
            XCTAssertEqual(model.textGroups.groupID(for: card.id), AnonymizationGroup.systemID,
                           "the remainder of the batch lands in «Без темы» after the pinned group is gone")
        }
        XCTAssertEqual(workspace.selection, model.textCards.last?.id,
                       "imported cards open sequentially until navigation")
        XCTAssertEqual(model.textCards.last?.attemptState, .waitingModel)
    }

    // MARK: - Distinct rejection reasons, batch continues (criterion 9)

    func testDistinctRejectionsSkipCandidatesAndKeepTheBatchAlive() async throws {
        let (_, model) = try makeModel()
        let workspace = makeWorkspace(model)
        let unsupported = try writeFile("notes.rtf", Data("{\\rtf заметка}".utf8))
        let undecodable = try writeFile("broken.txt", Data([0x98, 0x98]))
        let missing = root.appendingPathComponent("missing.txt")
        let empty = try writeFile("empty.txt", Data())
        let blank = try writeFile("blank.md", Data(" \n\t ".utf8))
        let valid = try writeFile("valid.txt", Data("Проходит проверку".utf8))
        let reported = model.errorHandler.messages.count
        workspace.importURLs([unsupported, undecodable, missing, empty, blank, valid])
        await model.importQueue.waitUntilIdle()

        XCTAssertEqual(model.textCards.map(\.displayName), ["valid"], "only the valid candidate creates a card")
        let messages = Array(model.errorHandler.messages.dropFirst(reported))
        XCTAssertEqual(messages.count, 5, "each rejected candidate reports exactly one reason")
        XCTAssertTrue(messages.contains { $0.contains("Неподдерживаемый формат файла") })
        XCTAssertTrue(messages.contains { $0.contains("Кодировка файла не поддерживается") })
        XCTAssertTrue(messages.contains { $0.contains("Не удалось прочитать файл") })
        XCTAssertEqual(messages.filter { $0.contains("Файл пуст или состоит из одних пробелов") }.count, 2)
        XCTAssertEqual(workspace.selection, model.textCards.first?.id)
    }

    // MARK: - Shown limit equals the acting limit; boundary (criterion 37)

    func testShownLimitMatchesActingLimitAndBoundaryRejection() async throws {
        let fixture = try makeModelWithProfiles()
        let workspace = makeWorkspace(fixture.model)
        try await assign(fixture.small, of: fixture.model, in: fixture.repo)
        let expected = AnonymizationInputLimit().limitBytes(profile: fixture.small, hardware: hardware)
        XCTAssertEqual(fixture.model.anonymizationImportLimitBytes, expected)
        XCTAssertEqual(workspace.importLimitText, L10n.text("Предел размера файла: %1$@", formatted(expected)))

        // The panel request carries the same limit text as the empty area.
        let requestBox = Mutex<AnonymizationWorkspaceModel.TextOpenPanelRequest?>(nil)
        let panelGate = Mutex<CheckedContinuation<[URL]?, Never>?>(nil)
        workspace.chooseImportFiles = { captured in
            requestBox.withLock { $0 = captured }
            return await withCheckedContinuation { continuation in
                panelGate.withLock { state in state = continuation }
            }
        }
        workspace.presentImportPanel()
        try await waitUntil { requestBox.withLock { $0 != nil } }
        let captured = try XCTUnwrap(requestBox.withLock { $0 })
        XCTAssertEqual(captured.limitText, workspace.importLimitText)
        XCTAssertEqual(captured.messageText, L10n.text("Выберите файлы TXT или Markdown. Обезличивание выполняется на этом Mac."))
        panelGate.withLock { $0 }?.resume(returning: nil)
        await fixture.model.importQueue.waitUntilIdle()

        // A file exactly at the limit passes; one byte more is rejected with
        // both sizes before any card exists.
        let exact = try writeFile("exact.txt", Data(repeating: 0x41, count: Int(expected)))
        let bigger = try writeFile("bigger.txt", Data(repeating: 0x41, count: Int(expected) + 1))
        let reported = fixture.model.errorHandler.messages.count
        workspace.importURLs([exact])
        await fixture.model.importQueue.waitUntilIdle()
        XCTAssertEqual(fixture.model.textCards.map(\.displayName), ["exact"])
        workspace.importURLs([bigger])
        await fixture.model.importQueue.waitUntilIdle()
        XCTAssertEqual(fixture.model.textCards.count, 1, "the oversized candidate is rejected entirely")
        XCTAssertEqual(Array(fixture.model.errorHandler.messages.dropFirst(reported)),
                       ["Файл больше предела для выбранной модели: размер \(formatted(expected + 1)) при пределе \(formatted(expected))."])

        // Changing the model changes the shown limit and admits the file.
        try await assign(fixture.large, of: fixture.model, in: fixture.repo)
        let largerLimit = AnonymizationInputLimit().limitBytes(profile: fixture.large, hardware: hardware)
        XCTAssertEqual(workspace.importLimitText, L10n.text("Предел размера файла: %1$@", formatted(largerLimit)))
        workspace.importURLs([bigger])
        await fixture.model.importQueue.waitUntilIdle()
        XCTAssertEqual(fixture.model.textCards.map(\.displayName).sorted(), ["bigger", "exact"])
    }

    // MARK: - Deferred check without an assignment (criteria 30, 37)

    func testWithoutAssignmentTheLimitCheckIsDeferredAndTheCardWaitsForModel() async throws {
        let (_, model) = try makeModel()
        let workspace = makeWorkspace(model)
        XCTAssertNil(model.anonymizationImportLimitBytes)
        XCTAssertEqual(workspace.importLimitText, L10n.text("Предел размера файла станет известен после выбора модели"))

        // Far above any conservative ceiling: without an assignment the file
        // still passes every import check and waits for the model.
        let big = try writeFile("big.txt", Data(repeating: 0x41, count: 2 * 1024 * 1024))
        workspace.importURLs([big])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.textCards.count, 1)
        XCTAssertEqual(model.textCards.first?.attemptState, .waitingModel)
        XCTAssertEqual(model.textCards.first?.statusTitle, L10n.text("Ожидает модель"))
    }

    /// Pre-commit card-size gate (review C7): without a model assignment the
    /// per-profile limit stays deferred, but a file whose card document
    /// (base64 of the bytes + the decoded text) can never fit under the JSON
    /// ceiling is rejected by the coordinator before the intention journal or
    /// `card.json` is written.
    func testOversizedFileWithoutAssignmentRejectedBeforePendingOrCard() async throws {
        let (_, model) = try makeModel()
        let workspace = makeWorkspace(model)
        let huge = try writeFile("huge.txt", Data(repeating: 0x41, count: 49 * 1024 * 1024))
        let reported = model.errorHandler.messages.count
        workspace.importURLs([huge])
        await model.importQueue.waitUntilIdle()
        XCTAssertTrue(model.textCards.isEmpty, "карточка не создаётся")
        let messages = Array(model.errorHandler.messages.dropFirst(reported))
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("слишком большой"), messages[0])
        let archive = try XCTUnwrap(model.textArchive)
        let directories: (items: [String], pending: [String]) = try await archive.perform { repo -> (items: [String], pending: [String]) in
            (try FileManager.default.contentsOfDirectory(atPath: repo.itemsURL.path),
             try FileManager.default.contentsOfDirectory(atPath: repo.pendingURL.path))
        }
        XCTAssertTrue(directories.items.isEmpty, "card.json не создаётся")
        XCTAssertTrue(directories.pending.isEmpty, "журнал намерений в pending/ не пишется")
    }

    // MARK: - Duplicates (criterion 35)

    func testDuplicateResolutionOpenCopyCancelAndPreviousSurvivor() async throws {
        let (_, model) = try makeModel()
        let workspace = makeWorkspace(model)
        let archive = try XCTUnwrap(model.textArchive)
        try await model.changeTextGroups { try $0.create(name: "Пакет") }
        let destination = model.textGroups.defaultID
        let payload = Data("Одинаковые исходные байты".utf8)
        let original = try writeFile("original.txt", payload)
        let copy = try writeFile("copy.txt", payload)

        workspace.importURLs([original], groupID: destination)
        await model.importQueue.waitUntilIdle()
        let first = try XCTUnwrap(model.textCards.first)
        XCTAssertEqual(model.textGroups.groupID(for: first.id), destination)

        var offered: [String] = []
        workspace.resolveDuplicateImport = { id in offered.append(id); return .cancel }
        workspace.importURLs([copy])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.textCards.count, 1, "cancel adds nothing")

        workspace.resolveDuplicateImport = { id in offered.append(id); return .openExisting }
        workspace.importURLs([copy])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.textCards.count, 1)
        XCTAssertEqual(workspace.selection, first.id, "«Открыть существующий» reveals the surviving card")

        workspace.resolveDuplicateImport = { id in offered.append(id); return .importSeparateCopy }
        workspace.importURLs([copy])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.textCards.count, 2)
        let second = try XCTUnwrap(model.textCards.last)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.importOrder, first.importOrder + 1)
        XCTAssertEqual(model.textGroups.groupID(for: second.id), destination, "the copy keeps the batch group")
        let document = try await archive.loadCard(second.id)
        XCTAssertEqual(document.source.text, "Одинаковые исходные байты")

        // The same text in another encoding is a different import (AC-35).
        var offeredEncodings = 0
        workspace.resolveAmbiguousEncoding = { _, _ in offeredEncodings += 1; return .utf8 }
        let utf16 = try writeFile("utf16.txt", Data([0xFF, 0xFE]) + "Одинаковые исходные байты".data(using: .utf16LittleEndian)!)
        workspace.importURLs([utf16])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.textCards.count, 3, "another encoding or BOM is not a duplicate")
        XCTAssertEqual(offeredEncodings, 0, "UTF-16 with a BOM needs no encoding confirmation")

        // After the newest match is deleted, the live search opens the
        // previous surviving card instead.
        _ = try await archive.prepareCardDeletion([second.id])
        try await archive.finishCardDeletion()
        await model.reloadTexts()
        workspace.resolveDuplicateImport = { id in offered.append(id); return .openExisting }
        workspace.importURLs([copy])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.textCards.count, 2)
        XCTAssertEqual(workspace.selection, first.id, "the previous surviving duplicate opens")

        // Every match deleted: the confirmed «open» imports a fresh card.
        _ = try await archive.prepareCardDeletion([first.id])
        try await archive.finishCardDeletion()
        await model.reloadTexts()
        workspace.importURLs([copy])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.textCards.count, 2, "an emptied duplicate history imports a new card")
        XCTAssertEqual(offered, [first.id, first.id, first.id, first.id])
    }

    // MARK: - Encoding confirmation (criterion 49)

    func testEncodingConfirmationAmbiguousVariantsAndCancel() async throws {
        let (_, model) = try makeModel()
        let workspace = makeWorkspace(model)
        let archive = try XCTUnwrap(model.textArchive)
        let ambiguous = Data("Проверка кодировки".utf8)
        guard case .ambiguous = TextImportDecoder.decode(ambiguous) else {
            XCTFail("fixture must be ambiguous")
            return
        }
        let mojibake = String(data: ambiguous, encoding: .windowsCP1251) ?? ""

        var asked: [[TextDecodingOption]] = []
        workspace.resolveAmbiguousEncoding = { options, _ in asked.append(options); return nil }
        let file = try writeFile("ambiguous.txt", ambiguous)
        workspace.importURLs([file])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked[0].map(\.encoding), [.utf8, .windows1251])
        XCTAssertTrue(model.textCards.isEmpty, "an unconfirmed encoding creates no card")

        workspace.resolveAmbiguousEncoding = { options, _ in asked.append(options); return .windows1251 }
        workspace.importURLs([file])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.textCards.count, 1)
        let card = try XCTUnwrap(model.textCards.first)
        let document = try await archive.loadCard(card.id)
        XCTAssertEqual(document.source.text, mojibake, "the confirmed preview text is saved")

        // Unambiguous encodings never ask: Windows-1251-only, UTF-8 with BOM,
        // UTF-16 LE/BE with BOM.
        workspace.resolveAmbiguousEncoding = { options, _ in asked.append(options); return .utf8 }
        let cp1251Only = try writeFile("cp1251.txt", XCTUnwrap("Отчёт".data(using: .windowsCP1251)))
        let utf8BOM = try writeFile("bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("С BOM".utf8))
        let utf16LE = try writeFile("le.txt", Data([0xFF, 0xFE]) + XCTUnwrap("LE".data(using: .utf16LittleEndian)))
        let utf16BE = try writeFile("be.txt", Data([0xFE, 0xFF]) + XCTUnwrap("BE".data(using: .utf16BigEndian)))
        workspace.importURLs([cp1251Only, utf8BOM, utf16LE, utf16BE])
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(asked.count, 2, "the two ambiguous imports asked; a single admissible text never asks")
        XCTAssertEqual(model.textCards.map(\.displayName), ["ambiguous", "cp1251", "bom", "le", "be"])
        var texts: [String] = []
        for summary in model.textCards { texts.append(try await archive.loadCard(summary.id).source.text) }
        XCTAssertEqual(texts[1], "Отчёт")
        XCTAssertEqual(texts[2], "С BOM")
        XCTAssertEqual(texts[3], "LE")
        XCTAssertEqual(texts[4], "BE")
    }

    // MARK: - Auto-open stops on explicit navigation (criterion 36)

    func testAutoRevealStopsAfterUserPicksACardOrLeavesTheSection() async throws {
        let (_, model) = try makeModel()
        let workspace = makeWorkspace(model)
        let pinned = try writeFile("pinned.txt", Data("Закреплённая карточка".utf8))
        workspace.importURLs([pinned])
        await model.importQueue.waitUntilIdle()
        let pinnedCard = try XCTUnwrap(model.textCards.first)
        XCTAssertEqual(workspace.selection, pinnedCard.id, "a single import opens its card")

        let first = try writeFile("auto-first.txt", Data("Первый из пакета".utf8))
        let second = try writeFile("auto-second.txt", Data("Второй из пакета".utf8))
        let callbacks = DelayedCallbacks([:])
        var providers: [NSItemProvider] = []
        for index in 0..<2 {
            let provider = NSItemProvider()
            provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
                callbacks.withLock {
                    $0[index] = { url in
                        if let url { completion(url as NSURL, nil) } else { completion(nil, nil) }
                    }
                }
                return Progress(totalUnitCount: 1)
            }
            providers.append(provider)
        }
        XCTAssertTrue(workspace.importProviders(providers, groupID: nil))
        try await waitRegistered(callbacks, count: 2)
        deliver(callbacks, index: 0, url: first)
        try await waitUntil { workspace.selection != pinnedCard.id && model.textCards.count == 2 }
        let revealedFirst = try XCTUnwrap(model.textCards.last, "the first batch candidate is imported and revealed")

        // Explicit navigation — the same hook the section switcher and the
        // sidebar rows use — stops opening the rest of the batch.
        workspace.selectSidebarTextCard(pinnedCard.id)
        XCTAssertFalse(workspace.importAutoRevealPermitted)
        deliver(callbacks, index: 1, url: second)
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.textCards.count, 3)
        XCTAssertEqual(workspace.selection, pinnedCard.id, "the rest of the batch only adds rows")
        XCTAssertEqual(workspace.sidebarRevealID, revealedFirst.id,
                       "the suppressed candidate never claims the reveal scroll target")

        // A new batch resets the permission: its successes open again.
        let fresh = try writeFile("fresh.txt", Data("Новый пакет".utf8))
        workspace.importURLs([fresh])
        await model.importQueue.waitUntilIdle()
        XCTAssertTrue(workspace.importAutoRevealPermitted)
        XCTAssertEqual(workspace.selection, model.textCards.last?.id)
    }

    func testSectionSwitchStopsAutoRevealThroughTheWorkspaceHook() async throws {
        let (_, model) = try makeModel()
        let workspace = makeWorkspace(model)
        let callbacks = DelayedCallbacks([:])
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
            callbacks.withLock {
                $0[0] = { url in
                    if let url { completion(url as NSURL, nil) } else { completion(nil, nil) }
                }
            }
            return Progress(totalUnitCount: 1)
        }
        XCTAssertTrue(workspace.importProviders([provider], groupID: nil))
        try await waitRegistered(callbacks, count: 1)
        // Leaving the texts section mid-batch is explicit navigation —
        // ContentView calls this hook from its mode onChange.
        workspace.stopImportAutoReveal()
        deliver(callbacks, index: 0, url: try writeFile("three.txt", Data("Три".utf8)))
        await model.importQueue.waitUntilIdle()
        XCTAssertEqual(model.textCards.count, 1)
        XCTAssertNil(workspace.selection, "the candidate after the section switch is added without opening")
    }
}
