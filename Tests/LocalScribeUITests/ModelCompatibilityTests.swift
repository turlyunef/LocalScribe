import AppKit
import SwiftUI
import XCTest
@testable import LocalScribeCore
@testable import LocalScribe

@MainActor
final class ModelCompatibilityTests: XCTestCase {
    private let hardware = ModelHardware(chip: "Fixture M1", memoryBytes: 16 * 1_073_741_824, cpuCores: 8,
        gpuWorkingSetBytes: 12 * 1_073_741_824, appleSilicon: true, supportsMetal: true)

    private func fixture(_ root: URL) throws -> (RecordingRepository, ModelCatalog, AppModel) {
        let repo = try RecordingRepository(root: root)
        var profiles = ModelRole.allCases.map { role in
            ModelProfile(id: role.rawValue, repository: "test/model", revision: "pinned", license: "test", files: [],
                         role: role, recommendedMemoryGB: role == .tokenizer ? 0 : 8, workingMemoryGB: role == .tokenizer ? 0 : 2,
                         recommendationRank: role == .asr || role == .summary ? 1 : nil)
        }
        profiles.append(ModelProfile(id: "summary-heavy", repository: "test/heavy", revision: "pinned", license: "test", files: [],
            role: .summary, recommendedMemoryGB: 32, workingMemoryGB: 24, recommendationRank: 2))
        for index in profiles.indices {
            let folder = repo.models.appendingPathComponent(profiles[index].id)
            try Disk.directory(folder)
            let file = folder.appendingPathComponent("weights.bin")
            try Data("fixture".utf8).write(to: file)
            profiles[index].files = [ModelFile(path: "weights.bin", localPath: "weights.bin", size: 7, sha256: try Disk.hash(file))]
        }
        let catalog = ModelCatalog(models: profiles)
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defaults.removePersistentDomain(forName: suite)
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults, catalog: catalog, hardware: hardware)
        return (repo, catalog, model)
    }
    func testDirectActionsRejectHeavyProfilesAndPreserveArchiveAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, catalog, model) = try fixture(root)
        var library = ModelLibrary()
        for profile in catalog.models.prefix(4) { library.installed(profile, catalog: catalog) }
        try library.save(at: repo.models)
        model.modelLibrary = library
        var manifest = Manifest(sourceType: "import", title: "Keep", filename: "a.wav")
        manifest.state = .waitingForModels; try repo.save(manifest)
        let manifestPath = repo.folder(manifest.id).appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestPath)
        let selectionPath = repo.models.appendingPathComponent("selection.json"), selection = try Data(contentsOf: selectionPath)
        let heavy = try XCTUnwrap(catalog.models.last)
        // Spoofing metadata in a direct caller must not bypass the authoritative catalog.
        var spoof = heavy; spoof.recommendedMemoryGB = 0; spoof.workingMemoryGB = 0
        model.installModels([spoof]); model.importModel(spoof); model.selectModel(spoof)
        XCTAssertFalse(model.installing)
        XCTAssertEqual(model.errorHandler.messages.count, 3)
        XCTAssertTrue(model.errorHandler.messages.allSatisfy { $0.contains("32 ГБ") })
        XCTAssertEqual(model.modelLibrary.selectedByRole, library.selectedByRole)
        XCTAssertEqual(try Data(contentsOf: selectionPath), selection)
        XCTAssertEqual(try Data(contentsOf: manifestPath), original)
        XCTAssertTrue(model.canManageModels)
        XCTAssertTrue(model.profilesToInstall(asrID: "asr", summaryID: heavy.id).isEmpty)
    }
    func testExistingIncompatibleSelectionRemainsInstalledAndRequiresManualChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, catalog, model) = try fixture(root)
        var library = ModelLibrary()
        for profile in catalog.models { library.installed(profile, catalog: catalog) }
        try library.save(at: repo.models)
        model.modelLibrary = library
        await model.verifyModels()
        XCTAssertFalse(model.modelsReady)
        XCTAssertNil(model.activeCatalog)
        XCTAssertEqual(model.modelLibrary.selectedByRole["summary"], "summary-heavy")
        XCTAssertTrue(model.modelsStatus.contains("Выберите совместимую"))
        XCTAssertTrue(model.modelLibrary.isInstalled(catalog.models.last!))
        XCTAssertEqual(model.initialModelID(for: .summary), "summary")
        let compatible = try XCTUnwrap(catalog.models.first { $0.id == "summary" })
        let draft = SettingsDraft(model: model)
        draft.summaryModelID = compatible.id
        draft.automaticSummaries = false
        XCTAssertTrue(draft.hasChanges(from: model))
        XCTAssertEqual(model.modelLibrary.selectedByRole["summary"], "summary-heavy")

        let selection = repo.models.appendingPathComponent("selection.json")
        let before = try Data(contentsOf: selection)
        draft.modelIDs[.asr] = "missing-profile"
        XCTAssertThrowsError(try model.applySettings(draft))
        XCTAssertEqual(try Data(contentsOf: selection), before)
        XCTAssertTrue(model.automaticSummaries)

        draft.modelIDs[.asr] = nil
        try model.applySettings(draft)
        XCTAssertTrue(model.modelsReady)
        XCTAssertEqual(model.activeCatalog?.models.first { $0.purpose == .summary }?.id, "summary")
        XCTAssertFalse(model.automaticSummaries)
        XCTAssertFalse(draft.hasChanges(from: model))
    }
    func testQwenInstallationIncludesAlignerAndSelectionDoesNotRewriteArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, base, _) = try fixture(root)
        var catalog = base
        var qwen = catalog.models[0]
        qwen.id = "qwen"; qwen.asrBackend = "qwen3"; qwen.alignerID = "aligner"; qwen.tokenizerID = "tokenizer"
        catalog.models.append(qwen)
        var aligner = qwen; aligner.id = "aligner"; aligner.role = nil; aligner.alignerID = nil
        catalog.models.append(aligner)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LocalScribeTests." + UUID().uuidString))
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults, catalog: catalog, hardware: hardware)
        let batch = model.profilesToInstall(asrID: qwen.id, summaryID: "summary")
        XCTAssertEqual(batch.map(\.id), ["tokenizer", "aligner", "qwen", "diarization", "summary"])
        for profile in catalog.models where profile.id != "summary-heavy" { model.modelLibrary.installed(profile, catalog: catalog) }
        var manifest = Manifest(sourceType: "import", title: "keep", filename: "a.wav")
        manifest.state = .queued; try repo.save(manifest)
        let path = repo.folder(manifest.id).appendingPathComponent("manifest.json"), before = try Data(contentsOf: path)
        let oldPosition = model.queuePosition(for: manifest.id)
        model.selectModel(qwen)
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertEqual(model.queuePosition(for: manifest.id), oldPosition)
        XCTAssertEqual(model.activeCatalog?.models.last?.id, "aligner")
        XCTAssertFalse(qwen.supportsClosedFragments)
    }

    func testNativeMenuUsesBoldDisabledColorAndAccessibleReasons() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, catalog, model) = try fixture(root)
        let summary = try XCTUnwrap(catalog.models.first { $0.id == "summary" })
        let light = ModelMenuOption(profile: summary, hardware: hardware, recommended: model.isRecommended(summary))
        let heavy = ModelMenuOption(profile: catalog.models.last!, hardware: hardware, recommended: false)
        let recommendedItem = light.menuItem(target: nil, action: nil), heavyItem = heavy.menuItem(target: nil, action: nil)
        let title = try XCTUnwrap(recommendedItem.attributedTitle)
        let font = try XCTUnwrap(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertTrue(title.string.contains("Максимально рекомендуется"))
        XCTAssertFalse(heavyItem.isEnabled)
        XCTAssertEqual(heavyItem.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .disabledControlTextColor)
        XCTAssertTrue(heavyItem.accessibilityHelp()?.contains("32 ГБ") == true)
        XCTAssertEqual(heavyItem.accessibilityLabel(), heavy.title)
        var selected = summary.id
        let popup = ModelPopup(options: [light, heavy], selection: Binding(get: { selected }, set: { selected = $0 }))
        let coordinator = popup.makeCoordinator()
        coordinator.choose(heavyItem)
        XCTAssertEqual(selected, summary.id)
    }
    func testOpeningSettingsDoesNotSelectOrInstallAndKeepsNativeMenuStyles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, catalog, model) = try fixture(root)
        for profile in catalog.models { model.modelLibrary.installed(profile, catalog: catalog) }
        try model.modelLibrary.save(at: repo.models)
        let path = repo.models.appendingPathComponent("selection.json"), before = try Data(contentsOf: path)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ModelSettings(model: model, draft: SettingsDraft(model: model)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let popups = descendants(host).compactMap { $0 as? NSPopUpButton }
        XCTAssertEqual(popups.count, 3)
        let summary = try XCTUnwrap(popups.first { !$0.pullsDown && $0.menu?.items.contains { ($0.representedObject as? String) == "summary-heavy" } == true })
        XCTAssertEqual(summary.selectedItem?.title, L10n.text("Модель не выбрана"))
        let compatible = try XCTUnwrap(summary.menu?.items.first { ($0.representedObject as? String) == "summary" })
        XCTAssertTrue(compatible.isEnabled)
        XCTAssertTrue(compatible.title.contains(L10n.text("Установлена")))
        let heavy = try XCTUnwrap(summary.menu?.items.first { ($0.representedObject as? String) == "summary-heavy" })
        XCTAssertFalse(heavy.isEnabled)
        let imports = try XCTUnwrap(popups.first { $0.pullsDown })
        XCTAssertFalse(try XCTUnwrap(imports.menu?.items.first { ($0.representedObject as? String) == "summary-heavy" }).isEnabled)
        XCTAssertEqual(model.modelLibrary.selectedByRole["summary"], "summary-heavy")
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertFalse(model.installing)
        XCTAssertTrue(model.canManageModels)
    }

    func testLateLibraryVerificationUpdatesDefaultWithoutOverwritingManualDownloadChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, originalCatalog, _) = try fixture(root)
        var catalog = originalCatalog
        catalog.models[catalog.models.count - 1].recommendedMemoryGB = 8
        catalog.models[catalog.models.count - 1].workingMemoryGB = 2
        let suite = "LocalScribeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults, catalog: catalog, hardware: hardware)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ModelSettings(model: model, draft: SettingsDraft(model: model)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 1300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        func popup() throws -> NSPopUpButton {
            try XCTUnwrap(descendants(host).compactMap { $0 as? NSPopUpButton }.first {
                !$0.pullsDown && $0.menu?.items.contains { ($0.representedObject as? String) == "summary-heavy" } == true
            })
        }
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try popup().selectedItem?.representedObject as? String, "summary-heavy")
        var library = ModelLibrary()
        for profile in catalog.models.prefix(4) { library.installed(profile, catalog: catalog) }
        model.modelLibrary = library
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try popup().selectedItem?.representedObject as? String, "summary")
        let menuItem = try XCTUnwrap(popup().menu?.items.first { ($0.representedObject as? String) == "summary-heavy" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(menuItem.action), to: menuItem.target, from: menuItem))
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try popup().selectedItem?.representedObject as? String, "summary-heavy")
        // A subsequent library update must not change the user's download choice.
        library.installed(catalog.models.last!, catalog: catalog)
        model.modelLibrary = library
        try await Task.sleep(for: .milliseconds(100))
        library = ModelLibrary()
        for profile in catalog.models.prefix(4) { library.installed(profile, catalog: catalog) }
        model.modelLibrary = library
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try popup().selectedItem?.representedObject as? String, "summary-heavy")
        XCTAssertEqual(model.modelLibrary.selectedByRole["summary"], "summary")
        XCTAssertFalse(model.installing)
    }

}
