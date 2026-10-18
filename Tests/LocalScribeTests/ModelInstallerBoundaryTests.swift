import XCTest
@testable import LocalScribeCore

final class ModelInstallerBoundaryTests: XCTestCase {
    private func fixture(at root: URL) throws -> (ModelProfile, URL) {
        let source = root.appendingPathComponent("source")
        try Disk.directory(source.appendingPathComponent("nested"))
        let data = Data("new model weights".utf8)
        let file = source.appendingPathComponent("nested/file.bin")
        try data.write(to: file)
        let profile = ModelProfile(id: "test", repository: "test/model", revision: "test", license: "test", files: [
            ModelFile(path: "nested/file.bin", localPath: "nested/file.bin", size: Int64(data.count), sha256: try Disk.hash(file))
        ])
        return (profile, source)
    }

    func testPreexistingSymlinksAreRejectedBeforeProgressOrFetch() async throws {
        // Include unlisted entries: otherwise a valid catalog file could hide a
        // symlink that would survive publication alongside the model.
        for boundary in ["root", "ancestor", "partial", "nested", "file", "extra", "final", "finalNested", "finalExtra", "danglingPartial", "danglingFinal"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (profile, _) = try fixture(at: root)
            let models = root.appendingPathComponent("models"), outside = root.appendingPathComponent("outside")
            try Disk.directory(outside)
            let sentinel = outside.appendingPathComponent("file.bin"), bytes = Data("external sentinel".utf8)
            try bytes.write(to: sentinel)
            var installRoot = models
            let link: URL
            switch boundary {
            case "root": link = models
            case "ancestor":
                link = models
                installRoot = models.appendingPathComponent("child/models")
            case "partial", "danglingPartial": link = models.appendingPathComponent("test.partial")
            case "nested": link = models.appendingPathComponent("test.partial/nested")
            case "file": link = models.appendingPathComponent("test.partial/nested/file.bin")
            case "extra": link = models.appendingPathComponent("test.partial/unlisted")
            case "final", "danglingFinal": link = models.appendingPathComponent("test")
            case "finalNested": link = models.appendingPathComponent("test/nested")
            default: link = models.appendingPathComponent("test/unlisted")
            }
            try Disk.directory(link.deletingLastPathComponent())
            let target = boundary.hasPrefix("dangling") ? outside.appendingPathComponent("missing") : boundary == "file" ? sentinel : outside
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            do {
                try await ModelInstaller().install(profile, root: installRoot, fetch: { _, _ in
                    XCTFail("Fetch reached through \(boundary)")
                    throw CancellationError()
                }) { _ in XCTFail("Progress reached before rejecting \(boundary)") }
                XCTFail("Accepted symlink at \(boundary)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Небезопасный путь"), "\(boundary): \(error)")
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes, boundary)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["file.bin"], boundary)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path, boundary)
        }
    }

    func testValidNestedPartialResumesWithoutItsOriginalSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (profile, source) = try fixture(at: root)
        let models = root.appendingPathComponent("models")
        let partial = models.appendingPathComponent("test.partial/nested")
        try Disk.directory(partial)
        try FileManager.default.copyItem(at: source.appendingPathComponent("nested/file.bin"), to: partial.appendingPathComponent("file.bin"))
        try FileManager.default.removeItem(at: source)
        try await ModelInstaller().install(profile, root: models, fetch: { _, _ in
            XCTFail("Verified nested partial was downloaded again")
            throw CancellationError()
        }) { _ in }
        try profile.validate(at: models)
        XCTAssertFalse(FileManager.default.fileExists(atPath: models.appendingPathComponent("test.partial").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: models.path), ["test"])
    }

    func testPathReplacementDuringFetchCannotWriteOutsideOrPublishSymlink() async throws {
        for boundary in ["partial", "nested", "file", "final"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (profile, source) = try fixture(at: root)
            let models = root.appendingPathComponent("models"), outside = root.appendingPathComponent("outside")
            try Disk.directory(outside)
            let sentinel = outside.appendingPathComponent("file.bin"), bytes = Data("external sentinel".utf8)
            try bytes.write(to: sentinel)
            let old = models.appendingPathComponent("test/old.bin")
            try Disk.directory(old.deletingLastPathComponent())
            try Data("old model".utf8).write(to: old)
            let relative: String
            switch boundary {
            case "partial": relative = "test.partial"
            case "nested": relative = "test.partial/nested"
            case "file": relative = "test.partial/nested/file.bin"
            default: relative = "test"
            }
            let replaced = models.appendingPathComponent(relative)
            do {
                try await ModelInstaller().install(profile, root: models, fetch: { _, _ in
                    try FileManager.default.moveItem(at: replaced, to: root.appendingPathComponent("parked"))
                    try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: boundary == "file" ? sentinel : outside)
                    return try FileHandle(forReadingFrom: source.appendingPathComponent("nested/file.bin"))
                }) { _ in }
                XCTFail("Published replaced \(boundary)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Небезопасный путь"), "\(boundary): \(error)")
            }
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes, boundary)
            let preserved = boundary == "final" ? root.appendingPathComponent("parked/old.bin") : old
            XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), "old model", boundary)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["file.bin"], boundary)
        }
    }

    func testReplacingRootDuringFetchKeepsAllWritesOnPinnedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (profile, source) = try fixture(at: root)
        let models = root.appendingPathComponent("models"), outside = root.appendingPathComponent("outside")
        let parked = root.appendingPathComponent("parked")
        try Disk.directory(outside)
        let sentinel = outside.appendingPathComponent("sentinel"), bytes = Data("keep".utf8)
        try bytes.write(to: sentinel)
        try await ModelInstaller().install(profile, root: models, fetch: { _, _ in
            try FileManager.default.moveItem(at: models, to: parked)
            try FileManager.default.createSymbolicLink(at: models, withDestinationURL: outside)
            return try FileHandle(forReadingFrom: source.appendingPathComponent("nested/file.bin"))
        }) { _ in }
        try profile.validate(at: parked)
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["sentinel"])
    }

    func testCatalogRejectsAmbiguousAndNULTerminatedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var (profile, _) = try fixture(at: root)
        for path in ["nested/./file.bin", "nested//file.bin", "nested/file.bin/", "nested/file.bin\0ignored"] {
            profile.files[0].localPath = path
            XCTAssertThrowsError(try profile.validatePaths(), path)
        }
        profile.id = "test\0ignored"
        XCTAssertThrowsError(try profile.validatePaths())
    }
}
