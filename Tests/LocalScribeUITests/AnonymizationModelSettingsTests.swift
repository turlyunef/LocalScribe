import AppKit
import SwiftUI
import XCTest
@testable import LocalScribeCore
@testable import LocalScribe

/// Independent settings assignments, a single installation across compatible
/// tasks, package-removal confirmations, and data-type validation.
@MainActor
final class AnonymizationModelSettingsTests: XCTestCase {
    private let hardware = ModelHardware(chip: "Fixture M1", memoryBytes: 16 * 1_073_741_824, cpuCores: 8,
                                         gpuWorkingSetBytes: 12 * 1_073_741_824, appleSilicon: true, supportsMetal: true)

    private struct Fixture {
        let repository: RecordingRepository
        let model: AppModel
        let multitask: ModelProfile
        let anonymizationOnly: ModelProfile
        let anonymizationAlias: ModelProfile
        /// A second installed member of the anonymization package with its own
        /// folder (only present when the fixture was asked for it).
        let anonymizationTwin: ModelProfile?
        let heavy: ModelProfile
        let nativeSummary: ModelProfile

        /// Place the catalog-pinned files of a profile that was created absent.
        func placeOnDisk(_ profile: ModelProfile, contents: [String]) throws {
            let folder = repository.models.appendingPathComponent(profile.id)
            try Disk.directory(folder)
            for (index, content) in contents.enumerated() {
                try Data(content.utf8).write(to: folder.appendingPathComponent(profile.files[index].localPath))
            }
        }
    }

