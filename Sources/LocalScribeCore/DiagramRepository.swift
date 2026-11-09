import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DuplicateDiagram: Error {
    public let id: String
}

/// File storage of the diagram archive — a sibling branch next to the audio
/// archive with its own root, items and groups catalog. Transactions, snapshots
/// and revisions belong to DiagramCoordinator; this structure only reads and
/// writes files and stays Sendable without actors.
public struct DiagramRepository: Sendable {
    public static let maxBytes: Int64 = 31_457_280 // 30 MiB
    public static let maxPixels: Int64 = 24_000_000 // 24 megapixels
    public static let maxSide = 8192
    static let chunk = 4 * 1024 * 1024

    public let root: URL
    public var groupsURL: URL { root.appendingPathComponent("groups.json") }
    public var itemsURL: URL { root.appendingPathComponent("items") }

    public init(root: URL) throws {
        self.root = root
        try Disk.directory(itemsURL)
    }

    public func folder(_ id: String) -> URL { itemsURL.appendingPathComponent(id) }
    public func run(_ id: String, _ runId: String) -> URL {
        folder(id).appendingPathComponent("runs").appendingPathComponent(runId)
    }
    public func originalURL(_ manifest: DiagramManifest) -> URL {
        folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
    }

    // MARK: - Manifests

