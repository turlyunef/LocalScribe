import Foundation

/// Rebuild a native report from an explicit subset of IPS fields. The selected
/// file, its path, symbols, free text and unrecognized fields never enter export.
struct NativeCrashAttachment: Codable, Sendable {
    enum Executable: String, Codable, Sendable {
        case app = "LocalScribe"
        case worker = "LocalScribeWorker"
        case modelService = "LocalScribeModelService"
    }

    enum Signal: String, Codable, Sendable {
        case abort = "SIGABRT", trap = "SIGTRAP", illegal = "SIGILL", segfault = "SIGSEGV"
        case bus = "SIGBUS", kill = "SIGKILL", term = "SIGTERM", floatingPoint = "SIGFPE"
    }

    enum TerminationNamespace: String, Codable, Sendable {
        case signal = "SIGNAL", dyld = "DYLD", codesigning = "CODESIGNING", watchdog = "WATCHDOG"
        case resource = "RESOURCE", runningboard = "RUNNINGBOARD", libsystem = "LIBSYSTEM"
    }

    struct Frame: Codable, Sendable {
        let imageUUID: UUID
        let imageOffset: UInt64
    }

    let executable: Executable
    let executableUUID: UUID
    let timestamp: Date?
    let signal: Signal?
    let terminationNamespace: TerminationNamespace?
    let terminationCode: UInt64?
    let frames: [Frame]

    enum ReadError: Error { case unsupportedReport }
    static let maximumBytes = 4 * 1024 * 1024

    private struct Header: Decodable {
        let bug_type: String
        let slice_uuid: UUID?
        let timestamp: String?
    }

    private struct Body: Decodable {
        struct Image: Decodable { let uuid: UUID?; let name: String?; let size: UInt64? }
        struct CrashThread: Decodable {
            struct RawFrame: Decodable { let imageIndex: Int?; let imageOffset: UInt64? }
            let triggered: Bool?
            let frames: [RawFrame]?
        }
        struct ExceptionInfo: Decodable { let signal: String? }
        struct TerminationInfo: Decodable { let namespace: String?; let code: UInt64? }

        let procName: String
        let faultingThread: Int?
        let threads: [CrashThread]?
        let usedImages: [Image]
        let exception: ExceptionInfo?
        let termination: TerminationInfo?
    }

    static func read(_ url: URL) throws -> Self {
        guard url.pathExtension.lowercased() == "ips" else { throw ReadError.unsupportedReport }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else {
            throw ReadError.unsupportedReport
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try parse(file.read(upToCount: maximumBytes + 1) ?? Data())
    }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes, let lineEnd = data.firstIndex(of: 10) else {
            throw ReadError.unsupportedReport
        }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data[..<lineEnd])
        guard header.bug_type == "309" else { throw ReadError.unsupportedReport }
        let body = try decoder.decode(Body.self, from: data[(lineEnd + 1)...])
        guard let executable = Executable(rawValue: body.procName),
              let imageUUID = body.usedImages.first(where: { $0.name == executable.rawValue })?.uuid,
              header.slice_uuid == nil || header.slice_uuid == imageUUID else {
            throw ReadError.unsupportedReport
        }
        let threads = body.threads ?? []
        let thread = body.faultingThread.flatMap { threads.indices.contains($0) ? threads[$0] : nil }
            ?? threads.first(where: { $0.triggered == true })
        let frames: [Frame] = (thread?.frames ?? []).prefix(96).compactMap { frame in
            guard let index = frame.imageIndex, body.usedImages.indices.contains(index),
                  let uuid = body.usedImages[index].uuid, let offset = frame.imageOffset,
                  let size = body.usedImages[index].size, offset < size else { return nil }
            return Frame(imageUUID: uuid, imageOffset: offset)
        }
        let timestamp = header.timestamp.flatMap { value -> Date? in
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
            return format.date(from: value)
        }
        return Self(executable: executable, executableUUID: imageUUID, timestamp: timestamp,
                    signal: body.exception?.signal.flatMap(Signal.init(rawValue:)),
                    terminationNamespace: body.termination?.namespace.flatMap(TerminationNamespace.init(rawValue:)),
                    terminationCode: body.termination?.code, frames: frames)
    }
}
