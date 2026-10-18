import Darwin
import XCTest
@testable import LocalScribeCore

final class ImportTests: XCTestCase {
    private let info = AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_f32le")

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