    private func makeFixture(root: URL, installMultitaskPackage: Bool = true,
                             installAnonymizationPackage: Bool = true,
                             installAnonymizationTwin: Bool = false) throws -> Fixture {
        let repo = try RecordingRepository(root: root)
        var entries: [(profile: ModelProfile, install: Bool)] = []
        func profile(_ id: String, role: ModelRole?, ram: Int = 8, working: Int = 2,
                     tasks: Set<ModelTask>? = nil, contents: [String], install: Bool) throws -> ModelProfile {
            var files: [ModelFile] = []
            for (index, content) in contents.enumerated() {
                let name = "file-\(index).bin"
                if install {
                    let folder = repo.models.appendingPathComponent(id)
                    try Disk.directory(folder)
                    let url = folder.appendingPathComponent(name)
                    try Data(content.utf8).write(to: url)
                    files.append(ModelFile(path: name, localPath: name, size: Int64(content.utf8.count), sha256: try Disk.hash(url)))
                } else {
                    // The catalog pins the true content hash; the files are
                    // simply absent until the test places them.
                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try Data(content.utf8).write(to: temp)
                    let sha = try Disk.hash(temp)
                    try? FileManager.default.removeItem(at: temp)
                    files.append(ModelFile(path: name, localPath: name, size: Int64(content.utf8.count), sha256: sha))
                }
            }
            let built = ModelProfile(id: id, repository: "test/\(id)", revision: "pinned", license: "test",
                                     files: files, role: role, recommendedMemoryGB: ram, workingMemoryGB: working,
                                     supportedTasks: tasks)
            entries.append((built, install))
            return built
        }
        _ = try profile("asr", role: .asr, contents: ["asr-1"], install: true)
        _ = try profile("diarization", role: .diarization, contents: ["dia-1"], install: true)
        let nativeSummary = try profile("summary", role: .summary, contents: ["sum-1"], install: true)
        _ = try profile("tokenizer", role: .tokenizer, ram: 0, working: 0, contents: ["tok-1"], install: true)
        let nativeDiagram = try profile("diagram", role: .diagram, contents: ["dia-a"], install: true)
        let multitask = try profile("multitask-9b", role: .diagram, tasks: Set(ModelTask.allCases),
                                 contents: ["sh-1", "sh-2"], install: installMultitaskPackage)
        let anonymizationContents = ["an-1"]
        let anonymizationOnly = try profile("anon-4b", role: nil, tasks: [.anonymization],
                                            contents: anonymizationContents, install: installAnonymizationPackage)
        let anonymizationAlias = try profile("anon-multitask-alias", role: nil, tasks: [.anonymization],
                                             contents: ["sh-1", "sh-2"], install: false)
        // A second installed member of the anonymization package: identical
        // pinned files in its own folder, so one shared package id.
        var anonymizationTwin: ModelProfile?
        if installAnonymizationTwin {
            anonymizationTwin = try profile("anon-4b-twin", role: nil, tasks: [.anonymization],
                                            contents: anonymizationContents, install: true)
        }
        let heavy = try profile("heavy-multitask", role: .summary, ram: 32, working: 24,
                                tasks: Set(ModelTask.allCases), contents: ["hv-1"], install: true)

        let catalog = ModelCatalog(models: entries.map(\.profile))
        var library = ModelLibrary()
        for entry in entries where entry.install {
            library.installed(entry.profile, catalog: catalog, hardware: hardware)
        }
        // Keep the native summary and diagram selections deterministic.
        try library.select(nativeSummary, catalog: catalog, hardware: hardware)
        try library.select(nativeDiagram, catalog: catalog, hardware: hardware)
        try library.save(at: repo.models)

        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults, catalog: catalog, hardware: hardware)
        return Fixture(repository: repo, model: model, multitask: multitask,
                       anonymizationOnly: anonymizationOnly, anonymizationAlias: anonymizationAlias,
                       anonymizationTwin: anonymizationTwin,
                       heavy: heavy, nativeSummary: nativeSummary)
    }

    private func open(_ root: URL, installMultitaskPackage: Bool = true,
                      installAnonymizationPackage: Bool = true,
                      installAnonymizationTwin: Bool = false) async throws -> Fixture {
        let fixture = try makeFixture(root: root, installMultitaskPackage: installMultitaskPackage,
                                      installAnonymizationPackage: installAnonymizationPackage,
                                      installAnonymizationTwin: installAnonymizationTwin)
        await fixture.model.verifyModels(verifyContents: false)
        return fixture
    }

    // MARK: - Draft, migration and the one-record commit

    func testDraftMirrorsSavedRecordAndAppliesTypesInOneWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root)
        let model = fixture.model
        let store = AnonymizationSettingsStore(root: fixture.repository.root)

        // The first open migrates the saved model choices and initial data types.
        let migrated = try XCTUnwrap(store.load())
        XCTAssertEqual(migrated.profileID(for: .summary), "summary")
        XCTAssertEqual(migrated.profileID(for: .diagramRecognition), "diagram")
        XCTAssertNil(migrated.profileID(for: .anonymization))
        XCTAssertEqual(migrated.dataTypes, AnonymizationSettings.initialDataTypes)

        let draft = SettingsDraft(model: model)
        XCTAssertEqual(draft.summaryModelID, "summary")
        XCTAssertEqual(draft.diagramModelID, "diagram")
        XCTAssertEqual(draft.anonymizationProfileID, "")
        XCTAssertEqual(draft.dataTypesText, AnonymizationSettings.initialDataTypes.joined(separator: "\n"))
        XCTAssertFalse(draft.hasChanges(from: model))

        draft.dataTypesText = "Имена и фамилии\n  \nВнутренние номера заявок\n\t\n  Телефоны  "
        XCTAssertTrue(draft.hasChanges(from: model))
        try model.applySettings(draft)

        // Whitespace-only lines are dropped; the order and the exact text of
        // the remaining lines are saved by one record write.
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.dataTypes, ["Имена и фамилии", "Внутренние номера заявок", "  Телефоны  "])
        XCTAssertFalse(draft.hasChanges(from: model))
        XCTAssertEqual(SettingsDraft(model: model).dataTypesText, "Имена и фамилии\nВнутренние номера заявок\n  Телефоны  ")
        await model.shutdown()
    }

    // MARK: - Per-task assignments

    func testModelInstalledForDiagramsCanBePinnedForSummariesWithoutChangingOtherTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root)
        let model = fixture.model
        let multitask = fixture.multitask
        var manifest = Manifest(sourceType: "import", title: "Встреча", filename: "a.wav")
        manifest.sourceComplete = true
        manifest.durationMs = 1000
        try fixture.repository.save(manifest)

        let draft = SettingsDraft(model: model)
        draft.summaryModelID = multitask.id
        draft.anonymizationProfileID = fixture.anonymizationOnly.id
        try model.applySettings(draft)
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .summary), multitask.id)
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .diagramRecognition), "diagram")
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .anonymization), fixture.anonymizationOnly.id)

        let runCatalog = try XCTUnwrap(model.activeCatalog)
        XCTAssertEqual(runCatalog.models.first { $0.purpose == .summary }?.id, multitask.id)
        XCTAssertEqual(runCatalog.models.first { $0.purpose == .asr }?.id, "asr")
        XCTAssertEqual(runCatalog.models.first { $0.purpose == .diarization }?.id, "diarization")
        XCTAssertEqual(runCatalog.models.first { $0.purpose == .tokenizer }?.id, "tokenizer")
        XCTAssertEqual(model.diagramProfile?.id, "diagram")

        // A new run pins the cross-task model and still resumes after the
        // summary assignment changes again.
        let archive = try XCTUnwrap(model.archive)
        _ = try await archive.beginRun(manifest.id, catalog: runCatalog)
        let nextDraft = SettingsDraft(model: model)
        nextDraft.summaryModelID = fixture.nativeSummary.id
        nextDraft.diagramModelID = multitask.id
        try model.applySettings(nextDraft)
        XCTAssertEqual(model.activeCatalog?.models.first { $0.purpose == .summary }?.id, "summary")
        XCTAssertEqual(model.diagramProfile?.id, multitask.id)
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .anonymization), fixture.anonymizationOnly.id)

        let fullCatalog = try XCTUnwrap(model.catalog)
        let recordingID = manifest.id
        let info = try await archive.perform { try $0.resumeRun(recordingID, catalog: fullCatalog) }
        XCTAssertEqual(info.modelIDs?["summary"], multitask.id)
        XCTAssertEqual(info.modelIDs?["asr"], "asr")
        XCTAssertEqual(info.modelIDs?["diarization"], "diarization")
        await model.shutdown()
    }

    func testUninstalledAssignmentIsSavedWithoutChangingTheOtherTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root, installMultitaskPackage: false)
        let model = fixture.model
        let draft = SettingsDraft(model: model)
        draft.diagramModelID = fixture.multitask.id
        try model.applySettings(draft)

        XCTAssertEqual(model.selectedTaskModel(.diagramRecognition)?.id, fixture.multitask.id)
        XCTAssertFalse(model.packageIsReady(fixture.multitask))
        XCTAssertNil(model.diagramProfile)
        XCTAssertEqual(model.activeCatalog?.models.first { $0.purpose == .summary }?.id, "summary")
        XCTAssertNil(model.selectedTaskModel(.anonymization))
        await model.shutdown()
    }

    func testIncompatibleModelChoicesLeaveSavedRecordUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root)
        let model = fixture.model
        let store = AnonymizationSettingsStore(root: fixture.repository.root)
        let before = try Data(contentsOf: store.url)

        let draft = SettingsDraft(model: model)
        draft.summaryModelID = fixture.heavy.id
        XCTAssertThrowsError(try model.applySettings(draft))
        draft.summaryModelID = fixture.nativeSummary.id
        draft.anonymizationProfileID = fixture.nativeSummary.id
        XCTAssertThrowsError(try model.applySettings(draft))

        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(model.selectedTaskModel(.summary)?.id, fixture.nativeSummary.id)
        XCTAssertNil(model.selectedTaskModel(.anonymization))
        await model.shutdown()
    }

    // MARK: - Data-type list (AC-5, AC-27)

    func testEmptyTypeListKeepsSavedRecordAndShowsMessageAtField() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root)
        let model = fixture.model
        let store = AnonymizationSettingsStore(root: fixture.repository.root)
        let before = try Data(contentsOf: store.url)

        let draft = SettingsDraft(model: model)
        draft.dataTypesText = "  \n\t\n\n"
        XCTAssertTrue(draft.hasChanges(from: model))
        XCTAssertThrowsError(try model.applySettings(draft))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(model.anonymizationSettings.dataTypes, AnonymizationSettings.initialDataTypes)

        _ = NSApplication.shared
        let (hosting, window) = host(ModelSettings(model: model, draft: draft), width: 760, height: 1500)
        defer { window.close() }
        model.settingsTab = .anonymization
        try await settle(hosting)
        XCTAssertEqual(text(try element("settings.anonymization.dataTypes.hint", in: hosting)),
                       L10n.text("Один тип данных на строку"))
        XCTAssertEqual(text(try element("settings.anonymization.dataTypes.error", in: hosting)),
                       L10n.message("Укажите хотя бы один тип данных"))
        draft.dataTypesText = "Телефоны"
        try await settle(hosting)
        XCTAssertNil(findElement("settings.anonymization.dataTypes.error", in: hosting))
        await model.shutdown()
    }

    func testNewInstallationCanBeSelectedFromAnotherTabWithoutAssigningItAutomatically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root, installMultitaskPackage: false)
        let model = fixture.model
        let multitask = fixture.multitask
        let alias = fixture.anonymizationAlias
        let store = AnonymizationSettingsStore(root: root)
        var settings = try XCTUnwrap(store.load())
        settings.setProfile(nil, for: .diagramRecognition)
        try store.save(settings)
        await model.reloadAnonymizationState()
        let draft = SettingsDraft(model: model)
        XCTAssertFalse(model.packageIsReady(multitask))
        XCTAssertFalse(model.packageIsReady(alias))
        XCTAssertNil(model.selectedTaskModel(.diagramRecognition))

        // Install the model using pre-placed files, without network.
        try fixture.placeOnDisk(multitask, contents: ["sh-1", "sh-2"])
        model.installModels([multitask])
        let deadline = Date().addingTimeInterval(5)
        while model.installing && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.packageIsReady(multitask))
        XCTAssertTrue(model.packageIsReady(alias))
        XCTAssertEqual(draft.anonymizationProfileID, "")
        XCTAssertNil(model.selectedTaskModel(.anonymization))
        XCTAssertNil(model.selectedTaskModel(.diagramRecognition))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repository.models.appendingPathComponent(alias.id).path))

        draft.anonymizationProfileID = alias.id
        try model.applySettings(draft)
        XCTAssertEqual(model.selectedTaskModel(.anonymization)?.id, alias.id)
        XCTAssertEqual(model.selectedTaskModel(.summary)?.id, "summary")
        XCTAssertNil(model.selectedTaskModel(.diagramRecognition))
        await model.shutdown()
    }

    // MARK: - Package removal

    func testRemovalListsAffectedTabsReconfirmsChangedListAndKeepsAssignments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root)
        let model = fixture.model
        let owner = fixture.multitask
        let alias = fixture.anonymizationAlias

        var dialogs: [AppModel.ModelRemovalConfirmation] = []
        model.presentRemovalDialog = { confirmation in
            dialogs.append(confirmation)
            if dialogs.count == 1 {
                // Two tabs select the same package under distinct IDs while
                // the first removal confirmation is open.
                let changed = SettingsDraft(model: model)
                changed.summaryModelID = owner.id
                changed.anonymizationProfileID = alias.id
                try? model.applySettings(changed)
                return true
            }
            return dialogs.count == 3
        }
        model.removeModel(alias)
        // First dialog: no tab uses the package. The changed list forces a
        // fresh confirmation; the cancelled re-confirmation keeps everything.
        XCTAssertEqual(dialogs.count, 2)
        XCTAssertFalse(dialogs[0].body.contains("Модель используется для следующих задач"))
        XCTAssertTrue(dialogs[1].body.contains("Состав затронутых вкладок изменился"))
        XCTAssertTrue(dialogs[1].body.contains("Обезличивание"))
        XCTAssertTrue(dialogs[1].body.contains("Итоги"))
        XCTAssertEqual(dialogs[1].confirmButton, L10n.text("Удалить модель"))
        XCTAssertTrue(model.modelLibrary.isInstalled(owner))
        XCTAssertTrue(model.packageIsReady(alias))
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .anonymization), alias.id)

        // The confirmed removal of the same package deletes the files, keeps
        // the assignment and switches readiness off (invariant 2).
        model.removeModel(alias)
        XCTAssertEqual(dialogs.count, 3)
        XCTAssertTrue(dialogs[2].body.contains("Модель используется для следующих задач"))
        XCTAssertTrue(dialogs[2].body.contains("Обезличивание"))
        let deadline = Date().addingTimeInterval(5)
        while model.modelLibrary.isInstalled(owner) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.modelLibrary.isInstalled(owner))
        XCTAssertFalse(model.packageIsReady(alias))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repository.models.appendingPathComponent(owner.id).path))
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .summary), owner.id)
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .anonymization), alias.id)
        XCTAssertEqual(model.diagramProfile?.id, "diagram")
        await model.shutdown()
    }

    /// A removal that fails mid-deletion (the first member folder is gone, the
    /// second refuses deletion) must not restore the readiness of the
    /// half-deleted package: the confirmed removal stays pending over the
    /// surviving files, and an explicit retry after the failure completes it.
    func testFailedRemovalMidDeletionKeepsReadinessOffUntilTheRetryCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = try await open(root, installAnonymizationTwin: true)
        let model = fixture.model
        let twin = try XCTUnwrap(fixture.anonymizationTwin)
        let ownerFolder = fixture.repository.models.appendingPathComponent(fixture.anonymizationOnly.id)
        let twinFolder = fixture.repository.models.appendingPathComponent(twin.id)
        defer {
            // Restore the permissions before the root cleanup: a locked twin
            // folder would survive `removeItem` and litter the temp directory.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: twinFolder.path)
            try? FileManager.default.removeItem(at: root)
        }
        let packageID = fixture.anonymizationOnly.effectivePackageID
        XCTAssertEqual(packageID, twin.effectivePackageID)

        // The twin folder refuses deletion (no write permission to unlink its
        // file), while the first member's folder is deleted normally.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: twinFolder.path)
        model.presentRemovalDialog = { _ in true }
        model.removeModel(fixture.anonymizationOnly)
        let deadline = Date().addingTimeInterval(5)
        while (model.modelLibrary.isInstalled(fixture.anonymizationOnly) || FileManager.default.fileExists(atPath: ownerFolder.path)) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.modelLibrary.isInstalled(fixture.anonymizationOnly))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerFolder.path))
        // The half-deleted package never gets its readiness back: the removal
        // stays pending and the surviving twin keeps its files for the retry.
        XCTAssertTrue(FileManager.default.fileExists(atPath: twinFolder.path))
        XCTAssertTrue(model.modelLibrary.isInstalled(twin))
        let pending = await model.packageRegistry.isRemovalPending(packageID)
        XCTAssertTrue(pending, "подтверждённое удаление сохраняется для повторной попытки")
        XCTAssertFalse(model.packageIsReady(fixture.anonymizationOnly), "готовность полуудалённого пакета не восстанавливается")
        XCTAssertFalse(model.packageIsReady(twin))
        XCTAssertFalse(model.errorHandler.messages.isEmpty, "ошибка удаления доходит до пользователя")

        // Unlocking and retrying completes the confirmed removal.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: twinFolder.path)
        model.removeModel(twin)
        let retryDeadline = Date().addingTimeInterval(5)
        while model.modelLibrary.isInstalled(twin) && Date() < retryDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.modelLibrary.isInstalled(twin))
        XCTAssertFalse(FileManager.default.fileExists(atPath: twinFolder.path))
        let stillPending = await model.packageRegistry.isRemovalPending(packageID)
        XCTAssertFalse(stillPending)
        XCTAssertFalse(model.packageIsReady(twin))
        await model.shutdown()
    }

    func testEachTabOffersCompatibleModelsAndMarksInstalledPackages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root, installAnonymizationPackage: false)
        let model = fixture.model
        let draft = SettingsDraft(model: model)
        let (hosting, window) = host(ModelSettings(model: model, draft: draft), width: 900, height: 1700)
        defer { window.close() }

        func menuItem(_ id: String) -> NSMenuItem? {
            nonPullDownPopups(in: hosting).compactMap { popup in
                popup.menu?.items.first { ($0.representedObject as? String) == id }
            }.first
        }
        func installed(_ item: NSMenuItem) -> Bool {
            (item.attributedTitle?.string ?? item.title).contains(L10n.text("Установлена"))
        }

        let tabs: [SettingsTab] = [.recordings, .diagrams, .anonymization]
        for tab in tabs {
            model.settingsTab = tab
            try await settle(hosting)
            let multitask = try XCTUnwrap(menuItem(fixture.multitask.id))
            XCTAssertTrue(multitask.isEnabled)
            XCTAssertTrue(installed(multitask))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(multitask.action), to: multitask.target, from: multitask))
        }

        XCTAssertEqual(draft.summaryModelID, fixture.multitask.id)
        XCTAssertEqual(draft.diagramModelID, fixture.multitask.id)
        XCTAssertEqual(draft.anonymizationProfileID, fixture.multitask.id)
        XCTAssertEqual(model.selectedTaskModel(.summary)?.id, "summary")
        XCTAssertEqual(model.selectedTaskModel(.diagramRecognition)?.id, "diagram")
        XCTAssertNil(model.selectedTaskModel(.anonymization))

        XCTAssertNil(findElement("settings.anonymization.mode", in: hosting))
        XCTAssertNil(menuItem(fixture.nativeSummary.id))
        let alias = try XCTUnwrap(menuItem(fixture.anonymizationAlias.id))
        XCTAssertTrue(alias.isEnabled)
        XCTAssertTrue(installed(alias))
        XCTAssertFalse(installed(try XCTUnwrap(menuItem(fixture.anonymizationOnly.id))))
        let heavy = try XCTUnwrap(menuItem(fixture.heavy.id))
        XCTAssertFalse(heavy.isEnabled)
        XCTAssertTrue(heavy.accessibilityHelp()?.contains("32 ГБ") == true)
        await model.shutdown()
    }

    // MARK: - Helpers

    private func descendants(_ element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
        return children + children.flatMap { descendants($0) }
    }

    private func subviews(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { subviews($0) }
    }

    private func findElement(_ id: String, in view: NSView) -> AnyObject? {
        if let element = descendants(view).first(where: { $0.accessibilityIdentifier?() == id }) { return element }
        for subview in subviews(view) {
            if let element = descendants(subview).first(where: { $0.accessibilityIdentifier?() == id }) { return element }
        }
        return nil
    }

    private func element(_ id: String, in view: NSView) throws -> AnyObject {
        try XCTUnwrap(findElement(id, in: view), id)
    }

    private func text(_ element: AnyObject) -> String? {
        guard let object = element as? NSObject else { return nil }
        for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { continue }
            let value = object.perform(selector)?.takeUnretainedValue()
            if let string = value as? String { return string }
            if let attributed = value as? NSAttributedString { return attributed.string }
        }
        return nil
    }

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> (NSHostingView<V>, NSWindow) {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }

    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(120))
        view.layoutSubtreeIfNeeded()
    }

    private func nonPullDownPopups(in view: NSView) -> [NSPopUpButton] {
        subviews(view).compactMap { $0 as? NSPopUpButton }.filter { !$0.pullsDown }
    }
}
