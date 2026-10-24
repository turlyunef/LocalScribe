import Darwin
import XCTest
import LocalScribeCore
@testable import LocalScribeModelService

@MainActor
final class DownloadServiceTests: XCTestCase {
    func testMalformedCatalogURLsReturnErrorsAndAllPinnedFilesRemainSupported() throws {
        for path in ["bad%ZZ.json", "file#fragment", "file?query", "bad\nfile", ""] {
            XCTAssertThrowsError(try DownloadService.sourceURL(repository: "owner/model", revision: "fixed", path: path))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try Disk.read(ModelCatalog.self, at: root.appendingPathComponent("Resources/models.lock.json"))
        for profile in catalog.models {
            for file in profile.files {
                let url = try DownloadService.sourceURL(repository: profile.repository, revision: profile.revision, path: file.path)
                XCTAssertEqual(url.absoluteString, "https://huggingface.co/\(profile.repository)/resolve/\(profile.revision)/\(file.path)")
            }
        }
    }

    func testServiceDoesNotKeepInvalidatedConnectionAlive() async throws {
        var service: DownloadService?
        weak var releasedConnection: NSXPCConnection?
        autoreleasepool {
            let connection = NSXPCConnection(serviceName: "local.localscribe.test.unused")
            service = DownloadService(connection: connection)
            connection.exportedObject = service
            connection.invalidationHandler = { [service] in service?.cancel() }
            releasedConnection = connection
            connection.resume()
            connection.invalidate()
        }
        let deadline = Date().addingTimeInterval(3)
        while releasedConnection != nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(releasedConnection)
        weak var releasedService = service
        service = nil
        while releasedService != nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(releasedService)
    }

    func testProbeFileIsUnlinkedWhileItsDescriptorRemainsReadable() async throws {
        let connection = NSXPCConnection(serviceName: "local.localscribe.test.unused")
        let service = DownloadService(connection: connection)
        let file: FileHandle = try await withCheckedThrowingContinuation { continuation in
            service.check { file, error in
                if let file { continuation.resume(returning: file) }
                else { continuation.resume(throwing: NSError(domain: error ?? "no file", code: 1)) }
            }
        }
        defer { try? file.close(); service.cancel() }
        var info = stat()
        XCTAssertEqual(fstat(file.fileDescriptor, &info), 0)
        XCTAssertEqual(info.st_nlink, 0, "The temporary pathname must already be removed")
        XCTAssertEqual(String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self), "LocalScribe model service")
    }
}
