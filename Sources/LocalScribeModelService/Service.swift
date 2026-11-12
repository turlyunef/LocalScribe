import Darwin
import Foundation
import LocalScribeCore
import Security
import os

final class DownloadService: NSObject, ModelDownloadServiceProtocol {
    weak var connection: NSXPCConnection?
    private var task: Task<Void, Never>?
    private var temporary: URL?
    init(connection: NSXPCConnection) { self.connection = connection }
    private func clean() {
        if let temporary { try? FileManager.default.removeItem(at:temporary) }; temporary = nil
    }
    private func openTemporary(_ url: URL) throws -> FileHandle {
        temporary = url
        let file = try FileHandle(forReadingFrom: url)
        // XPC transfers the open descriptor. Unlink now so even a killed service
        // cannot leave a completed multi-gigabyte download on disk.
        try FileManager.default.removeItem(at: url); temporary = nil
        return file
    }
    func download(_ profileID: String, fileIndex: Int, requestID: String, withReply reply: @escaping (FileHandle?, String?) -> Void) {
        DispatchQueue.main.async {
            guard self.task == nil else { reply(nil,"Другая загрузка ещё работает"); return }
            self.task = Task { @MainActor in
                defer { self.task = nil }
                do {
                    self.clean()
                    guard let resources = Bundle.main.resourceURL else { throw ScribeError.message("Не удалось прочитать закреплённый каталог моделей") }
                    let catalog = try Disk.read(ModelCatalog.self, at: resources.appendingPathComponent("models.lock.json"))
                    guard let profile = catalog.models.first(where: { $0.id == profileID }), profile.files.indices.contains(fileIndex) else { throw ScribeError.message("Файл не входит в закреплённый каталог") }
                    let file = profile.files[fileIndex]
                    let url = try ModelProfile.downloadURL(repository: profile.repository, revision: profile.revision, path: file.path)
                    let transfer = ModelFileDownload(expectedSize: file.size) { bytes in
                        (self.connection?.remoteObjectProxy as? ModelDownloadProgressProtocol)?.update(requestID, bytesWritten: bytes)
                    }
                    let (temporary,response) = try await transfer.download(from:url)
                    self.temporary = temporary
                    try Task.checkCancellation()
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ScribeError.message("Источник модели недоступен") }
                    reply(try self.openTemporary(temporary),nil)
                } catch { self.clean(); reply(nil,error is CancellationError ? "Загрузка отменена" : error.localizedDescription) }
            }
        }
    }
    func check(withReply reply: @escaping (FileHandle?, String?) -> Void) {
        DispatchQueue.main.async {
            guard self.task == nil else { reply(nil,"Другая загрузка ещё работает"); return }
            do {
                self.clean()
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                self.temporary = temporary
                try Data("LocalScribe model service".utf8).write(to:temporary)
                reply(try self.openTemporary(temporary),nil)
            } catch { self.clean(); reply(nil,error.localizedDescription) }
        }
    }
    func releaseDownload() { DispatchQueue.main.async { self.clean() } }
    func cancel() { DispatchQueue.main.async { self.task?.cancel(); if self.task == nil { self.clean() } } }
}
final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private static let log = Logger(subsystem: "local.localscribe.mac.models", category: "client")
    private let clientExecutable: String

    override init() {
        var app = Bundle.main.bundleURL
        while app.pathExtension != "app", app.path != "/" {
            app.deleteLastPathComponent()
        }
        clientExecutable = app.pathExtension == "app" ? app.appendingPathComponent("Contents/MacOS/LocalScribe").path : ""
        super.init()
    }

    private func requirement(for process: pid_t) -> String? {
        // The service sandbox can read its own bundle, but does not necessarily
        // have filesystem access to the enclosing app. Ask the kernel for the
        // running peer's executable instead of opening the app on disk.
        guard !clientExecutable.isEmpty, process > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        guard proc_pidpath(process, &path, UInt32(path.count)) > 0,
              String(cString: path) == clientExecutable else {
            Self.log.error("The connection peer does not match the bundled application executable.")
            return nil
        }
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: process),
                          kSecGuestAttributeDynamicCode as String: true] as CFDictionary
        var guest: SecCode?
        let lookup = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest)
        guard lookup == errSecSuccess, let guest else {
            Self.log.error("Could not identify the running application signature: \(lookup, privacy: .public)")
            return nil
        }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        let signing = SecCodeCopySigningInformation(code, [], &info)
        guard signing == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else {
            Self.log.error("Could not read the running application code hash: \(signing, privacy: .public)")
            return nil
        }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        // XPC applies this requirement to the authenticated sender of messages
        // on this connection, including ad-hoc signed builds.
        return "cdhash H\"\(hex)\""
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid(),
              let clientRequirement = requirement(for: connection.processIdentifier) else { return false }
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: ModelDownloadServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: ModelDownloadProgressProtocol.self)
        let service = DownloadService(connection: connection)
        connection.exportedObject = service
        connection.invalidationHandler = { service.cancel() }
        connection.resume(); return true
    }
}
@main struct ModelServiceMain {
    static func main() {
        let delegate = ServiceDelegate(), listener = NSXPCListener.service()
        listener.delegate = delegate; listener.resume()
        withExtendedLifetime(delegate) { RunLoop.current.run() }
    }
}
