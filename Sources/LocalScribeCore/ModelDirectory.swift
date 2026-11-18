import Darwin
import Foundation

/// Every model path is traversed relative to a pinned directory, without following
/// links. Keep these descriptors alive across downloads and progress callbacks.
final class ModelDirectory {
    let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    static var unsafePath: ScribeError { .message("Небезопасный путь в каталоге моделей: требуется каталог или обычный файл без символических ссылок") }

    static func root(_ url: URL) throws -> ModelDirectory {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw unsafePath }
        // macOS exposes its temporary directories through these system aliases.
        // Expand only the fixed OS aliases, never resolve links supplied in models.
        var path = url.path
        for alias in ["var", "tmp", "etc"] {
            if path.hasPrefix("/\(alias)/") { path = "/private" + path; break }
        }
        // Traversal needs search permission, not directory-listing access to
        // ancestors outside the app container.
        var directory = ModelDirectory(Darwin.open("/", O_SEARCH | O_CLOEXEC))
        guard directory.descriptor >= 0 else { throw unsafePath }
        for component in path.split(separator: "/").map(String.init) {
            guard ModelProfile.safeComponent(component) else { throw unsafePath }
            directory = try directory.child(component, create: true)!
        }
        return directory
    }

    func child(_ name: String, create: Bool = false) throws -> ModelDirectory? {
        var fd = openat(descriptor, name, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT, create {
            // Do not request write access to existing ancestors of the container.
            if mkdirat(descriptor, name, 0o700) != 0, errno != EEXIST { throw Self.unsafePath }
            fd = openat(descriptor, name, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        }
        if fd < 0 {
            if !create, errno == ENOENT { return nil }
            throw Self.unsafePath
        }
        return ModelDirectory(fd)
    }

    func location(_ path: String, create: Bool = true) throws -> (ModelDirectory, String)? {
        let parts = path.split(separator: "/").map(String.init)
        var directory = self
        for name in parts.dropLast() {
            guard let child = try directory.child(name, create: create) else { return nil }
            directory = child
        }
        guard let name = parts.last else { throw Self.unsafePath }
        return (directory, name)
    }

    func read(_ name: String) throws -> FileHandle? {
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw Self.unsafePath
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw Self.unsafePath }
        return file
    }

    func create(_ name: String) throws -> FileHandle {
        // Unlink rather than truncate: an existing hard link must not modify its
        // other names. O_EXCL also rejects a link inserted after the unlink.
        try remove(name)
        let fd = openat(descriptor, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.unsafePath }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func matches(_ file: ModelFile) throws -> Bool {
        guard let (parent, name) = try location(file.localPath, create: false) else { return false }
        guard let input = try parent.read(name) else { return false }
        defer { try? input.close() }
        return try Self.matches(input, file)
    }

    static func matches(_ input: FileHandle, _ file: ModelFile) throws -> Bool {
        var status = stat()
        guard fstat(input.fileDescriptor, &status) == 0 else { throw unsafePath }
        guard status.st_size == file.size else { return false }
        try input.seek(toOffset: 0)
        return try Disk.hash(input, checkCancellation: true) == file.sha256
    }

    private func names() throws -> [String] {
        // Opening '.' gives readdir its own offset; dup would share that offset.
        let fd = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.unsafePath }
        guard let stream = fdopendir(fd) else { Darwin.close(fd); throw Self.unsafePath }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Self.unsafePath }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
        }
    }

    /// Check even unlisted entries, so a leftover symlink cannot be published.
    func validateTree() throws {
        for name in try names() {
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.unsafePath }
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                guard let directory = try child(name) else { throw Self.unsafePath }
                try directory.validateTree()
            case S_IFREG: break
            default: throw Self.unsafePath
            }
        }
    }

    func remove(_ name: String) throws {
        var status = stat()
        if fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw Self.unsafePath
        }
        if status.st_mode & S_IFMT == S_IFDIR {
            guard let directory = try child(name) else { throw Self.unsafePath }
            for entry in try directory.names() { try directory.remove(entry) }
            guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw Self.unsafePath }
        } else {
            // unlinkat never follows the last component, including during cleanup.
            guard unlinkat(descriptor, name, 0) == 0 else { throw Self.unsafePath }
        }
    }

    /// Claim the completed partial inside a fresh private parent before publishing.
    /// A replacement of the public partial name cannot become the final model.
    func publish(_ partial: ModelDirectory, named partialName: String, as finalName: String, profile: ModelProfile) throws {
        let stagingName = ".model-publish-" + UUID().uuidString
        guard mkdirat(descriptor, stagingName, 0o700) == 0 else { throw Self.unsafePath }
        guard let staging = try child(stagingName) else { throw Self.unsafePath }
        // Only remove an empty staging parent. If rollback cannot restore the
        // public name, retain its contents rather than deleting verified files.
        defer { _ = unlinkat(descriptor, stagingName, AT_REMOVEDIR) }
        guard renameatx_np(descriptor, partialName, staging.descriptor, "contents", UInt32(RENAME_EXCL)) == 0 else { throw Self.unsafePath }
        var published = false
        defer {
            if !published {
                // Do not overwrite a new partial installed by another caller.
                // Keep the claimed files if restoration fails.
                _ = renameatx_np(staging.descriptor, "contents", descriptor, partialName, UInt32(RENAME_EXCL))
            }
        }
        guard let claimed = try staging.child("contents") else { throw Self.unsafePath }
        var expected = stat(), actual = stat()
        guard fstat(partial.descriptor, &expected) == 0, fstat(claimed.descriptor, &actual) == 0,
              expected.st_dev == actual.st_dev, expected.st_ino == actual.st_ino else { throw Self.unsafePath }
        try claimed.validateTree()
        for file in profile.files {
            guard try claimed.matches(file) else { throw ScribeError.message("Не совпала SHA-256 файла \(file.localPath). Повторите загрузку.") }
        }
        try Task.checkCancellation()
        let final = try child(finalName)
        try final?.validateTree()
        let flags = final == nil ? RENAME_EXCL : RENAME_SWAP
        guard renameatx_np(staging.descriptor, "contents", descriptor, finalName, UInt32(flags)) == 0 else { throw Self.unsafePath }
        published = true
        // After a swap the previous installation is privately staged. Failure
        // to remove it cannot invalidate the newly published installation.
        if final != nil { try? staging.remove("contents") }
    }
}
