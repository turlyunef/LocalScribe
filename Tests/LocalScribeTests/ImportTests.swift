import Darwin
import Synchronization
import XCTest
@testable import LocalScribeCore

final class ImportTests: XCTestCase {
    private let info = AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_f32le")

    /// Publishing a new manifest must place it exactly where a full sort of
    /// the listing (createdAt descending, id ascending) places it — the
    /// binary insertion is only an optimization of that order.
    func testPublishInsertsNewManifestsExactlyWhereFullSortPlacesThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let archive = RecordingCoordinator(repository: repo)
        let base = Date(timeIntervalSince1970: 1_000_000)
        func insert(_ offset: TimeInterval) async throws {
            var value = Manifest(sourceType: "import", title: "m", filename: "original.wav")
            value.createdAt = base.addingTimeInterval(offset)
            value.sha256 = String(repeating: "a", count: 64); value.durationMs = 1
            value.sourceComplete = true
            try await archive.createRecording(value, groupID: RecordingGroup.ungroupedID)
            let snapshot = await archive.snapshot()
            let sorted = snapshot.manifests.sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
            }
            XCTAssertEqual(snapshot.manifests.map(\.id), sorted.map(\.id))
        }
        // Seed the archive in sorted order, as `repository.list()` would.
        for offset in [0.0, -1.0, -1.0, -2.0, -3.0] { try await insert(offset) }
        // Insertions at every interesting position: newest, middle, ties on
        // createdAt (the id breaks them), second-newest and oldest.
        for offset in [0.0, -1.0, -1.0, -2.0, -3.5] { try await insert(offset) }
        // The listing itself re-sorts from disk identically after a restart.
        let snapshot = await archive.snapshot()
        XCTAssertEqual(snapshot.manifests.map(\.id), repo.list().map(\.id))
        await archive.flushIndex()
    }

    func testCoordinatorReprobesVerifiedCopyAfterSourceReplacementAndRollsBackProbeFailure() async throws {
        for failVerification in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
            let source = root.appendingPathComponent("selected.wav")
            let initial = Data("initial".utf8), replacement = Data("replacement".utf8), later = Data("later change".utf8)
            try initial.write(to: source)
            let calls = Mutex(0)
            let archive = RecordingCoordinator(repository: repo, importProbe: { url, _ in
                let index = calls.withLock { count in defer { count += 1 }; return count }
                if index == 0 {
                    XCTAssertEqual(url, source)
                    XCTAssertEqual(try Data(contentsOf: url), initial)
                    // Replace exactly after the first probe and before ImportSource.open.
                    try replacement.write(to: source)
                    return AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le")
                }
                XCTAssertNotEqual(url, source)
                XCTAssertEqual(try Data(contentsOf: url), replacement)
                try later.write(to: source) // External changes cannot affect the private copy.
                if failVerification { throw ScribeError.message("invalid replacement audio") }
                return AudioInfo(duration: 2, sampleRate: 32000, channels: 2, codec: "pcm_s16le")
            })
            do {
                let manifest = try await archive.importFile(source, tools: root)
                XCTAssertFalse(failVerification)
                XCTAssertEqual(manifest.durationMs, 2000)
                XCTAssertEqual(manifest.sampleRate, 32000); XCTAssertEqual(manifest.channels, 2)
                let saved = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
                XCTAssertEqual(try Data(contentsOf: saved), replacement)
                XCTAssertEqual(manifest.sha256, try Disk.hash(saved))
            } catch { XCTAssertTrue(failVerification) }
            XCTAssertEqual(calls.withLock { $0 }, 2)
            XCTAssertEqual(try Data(contentsOf: source), later)
            if failVerification {
                let snapshot = await archive.snapshot()
                XCTAssertTrue(snapshot.manifests.isEmpty)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("archive/recordings").path), [])
            }
            await archive.flushIndex()
        }
    }

    func testRegularFileImportCreatesIndependentOriginal() throws {
        try checkIndependentImport(link: nil)
    }

    func testAbsoluteSymlinkImportCreatesIndependentOriginal() throws {
        try checkIndependentImport(link: "absolute")
    }

    func testRelativeSymlinkImportCreatesIndependentOriginal() throws {
        try checkIndependentImport(link: "relative")
    }

    private func checkIndependentImport(link: String?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let external = root.appendingPathComponent("external")
        try Disk.directory(external)
        let target = external.appendingPathComponent("meeting.wav")
        // Cross the streaming chunk boundary; no FFmpeg or audio probing is needed.
        let bytes = Data((0..<(4 * 1024 * 1024 + 31)).map { UInt8($0 % 251) })
        try bytes.write(to: target)
        let source: URL
        if let link {
            source = external.appendingPathComponent("selected.wav")
            try fm.createSymbolicLink(atPath: source.path, withDestinationPath: link == "absolute" ? target.path : target.lastPathComponent)
        } else {
            source = target
        }
        let digest = try Disk.hash(target)
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let manifest = try repo.importFile(source, info: info)
        let original = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        XCTAssertEqual(try fm.attributesOfItem(atPath: original.path)[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(manifest.sha256, digest)
        XCTAssertTrue(manifest.sourceComplete)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertThrowsError(try repo.importFile(source, info: info)) { error in
            XCTAssertEqual((error as? DuplicateRecording)?.id, manifest.id)
        }

        // Write in place to catch hard links as well as symbolic links.
        try Data("changed external source".utf8).write(to: target)
        XCTAssertEqual(try Disk.hash(original), digest)
        try fm.removeItem(at: target)
        if link != nil { try fm.removeItem(at: source) }
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Disk.hash(original), try repo.load(manifest.id).sha256)
    }

    func testOpenedImportSourceSurvivesPathAndSymlinkReplacement() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try Disk.directory(root)
        for symlink in [false, true] {
            let target = root.appendingPathComponent("target.wav")
            let source = symlink ? root.appendingPathComponent("selected.wav") : target
            let bytes = Data("selected original".utf8)
            try bytes.write(to: target)
            if symlink { try fm.createSymbolicLink(atPath: source.path, withDestinationPath: target.path) }
            let input = try ImportSource(source)
            let digest = try input.hash()

            // Deterministically replace the pathname between hashing and copying.
            try fm.removeItem(at: source)
            if symlink {
                let other = root.appendingPathComponent("other.wav")
                try Data("replacement".utf8).write(to: other)
                try fm.createSymbolicLink(atPath: source.path, withDestinationPath: other.path)
                try fm.removeItem(at: target)
            } else {
                try Data("replacement".utf8).write(to: source)
            }
            let copy = root.appendingPathComponent("copy-\(symlink).partial")
            try input.copy(to: copy, verifying: digest)
            XCTAssertEqual(try Data(contentsOf: copy), bytes)
            XCTAssertEqual(try Disk.hash(copy), digest)
        }
    }

    func testChangedOpenFileFailsVerificationAndRemovesPartialCopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try Disk.directory(root)
        let source = root.appendingPathComponent("meeting.wav")
        try Data("initial content".utf8).write(to: source)
        let input = try ImportSource(source)
        let digest = try input.hash()
        let writer = try FileHandle(forWritingTo: source)
        try writer.truncate(atOffset: 0)
        try writer.write(contentsOf: Data("modified content".utf8))
        try writer.close()
        let partial = root.appendingPathComponent("original.wav.partial")
        XCTAssertThrowsError(try input.copy(to: partial, verifying: digest))
        XCTAssertFalse(fm.fileExists(atPath: partial.path))
    }

    func testForeignDigestFailsStreamedVerificationAndRemovesPartialCopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try Disk.directory(root)
        let source = root.appendingPathComponent("meeting.wav")
        // Cross the streaming chunk boundary so the streamed digest covers several writes.
        try Data((0..<(4 * 1024 * 1024 + 31)).map { UInt8($0 % 251) }).write(to: source)
        let input = try ImportSource(source)
        let digest = try input.hash()
        let partial = root.appendingPathComponent("original.wav.partial")
        XCTAssertThrowsError(try input.copy(to: partial, verifying: String(digest.reversed()))) { error in
            XCTAssertTrue(error is ScribeError)
        }
        XCTAssertFalse(fm.fileExists(atPath: partial.path))
        // The same bytes with the matching digest still produce an identical file.
        let copy = root.appendingPathComponent("verified.partial")
        try input.copy(to: copy, verifying: digest)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
        XCTAssertEqual(try Disk.hash(copy), digest)
    }

    func testInaccessibleSourceDoesNotPublishRecording() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses file read permissions") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try Disk.directory(root)
        let target = root.appendingPathComponent("unreadable.wav")
        try Data("private source".utf8).write(to: target)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: target.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path) }
        let link = root.appendingPathComponent("selected.wav")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        for source in [target, link] {
            XCTAssertThrowsError(try repo.importFile(source, info: info))
            try assertEmptyArchive(repo)
        }
    }

    func testMissingAndNonRegularSourcesDoNotPublishRecording() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try Disk.directory(root)
        let missing = root.appendingPathComponent("missing.wav")
        let link = root.appendingPathComponent("dangling.wav")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: missing.path)
        let fifo = root.appendingPathComponent("pipe.wav")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        for source in [missing, link, root, fifo] {
            XCTAssertThrowsError(try repo.importFile(source, info: info))
            try assertEmptyArchive(repo)
        }
    }

    private func assertEmptyArchive(_ repo: RecordingRepository, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(repo.list().isEmpty, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.root.appendingPathComponent("recordings").path), [], file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("index.json").path), file: file, line: line)
    }
}
