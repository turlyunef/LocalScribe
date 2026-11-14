import AppKit
import SwiftUI
import XCTest
@testable import LocalScribeCore
@testable import LocalScribe

/// The settings tabs of the three model assignments (work 4): both modes and
/// the transitions, one-record draft commits, discard on cancel, the empty-slot
/// substitution after a recordings-tab install, incompatibility reasons with
/// causes, package-removal confirmations with the affected-tab list, and the
/// data-type list rules (AC-1–5, AC-27).
@MainActor
final class AnonymizationModelSettingsTests: XCTestCase {
    private let hardware = ModelHardware(chip: "Fixture M1", memoryBytes: 16 * 1_073_741_824, cpuCores: 8,
                                         gpuWorkingSetBytes: 12 * 1_073_741_824, appleSilicon: true, supportsMetal: true)

    private struct Fixture {
        let repository: RecordingRepository
        let catalog: ModelCatalog
        let model: AppModel
        let shared: ModelProfile
        let anonymizationOnly: ModelProfile
        let heavy: ModelProfile
        let nativeSummary: ModelProfile
        let nativeDiagram: ModelProfile
        let anonymizationContents: [String]

        /// Place the catalog-pinned files of a profile that was created absent.
        func placeOnDisk(_ profile: ModelProfile, contents: [String]) throws {
            let folder = repository.models.appendingPathComponent(profile.id)
            try Disk.directory(folder)
            for (index, content) in contents.enumerated() {
                try Data(content.utf8).write(to: folder.appendingPathComponent(profile.files[index].localPath))
            }
        }
    }

    private func makeFixture(root: URL, installSharedPackage: Bool = true,
                             installAnonymizationPackage: Bool = true) throws -> Fixture {
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
        let shared = try profile("shared-9b", role: .diagram, tasks: Set(ModelTask.allCases),
                                 contents: ["sh-1", "sh-2"], install: installSharedPackage)
        let anonymizationContents = ["an-1"]
        let anonymizationOnly = try profile("anon-4b", role: nil, tasks: [.anonymization],
                                            contents: anonymizationContents, install: installAnonymizationPackage)
        let heavy = try profile("heavy-shared", role: .summary, ram: 32, working: 24,
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
        return Fixture(repository: repo, catalog: catalog, model: model, shared: shared,
                       anonymizationOnly: anonymizationOnly, heavy: heavy,
                       nativeSummary: nativeSummary, nativeDiagram: nativeDiagram,
                       anonymizationContents: anonymizationContents)
    }

    private func open(_ root: URL, installSharedPackage: Bool = true,
                      installAnonymizationPackage: Bool = true) async throws -> Fixture {
        let fixture = try makeFixture(root: root, installSharedPackage: installSharedPackage,
                                       installAnonymizationPackage: installAnonymizationPackage)
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

        // The first open migrates: separate mode, library-coupled slots, an
        // empty anonymization slot and the initial data types.
        let migrated = try XCTUnwrap(store.load())
        XCTAssertEqual(migrated.modelAssignmentMode, .separate)
        XCTAssertEqual(migrated.separateProfiles[ModelTask.summary.rawValue], "summary")
        XCTAssertEqual(migrated.separateProfiles[ModelTask.diagramRecognition.rawValue], "diagram")
        XCTAssertNil(migrated.separateProfiles[ModelTask.anonymization.rawValue])
        XCTAssertEqual(migrated.dataTypes, AnonymizationSettings.initialDataTypes)

        let draft = SettingsDraft(model: model)
        XCTAssertEqual(draft.anonymizationMode, .separate)
        XCTAssertEqual(draft.sharedProfileID, "")
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
        XCTAssertEqual(saved.modelAssignmentMode, .separate)
        XCTAssertFalse(draft.hasChanges(from: model))
        XCTAssertEqual(SettingsDraft(model: model).dataTypesText, "Имена и фамилии\nВнутренние номера заявок\n  Телефоны  ")
        await model.shutdown()
    }

    // MARK: - Shared mode and the native pinning points

    func testSharedModePinsSharedProfileForNewSummariesAndDiagramsOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root)
        let model = fixture.model
        let shared = fixture.shared
        var manifest = Manifest(sourceType: "import", title: "Встреча", filename: "a.wav")
        manifest.sourceComplete = true; manifest.durationMs = 1000
        try fixture.repository.save(manifest)