    /// Shared checks for manifests entering the archive. Damaged recognizable
    /// items stay on disk untouched; validation only gates new writes.
    static func validate(_ manifest: DiagramManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw ScribeError.message("Эта версия схемы создана другим выпуском. Исходные файлы сохранены; обновите приложение.")
        }
        guard UUID(uuidString: manifest.id) != nil else { throw ScribeError.message("Недопустимый идентификатор схемы") }
        guard manifest.originalRelativePath.hasPrefix("original."),
              manifest.originalRelativePath.count > "original.".count,
              !manifest.originalRelativePath.contains("/"),
              !manifest.originalRelativePath.contains("\\"),
              !manifest.originalRelativePath.contains("\0") else {
            throw ScribeError.message("Недопустимый путь оригинала схемы")
        }
    }

    public func save(_ manifest: DiagramManifest) throws {
        try DiagramRepository.validate(manifest)
        try Disk.write(manifest, to: folder(manifest.id).appendingPathComponent("manifest.json"))
    }

    public func load(_ id: String) throws -> DiagramManifest {
        guard UUID(uuidString: id) != nil else { throw ScribeError.message("Недопустимый идентификатор схемы") }
        let manifest = try Disk.read(DiagramManifest.self, at: folder(id).appendingPathComponent("manifest.json"))
        guard manifest.id == id else { throw ScribeError.message("Идентификатор схемы не совпадает с её каталогом") }
        return manifest
    }

    /// Only UUID directories without symlinks that contain a manifest are items.
    /// Unrelated folders are ignored; a recognizable damaged item is reported,
    /// never hidden and never deleted.
    public func list(reportInvalid: (String) -> Void = { _ in }) -> [DiagramManifest] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: itemsURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return dirs.compactMap { url -> DiagramManifest? in
            let id = url.lastPathComponent
            guard UUID(uuidString: id) != nil,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
            do { return try load(id) }
            catch { reportInvalid(id); return nil }
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }

    public func rename(_ id: String, title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ScribeError.message("Название схемы не может быть пустым") }
        // Read the current manifest so renaming cannot restore stale processing state.
        var manifest = try load(id)
        manifest.displayTitle = title
        try save(manifest)
    }

    public func delete(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw ScribeError.message("Недопустимый идентификатор схемы") }
        try FileManager.default.removeItem(at: folder(id))
    }

    /// A restart interrupts jobs that were queued or recognizing. Warnings are
    /// never touched here; the caller receives the resulting snapshot.
    @discardableResult
    public func recover(reportInvalid: (String) -> Void = { _ in }) throws -> [DiagramManifest] {
        var manifests = list(reportInvalid: reportInvalid)
        for index in manifests.indices {
            var m = manifests[index]
            guard m.schemaVersion == 1 else { continue }
            if m.state == .queued || m.state == .recognizing {
                m.state = .interrupted
                try save(m)
                manifests[index] = m
            }
        }
        return manifests
    }

    // MARK: - Import

    /// Overflow-safe pixel limits. The width-by-height product is computed
    /// through Int64 with an explicit overflow report, never through Int.
    static func checkPixelLimits(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw ScribeError.message("Некорректные размеры изображения") }
        guard width <= maxSide, height <= maxSide else {
            throw ScribeError.message("Сторона изображения превышает \(maxSide) пикселей. Уменьшите изображение.")
        }
        let product = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard !product.overflow, product.partialValue <= maxPixels else {
            throw ScribeError.message("Изображение превышает \(maxPixels / 1_000_000) мегапикселей. Уменьшите изображение.")
        }
    }

    public func importImage(at source: URL,
                            existingDiagrams: [DiagramManifest]? = nil,
                            beforePublish: (DiagramManifest) throws -> Void = { _ in }) throws -> DiagramManifest {
        try Task.checkCancellation()
        let fm = FileManager.default
        let input = try PinnedImageSource(source)
        defer { input.close() }
        guard input.size > 0 else { throw ScribeError.message("Файл изображения пуст") }
        guard input.size <= Self.maxBytes else {
            throw ScribeError.message("Изображение больше 30 МБ. Уменьшите файл и повторите импорт.")
        }
        // Hash the pinned bytes before any copying; a later path change cannot alter them.
        let digest = try input.hash()
        try Task.checkCancellation()
        if let duplicate = existingDiagrams?.first(where: { $0.sha256 == digest }) {
            throw DuplicateDiagram(id: duplicate.id)
        }
        try Disk.requireSpace(input.size * 2 + 50_000_000, at: root)
        let id = UUID().uuidString
        let itemFolder = folder(id)
        var published = false
        defer { if !published { try? fm.removeItem(at: itemFolder) } }
        // The independent copy is verified inside a .partial directory and only
        // then moved into place; cancellation removes only these temporary files.
        let partialDirectory = itemFolder.appendingPathComponent(".partial")
        try Disk.directory(partialDirectory)
        let sourceExtension = source.pathExtension.isEmpty ? "img" : source.pathExtension.lowercased()
        let partialCopy = partialDirectory.appendingPathComponent("original.\(sourceExtension)")
        try input.copy(to: partialCopy, verifying: digest)
        try Task.checkCancellation()
        // Preliminary path-based probing may precede a replacement of the source.
        // Only metadata measured from our verified independent copy is authoritative.
        let probe = try DiagramImageProbe.read(at: partialCopy)
        var manifest = DiagramManifest(title: importTitle(from: source), filename: source.lastPathComponent,
                                       ext: probe.fileExtension, uti: probe.uti)
        manifest.id = id
        manifest.byteSize = input.size
        manifest.pixelWidth = probe.pixelWidth
        manifest.pixelHeight = probe.pixelHeight
        manifest.orientation = probe.orientation
        manifest.sha256 = digest
        try fm.moveItem(at: partialCopy, to: originalURL(manifest))
        try? fm.removeItem(at: partialDirectory)
        try Task.checkCancellation()
        try beforePublish(manifest)
        try save(manifest)
        published = true
        return manifest
    }

    private func importTitle(from source: URL) -> String {
        let name = source.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Изображение" : name
    }

    // MARK: - Runs

    @discardableResult
    public func beginRun(_ manifest: inout DiagramManifest, profile: ModelProfile) throws -> DiagramRunInfo {
        let catalog = ModelCatalog(models: [profile])
        let info = DiagramRunInfo(sourceHash: manifest.sha256, modelID: profile.id, profileHash: catalog.fingerprint)
        let path = run(manifest.id, info.id)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: path) } }
        try Disk.directory(path)
        try Disk.write(info, to: path.appendingPathComponent("run.json"))
        var updated = manifest
        updated.pendingRunId = info.id
        updated.state = .queued
        updated.lastError = nil
        try save(updated)
        manifest = updated; published = true
        return info
    }

    /// Read and verify an existing diagram job without replacing its identity.
    /// Incompatibility throws while preserving the run and the manifest.
    public func resumeRun(_ manifest: DiagramManifest) throws -> DiagramRunInfo {
        do {
            guard manifest.schemaVersion == 1, let pending = manifest.pendingRunId, UUID(uuidString: pending) != nil else {
                throw ScribeError.message("Некорректное незавершённое задание схемы")
            }
            let info: DiagramRunInfo
            do { info = try Disk.read(DiagramRunInfo.self, at: run(manifest.id, pending).appendingPathComponent("run.json")) }
            catch { throw ScribeError.message("Не удалось прочитать незавершённое задание схемы") }
            guard info.schemaVersion == 1, info.id == pending else { throw ScribeError.message("Некорректное незавершённое задание схемы") }
            guard info.pipelineVersion == DiagramRunInfo.currentPipelineVersion,
                  info.promptVersion == DiagramRunInfo.currentPromptVersion,
                  info.preprocessingVersion == DiagramRunInfo.currentPreprocessingVersion else {
                throw ScribeError.message("Версия обработки изменилась; задание схемы несовместимо")
            }
            guard info.sourceHash == manifest.sha256 else { throw ScribeError.message("Оригинал не совпадает с незавершённым заданием схемы") }
            return info
        } catch {
            throw ScribeError.message("Не удалось продолжить: \(error.localizedDescription). Задание сохранено; для нового задания с выбранными моделями нажмите «Распознать заново».")
        }
    }

    /// Read and verify the published result of a run. The file size is checked
    /// before decoding; a corrupted result is an error, never a fallback.
    public func results(_ id: String, runId: String) throws -> DiagramResult {
        guard UUID(uuidString: id) != nil, UUID(uuidString: runId) != nil else {
            throw ScribeError.message("Недопустимый идентификатор задания схемы")
        }
        let runFolder = run(id, runId)
        let info: DiagramRunInfo
        do { info = try Disk.read(DiagramRunInfo.self, at: runFolder.appendingPathComponent("run.json")) }
        catch { throw ScribeError.message("Задание схемы не найдено") }
        guard info.schemaVersion == 1, info.id == runId else { throw ScribeError.message("Некорректное задание схемы") }
        let resultURL = runFolder.appendingPathComponent("result.json")
        let size: Int64
        do { size = try resultURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0 }
        catch { throw ScribeError.message("Результат схемы отсутствует") }
        guard size > 0, size <= DiagramResult.maxJSONBytes else {
            throw ScribeError.message("Результат схемы отсутствует или превышает допустимый размер")
        }
        let result = try Disk.read(DiagramResult.self, at: resultURL)
        try result.validate(expectedFingerprint: info.fingerprint)
        return result
    }

    /// Write worker output into the run folder. Called only by the GUI
    /// coordinator after validation; the size of the payload is bounded here.
    public func publishResult(_ id: String, runId: String, data: Data) throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: runId) != nil else {
            throw ScribeError.message("Недопустимый идентификатор задания схемы")
        }
        guard Int64(data.count) <= DiagramResult.maxJSONBytes else {
            throw ScribeError.message("Результат схемы превышает допустимый размер")
        }
        let runFolder = run(id, runId)
        guard FileManager.default.fileExists(atPath: runFolder.appendingPathComponent("run.json").path) else {
            throw ScribeError.message("Задание схемы не найдено")
        }
        try data.write(to: runFolder.appendingPathComponent("result.json"), options: .atomic)
    }
}

