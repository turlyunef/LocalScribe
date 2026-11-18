import CryptoKit
import Darwin
import Foundation

/// Pins the selected file before hashing so path/symlink replacement cannot change
/// the input of the copy. The caller keeps its security scope for this lifetime.
public final class ImportSource {
    private let file: FileHandle
    public let size: Int64
    private let allowsAppendedBytes: Bool

    public init(_ url: URL, allowsAppendedBytes: Bool = false) throws {
        // Nonblocking open lets us reject a FIFO without waiting for a writer.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw ScribeError.message("Для импорта выберите обычный файл")
        }
        self.file = file
        size = status.st_size
        self.allowsAppendedBytes = allowsAppendedBytes
    }

    private func readPinnedBytes(_ consume: (Data) throws -> Void) throws {
        func requireUnchangedSize() throws {
            guard !allowsAppendedBytes else { return }
            var status = stat()
            guard fstat(file.fileDescriptor, &status) == 0, status.st_size == size else {
                throw ScribeError.message("Размер исходного файла изменился во время импорта")
            }
        }
        try requireUnchangedSize()
        try file.seek(toOffset: 0)
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let bytes = try file.read(upToCount: Int(min(remaining, 4 * 1024 * 1024))), !bytes.isEmpty else {
                    throw ScribeError.message("Размер исходного файла изменился во время импорта")
                }
                try consume(bytes)
                remaining -= Int64(bytes.count)
            }
        }
        try requireUnchangedSize()
    }

    public func hash() throws -> String {
        var hash = SHA256()
        try readPinnedBytes { hash.update(data: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One full pinned byte snapshot of the source, read in bounded chunks.
    /// The local text import fixes its byte sequence with this single read:
    /// a path/symlink swap or size change during it becomes a read error
    /// instead of silently mixing two files.
    public func readBytes() throws -> Data {
        var data = Data()
        data.reserveCapacity(Int(size))
        try readPinnedBytes { data.append($0) }
        return data
    }

    public func close() { try? file.close() }

    public func copy(to destination: URL, verifying digest: String) throws {
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
        // Hash the bytes stream-wise while writing them: the written copy is exactly
        // the pinned bytes just verified against `digest`, so re-reading the
        // destination for a separate hash pass would walk the same bytes twice.
        // An in-place modification of the pinned source still fails the comparison
        // and the partial copy is removed.
        var hash = SHA256()
        try readPinnedBytes { bytes in
            try output.write(contentsOf: bytes)
            hash.update(data: bytes)
        }
        try output.synchronize()
        guard hash.finalize().map { String(format: "%02x", $0) }.joined() == digest else {
            throw ScribeError.message("Не удалось проверить сохранённый оригинал")
        }
        verified = true
    }
}
