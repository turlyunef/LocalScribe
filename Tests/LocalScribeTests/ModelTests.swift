import XCTest
@testable import LocalScribeCore

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ModelInstallProgress] = []
    func append(_ event: ModelInstallProgress) { lock.lock(); defer { lock.unlock() }; events.append(event) }
    var values: [ModelInstallProgress] { lock.lock(); defer { lock.unlock() }; return events }
}

final class ModelTests: XCTestCase {
    private func fixture(_ id: String, role: ModelRole, root: URL, contents: [String] = ["weights"]) throws -> (ModelProfile, URL) {
        let source = root.appendingPathComponent("source-" + id); try Disk.directory(source)
        let files = try contents.enumerated().map { index, text in
            let name = "file-\(index).bin", data = Data(text.utf8)
            let url = source.appendingPathComponent(name); try data.write(to: url)
            return ModelFile(path: name, localPath: name, size: Int64(data.count), sha256: try Disk.hash(url))
        }
        return (ModelProfile(id: id, repository: "test/model", revision: "same-revision", license: "test", files: files, role: role), source)
    }
    func testInstallProgressCountsAllBytesAndResumesVerifiedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (profile, source) = try fixture("asr-small", role: .asr, root: root, contents: ["1234", String(repeating: "x", count: 9_000_000)])
        let models = root.appendingPathComponent("models"), partial = root.appendingPathComponent("models/asr-small.partial")
        try Disk.directory(partial)
        try FileManager.default.copyItem(at: source.appendingPathComponent("file-0.bin"), to: partial.appendingPathComponent("file-0.bin"))
        // The first source file is unavailable: a successful install proves the verified partial is reused.
        try FileManager.default.removeItem(at: source.appendingPathComponent("file-0.bin"))
        let log = ProgressLog()
        try await ModelInstaller().install(profile, root: models, localSource: source) { log.append($0) }
        let events = log.values
        XCTAssertTrue(events.contains { $0.completedFiles == 1 && $0.completedBytes == 4 })
        XCTAssertTrue(events.contains { $0.fileIndex == 1 && $0.fileBytes > 0 && $0.fileBytes < 9_000_000 })
        XCTAssertEqual(events.last?.completedFiles, 2)
        XCTAssertEqual(events.last?.downloadedBytes, 9_000_004)
        XCTAssertEqual(events.last?.fraction, 1)
        XCTAssertEqual(events.last?.phase, .complete)
        XCTAssertTrue(zip(events, events.dropFirst()).allSatisfy { $0.downloadedBytes <= $1.downloadedBytes })
        try profile.validate(at: models)
    }
    func testNetworkByteUpdatesIncludeEarlierFilesAndClampToCatalogSize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (profile, source) = try fixture("asr", role: .asr, root: root, contents: ["1234", "12345678"])
        let models = root.appendingPathComponent("models"); try Disk.directory(models)
        let log = ProgressLog()
        try await ModelInstaller().install(profile, root: models, fetch: { index, bytes in
            bytes(2); bytes(100)
            return try FileHandle(forReadingFrom: source.appendingPathComponent("file-\(index).bin"))
        }) { log.append($0) }
        XCTAssertTrue(log.values.contains { $0.fileIndex == 1 && $0.downloadedBytes == 6 && $0.totalBytes == 12 })
        XCTAssertTrue(log.values.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 })
    }
    func testNewestDefaultManualSelectionDeletionAndArchivePreservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("data"))
        var recording = Manifest(sourceType: "import", title: "Keep", filename: "a.wav")
        recording.state = .waitingForModels; try repo.save(recording)
        let manifestURL = repo.folder(recording.id).appendingPathComponent("manifest.json")
        let archiveBefore = try Data(contentsOf: manifestURL)
        let (older, olderSource) = try fixture("asr", role: .asr, root: root)
        let (newer, newerSource) = try fixture("asr-small", role: .asr, root: root)
        let catalog = ModelCatalog(models: [older, newer])
        var library = ModelLibrary()
        try await ModelInstaller().install(older, root: repo.models, localSource: olderSource) { _ in }
        library.installed(older, at: Date(timeIntervalSince1970: 1), catalog: catalog)
        try await ModelInstaller().install(newer, root: repo.models, localSource: newerSource) { _ in }
        library.installed(newer, at: Date(timeIntervalSince1970: 2), catalog: catalog)
        XCTAssertTrue(library.isSelected(newer)); XCTAssertTrue(library.isInstalled(older))
        try library.save(at: repo.models)
        library = try ModelLibrary.load(at: repo.models, catalog: catalog)
        XCTAssertTrue(library.isSelected(newer))
        try library.select(older, catalog: catalog); try library.save(at: repo.models)
        library = try ModelLibrary.load(at: repo.models, catalog: catalog)
        XCTAssertTrue(library.isSelected(older))
        try library.remove(older, at: repo.models, catalog: catalog)
        XCTAssertTrue(library.isSelected(newer)); XCTAssertFalse(library.isInstalled(older))
        try newer.validate(at: repo.models)
        XCTAssertEqual(try Data(contentsOf: manifestURL), archiveBefore)
        try library.remove(newer, at: repo.models, catalog: catalog)
        XCTAssertNil(library.activeCatalog(from: catalog)); XCTAssertTrue(library.installedAt.isEmpty)
    }
    func testLegacyFoldersMigrateAndCorruptionFallsBackToValidModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("data"))
        let (a, sourceA) = try fixture("summary", role: .summary, root: root)
        let (b, sourceB) = try fixture("summary-27b", role: .summary, root: root)
        let catalog = ModelCatalog(models: [a, b])
        try await ModelInstaller().install(a, root: repo.models, localSource: sourceA) { _ in }
        var library = try ModelLibrary.load(at: repo.models, catalog: catalog)
        XCTAssertTrue(library.isSelected(a))
        try await ModelInstaller().install(b, root: repo.models, localSource: sourceB) { _ in }
        library.installed(b, catalog: catalog); try library.save(at: repo.models)
        try Data("corrupt".utf8).write(to: repo.models.appendingPathComponent("summary-27b/file-0.bin"))
        library = try ModelLibrary.load(at: repo.models, catalog: catalog)
        XCTAssertFalse(library.isInstalled(b)); XCTAssertTrue(library.isSelected(a))
    }
    func testCancelledInstallDoesNotPublishOrReplaceExistingModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("data"))
        let (old, source) = try fixture("asr", role: .asr, root: root)
        try await ModelInstaller().install(old, root: repo.models, localSource: source) { _ in }
        let (new, _) = try fixture("asr-small", role: .asr, root: root)
        do {
            try await ModelInstaller().install(new, root: repo.models, fetch: { _, _ in throw CancellationError() }) { _ in }
            XCTFail("Cancelled model was installed")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try old.validate(at: repo.models)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.models.appendingPathComponent(new.id).path))
    }
    func testSelectedProfilesAndTokenizerAreBoundToNewRunOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("data"))
        var profiles = try ModelRole.allCases.map { try fixture($0.rawValue, role: $0, root: root).0 }
        var small = try fixture("asr-small", role: .asr, root: root).0; small.tokenizerID = "tokenizer-small"
        let tokenizer = try fixture("tokenizer-small", role: .tokenizer, root: root).0
        profiles += [small, tokenizer]
        let catalog = ModelCatalog(models: profiles)
        var library = ModelLibrary()
        for profile in profiles.prefix(4) { library.installed(profile, catalog: catalog) }
        let original = try XCTUnwrap(library.activeCatalog(from: catalog))
        library.installed(small, catalog: catalog)
        XCTAssertNil(library.activeCatalog(from: catalog))
        XCTAssertThrowsError(try library.select(small, catalog: catalog))
        library.installed(tokenizer, catalog: catalog)
        let current = try XCTUnwrap(library.activeCatalog(from: catalog))
        XCTAssertEqual(current.models.first { $0.purpose == .asr }?.id, small.id)
        XCTAssertEqual(current.models.first { $0.purpose == .tokenizer }?.id, tokenizer.id)
        XCTAssertNotEqual(original.fingerprint, current.fingerprint)
        var m = Manifest(sourceType: "import", title: "Keep", filename: "a.wav")
        let old = try repo.beginRun(&m, catalog: original)
        m.activeRunId = old.id; m.pendingRunId = nil; m.state = .completed; m.durationMs = 1000; try repo.save(m)
        let transcript = Transcript(fingerprint: old.fingerprint, diarized: true, segments: [Segment(id: "s", startMs: 0, endMs: 1000, text: "Keep this", language: "en")])
        let oldPath = repo.run(m.id, old.id).appendingPathComponent("transcript.json")
        try Disk.write(transcript, to: oldPath)
        let oldBytes = try Data(contentsOf: oldPath)
        let new = try repo.beginRun(&m, catalog: current, summaryOnly: true)
        XCTAssertEqual(try new.modelID(for: .asr), small.id)
        XCTAssertEqual(new.transcriptSourceRunID, old.id)
        let copied = try Disk.read(Transcript.self, at: repo.run(m.id, new.id).appendingPathComponent("transcript.json"))
        XCTAssertEqual(copied.fingerprint, new.fingerprint); XCTAssertEqual(copied.segments, transcript.segments)
        XCTAssertEqual(try Data(contentsOf: oldPath), oldBytes); XCTAssertEqual(m.activeRunId, old.id)
        XCTAssertEqual(try RunInfo(sourceHash: "", profileHash: "").modelID(for: .asr), "asr")
    }
    func testHardwareWarningUsesRAMAndGPUBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = try fixture("summary-heavy", role: .summary, root: root).0
        profile.recommendedMemoryGB = 32; profile.workingMemoryGB = 24
        let gib: UInt64 = 1_073_741_824
        func machine(_ ram: UInt64, _ gpu: UInt64, apple: Bool = true) -> ModelHardware {
            ModelHardware(chip: "Test Mac", memoryBytes: ram * gib, cpuCores: 8, gpuWorkingSetBytes: gpu * gib, appleSilicon: apple, supportsMetal: true)
        }
        XCTAssertTrue(try XCTUnwrap(machine(16, 10).warning(for: profile)).contains("32 ГБ"))
        XCTAssertTrue(try XCTUnwrap(machine(32, 20).warning(for: profile)).contains("Metal"))
        XCTAssertNil(machine(64, 48).warning(for: profile))
        XCTAssertNotNil(machine(64, 48, apple: false).warning(for: profile))
    }
    func testSameRepositoryRevisionDoesNotMakeAlternativeModelsEquivalent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try fixture("asr-small", role: .asr, root: root).0
        let b = try fixture("asr-medium", role: .asr, root: root).0
        XCTAssertNotEqual(ModelCatalog(models: [a]).fingerprint, ModelCatalog(models: [b]).fingerprint)
        var malicious = RunInfo(sourceHash: "", profileHash: ""); malicious.modelIDs = ["asr": "../outside"]
        XCTAssertThrowsError(try malicious.modelID(for: .asr))
    }
}
