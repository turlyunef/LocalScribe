import Foundation
import LocalScribeCore

@MainActor final class ModelDownloadClient: NSObject, ModelDownloadProgressProtocol {
    private var connection: NSXPCConnection?
    private var pending: CheckedContinuation<FileHandle, Error>?
    private var requestID: String?
    private var progress: (@Sendable (Int64) -> Void)?
    nonisolated func update(_ requestID: String, bytesWritten: Int64) {
        Task { @MainActor in if self.requestID == requestID { self.progress?(bytesWritten) } }
    }
    private func finish(_ file: FileHandle? = nil, error: Error? = nil) {
        guard let pending else { return }; self.pending = nil; requestID = nil; progress = nil
        if let error { pending.resume(throwing: error) } else if let file { pending.resume(returning:file) } else { pending.resume(throwing:ScribeError.message("Загрузчик не передал файл")) }
    }
    private func connect() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: "local.localscribe.mac.models")
        connection.remoteObjectInterface = NSXPCInterface(with: ModelDownloadServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: ModelDownloadProgressProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self, weak connection] in Task { @MainActor in
            guard let self, self.connection === connection else { return }
            self.finish(error:ScribeError.message("Процесс загрузки моделей остановлен"))
            self.connection = nil
        } }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume(); self.connection = connection; return connection
    }
    func fetch(profileID: String?, index: Int = 0, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> FileHandle {
        try Task.checkCancellation()
        guard pending == nil else { throw ScribeError.message("Загрузка уже запущена") }
        let connection = self.connection ?? connect()
        let requestID = UUID().uuidString; self.requestID = requestID; self.progress = progress
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            guard let service = connection.remoteObjectProxyWithErrorHandler({ error in Task { @MainActor in
                if self.requestID == requestID { self.finish(error:error) }
            } }) as? ModelDownloadServiceProtocol else { finish(error:ScribeError.message("Недоступен встроенный загрузчик моделей")); return }
            let reply: (FileHandle?,String?) -> Void = { file,error in Task { @MainActor in
                guard self.requestID == requestID else { try? file?.close(); return }
                self.finish(file,error:error.map { ScribeError.message($0) })
            } }
            if let profileID { service.download(profileID,fileIndex:index,requestID:requestID,withReply:reply) }
            else { service.check(withReply:reply) }
        }
    }
    func cancel() { (connection?.remoteObjectProxy as? ModelDownloadServiceProtocol)?.cancel() }
    func releaseDownload() { (connection?.remoteObjectProxy as? ModelDownloadServiceProtocol)?.releaseDownload() }
    func close() { cancel(); finish(error: CancellationError()); connection?.invalidate(); connection = nil }
}
