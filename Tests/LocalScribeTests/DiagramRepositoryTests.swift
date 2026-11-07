import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LocalScribeCore

final class DiagramRepositoryTests: XCTestCase {
    private func makeRepository() throws -> DiagramRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try DiagramRepository(root: root)
    }

    private func imageData(type: UTType = .png, width: Int = 4, height: Int = 4, orientation: Int? = nil) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw ScribeError.message("Не удалось создать тестовое изображение") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw ScribeError.message("Не удалось создать тестовый PNG/JPEG")
        }
        var properties: [String: Any]?
        if let orientation { properties = [kCGImagePropertyTIFFOrientation as String: orientation] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { throw ScribeError.message("Не удалось записать тестовое изображение") }
        return output as Data
    }

    private func writeExternalFixture(_ data: Data, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Disk.directory(directory)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func profile(id: String = "qwen2.5-vl-7b") -> ModelProfile {
        ModelProfile(id: id, repository: "org/diagram", revision: "rev1", license: "apache-2.0",
                     files: [ModelFile(path: "m.bin", localPath: "m.bin", size: 10, sha256: "00")], role: .diagram)
    }

    private func seed(_ repo: DiagramRepository, date: Double, state: DiagramState = .completed,
                      warnings: [String] = []) throws -> DiagramManifest {
        var manifest = DiagramManifest(title: "item", filename: "pic.png", ext: "png", uti: "public.png")
        manifest.createdAt = Date(timeIntervalSince1970: date)
        manifest.state = state
        manifest.warnings = warnings
        manifest.byteSize = 1; manifest.pixelWidth = 1; manifest.pixelHeight = 1; manifest.sha256 = "00"
        try Disk.directory(repo.folder(manifest.id))
        try Data("png".utf8).write(to: repo.originalURL(manifest))
        try repo.save(manifest)
        return manifest
    }

    private func resultData(fingerprint: String,
                            nodes: [DiagramNode] = [DiagramNode(id: "a", label: "Узел A")],
                            edges: [DiagramEdge] = []) throws -> Data {
        try JSONEncoder().encode(DiagramResult(fingerprint: fingerprint, nodes: nodes, edges: edges))
    }

    // MARK: - Import

    func testImportPNGStoresIndependentVerifiedCopyAndManifest() throws {
        let repo = try makeRepository()
        let data = try imageData(width: 6, height: 4)
        let source = try writeExternalFixture(data, name: "Схема процесса.png")
        var reservedID: String?
        let manifest = try repo.importImage(at: source) { reservedID = $0.id }
        XCTAssertEqual(reservedID, manifest.id)
        XCTAssertEqual(manifest.displayTitle, "Схема процесса")
        XCTAssertEqual(manifest.originalFilename, "Схема процесса.png")
        XCTAssertEqual(manifest.uti, "public.png")
        XCTAssertEqual(manifest.originalRelativePath, "original.png")
        XCTAssertEqual(manifest.byteSize, Int64(data.count))
        XCTAssertEqual(manifest.pixelWidth, 6)
        XCTAssertEqual(manifest.pixelHeight, 4)
        XCTAssertEqual(manifest.orientation, 1)
        XCTAssertEqual(manifest.sha256, try Disk.hash(source))
        XCTAssertEqual(manifest.state, .waitingForModels)
        let original = repo.originalURL(manifest)
        XCTAssertEqual(try Data(contentsOf: original), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.folder(manifest.id).appendingPathComponent(".partial").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.itemsURL.path), [manifest.id])
        // The archived copy is independent: replacing the source changes nothing.
        try Data("tampered".utf8).write(to: source)
        XCTAssertEqual(try Data(contentsOf: original), data)
    }

    func testImportJPEGRoundTripsOrientation() throws {
        let repo = try makeRepository()
        let data = try imageData(type: .jpeg, width: 3, height: 5, orientation: 6)
        let source = try writeExternalFixture(data, name: "photo.JPG")
        let manifest = try repo.importImage(at: source)
        XCTAssertEqual(manifest.uti, "public.jpeg")
        XCTAssertEqual(manifest.originalRelativePath, "original.jpg")
        XCTAssertEqual(manifest.pixelWidth, 3)
        XCTAssertEqual(manifest.pixelHeight, 5)
        XCTAssertEqual(manifest.orientation, 6)
        XCTAssertEqual(manifest.displayTitle, "photo")
    }

    func testDuplicateHashCreatesSeparateItems() throws {
        let repo = try makeRepository()
        let source = try writeExternalFixture(try imageData(), name: "same.png")
        let first = try repo.importImage(at: source)
        let second = try repo.importImage(at: source)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.sha256, second.sha256)
        XCTAssertEqual(repo.list().count, 2)
    }

    func testTruncatedImageIsRejectedWithoutPublishing() throws {
        let repo = try makeRepository()
        let data = try imageData()
        // Cut into the compressed data, not just the trailing IEND chunk that
        // ImageIO tolerates: half of the file must not decode completely.
        let truncated = data.prefix(max(1, data.count / 2))
        let source = try writeExternalFixture(truncated, name: "broken.png")
        XCTAssertThrowsError(try repo.importImage(at: source))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.itemsURL.path), [])
        XCTAssertEqual(try Data(contentsOf: source), truncated)
    }

    func testNonImageAndMultiPageFilesAreRejected() throws {
        let repo = try makeRepository()
        let text = try writeExternalFixture(Data("not an image".utf8), name: "note.png")
        XCTAssertThrowsError(try repo.importImage(at: text))
        // A two-page TIFF is a document, not a single diagram image.
        let tiff = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(tiff as CFMutableData, UTType.tiff.identifier as CFString, 2, nil),
              let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw ScribeError.message("Тестовое изображение") }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScribeError.message("Тестовое изображение") }
        let pages = try writeExternalFixture(tiff as Data, name: "pages.tiff")
        XCTAssertThrowsError(try repo.importImage(at: pages))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.itemsURL.path), [])
    }

    func testByteLimitRejectsOversizeFileBeforeCopying() throws {
        let repo = try makeRepository()
        let source = try writeExternalFixture(Data(repeating: 0, count: Int(DiagramRepository.maxBytes) + 1), name: "huge.png")
        XCTAssertThrowsError(try repo.importImage(at: source)) { error in
            XCTAssertEqual((error as? ScribeError)?.errorDescription?.contains("30 МБ"), true)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.itemsURL.path), [])
    }

    func testPixelLimitsRejectOversizeSidesAndMegapixels() {
        XCTAssertNoThrow(try DiagramRepository.checkPixelLimits(width: 6000, height: 4000)) // ровно 24 МП
        XCTAssertNoThrow(try DiagramRepository.checkPixelLimits(width: 8192, height: 1))
        XCTAssertThrowsError(try DiagramRepository.checkPixelLimits(width: 6000, height: 4001))
        XCTAssertThrowsError(try DiagramRepository.checkPixelLimits(width: 8193, height: 100))
        XCTAssertThrowsError(try DiagramRepository.checkPixelLimits(width: 100, height: 8193))
        XCTAssertThrowsError(try DiagramRepository.checkPixelLimits(width: 8192, height: 8192))
        // Overflow-safe product: huge sides fail on the side check, huge products on the Int64 check.
        XCTAssertThrowsError(try DiagramRepository.checkPixelLimits(width: Int.max, height: 2))
        XCTAssertThrowsError(try DiagramRepository.checkPixelLimits(width: 0, height: 5))
        XCTAssertThrowsError(try DiagramRepository.checkPixelLimits(width: -5, height: 5))
    }

    func testSymlinkSourceImportsPinnedOriginal() throws {
        let repo = try makeRepository()
        let data = try imageData()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Disk.directory(directory)
        let real = directory.appendingPathComponent("real.png")
        try data.write(to: real)
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let manifest = try repo.importImage(at: link)
        XCTAssertEqual(manifest.sha256, try Disk.hash(real))
        XCTAssertEqual(try Data(contentsOf: repo.originalURL(manifest)), data)
    }

    func testGrowthAfterOpenCopiesOnlyPinnedPrefixAndShrinkIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Disk.directory(directory)
        let source = directory.appendingPathComponent("grow.png")
        try Data("0123456789".utf8).write(to: source)
        let pinned = try PinnedImageSource(source)
        defer { pinned.close() }
        XCTAssertEqual(pinned.size, 10)
        let digest = try pinned.hash()
        let writer = try FileHandle(forWritingTo: source)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("EXTRA".utf8))
        let destination = directory.appendingPathComponent("copy.bin")
        try pinned.copy(to: destination, verifying: digest)
        XCTAssertEqual(try Data(contentsOf: destination), Data("0123456789".utf8))
        // A shrunk source no longer matches its pinned size: the copy must fail.
        try writer.truncate(atOffset: 4)
        XCTAssertThrowsError(try pinned.copy(to: directory.appendingPathComponent("copy2.bin"), verifying: digest)) { error in
            XCTAssertEqual((error as? ScribeError)?.errorDescription?.contains("изменился"), true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("copy2.bin").path))
    }

    func testCancelledImportCleansTemporaryFilesAndKeepsSource() async throws {
        let repo = try makeRepository()
        let data = try imageData()
        let source = try writeExternalFixture(data, name: "cancel.png")
        try await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try repo.importImage(at: source)) { XCTAssertTrue($0 is CancellationError) }
        }.value
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.itemsURL.path), [])
        XCTAssertEqual(try Data(contentsOf: source), data)
    }

    // MARK: - Manifests and listing

    func testSaveLoadValidationAndIDMismatch() throws {
        let repo = try makeRepository()
        let seeded = try seed(repo, date: 1)
        XCTAssertNotNil(try repo.load(seeded.id))
        XCTAssertThrowsError(try repo.load("not-a-uuid"))
        var future = seeded
        future.schemaVersion = 999
        XCTAssertThrowsError(try repo.save(future))
        var traversing = seeded
        traversing.originalRelativePath = "../../etc/passwd"
        XCTAssertThrowsError(try repo.save(traversing))
        // A manifest stored under a foreign UUID folder must not load.
        let stranger = UUID().uuidString
        var foreign = seeded
        foreign.id = stranger
        try Disk.write(foreign, to: repo.folder(seeded.id).appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try repo.load(seeded.id))
    }

    func testListSortsByDateDescThenIDAscAndReportsDamagedItems() throws {
        let repo = try makeRepository()
        let a = try seed(repo, date: 3)
        let b = try seed(repo, date: 5)
        let c = try seed(repo, date: 5)
        XCTAssertEqual(repo.list().map(\.id), [b.id, c.id].sorted() + [a.id])
        // Damaged recognizable item is reported, not hidden and not deleted.
        var invalid: [String] = []
        try Data("broken".utf8).write(to: repo.folder(a.id).appendingPathComponent("manifest.json"))
        XCTAssertEqual(Set(repo.list(reportInvalid: { invalid.append($0) }).map(\.id)), Set([b.id, c.id]))
        XCTAssertEqual(invalid, [a.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.folder(a.id).appendingPathComponent("manifest.json").path))
        // Non-UUID folders, symlinks and empty folders are ignored.
        try Disk.directory(repo.itemsURL.appendingPathComponent("not-a-uuid"))
        try FileManager.default.createSymbolicLink(at: repo.itemsURL.appendingPathComponent(UUID().uuidString), withDestinationURL: repo.folder(b.id))
        XCTAssertEqual(repo.list().count, 2)
    }

    func testRecoverInterruptsQueuedAndRecognizingOnly() throws {
        let repo = try makeRepository()
        let queued = try seed(repo, date: 1, state: .queued)
        let recognizing = try seed(repo, date: 2, state: .recognizing)
        let completed = try seed(repo, date: 3, state: .completed, warnings: ["предупреждение"])
        let cancelled = try seed(repo, date: 4, state: .cancelled)
        let recovered = try repo.recover()
        func state(_ id: String) throws -> DiagramState { try repo.load(id).state }
        XCTAssertEqual(try state(queued.id), .interrupted)
        XCTAssertEqual(try state(recognizing.id), .interrupted)
        XCTAssertEqual(try state(completed.id), .completed)
        XCTAssertEqual(try repo.load(completed.id).warnings, ["предупреждение"])
        XCTAssertEqual(try state(cancelled.id), .cancelled)
        XCTAssertEqual(recovered.map(\.id).count, 4)
    }

    func testDeleteRemovesFolderAndRejectsInvalidID() throws {
        let repo = try makeRepository()
        let seeded = try seed(repo, date: 1)
        try repo.delete(seeded.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.folder(seeded.id).path))
        XCTAssertThrowsError(try repo.delete("not-a-uuid"))
        XCTAssertThrowsError(try repo.delete(UUID().uuidString))
    }

    func testAudioArchiveRootIsNotTouchedByDiagramArchive() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let audio = try RecordingRepository(root: base.appendingPathComponent("audio"))
        let diagrams = try DiagramRepository(root: base.appendingPathComponent("diagrams"))
        let source = try writeExternalFixture(try imageData(), name: "pic.png")
        _ = try diagrams.importImage(at: source)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: audio.root.appendingPathComponent("recordings").path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.root.appendingPathComponent("items").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.root.appendingPathComponent("groups.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagrams.root.appendingPathComponent("recordings").path))
    }

    // MARK: - Runs

    func testBeginRunWritesRunAndQueuesManifest() throws {
        let repo = try makeRepository()
        let seeded = try seed(repo, date: 1)
        var manifest = seeded
        let info = try repo.beginRun(&manifest, profile: profile())
        XCTAssertEqual(info.sourceHash, seeded.sha256)
        XCTAssertEqual(info.modelID, "qwen2.5-vl-7b")
        XCTAssertEqual(info.profileHash, ModelCatalog(models: [profile()]).fingerprint)
        XCTAssertEqual(info.pipelineVersion, DiagramRunInfo.currentPipelineVersion)
        XCTAssertEqual(manifest.pendingRunId, info.id)
        XCTAssertEqual(manifest.state, .queued)
        XCTAssertNil(manifest.lastError)
        let stored = try Disk.read(DiagramRunInfo.self, at: repo.run(seeded.id, info.id).appendingPathComponent("run.json"))
        XCTAssertEqual(stored.id, info.id)
    }

    func testResumeRunChecksVersionsAndSourceHashAndPreservesRun() throws {
        let repo = try makeRepository()
        var manifest = try seed(repo, date: 1)
        let info = try repo.beginRun(&manifest, profile: profile())
        XCTAssertEqual(try repo.resumeRun(manifest).id, info.id)
        // Tampered pipeline version: the run stays on disk.
        var old = info
        old.pipelineVersion = "0.0.1-old"
        try Disk.write(old, to: repo.run(manifest.id, info.id).appendingPathComponent("run.json"))
        XCTAssertThrowsError(try repo.resumeRun(manifest)) { error in
            XCTAssertEqual((error as? ScribeError)?.errorDescription?.contains("сохран"), true)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.run(manifest.id, info.id).appendingPathComponent("run.json").path))
        // A changed original invalidates the pending run.
        var changed = try repo.load(manifest.id)
        changed.sha256 = "ff"
        try repo.save(changed)
        XCTAssertThrowsError(try repo.resumeRun(changed))
    }

    func testResultsValidatesFingerprintSchemaAndSize() throws {
        let repo = try makeRepository()
        var manifest = try seed(repo, date: 1)
        let info = try repo.beginRun(&manifest, profile: profile())
        XCTAssertThrowsError(try repo.results(manifest.id, runId: info.id))
        let nodes = [DiagramNode(id: "a", label: "Узел"), DiagramNode(id: "b", label: "Цель", uncertain: true)]
        let edges = [DiagramEdge(from: "a", to: "b", direction: .forward, label: "шаг", uncertain: true)]
        let valid = try resultData(fingerprint: info.fingerprint, nodes: nodes, edges: edges)
        try repo.publishResult(manifest.id, runId: info.id, data: valid)
        XCTAssertEqual(try repo.results(manifest.id, runId: info.id),
                       DiagramResult(fingerprint: info.fingerprint, nodes: nodes, edges: edges))
        // Wrong fingerprint and empty graphs are rejected at read time.
        try repo.publishResult(manifest.id, runId: info.id, data: try resultData(fingerprint: "bad"))
        XCTAssertThrowsError(try repo.results(manifest.id, runId: info.id))
        try repo.publishResult(manifest.id, runId: info.id, data: try resultData(fingerprint: info.fingerprint, nodes: []))
        XCTAssertThrowsError(try repo.results(manifest.id, runId: info.id))
        // Oversized or corrupt files are rejected before/independent of decoding.
        try Data(repeating: 0x20, count: DiagramResult.maxJSONBytes + 1)
            .write(to: repo.run(manifest.id, info.id).appendingPathComponent("result.json"))
        XCTAssertThrowsError(try repo.results(manifest.id, runId: info.id)) { error in
            XCTAssertEqual((error as? ScribeError)?.errorDescription?.contains("размер"), true)
        }
        try Data("{broken".utf8).write(to: repo.run(manifest.id, info.id).appendingPathComponent("result.json"))
        XCTAssertThrowsError(try repo.results(manifest.id, runId: info.id))
    }

    func testPublishResultBoundsPayloadAndRequiresExistingRun() throws {
        let repo = try makeRepository()
        var manifest = try seed(repo, date: 1)
        let info = try repo.beginRun(&manifest, profile: profile())
        XCTAssertThrowsError(try repo.publishResult(manifest.id, runId: UUID().uuidString, data: Data("{}".utf8)))
        XCTAssertThrowsError(try repo.publishResult(manifest.id, runId: info.id,
                                                    data: Data(repeating: 0x20, count: DiagramResult.maxJSONBytes + 1)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.run(manifest.id, info.id).appendingPathComponent("result.json").path))
    }
}