/// Pins an open regular-file descriptor before hashing so a later path or
/// symlink change cannot alter the input of the copy (ImportSource pattern).
/// All reads are bounded by the size observed at open time: a file that grows
/// afterwards is rejected instead of being read past its declared size.
struct PinnedImageSource {
    private let file: FileHandle
    let size: Int64

    init(_ url: URL) throws {
        // Nonblocking open lets us reject a FIFO without waiting for a writer.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw ScribeError.message("Для импорта выберите обычный файл") }
        self.file = file
        size = status.st_size
    }

    func close() { try? file.close() }

    /// SHA-256 of exactly the pinned byte range.
    func hash() throws -> String {
        try file.seek(toOffset: 0)
        var hash = SHA256()
        var count: Int64 = 0
        while count < size {
            try Task.checkCancellation()
            let limit = min(DiagramRepository.chunk, Int(size - count))
            let hasBytes = try autoreleasepool {
                guard let bytes = try file.read(upToCount: limit), !bytes.isEmpty else { return false }
                hash.update(data: bytes)
                count += Int64(bytes.count)
                return true
            }
            if !hasBytes { throw ScribeError.message("Размер исходного файла изменился во время импорта") }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func copy(to destination: URL, verifying digest: String) throws {
        // Always create a fresh regular file, never follow an existing destination.
        let descriptor = destination.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var verified = false
        defer {
            try? output.close()
            if !verified { try? FileManager.default.removeItem(at: destination) }
        }
        try file.seek(toOffset: 0)
        var count: Int64 = 0
        // Reads never pass the size observed at open time: bytes appended to a
        // growing file are not part of the pinned, hashed image and are ignored.
        while count < size {
            try Task.checkCancellation()
            let limit = min(DiagramRepository.chunk, Int(size - count))
            guard let bytes = try file.read(upToCount: limit), !bytes.isEmpty else {
                throw ScribeError.message("Размер исходного файла изменился во время импорта")
            }
            try output.write(contentsOf: bytes)
            count += Int64(bytes.count)
        }
        try output.synchronize()
        try output.close()
        guard try Disk.hash(destination, checkCancellation: true) == digest else {
            throw ScribeError.message("Не удалось проверить сохранённый оригинал")
        }
        verified = true
    }
}

/// ImageIO metadata measured from our own verified copy, never from the source
/// path: the actual UTI (not the extension), full decodability and pixel size.
struct DiagramImageProbe: Sendable {
    let uti: String
    let fileExtension: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// EXIF orientation 1...8; the stored pixel sizes are the raw encoded ones.
    let orientation: Int

    static func read(at url: URL) throws -> DiagramImageProbe {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ScribeError.message("Не удалось открыть файл изображения")
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw ScribeError.message("Ожидается одно изображение, а не набор страниц")
        }
        guard CGImageSourceGetStatus(source) == .statusComplete else {
            throw ScribeError.message("Изображение не декодируется полностью; файл повреждён или обрезан")
        }
        guard let type = CGImageSourceGetType(source) as String?,
              type == UTType.png.identifier || type == UTType.jpeg.identifier else {
            throw ScribeError.message("Поддерживаются только изображения PNG и JPEG")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else {
            throw ScribeError.message("Не удалось определить размеры изображения")
        }
        try DiagramRepository.checkPixelLimits(width: width, height: height)
        var orientation = (properties[kCGImagePropertyOrientation as String] as? Int)
            ?? (properties[kCGImagePropertyTIFFOrientation as String] as? Int) ?? 1
        if !(1...8).contains(orientation) { orientation = 1 }
        return DiagramImageProbe(uti: type,
                                 fileExtension: type == UTType.png.identifier ? "png" : "jpg",
                                 pixelWidth: width, pixelHeight: height, orientation: orientation)
    }
}
