import Foundation

public enum ModelRole: String, Codable, CaseIterable, Sendable {
    case asr, diarization, summary, tokenizer
    public var title: String {
        switch self {
        case .asr: return "Распознавание речи"
        case .diarization: return "Определение участников"
        case .summary: return "Итоги"
        case .tokenizer: return "Токенизатор речи"
        }
    }
}
public struct ModelFile: Codable, Sendable {
    public var path: String; public var localPath: String; public var size: Int64; public var sha256: String
}
public struct ModelProfile: Codable, Sendable, Identifiable {
    public var id: String; public var repository: String; public var revision: String; public var license: String; public var files: [ModelFile]
    public var role: ModelRole?
    public var name: String?
    public var recommendedMemoryGB: Int?
    public var workingMemoryGB: Int?
    public var tokenizerID: String?
    public var purpose: ModelRole? { role ?? ModelRole(rawValue: id) }
    public var displayName: String { name ?? repository.components(separatedBy: "/").last ?? id }
    public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public func validatePaths() throws {
        guard Self.safeComponent(id), !files.isEmpty,
              files.allSatisfy({ $0.size >= 0 && !$0.localPath.hasPrefix("/") && !$0.localPath.isEmpty &&
                  !$0.localPath.split(separator: "/").contains("..") }),
              Set(files.map(\.localPath)).count == files.count else { throw ScribeError.message("Недопустимый путь в каталоге моделей") }
    }
    public static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }
    public func validate(at root: URL) throws {
        try validatePaths()
        for f in files {
            let url = root.appendingPathComponent(id).appendingPathComponent(f.localPath)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == f.size,
                  try Disk.hash(url) == f.sha256 else { throw ScribeError.message("Модель \(displayName): отсутствует или повреждён \(f.localPath)") }
        }
    }
}
public struct ModelCatalog: Codable, Sendable {
    public var schemaVersion: Int; public var models: [ModelProfile]
    public var fingerprint: String {
        // Preserve checkpoints made with the original four profiles. Variants in the
        // same repository can share a revision, so their identity must also be hashed.
        let legacy = models.allSatisfy { $0.id == $0.purpose?.rawValue }
        return Disk.fingerprint(models.map { legacy ? $0.revision : "\($0.id):\($0.revision):\($0.files.map(\.sha256).joined())" }.joined(separator: ":"))
    }
    public init(schemaVersion: Int = 1, models: [ModelProfile]) { self.schemaVersion = schemaVersion; self.models = models }
    public func validate(at root: URL, progress: (@Sendable (String) -> Void)? = nil) throws {
        for m in models {
            try m.validate(at: root)
            progress?(m.id)
        }
    }
}

public struct ModelInstallProgress: Sendable {
    public enum Phase: Int, Sendable { case checking, downloading, verifying, complete }
    public let profileID: String
    public let fileIndex: Int
    public let completedFiles: Int
    public let completedBytes: Int64
    public let fileBytes: Int64
    public let totalBytes: Int64
    public let phase: Phase
    public var downloadedBytes: Int64 { min(totalBytes, completedBytes + fileBytes) }
    public var fraction: Double { totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0 }
    public init(profile: ModelProfile, fileIndex: Int = 0, completedFiles: Int = 0, completedBytes: Int64 = 0, fileBytes: Int64 = 0, phase: Phase = .checking) {
        profileID = profile.id; self.fileIndex = fileIndex; self.completedFiles = completedFiles
        self.completedBytes = completedBytes; totalBytes = profile.bytes; self.phase = phase
        self.fileBytes = profile.files.indices.contains(fileIndex) ? max(0, min(fileBytes, profile.files[fileIndex].size)) : 0
    }
}

/// An explicit download task is required: URLSession's async download API does
/// not deliver download progress to its per-task delegate. Delegate callbacks are
/// serial; the lock protects start/cancel/completion from task-cancellation races.
public final class ModelFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var cancelled = false
    private var downloaded: URL?
    private var fileError: Error?
    private var lastReport = Date.distantPast
    public init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    public func download(from url: URL) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { start(url, continuation: $0) }
        } onCancel: { self.cancel() }
    }
    private func start(_ url: URL, continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        self.session = session; self.task = task; self.continuation = continuation
        lock.unlock()
        task.resume()
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession deletes its file when this callback returns. Keep our own
        // temporary file until the installer or XPC client has consumed it.
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("localscribe-model-" + UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: saved); downloaded = saved }
        catch { fileError = error }
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite {
            lastReport = now; progress(totalBytesWritten)
        }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation, cancelled = self.cancelled
        self.continuation = nil; self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if !cancelled, error == nil, fileError == nil, let downloaded, let response = task.response {
            continuation?.resume(returning: (downloaded, response))
        } else {
            if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
            continuation?.resume(throwing: cancelled ? CancellationError() : error ?? fileError ?? ScribeError.message("Загрузчик не сохранил файл"))
        }
    }
}

