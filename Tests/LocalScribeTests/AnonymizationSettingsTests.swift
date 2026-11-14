import Foundation
import XCTest
@testable import LocalScribeCore

/// Settings record, its additive migration and the rollback contract: the
/// first open creates the record from the previous summary and diagram
/// selections, later opens read the saved record, and the old version's keys
/// are never touched or rewritten.
final class AnonymizationSettingsTests: XCTestCase {
    private func makeRoot() throws -> (root: URL, modelsRoot: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(root)
        let modelsRoot = root.appendingPathComponent("models")
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root) }
        return (root, modelsRoot)
    }

    private func makeProfile(id: String, role: ModelRole?, modelsRoot: URL, contents: [String] = ["a", "b"],
                             tasks: Set<ModelTask>? = nil) throws -> ModelProfile {
        var files: [ModelFile] = []
        for (index, text) in contents.enumerated() {
            let name = "file-\(index).bin"
            let url = modelsRoot.appendingPathComponent(id).appendingPathComponent(name)
            try Disk.directory(url.deletingLastPathComponent())
            try Data(text.utf8).write(to: url)
            files.append(ModelFile(path: name, localPath: name, size: Int64(text.utf8.count), sha256: try Disk.hash(url)))
        }
        return ModelProfile(id: id, repository: "test/\(id)", revision: "rev-1", license: "test",
                            files: files, role: role, supportedTasks: tasks)
    }

    /// A catalog and a library with previous summary and diagram selections.
    private func previousState(modelsRoot: URL) throws -> (ModelCatalog, ModelLibrary, URL) {
        let summary = try makeProfile(id: "summary-9b", role: .summary, modelsRoot: modelsRoot)
        let diagram = try makeProfile(id: "diagram-vlm", role: .diagram, modelsRoot: modelsRoot)
        let catalog = ModelCatalog(models: [summary, diagram])
        var library = ModelLibrary()
        library.installed(summary, catalog: catalog)
        library.installed(diagram, catalog: catalog)
        try library.save(at: modelsRoot)
        return (catalog, library, modelsRoot.appendingPathComponent("selection.json"))
    }

    // MARK: - First open migration

    func testFirstOpenMigratesPreviousAssignmentsWithInitialValues() throws {
        let (root, modelsRoot) = try makeRoot()
        let (catalog, library, _) = try previousState(modelsRoot: modelsRoot)
        let selectionBefore = try Data(contentsOf: modelsRoot.appendingPathComponent("selection.json"))
        let store = AnonymizationSettingsStore(root: root)

        let settings = try store.loadOrMigrate(catalog: catalog, library: library)

        XCTAssertEqual(settings.profileID(for: .summary), "summary-9b")
        XCTAssertEqual(settings.profileID(for: .diagramRecognition), "diagram-vlm")
        XCTAssertNil(settings.profileID(for: .anonymization))
        XCTAssertEqual(settings.dataTypes, ["Имена и фамилии", "Телефоны", "Адреса электронной почты", "Почтовые адреса"])
        // The record is persisted and the old selection file is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertEqual(try Data(contentsOf: modelsRoot.appendingPathComponent("selection.json")), selectionBefore)
        let reloaded = try XCTUnwrap(store.load())
        XCTAssertEqual(reloaded, settings)
    }

    func testBootstrapCreatesEmptyArchiveAndMigratesSettingsTogether() throws {
        let (root, modelsRoot) = try makeRoot()
        let (catalog, library, _) = try previousState(modelsRoot: modelsRoot)
        let opened = try AnonymizationBootstrap.open(root: root, catalog: catalog, library: library)
        XCTAssertTrue(opened.settingsCreated)
        XCTAssertEqual(opened.settings.profileID(for: .summary), "summary-9b")
        // The archive is the item-2 storage: empty with the system group.
        let archiveCatalog = try opened.repository.loadCatalog()
        XCTAssertEqual(archiveCatalog.groups.map(\.id), [AnonymizationGroup.systemID])
        XCTAssertTrue(archiveCatalog.membership.isEmpty)
        // The second open reads both locations without re-migrating.
        let again = try AnonymizationBootstrap.open(root: root, catalog: catalog, library: library)
        XCTAssertFalse(again.settingsCreated)
        XCTAssertEqual(again.settings, opened.settings)
    }

    func testSelectionMissingFromCatalogLeavesSlotEmpty() throws {
        let (root, modelsRoot) = try makeRoot()
        // The old selection was made against a catalog that still listed the
        // profile; the migration catalog no longer resolves it.
        let gone = try makeProfile(id: "summary-9b", role: .summary, modelsRoot: modelsRoot)
        let oldCatalog = ModelCatalog(models: [gone])
        var library = ModelLibrary()
        library.installed(gone, catalog: oldCatalog)
        XCTAssertEqual(library.selectedByRole[ModelRole.summary.rawValue], "summary-9b")

        let currentCatalog = ModelCatalog(models: [try makeProfile(id: "diagram-vlm", role: .diagram, modelsRoot: modelsRoot)])
        let settings = try AnonymizationSettingsStore(root: root).loadOrMigrate(catalog: currentCatalog, library: library)

        XCTAssertTrue(settings.profilesByTask.isEmpty)
    }

    func testLegacySharedRecordMigratesEffectiveAssignmentsAndSavesIndependentChoices() throws {
        let (root, modelsRoot) = try makeRoot()
        let (catalog, library, _) = try previousState(modelsRoot: modelsRoot)
        let store = AnonymizationSettingsStore(root: root)
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "modelAssignmentMode": "SHARED",
            "sharedProfileID": "vision-model",
            "separateProfiles": ["SUMMARY": "summary-9b", "DIAGRAM_RECOGNITION": "diagram-vlm"],
            "dataTypes": ["Телефоны"]
        ]
        try Disk.directory(store.url.deletingLastPathComponent())
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.url)

        var loaded = try store.loadOrMigrate(catalog: catalog, library: library)
        for task in ModelTask.allCases {
            XCTAssertEqual(loaded.profileID(for: task), "vision-model")
        }
        XCTAssertEqual(loaded.dataTypes, ["Телефоны"])
        loaded.setProfile("summary-9b", for: .summary)
        try store.save(loaded)

        let saved = try store.loadOrMigrate(catalog: catalog, library: library)
        XCTAssertEqual(saved.profileID(for: .summary), "summary-9b")
        XCTAssertEqual(saved.profileID(for: .diagramRecognition), "vision-model")
        XCTAssertEqual(saved.profileID(for: .anonymization), "vision-model")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        XCTAssertEqual(json["modelAssignmentMode"] as? String, "SEPARATE")
        XCTAssertNil(json["sharedProfileID"])
    }

    func testLegacySeparateRecordUsesLatestNativeChoicesAndKeepsAnonymization() throws {
        let (root, modelsRoot) = try makeRoot()
        let (catalog, library, _) = try previousState(modelsRoot: modelsRoot)
        let store = AnonymizationSettingsStore(root: root)
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "modelAssignmentMode": "SEPARATE",
            "sharedProfileID": "vision-model",
            "separateProfiles": ["SUMMARY": "old-summary", "ANONYMIZATION": "text-model"],
            "dataTypes": ["Телефоны"]
        ]
        try Disk.directory(store.url.deletingLastPathComponent())
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.url)

        let settings = try store.loadOrMigrate(catalog: catalog, library: library)
        XCTAssertEqual(settings.profileID(for: .summary), "summary-9b")
        XCTAssertEqual(settings.profileID(for: .diagramRecognition), "diagram-vlm")
        XCTAssertEqual(settings.profileID(for: .anonymization), "text-model")
        XCTAssertEqual(try store.load(), settings)
    }

    // MARK: - Subsequent opens, rollback and return

    func testSubsequentOpenReadsSavedRecordInsteadOfRemigrating() throws {
        let (root, modelsRoot) = try makeRoot()
        let (catalog, library, _) = try previousState(modelsRoot: modelsRoot)
        let store = AnonymizationSettingsStore(root: root)
        _ = try store.loadOrMigrate(catalog: catalog, library: library)

        // The user selects an anonymization model and edits the data types.
        var saved = try XCTUnwrap(store.load())
        saved.setProfile("text-model", for: .anonymization)
        try saved.applyDataTypes(["Внутренние номера заявок", " ", "", "Имена и фамилии"])
        try store.save(saved)

        // The old version changes its own selections after a rollback.
        let other = try makeProfile(id: "summary-4b", role: .summary, modelsRoot: modelsRoot, contents: ["a", "b", "c"])
        let oldCatalog = ModelCatalog(models: catalog.models + [other])
        var oldLibrary = library
        oldLibrary.installed(other, catalog: oldCatalog)
        try oldLibrary.save(at: modelsRoot)

        // Returning to the new version re-reads the saved record.
        let reopened = try store.loadOrMigrate(catalog: catalog, library: oldLibrary)
        XCTAssertEqual(reopened, saved)
        XCTAssertEqual(reopened.dataTypes, ["Внутренние номера заявок", "Имена и фамилии"])
        XCTAssertEqual(reopened.profileID(for: .anonymization), "text-model")
        XCTAssertEqual(reopened.profileID(for: .summary), "summary-9b")
    }

    func testRollbackLeavesOldSettingsReadableAndNewRecordIntact() throws {
        let (root, modelsRoot) = try makeRoot()
        let (catalog, library, selectionURL) = try previousState(modelsRoot: modelsRoot)
        let store = AnonymizationSettingsStore(root: root)
        _ = try store.loadOrMigrate(catalog: catalog, library: library)
        let record = try Data(contentsOf: store.url)

        // The old version keeps working with selection.json only: it installs
        // and selects another summary model after the rollback.
        let other = try makeProfile(id: "summary-4b", role: .summary, modelsRoot: modelsRoot, contents: ["a", "b", "c"])
        let oldCatalog = ModelCatalog(models: catalog.models + [other])
        var oldLibrary = library
        oldLibrary.installed(other, catalog: oldCatalog)
        try oldLibrary.save(at: modelsRoot)
        let oldView = try ModelLibrary.load(at: modelsRoot, catalog: oldCatalog, verifyContents: false)
        XCTAssertEqual(oldView.selectedByRole[ModelRole.summary.rawValue], "summary-4b")

        // The new record is neither rewritten nor removed by the old version.
        XCTAssertEqual(try Data(contentsOf: store.url), record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selectionURL.path))
    }

    // MARK: - Damaged records

    func testDamagedRecordIsAnErrorAndNeverReplaced() throws {
        let (root, modelsRoot) = try makeRoot()
        let (catalog, library, _) = try previousState(modelsRoot: modelsRoot)
        let store = AnonymizationSettingsStore(root: root)
        try Disk.directory(store.url.deletingLastPathComponent())
        try Data("not json".utf8).write(to: store.url)
        let damaged = try Data(contentsOf: store.url)

        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.loadOrMigrate(catalog: catalog, library: library))
        // The damaged bytes stay on disk untouched.
        XCTAssertEqual(try Data(contentsOf: store.url), damaged)
    }

    /// A damaged record can only arrive from disk; variants are built by
    /// tampering with the JSON representation, never via public API.
    func testValidationRejectsDamagedVariants() throws {
        func damaged(_ mutate: (inout [String: Any]) -> Void) throws -> AnonymizationSettings {
            var base = AnonymizationSettings()
            base.setProfile("summary-9b", for: .summary)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
            mutate(&json)
            let settings = try JSONDecoder().decode(AnonymizationSettings.self,
                                                    from: JSONSerialization.data(withJSONObject: json))
            try settings.validate()
            return settings
        }
        XCTAssertThrowsError(try damaged { $0["schemaVersion"] = 2 })
        XCTAssertThrowsError(try damaged { $0["modelAssignmentMode"] = "SHARED" }) // shared without a profile
        XCTAssertThrowsError(try damaged { $0["sharedProfileID"] = "bad/id" })
        XCTAssertThrowsError(try damaged { $0["separateProfiles"] = ["ASR": "summary-9b"] }) // unknown task key
        XCTAssertThrowsError(try damaged { $0["separateProfiles"] = ["SUMMARY": "bad\\id"] })
        XCTAssertThrowsError(try damaged { $0["dataTypes"] = [] })
        XCTAssertThrowsError(try damaged { $0["dataTypes"] = [" ", "\n\t"] })
        XCTAssertNoThrow(try damaged { _ in () })
    }

    // MARK: - Data types

    func testSanitizeDropsWhitespaceOnlyLinesAndKeepsContentVerbatim() throws {
        let sanitized = AnonymizationSettings.sanitizeDataTypes(
            ["Имена и фамилии", "", "  ", "\t\n", "  Телефоны  ", "Почтовые адреса", " ", "Адреса\tэлектронной почты"])
        // Non-whitespace lines keep their exact content, including surrounding
        // spaces and internal tabs; the order of the remaining lines is saved.
        XCTAssertEqual(sanitized, ["Имена и фамилии", "  Телефоны  ", "Почтовые адреса", "Адреса\tэлектронной почты"])
        var settings = AnonymizationSettings()
        try settings.applyDataTypes(["Имена и фамилии", " ", "Телефоны", ""])
        XCTAssertEqual(settings.dataTypes, ["Имена и фамилии", "Телефоны"])
    }

    func testApplyDataTypesRejectsEmptyRemainderKeepingActiveRecord() throws {
        let (root, _) = try makeRoot()
        var settings = AnonymizationSettings()
        XCTAssertThrowsError(try settings.applyDataTypes(["", "  ", "\t"]))
        // The active record keeps its previous list after the rejection.
        XCTAssertEqual(settings.dataTypes, AnonymizationSettings.initialDataTypes)
        try settings.applyDataTypes([" ", "Телефоны", ""])
        XCTAssertEqual(settings.dataTypes, ["Телефоны"])
        // Save rejects an unvalidated record before any disk write.
        let store = AnonymizationSettingsStore(root: root)
        settings.dataTypes = [" ", ""]
        XCTAssertThrowsError(try store.save(settings))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }
}
