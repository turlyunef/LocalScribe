import Foundation
import Network
import XCTest
@testable import LocalScribeCore

/// A paced loopback HTTP response makes cancellation observable before EOF,
/// including responses for which Content-Length cannot provide a size limit.
private final class ModelHTTPFixture: @unchecked Sendable {
    enum Framing: CaseIterable { case length, chunked, connectionClose }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "model-http-fixture")
    private var connection: NWConnection?
    private let lock = NSLock()
    private var sent = 0
    private let body: Data
    private let framing: Framing
    var bytesSent: Int { lock.lock(); defer { lock.unlock() }; return sent }

    init(body: Data, framing: Framing) throws {
        self.body = body; self.framing = framing
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)/weights")!)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connection = connection
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, _, error in
                    guard let self, error == nil else { connection.cancel(); return }
                    let header: String
                    switch self.framing {
                    case .length: header = "Content-Length: \(self.body.count)\r\n"
                    case .chunked: header = "Transfer-Encoding: chunked\r\n"
                    case .connectionClose: header = ""
                    }
                    connection.send(content: Data("HTTP/1.1 200 OK\r\n\(header)Connection: close\r\n\r\n".utf8), completion: .contentProcessed { [weak self] error in
                        if error == nil { self?.sendChunk(at: 0, on: connection) }
                    })
                }
            }
            listener.start(queue: queue)
        }
    }
    private func sendChunk(at offset: Int, on connection: NWConnection) {
        guard offset < body.count else {
            connection.send(content: framing == .chunked ? Data("0\r\n\r\n".utf8) : nil,
                            isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let end = min(body.count, offset + 16 * 1024)
        let payload = body.subdata(in: offset..<end)
        let packet = framing == .chunked ? Data(String(payload.count, radix: 16).utf8) + Data("\r\n".utf8) + payload + Data("\r\n".utf8) : payload
        lock.lock(); sent += payload.count; lock.unlock()
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                self?.sendChunk(at: end, on: connection)
            }
        })
    }
    func stop() {
        listener.cancel()
        queue.async { [self] in connection?.cancel(); connection = nil }
    }
}

final class ModelDownloadTests: XCTestCase {
    private func savedDownloads() throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("localscribe-model-") })
    }

    func testOversizedHTTPResponsesStopBeforeEOFAndPreserveInstallation() async throws {
        for framing in ModelHTTPFixture.Framing.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let models = root.appendingPathComponent("models"), partial = models.appendingPathComponent("asr.partial")
            let old = models.appendingPathComponent("asr/weights.bin")
            try Disk.directory(old.deletingLastPathComponent()); try Data("old model".utf8).write(to: old)
            try Disk.directory(partial)
            let verified = partial.appendingPathComponent("config.json")
            try Data("verified".utf8).write(to: verified)
            let files = [ModelFile(path: "config.json", localPath: "config.json", size: 8, sha256: try Disk.hash(verified)),
                         ModelFile(path: "weights.bin", localPath: "weights.bin", size: 32 * 1024, sha256: String(repeating: "0", count: 64))]
            let profile = ModelProfile(id: "asr", repository: "test/model", revision: "test", license: "test", files: files)
            let server = try ModelHTTPFixture(body: Data(repeating: 120, count: 8 * 1024 * 1024), framing: framing)
            defer { server.stop() }
            let url = try await server.start(), before = try savedDownloads()
            do {
                try await ModelInstaller().install(profile, root: models, fetch: { index, progress in
                    XCTAssertEqual(index, 1)
                    let transfer = ModelFileDownload(expectedSize: files[index].size, progress: progress)
                    let (temporary, _) = try await transfer.download(from: url)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    return try FileHandle(forReadingFrom: temporary)
                }) { _ in }
                XCTFail("Oversized HTTP response was installed")
            } catch { XCTAssertTrue(error.localizedDescription.contains("превышает размер в каталоге"), "\(error)") }
            XCTAssertLessThanOrEqual(server.bytesSent, Int(files[1].size) + 256 * 1024, "Cancel promptly instead of consuming the 8 MiB body")
            XCTAssertEqual(try savedDownloads(), before)
            XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "old model")
            XCTAssertEqual(try Disk.hash(verified), files[0].sha256)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.appendingPathComponent("weights.bin").path))
        }
    }

    func testExactHTTPBodyIsReturnedAndShortBodyIsRejected() async throws {
        for size in [0, 32 * 1024] {
            let body = Data(repeating: 120, count: size)
            let server = try ModelHTTPFixture(body: body, framing: .chunked)
            defer { server.stop() }
            let url = try await server.start()
            let (saved, _) = try await ModelFileDownload(expectedSize: Int64(size)) { _ in }.download(from: url)
            defer { try? FileManager.default.removeItem(at: saved) }
            XCTAssertEqual(try Data(contentsOf: saved), body)
        }
        let server = try ModelHTTPFixture(body: Data("short".utf8), framing: .connectionClose)
        defer { server.stop() }
        let url = try await server.start(), before = try savedDownloads()
        do {
            _ = try await ModelFileDownload(expectedSize: 100) { _ in }.download(from: url)
            XCTFail("Short body was accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("не совпал с каталогом")) }
        XCTAssertEqual(try savedDownloads(), before)
    }
}