/// Explicit network operations only. Inference does not hold an instance of this actor.
public actor ModelInstaller {
    public init() {}
    public func install(_ profile: ModelProfile, root: URL, localSource: URL? = nil,
                        fetch: (@Sendable (Int, @escaping @Sendable (Int64) -> Void) async throws -> FileHandle)? = nil,
                        progress: @escaping @Sendable (ModelInstallProgress) -> Void) async throws {
        try profile.validatePaths()
        try Task.checkCancellation()
        let fm = FileManager.default
        let final = root.appendingPathComponent(profile.id)
        progress(ModelInstallProgress(profile: profile))
        if fm.fileExists(atPath:final.path) {
            if (try? profile.validate(at: root)) != nil {
                try Task.checkCancellation()
                progress(ModelInstallProgress(profile: profile, fileIndex: profile.files.count, completedFiles: profile.files.count, completedBytes: profile.bytes, phase: .complete)); return
            }
        }
        let partial = root.appendingPathComponent(profile.id + ".partial")
        try Disk.directory(partial)
        let temporaryBytes = localSource == nil ? (profile.files.map(\.size).max() ?? 0) : 0
        try Disk.requireSpace(profile.bytes + temporaryBytes + 500_000_000, at: root)
        var completedBytes: Int64 = 0
        for (index, f) in profile.files.enumerated() {
            try Task.checkCancellation()
            let verifiedBytes = completedBytes
            let report: @Sendable (Int64, ModelInstallProgress.Phase) -> Void = { bytes, phase in
                progress(ModelInstallProgress(profile: profile, fileIndex: index, completedFiles: index, completedBytes: verifiedBytes, fileBytes: bytes, phase: phase))
            }
            let destination = partial.appendingPathComponent(f.localPath)
            report(0, .checking)
            if (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == f.size,
               (try? Disk.hash(destination)) == f.sha256 {
                completedBytes += f.size
                progress(ModelInstallProgress(profile: profile, fileIndex: index + 1, completedFiles: index + 1, completedBytes: completedBytes))
                continue
            }
            try Disk.directory(destination.deletingLastPathComponent())
            report(0, .downloading)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            if let localSource {
                let source = localSource.appendingPathComponent(f.localPath)
                let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
                try copy(input, to: destination) { report($0, .downloading) }
            } else if let fetch {
                let source = try await fetch(index) { report($0, .downloading) }
                defer { try? source.close() }
                report(f.size, .verifying)
                try copy(source, to: destination) { _ in }
            } else {
                let encoded = f.path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }.joined(separator: "/")
                let url = URL(string: "https://huggingface.co/\(profile.repository)/resolve/\(profile.revision)/\(encoded)")!
                let transfer = ModelFileDownload { report($0, .downloading) }
                let (temp, response) = try await transfer.download(from: url)
                defer { try? fm.removeItem(at: temp) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ScribeError.message("Источник модели недоступен") }
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: temp, to: destination)
            }
            report(f.size, .verifying)
            guard (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == f.size,
                  try Disk.hash(destination) == f.sha256 else { try? fm.removeItem(at: destination); throw ScribeError.message("Не совпала SHA-256 файла \(f.localPath). Повторите загрузку.") }
            completedBytes += f.size
            progress(ModelInstallProgress(profile: profile, fileIndex: index + 1, completedFiles: index + 1, completedBytes: completedBytes))
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: partial, to: final)
        progress(ModelInstallProgress(profile: profile, fileIndex: profile.files.count, completedFiles: profile.files.count, completedBytes: profile.bytes, phase: .complete))
    }
    private func copy(_ input: FileHandle, to destination: URL, progress: (Int64) -> Void) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ScribeError.message("Не удалось создать файл модели") }
        let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
        var count: Int64 = 0
        while let bytes = try input.read(upToCount: 4 * 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation(); try output.write(contentsOf: bytes)
            count += Int64(bytes.count); progress(count)
        }
        try output.synchronize()
    }
}
