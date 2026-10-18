import Darwin
import XCTest
@testable import LocalScribeModelService

@MainActor
final class DownloadServiceTests: XCTestCase {
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
