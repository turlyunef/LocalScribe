import Darwin
import Foundation

/// Pins the selected file before hashing so path/symlink replacement cannot change
/// the input of the copy. The caller keeps its security scope for this lifetime.
final class ImportSource {
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
        guard fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw ScribeError.message("Для импорта выберите обычный файл")
        }
        self.file = file
        size = status.st_size
    }

    func hash() throws -> String {
        try file.seek(toOffset: 0)
        return try Disk.hash(file, checkCancellation: true)
    }

    func close() { try? file.close() }

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
        while true {
            try Task.checkCancellation()
            guard let bytes = try file.read(upToCount: 4 * 1024 * 1024), !bytes.isEmpty else { break }
            try output.write(contentsOf: bytes)
        }
        try output.synchronize()
        try output.close()
        guard try Disk.hash(destination, checkCancellation: true) == digest else {
            throw ScribeError.message("Не удалось проверить сохранённый оригинал")
        }
        verified = true
    }
}