        let draft = SettingsDraft(model: model)
        draft.anonymizationProfileID = fixture.anonymizationOnly.id
        draft.anonymizationMode = .shared
        draft.sharedProfileID = shared.id
        try model.applySettings(draft)
        XCTAssertEqual(model.anonymizationSettings.modelAssignmentMode, .shared)
        XCTAssertEqual(model.anonymizationSettings.sharedProfileID, shared.id)
        // The last separate anonymization assignment survives the shared mode
        // and the shared assignment is effective for the task (AC-4).
        XCTAssertEqual(model.anonymizationSettings.separateProfiles[ModelTask.anonymization.rawValue],
                       fixture.anonymizationOnly.id)
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .anonymization), shared.id)

        // New audio runs pin the shared profile for summaries through the
        // native pinning points; ASR and diarization keep their own selections.
        let runCatalog = try XCTUnwrap(model.activeCatalog)
        XCTAssertEqual(runCatalog.models.first { $0.purpose == .summary }?.id, shared.id)
        XCTAssertEqual(runCatalog.models.first { $0.purpose == .asr }?.id, "asr")
        XCTAssertEqual(runCatalog.models.first { $0.purpose == .diarization }?.id, "diarization")
        XCTAssertEqual(runCatalog.models.first { $0.purpose == .tokenizer }?.id, "tokenizer")
        XCTAssertEqual(model.diagramProfile?.id, shared.id)
        XCTAssertEqual(model.modelLibrary.selectedByRole[ModelRole.summary.rawValue], "summary")
        XCTAssertEqual(model.modelLibrary.selectedByRole[ModelRole.asr.rawValue], "asr")
        XCTAssertEqual(model.modelLibrary.selectedByRole[ModelRole.diagram.rawValue], "diagram")

        // A real run pins the shared profile and resumes against the full
        // catalog with the relaxed summary-slot resolution.
        _ = try await model.archive!.beginRun(manifest.id, catalog: runCatalog)
        let fullCatalog = model.catalog!
        let recordingID = manifest.id
        let info = try await model.archive!.perform { try $0.resumeRun(recordingID, catalog: fullCatalog) }
        XCTAssertEqual(info.modelIDs?["summary"], shared.id)
        XCTAssertEqual(info.modelIDs?["asr"], "asr")
        XCTAssertEqual(info.modelIDs?["diarization"], "diarization")

        // Returning to the separate mode restores the last saved assignments.
        let separate = SettingsDraft(model: model)
        separate.anonymizationMode = .separate
        try model.applySettings(separate)
        XCTAssertEqual(model.anonymizationSettings.modelAssignmentMode, .separate)
        XCTAssertEqual(model.activeCatalog?.models.first { $0.purpose == .summary }?.id, "summary")
        XCTAssertEqual(model.diagramProfile?.id, "diagram")
        XCTAssertEqual(model.anonymizationSettings.separateProfiles[ModelTask.summary.rawValue], "summary")
        XCTAssertEqual(model.anonymizationSettings.separateProfiles[ModelTask.diagramRecognition.rawValue], "diagram")
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .anonymization), fixture.anonymizationOnly.id)
        await model.shutdown()
    }

    func testSharedModeWithoutVerifiedPackageKeepsNativeAssignments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root, installSharedPackage: false)
        let model = fixture.model
        let draft = SettingsDraft(model: model)
        draft.anonymizationMode = .shared
        draft.sharedProfileID = fixture.shared.id
        try model.applySettings(draft)
        // The assignment is saved, but its jobs are not ready: the native
        // assignments stay effective until the package is verified.
        XCTAssertEqual(model.anonymizationSettings.sharedProfileID, fixture.shared.id)
        XCTAssertNil(model.readySharedProfile())
        XCTAssertFalse(model.packageIsReady(fixture.shared))
        XCTAssertEqual(model.activeCatalog?.models.first { $0.purpose == .summary }?.id, "summary")
        XCTAssertEqual(model.diagramProfile?.id, "diagram")
        await model.shutdown()
    }

    // MARK: - Incompatibility

    func testIncompatibleProfilesRejectedWithReasonsAndRecordUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root)
        let model = fixture.model
        let store = AnonymizationSettingsStore(root: fixture.repository.root)
        let before = try Data(contentsOf: store.url)

        // Menu options: a Mac-incompatible profile and a task-incomplete
        // profile stay disabled with the combined reason.
        func sharedOption(_ profile: ModelProfile) -> ModelMenuOption {
            let reasons = ModelTaskSupport.sharedCompatibility(profile: profile, hardware: hardware).reasons
            return ModelMenuOption(profile: profile,
                                   reason: reasons.isEmpty ? nil : reasons.map(L10n.message).joined(separator: "; "),
                                   recommended: false)
        }
        XCTAssertFalse(sharedOption(fixture.heavy).enabled)
        XCTAssertTrue(sharedOption(fixture.heavy).reason?.contains("32 ГБ") == true)
        XCTAssertFalse(sharedOption(fixture.nativeSummary).enabled)
        XCTAssertTrue(sharedOption(fixture.nativeSummary).reason?
            .contains(L10n.message("Общий профиль должен поддерживать итоги, схемы и обезличивание")) == true)
        XCTAssertTrue(sharedOption(fixture.shared).enabled)
        let taskReasons = ModelTaskSupport.compatibility(task: .anonymization, profile: fixture.nativeSummary, hardware: hardware).reasons
        XCTAssertEqual(taskReasons.first, "Модель не поддерживает эту задачу")

        // «ОК» rejects an incompatible shared profile and an incompatible task
        // slot; the saved record keeps its bytes and the mode.
        var draft = SettingsDraft(model: model)
        draft.anonymizationMode = .shared
        draft.sharedProfileID = fixture.heavy.id
        XCTAssertThrowsError(try model.applySettings(draft))
        draft.sharedProfileID = ""
        XCTAssertThrowsError(try model.applySettings(draft))
        draft.anonymizationMode = .separate
        draft.anonymizationProfileID = fixture.nativeSummary.id
        XCTAssertThrowsError(try model.applySettings(draft))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(model.anonymizationSettings.modelAssignmentMode, .separate)
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

    // MARK: - Empty-slot substitution after a recordings-tab install

    func testRecordingsInstallFillsOnlyEmptyAnonymizationSlotOfDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root, installAnonymizationPackage: false)
        let model = fixture.model
        let anon = fixture.anonymizationOnly
        XCTAssertFalse(model.packageIsReady(anon))

        // An existing choice is never overwritten by the substitution.
        let kept = SettingsDraft(model: model)
        kept.anonymizationProfileID = fixture.shared.id
        _ = NSApplication.shared
        let (hosting, window) = host(ModelSettings(model: model, draft: kept), width: 760, height: 1500)
        defer { window.close() }
        model.settingsTab = .recordings
        try await settle(hosting)

        // The recordings-tab download (files fully pre-placed, offline install).
        try fixture.placeOnDisk(anon, contents: fixture.anonymizationContents)
        model.installModels([anon], mayFillAnonymizationSlot: true)
        while model.installing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.modelLibrary.isInstalled(anon))
        XCTAssertTrue(model.packageIsReady(anon))
        XCTAssertEqual(model.installedAnonymizationCandidateID, anon.id)
        try await settle(hosting)
        XCTAssertEqual(kept.anonymizationProfileID, fixture.shared.id)
        XCTAssertNil(model.anonymizationSettings.profileID(for: .anonymization))

        // A cancelled draft discards the assignment; the package stays ready.
        XCTAssertEqual(SettingsDraft(model: model).anonymizationProfileID, "")

        // The fill enters a fresh empty draft on the next install event and is
        // applied by «ОК».
        let filled = SettingsDraft(model: model)
        XCTAssertEqual(filled.anonymizationProfileID, "")
        let (fillHosting, fillWindow) = host(ModelSettings(model: model, draft: filled), width: 760, height: 1500)
        defer { fillWindow.close() }
        try await settle(fillHosting)
        model.installModels([fixture.shared], mayFillAnonymizationSlot: true)
        while model.installing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.installedAnonymizationCandidateID, fixture.shared.id)
        try await settle(fillHosting)
        XCTAssertEqual(filled.anonymizationProfileID, fixture.shared.id)
        try model.applySettings(filled)
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .anonymization), fixture.shared.id)
        XCTAssertTrue(model.packageIsReady(anon))
        await model.shutdown()
    }

    // MARK: - Package removal

    func testRemovalListsAffectedTabsReconfirmsChangedListAndKeepsAssignments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root)
        let model = fixture.model
        let anon = fixture.anonymizationOnly

        var dialogs: [AppModel.ModelRemovalConfirmation] = []
        model.presentRemovalDialog = { confirmation in
            dialogs.append(confirmation)
            if dialogs.count == 1 {
                // The affected list changes under the first confirmation: the
                // still-empty slot gets assigned inside the dialog.
                var changed = SettingsDraft(model: model)
                changed.anonymizationProfileID = anon.id
                try? model.applySettings(changed)
                return true
            }
            return dialogs.count == 3
        }
        model.removeModel(anon)
        // First dialog: no tab uses the package. The changed list forces a
        // fresh confirmation; the cancelled re-confirmation keeps everything.
        XCTAssertEqual(dialogs.count, 2)
        XCTAssertFalse(dialogs[0].body.contains("Комплект используют вкладки"))
        XCTAssertTrue(dialogs[1].body.contains("Состав затронутых вкладок изменился"))
        XCTAssertTrue(dialogs[1].body.contains("Обезличивание"))
        XCTAssertEqual(dialogs[1].confirmButton, L10n.text("Удалить комплект"))
        XCTAssertTrue(model.modelLibrary.isInstalled(anon))
        XCTAssertTrue(model.packageIsReady(anon))
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .anonymization), anon.id)

        // The confirmed removal of the same package deletes the files, keeps
        // the assignment and switches readiness off (invariant 2).
        model.removeModel(anon)
        XCTAssertEqual(dialogs.count, 3)
        XCTAssertTrue(dialogs[2].body.contains("Комплект используют вкладки"))
        XCTAssertTrue(dialogs[2].body.contains("Обезличивание"))
        let deadline = Date().addingTimeInterval(5)
        while model.modelLibrary.isInstalled(anon) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.modelLibrary.isInstalled(anon))
        XCTAssertFalse(model.packageIsReady(anon))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repository.models.appendingPathComponent(anon.id).path))
        XCTAssertEqual(model.anonymizationSettings.profileID(for: .anonymization), anon.id)
        await model.shutdown()
    }

    // MARK: - Tab layout and the shared links (AC-1, AC-2, AC-3)

    func testTabsShowModeBlocksSharedLinksAndDisabledReasons() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await open(root)
        let model = fixture.model
        let draft = SettingsDraft(model: model)
        draft.anonymizationMode = .shared
        draft.sharedProfileID = fixture.shared.id
        _ = NSApplication.shared
        let (hosting, window) = host(ModelSettings(model: model, draft: draft), width: 900, height: 1700)
        defer { window.close() }
        try await settle(hosting)

        // Recordings tab: the shared-model link replaces the summary picker.
        XCTAssertNotNil(findElement("settings.models.sharedSummary", in: hosting))
        XCTAssertTrue(try element("settings.models.sharedSummary.configureShared", in: hosting).accessibilityPerformPress?() ?? false)
        try await settle(hosting)
        XCTAssertEqual(model.settingsTab, .anonymization)
        XCTAssertEqual(nonPullDownPopups(in: hosting).count, 1)

        // Anonymization tab: the mode switch, the shared picker with disabled
        // incompatible entries and the installation state.
        XCTAssertNotNil(findElement("settings.anonymization.mode", in: hosting))
        XCTAssertNotNil(findElement("settings.anonymization.sharedProfile", in: hosting))
        XCTAssertNotNil(findElement("settings.anonymization.ready.\(fixture.shared.id)", in: hosting))
        XCTAssertNil(findElement("settings.anonymization.profile", in: hosting))
        let sharedPopup = try XCTUnwrap(nonPullDownPopups(in: hosting).last)
        let heavyItem = try XCTUnwrap(sharedPopup.menu?.items.first { ($0.representedObject as? String) == fixture.heavy.id })
        XCTAssertFalse(heavyItem.isEnabled)
        XCTAssertTrue(heavyItem.accessibilityHelp()?.contains("32 ГБ") == true)

        // Diagrams tab: the shared-model link instead of the separate status.
        model.settingsTab = .diagrams
        try await settle(hosting)
        XCTAssertNotNil(findElement("settings.diagramModels.shared", in: hosting))
        XCTAssertNotNil(findElement("settings.diagramModels.shared.configureShared", in: hosting))
        XCTAssertNil(findElement("settings.diagramModels.status", in: hosting))

        // Separate mode: the slot picker appears, the shared links disappear
        // and the summary picker returns.
        draft.anonymizationMode = .separate
        model.settingsTab = .anonymization
        try await settle(hosting)
        XCTAssertNotNil(findElement("settings.anonymization.profile", in: hosting))
        XCTAssertNil(findElement("settings.anonymization.sharedProfile", in: hosting))
        model.settingsTab = .recordings
        try await settle(hosting)
        XCTAssertNil(findElement("settings.models.sharedSummary", in: hosting))
        XCTAssertEqual(nonPullDownPopups(in: hosting).count, 2)
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
