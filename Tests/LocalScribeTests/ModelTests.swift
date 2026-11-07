import Darwin
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
    func testCancellationDuringCopyDeletesUnverifiedFileAndKeepsVerifiedFilesForResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (profile, source) = try fixture("asr", role: .asr, root: root, contents: ["verified", String(repeating: "x", count: 9_000_000)])
        let models = root.appendingPathComponent("models"); try Disk.directory(models)
        let installation = Task {
            try await ModelInstaller().install(profile, root: models, localSource: source) { progress in
                if progress.fileIndex == 1 && progress.phase == .downloading && progress.fileBytes > 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { try await installation.value; XCTFail("Cancelled copy was published") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let partial = models.appendingPathComponent("asr.partial")
        XCTAssertEqual(try Disk.hash(partial.appendingPathComponent("file-0.bin")), profile.files[0].sha256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.appendingPathComponent("file-1.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: models.appendingPathComponent("asr").path))
        try FileManager.default.removeItem(at: source.appendingPathComponent("file-0.bin"))
        try await ModelInstaller().install(profile, root: models, localSource: source) { _ in }
        try profile.validate(at: models)
    }
    func testOversizedLocalAndFetchedRegularFilesAreRejectedBeforeReading() async throws {
        for fetched in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let models = root.appendingPathComponent("models")
            let (old, oldSource) = try fixture("asr", role: .asr, root: root, contents: ["old weights"])
            try await ModelInstaller().install(old, root: models, localSource: oldSource) { _ in }
            let (profile, source) = try fixture("asr", role: .asr, root: root, contents: ["verified", "new weights"])
            let partial = models.appendingPathComponent("asr.partial")
            try Disk.directory(partial)
            try FileManager.default.copyItem(at: source.appendingPathComponent("file-0.bin"), to: partial.appendingPathComponent("file-0.bin"))
            // Reuse is required: the verified partial's source is unavailable.
            try FileManager.default.removeItem(at: source.appendingPathComponent("file-0.bin"))
            let oversized = source.appendingPathComponent("file-1.bin")
            let writer = try FileHandle(forWritingTo: oversized)
            try writer.truncate(atOffset: 64 * 1024 * 1024); try writer.close()
            let input = try FileHandle(forReadingFrom: oversized)
            let observer = FileHandle(fileDescriptor: dup(input.fileDescriptor), closeOnDealloc: true)
            defer { try? input.close(); try? observer.close() }
            // An earlier incomplete attempt must be removed on failure too.
            try Data("incomplete".utf8).write(to: partial.appendingPathComponent("file-1.bin"))
            let log = ProgressLog()
            do {
                if fetched {
                    try await ModelInstaller().install(profile, root: models, fetch: { index, _ in
                        XCTAssertEqual(index, 1)
                        return input
                    }) { log.append($0) }
                } else {
                    try await ModelInstaller().install(profile, root: models, localSource: source) { log.append($0) }
                }
                XCTFail("Oversized regular file was installed")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Размер исходного файла")) }
            if fetched {
                XCTAssertEqual(try observer.offset(), 0, "Reject a regular FD before reading any data")
            } else {
                XCTAssertFalse(log.values.contains { $0.fileIndex == 1 && $0.fileBytes > 0 })
            }
            try old.validate(at: models)
            XCTAssertEqual(try Disk.hash(partial.appendingPathComponent("file-0.bin")), profile.files[0].sha256)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.appendingPathComponent("file-1.bin").path))
        }
    }
    func testFetchedStreamReadsAtMostOneByteBeyondCatalogSize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (profile, _) = try fixture("asr", role: .asr, root: root)
        let pipe = Pipe(), body = Data(repeating: 120, count: 1024)
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        try pipe.fileHandleForWriting.write(contentsOf: body)
        try pipe.fileHandleForWriting.close()
        let observer = FileHandle(fileDescriptor: dup(pipe.fileHandleForReading.fileDescriptor), closeOnDealloc: true)
        defer { try? observer.close() }
        let models = root.appendingPathComponent("models")
        do {
            try await ModelInstaller().install(profile, root: models, fetch: { _, _ in pipe.fileHandleForReading }) { _ in }
            XCTFail("Oversized stream was installed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("превышает размер в каталоге")) }
        let unread = try observer.readToEnd() ?? Data()
        XCTAssertEqual(unread.count, body.count - Int(profile.files[0].size) - 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: models.appendingPathComponent("asr.partial/file-0.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: models.appendingPathComponent("asr").path))
    }
    func testGrowingLocalFileCannotWriteBeyondCatalogSize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (profile, source) = try fixture("asr", role: .asr, root: root, contents: [String(repeating: "x", count: 5 * 1024 * 1024)])
        let models = root.appendingPathComponent("models"), log = ProgressLog()
        let writer = try FileHandle(forWritingTo: source.appendingPathComponent("file-0.bin"))
        defer { try? writer.close() }
        try writer.seekToEnd()
        do {
            try await ModelInstaller().install(profile, root: models, localSource: source) { event in
                log.append(event)
                if event.phase == .downloading && event.fileBytes == 4 * 1024 * 1024 {
                    try? writer.write(contentsOf: Data(repeating: 120, count: 2 * 1024 * 1024))
                }
            }
            XCTFail("Growing file was installed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("превышает размер в каталоге")) }
        XCTAssertEqual(log.values.map(\.fileBytes).max(), 4 * 1024 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: models.appendingPathComponent("asr.partial/file-0.bin").path))
    }
    func testSelectedProfilesAndTokenizerAreBoundToNewRunOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("data"))
        var profiles = try ModelRole.audioRoles.map { try fixture($0.rawValue, role: $0, root: root).0 }
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
        m.sourceComplete = true; m.sha256 = "source"
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
