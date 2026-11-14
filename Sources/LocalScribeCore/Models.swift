import Darwin
import Foundation

public enum ModelRole: String, Codable, CaseIterable, Sendable {
    case asr, diarization, summary, tokenizer, diagram
    /// The immutable audio complect order; diagram readiness never affects it.
    public static let audioRoles: [ModelRole] = [.asr, .diarization, .summary, .tokenizer]
    public var title: String {
        switch self {
        case .asr: return L10n.text("Распознавание речи")
        case .diarization: return L10n.text("Определение участников")
        case .summary: return L10n.text("Итоги")
        case .tokenizer: return L10n.text("Токенизатор речи")
        case .diagram: return L10n.text("Распознавание схем")
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
    /// Absent in legacy catalogs, which use Whisper.
    public var asrBackend: String?
    public var resolvedASRBackend: String { asrBackend ?? "whisper" }
    /// Optional dependency; never a fifth mandatory legacy role.
    public var alignerID: String?
    public var asrPolicy: String?
    public var profileDescription: String?
    public var experimental: Bool?
    public var supportsClosedFragments: Bool { purpose == .asr && resolvedASRBackend == "whisper" }
    public var recommendationRank: Int?
    /// Tasks the profile is qualified for among summary, diagram recognition
    /// and anonymization. The catalog stamps the role-verified tasks
    /// (SUMMARY on summary profiles, DIAGRAM_RECOGNITION on diagram
    /// profiles); ANONYMIZATION and limits are added only by qualification
    /// (work 13, docs/TextAnonymization/Qualification.md). Without a value
    /// the effective set is derived from the role.
    public var supportedTasks: Set<ModelTask>?
    /// Explicit reference to the immutable file set shared by several profiles.
    /// When absent, the package identity is derived from the pinned files, so
    /// profiles with equal sizes and SHA-256 share one physical installation.
    public var packageID: String?
    /// Catalog-provided byte limit of a full anonymization pass for this
    /// profile. Absent until qualification; the conservative hardware estimate
    /// applies in the meantime. See `AnonymizationInputLimit`.
    public var anonymizationInputLimitBytes: Int64?
    public var purpose: ModelRole? { role ?? ModelRole(rawValue: id) }
    var catalogName: String { name ?? repository.components(separatedBy: "/").last ?? id }
    public var displayName: String { L10n.text(catalogName) }
    public var displayDescription: String? { profileDescription.map { L10n.text($0) } }
    public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public static func downloadURL(repository: String, revision: String, path: String) throws -> URL {
        guard !repository.isEmpty, !revision.isEmpty, !path.isEmpty,
              let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)", encodingInvalidCharacters: false),
              url.scheme == "https", url.host == "huggingface.co", url.query == nil, url.fragment == nil else {
            throw ScribeError.message("Некорректный адрес файла в закреплённом каталоге моделей")
        }
        return url
    }
    public func validatePaths() throws {
        guard Self.safeComponent(id), !files.isEmpty,
              files.allSatisfy({ $0.size >= 0 && !$0.localPath.hasPrefix("/") && !$0.localPath.isEmpty &&
                  $0.localPath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { Self.safeComponent(String($0)) } }),
              Set(files.map(\.localPath)).count == files.count else { throw ScribeError.message("Недопустимый путь в каталоге моделей") }
        if let packageID, !Self.safeComponent(packageID) {
            throw ScribeError.message("Недопустимая ссылка на комплект моделей")
        }
        if let limit = anonymizationInputLimitBytes, limit <= 0 {
            throw ScribeError.message("Недопустимый предел входа обезличивания в каталоге моделей")
        }
    }
    public static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }
    public func validate(at root: URL) throws {
        try validateFiles(at: root, verifyContents: true)
    }
    func validateFiles(at root: URL, verifyContents: Bool) throws {
        try validatePaths()
        for f in files {
            let url = root.appendingPathComponent(id).appendingPathComponent(f.localPath)
            let invalid = ScribeError.message("Модель \(catalogName): отсутствует или повреждён \(f.localPath)")
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == f.size else { throw invalid }
            if verifyContents, try Disk.hash(url) != f.sha256 { throw invalid }
        }
    }
}
public struct ModelCatalog: Codable, Sendable {
    public var schemaVersion: Int; public var models: [ModelProfile]
    public var fingerprint: String {
        // Preserve checkpoints made with the original four profiles. Variants in the
        // same repository can share a revision, so their identity must also be hashed.
        let legacy = models.allSatisfy { $0.id == $0.purpose?.rawValue }
        let identities = models.map { profile in
            let identity = legacy ? profile.revision : "\(profile.id):\(profile.revision):\(profile.files.map(\.sha256).joined())"
            // An explicit Whisper annotation is identical to the historical default.
            // Other backends cannot reuse the same checkpoints, even with equal files.
            var result = profile.purpose == .asr && profile.resolvedASRBackend != "whisper"
                ? identity + ":asr-backend:" + profile.resolvedASRBackend : identity
            if let aligner = profile.alignerID { result += ":aligner:" + aligner }
            if let policy = profile.asrPolicy { result += ":asr-policy:" + policy }
            return result
        }
        return Disk.fingerprint(identities.joined(separator: ":"))
    }
    public init(schemaVersion: Int = 1, models: [ModelProfile]) { self.schemaVersion = schemaVersion; self.models = models }
    /// Resolve the run's frozen selection, never the preferences for new jobs.
    /// The role order and fingerprint algorithm also preserve legacy checkpoints.
    public func pinned(to info: RunInfo) throws -> ModelCatalog {
        guard schemaVersion == 1 else { throw ScribeError.message("Несовместимая версия каталога моделей") }
        if let ids = info.modelIDs, Set(ids.keys) != Set(ModelRole.audioRoles.map(\.rawValue)) {
            throw ScribeError.message("Некорректный закреплённый комплект моделей")
        }
        var profiles = try ModelRole.audioRoles.map { role -> ModelProfile in
            let id = try info.modelID(for: role)
            let matches = models.filter { $0.id == id && $0.purpose == role }
            if matches.count == 1 { return matches[0] }
            // Shared-mode summaries may pin a task-qualified profile of another
            // catalog purpose (the shared model serves three tasks). Resolve it
            // with a summary role view: the pinned identity — id, revision and
            // pinned files — is unchanged, so the run fingerprint stays equal.
            if role == .summary {
                let taskMatches = models.filter { $0.id == id && $0.supports(.summary) }
                if taskMatches.count == 1 {
                    var view = taskMatches[0]
                    view.role = .summary
                    return view
                }
            }
            throw ScribeError.message("Закреплённая модель \(id) недоступна в каталоге")
        }
        if let asr = profiles.first(where: { $0.purpose == .asr }), asr.resolvedASRBackend != "whisper",
           let tokenizerID = asr.tokenizerID,
           profiles.first(where: { $0.purpose == .tokenizer })?.id != tokenizerID {
            throw ScribeError.message("Закреплённый токенизатор не соответствует модели распознавания")
        }
        if let alignerID = profiles.first(where: { $0.purpose == .asr })?.alignerID {
            guard info.auxiliaryModelIDs == ["aligner": alignerID], ModelProfile.safeComponent(alignerID),
                  !profiles.contains(where: { $0.id == alignerID }) else {
                throw ScribeError.message("Не совпала закреплённая модель выравнивания")
            }
            let matches = models.filter { $0.id == alignerID && $0.purpose == nil && $0.alignerID == nil }
            guard matches.count == 1 else { throw ScribeError.message("Закреплённая модель выравнивания недоступна") }
            profiles.append(matches[0])
        } else if info.auxiliaryModelIDs?.isEmpty == false {
            throw ScribeError.message("Лишние зависимости в закреплённом комплекте")
        }
        let pinned = ModelCatalog(models: profiles)
        guard pinned.fingerprint == info.profileHash else {
            throw ScribeError.message("Ревизии или SHA-256 закреплённых моделей не совпадают с заданием")
        }
        return pinned
    }
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
    private let expectedSize: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var cancelled = false
    private var downloaded: URL?
    private var fileError: Error?
    private var lastReport = Date.distantPast
    public init(expectedSize: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.expectedSize = expectedSize; self.progress = progress
    }
    public func download(from url: URL) async throws -> (URL, URLResponse) {
        guard expectedSize >= 0 else { throw ScribeError.message("Недопустимый размер файла модели") }
        return try await withTaskCancellationHandler {
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
        do {
            guard fileError == nil else { return }
            guard (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == expectedSize else {
                throw ScribeError.message("Размер загруженного файла модели не совпал с каталогом")
            }
            try FileManager.default.moveItem(at: location, to: saved); downloaded = saved
        }
        catch { fileError = error }
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Check every callback, before throttling UI progress. Content-Length may
        // be missing or false; URLSession has written this chunk to its temp file.
        guard fileError == nil else { return }
        guard totalBytesWritten <= expectedSize else {
            fileError = ScribeError.message("Размер загружаемого файла модели превышает размер в каталоге")
            downloadTask.cancel()
            return
        }
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
            continuation?.resume(throwing: cancelled ? CancellationError() : fileError ?? error ?? ScribeError.message("Загрузчик не сохранил файл"))
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
        let directory = try ModelDirectory.root(root)
        let partialName = profile.id + ".partial"
        let existingPartial = try directory.child(partialName)
        try existingPartial?.validateTree()
        let final = try directory.child(profile.id)
        try final?.validateTree()
        progress(ModelInstallProgress(profile: profile))
        if let final {
            if try profile.files.allSatisfy({ try final.matches($0) }) {
                try Task.checkCancellation()
                progress(ModelInstallProgress(profile: profile, fileIndex: profile.files.count, completedFiles: profile.files.count, completedBytes: profile.bytes, phase: .complete)); return
            }
        }
        let partial = try existingPartial ?? directory.child(partialName, create: true)!
        let temporaryBytes = localSource == nil ? (profile.files.map(\.size).max() ?? 0) : 0
        try Disk.requireSpace(profile.bytes + temporaryBytes + 500_000_000, at: root)
        var completedBytes: Int64 = 0
        for (index, f) in profile.files.enumerated() {
            try Task.checkCancellation()
            let verifiedBytes = completedBytes
            let report: @Sendable (Int64, ModelInstallProgress.Phase) -> Void = { bytes, phase in
                progress(ModelInstallProgress(profile: profile, fileIndex: index, completedFiles: index, completedBytes: verifiedBytes, fileBytes: bytes, phase: phase))
            }
            let (parent, name) = try partial.location(f.localPath)!
            report(0, .checking)
            if try partial.matches(f) {
                completedBytes += f.size
                progress(ModelInstallProgress(profile: profile, fileIndex: index + 1, completedFiles: index + 1, completedBytes: completedBytes))
                continue
            }
            var verified = false
            defer { if !verified { try? parent.remove(name) } }
            report(0, .downloading)
            let output = try parent.create(name)
            defer { try? output.close() }
            if let localSource {
                let source = localSource.appendingPathComponent(f.localPath)
                let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
                try copy(input, to: output, expectedSize: f.size) { report($0, .downloading) }
            } else if let fetch {
                let source = try await fetch(index) { report($0, .downloading) }
                defer { try? source.close() }
                report(f.size, .verifying)
                try copy(source, to: output, expectedSize: f.size) { _ in }
            } else {
                let url = try ModelProfile.downloadURL(repository: profile.repository, revision: profile.revision, path: f.path)
                let transfer = ModelFileDownload(expectedSize: f.size) { report($0, .downloading) }
                let (temp, response) = try await transfer.download(from: url)
                defer { try? fm.removeItem(at: temp) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ScribeError.message("Источник модели недоступен") }
                let input = try FileHandle(forReadingFrom: temp); defer { try? input.close() }
                try copy(input, to: output, expectedSize: f.size) { _ in }
            }
            report(f.size, .verifying)
            guard try ModelDirectory.matches(output, f) else { throw ScribeError.message("Не совпала SHA-256 файла \(f.localPath). Повторите загрузку.") }
            verified = true
            completedBytes += f.size
            progress(ModelInstallProgress(profile: profile, fileIndex: index + 1, completedFiles: index + 1, completedBytes: completedBytes))
        }
        try Task.checkCancellation()
        try directory.publish(partial, named: partialName, as: profile.id, profile: profile)
        progress(ModelInstallProgress(profile: profile, fileIndex: profile.files.count, completedFiles: profile.files.count, completedBytes: profile.bytes, phase: .complete))
    }
    private func copy(_ input: FileHandle, to output: FileHandle, expectedSize: Int64, progress: (Int64) -> Void) throws {
        var status = stat()
        guard fstat(input.fileDescriptor, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if status.st_mode & S_IFMT == S_IFREG, status.st_size != expectedSize {
            throw ScribeError.message("Размер исходного файла модели не совпал с каталогом")
        }
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            // Also bound streams and files that grow after fstat. Probe at most
            // one byte beyond the catalog size, and never write that byte.
            let remaining = expectedSize - count
            let limit = remaining >= 4 * 1024 * 1024 ? 4 * 1024 * 1024 : Int(remaining) + 1
            guard let bytes = try input.read(upToCount: limit), !bytes.isEmpty else { break }
            guard Int64(bytes.count) <= remaining else {
                throw ScribeError.message("Размер исходного файла модели превышает размер в каталоге")
            }
            try Task.checkCancellation(); try output.write(contentsOf: bytes)
            count += Int64(bytes.count); progress(count)
        }
        try output.synchronize()
    }
}
