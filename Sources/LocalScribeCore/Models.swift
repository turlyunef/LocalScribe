import Foundation

public struct ModelFile: Codable, Sendable {
    public var path: String; public var localPath: String; public var size: Int64; public var sha256: String
}
public struct ModelProfile: Codable, Sendable, Identifiable {
    public var id: String; public var repository: String; public var revision: String; public var license: String; public var files: [ModelFile]
    public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
}
public struct ModelCatalog: Codable, Sendable {
    public var schemaVersion: Int; public var models: [ModelProfile]
    public var fingerprint: String { Disk.fingerprint(models.map { $0.revision }.joined(separator: ":")) }
    public func validate(at root: URL, progress: (@Sendable (String) -> Void)? = nil) throws {
        for m in models {
            for f in m.files {
                let path = root.appendingPathComponent(m.id).appendingPathComponent(f.localPath)
                guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == f.size,
                      try Disk.hash(path) == f.sha256 else { throw ScribeError.message("Модель \(m.id): отсутствует или повреждён \(f.localPath)") }
            }
            progress?(m.id)
        }
    }
}

/// Explicit network operations only. Inference does not hold an instance of this actor.
public actor ModelInstaller {
    public init() {}
    public func install(_ profile: ModelProfile, root: URL, localSource: URL? = nil,
                        fetch: (@Sendable (Int) async throws -> FileHandle)? = nil,
                        progress: @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        let final = root.appendingPathComponent(profile.id)
        if fm.fileExists(atPath:final.path) {
            let valid = profile.files.allSatisfy { file in
                let url = final.appendingPathComponent(file.localPath)
                return (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize).map(Int64.init) == file.size && (try? Disk.hash(url)) == file.sha256
            }
            if valid { progress("\(profile.id): проверено"); return }
        }
        let partial = root.appendingPathComponent(profile.id + ".partial")
        try Disk.directory(partial)
        try Disk.requireSpace(profile.bytes + 500_000_000, at: root)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for (index, f) in profile.files.enumerated() {
            try Task.checkCancellation()
            guard !f.localPath.hasPrefix("/"), !f.localPath.split(separator: "/").contains("..") else { throw ScribeError.message("Недопустимый путь в каталоге моделей") }
            let destination = partial.appendingPathComponent(f.localPath)
            if fm.fileExists(atPath: destination.path), (try? Disk.hash(destination)) == f.sha256 { continue }
            try Disk.directory(destination.deletingLastPathComponent())
            progress("\(profile.id): файл \(index + 1) из \(profile.files.count)")
            if let localSource {
                let source = localSource.appendingPathComponent(f.localPath)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: source, to: destination)
            } else if let fetch {
                let source = try await fetch(index)
                defer { try? source.close() }
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                guard fm.createFile(atPath: destination.path, contents: nil) else { throw ScribeError.message("Не удалось создать файл модели") }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                while let bytes = try source.read(upToCount:4*1024*1024), !bytes.isEmpty { try Task.checkCancellation(); try output.write(contentsOf:bytes) }
                try output.synchronize()
            } else {
                let encoded = f.path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }.joined(separator: "/")
                let url = URL(string: "https://huggingface.co/\(profile.repository)/resolve/\(profile.revision)/\(encoded)")!
                let (temp, response) = try await session.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ScribeError.message("Источник модели недоступен") }
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: temp, to: destination)
            }
            guard (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == f.size,
                  try Disk.hash(destination) == f.sha256 else { try? fm.removeItem(at: destination); throw ScribeError.message("Не совпала SHA-256 файла \(f.localPath). Повторите загрузку.") }
        }
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: partial, to: final)
    }
}
