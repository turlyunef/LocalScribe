import Foundation
import XCTest
@testable import LocalScribeCore

/// Regression tests for the «silent bootstrap paralysis» cluster: an existing
/// but unreadable archive directory must be reported upward instead of looking
/// like an honestly empty archive, and the derived recording index is never
/// replaced with the empty listing of a directory that could not be read.
/// Unreadability is simulated with chmod 000 and always restored in defer.
final class ArchiveUnreadableTests: XCTestCase {
    private func deny(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }
    private func allow(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    private func completed(_ repo: RecordingRepository) throws -> Manifest {
        var m = Manifest(sourceType: "microphone", title: "Unreadable archive", filename: "original.caf")
        m.sourceComplete = true; m.sha256 = String(repeating: "a", count: 64); m.durationMs = 1000
        try repo.save(m); return m
    }

    // MARK: - Recordings repository

    func testUnreadableRecordingsDirectoryIsReportedAndKeepsPreviousIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let manifest = try completed(repo)
        try repo.writeIndex([manifest])
        try deny(root.appendingPathComponent("recordings"))
        defer { try? allow(root.appendingPathComponent("recordings")) }

        var unreadable: [Error] = []
        XCTAssertTrue(repo.list(reportInvalid: { _ in }, reportUnreadable: { unreadable.append($0) }).isEmpty)
        XCTAssertEqual(unreadable.count, 1, "an existing but unreadable directory is an error, not «no recordings»")

        // recover must not replace the previous index with an empty listing.
        _ = try repo.recover(reportInvalid: { _ in }, reportUnreadable: { _ in })
        XCTAssertEqual(try Disk.read([Manifest].self, at: root.appendingPathComponent("index.json")).map(\.id), [manifest.id])

        // Once readable again, listings and index writes resume without reports.
        try allow(root.appendingPathComponent("recordings"))
        unreadable.removeAll()
        XCTAssertEqual(repo.list(reportInvalid: { _ in }, reportUnreadable: { unreadable.append($0) }).map(\.id), [manifest.id])
        XCTAssertTrue(unreadable.isEmpty)
    }

    func testMissingRecordingsDirectoryIsAnHonestEmptyArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("recordings"))
        var unreadable: [Error] = []
        XCTAssertTrue(repo.list(reportInvalid: { _ in }, reportUnreadable: { unreadable.append($0) }).isEmpty)
        XCTAssertTrue(unreadable.isEmpty, "a missing directory is a fresh install, not a damaged archive")
    }

    // MARK: - Recordings coordinator

    func testCoordinatorReportsUnreadableArchiveAndPreservesIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let manifest = try completed(repo)
        try repo.writeIndex([manifest])
        let coordinator = RecordingCoordinator(repository: repo)
        try deny(root.appendingPathComponent("recordings"))
        defer { try? allow(root.appendingPathComponent("recordings")) }

        let snapshot = try await coordinator.recover()
        XCTAssertNotNil(snapshot.archiveError)
        XCTAssertTrue(snapshot.manifests.isEmpty)
        XCTAssertTrue(snapshot.unreadableRecordingIDs.isEmpty)
        XCTAssertEqual(try Disk.read([Manifest].self, at: root.appendingPathComponent("index.json")).map(\.id), [manifest.id],
                       "the unreadable archive never rewrites the derived index")

        try allow(root.appendingPathComponent("recordings"))
        let healthy = try await coordinator.recover()
        XCTAssertNil(healthy.archiveError)
        XCTAssertEqual(healthy.manifests.map(\.id), [manifest.id])
    }

    // MARK: - Diagram repository and coordinator

    private func seedDiagram(_ repo: DiagramRepository) throws -> DiagramManifest {
        var manifest = DiagramManifest(title: "item", filename: "pic.png", ext: "png", uti: "public.png")
        manifest.byteSize = 1; manifest.pixelWidth = 1; manifest.pixelHeight = 1; manifest.sha256 = "00"
        try Disk.directory(repo.folder(manifest.id))
        try Data("png".utf8).write(to: repo.originalURL(manifest))
        try repo.save(manifest)
        return manifest
    }

    func testUnreadableDiagramItemsDirectoryIsReportedThroughCoordinator() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try DiagramRepository(root: root)
        let manifest = try seedDiagram(repo)
        try deny(repo.itemsURL)
        defer { try? allow(repo.itemsURL) }

        var unreadable: [Error] = []
        XCTAssertTrue(repo.list(reportInvalid: { _ in }, reportUnreadable: { unreadable.append($0) }).isEmpty)
        XCTAssertEqual(unreadable.count, 1, "an existing but unreadable items directory is an error, not «no diagrams»")

        let coordinator = DiagramCoordinator(repository: repo)
        let snapshot = try await coordinator.recover()
        XCTAssertNotNil(snapshot.archiveError)
        XCTAssertTrue(snapshot.manifests.isEmpty)

        try allow(repo.itemsURL)
        let healthy = try await coordinator.recover()
        XCTAssertNil(healthy.archiveError)
        XCTAssertEqual(healthy.manifests.map(\.id), [manifest.id])
    }

    func testMissingDiagramItemsDirectoryIsAnHonestEmptyArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try DiagramRepository(root: root)
        try FileManager.default.removeItem(at: repo.itemsURL)
        var unreadable: [Error] = []
        XCTAssertTrue(repo.list(reportInvalid: { _ in }, reportUnreadable: { unreadable.append($0) }).isEmpty)
        XCTAssertTrue(unreadable.isEmpty, "a missing items directory is a fresh install, not a damaged archive")
    }
}
