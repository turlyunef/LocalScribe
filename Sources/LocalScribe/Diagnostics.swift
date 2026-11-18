import Darwin
import Foundation
import os
import LocalScribeCore

enum DiagnosticOperation: String, Codable, Sendable {
    case application, archive, importAudio, importDiagram, importText, capture, export
    case modelDownload, modelImport, modelVerification, recording, diagram, anonymization
}

enum DiagnosticMode: String, Codable, Sendable { case new, resume, retry }

struct DiagnosticJobReference: Codable, Equatable, Sendable {
    let operation: DiagnosticOperation
    let itemID: UUID
    var runID: UUID?

    init?(_ operation: DiagnosticOperation, item: String, run: String? = nil) {
        guard let itemID = UUID(uuidString: item) else { return nil }
        self.operation = operation
        self.itemID = itemID
        runID = run.flatMap(UUID.init(uuidString:))
    }
}

struct DiagnosticJob: Codable, Sendable {
    struct Model: Codable, Sendable {
        let profile: String
        let revision: String
        let backend: Backend

        enum Backend: String, Codable, Sendable {
            case whisper, qwen, qwen3, vibevoice, gigaam, speakerKit, mlx, unknown
        }

        init(_ profile: ModelProfile, backend: Backend) {
            self.profile = DiagnosticField.identifier(profile.id) ?? "unknown"
            revision = DiagnosticField.identifier(profile.revision) ?? "unknown"
            self.backend = backend
        }
    }

    var reference: DiagnosticJobReference?
    var mode: DiagnosticMode = .new
    var stage: Stage?
    var phase: DiagnosticPhase?
    var live: Bool?
    var pipeline: String?
    var prompt: String?
    var preprocessing: String?
    var models: [Model] = []
    var inputFormat: String?
    var durationMs: Int?
    var sampleRate: Double?
    var channels: Int?
    var width: Int?
    var height: Int?
    var bytes: UInt?
    var limitBytes: UInt?
}

enum DiagnosticField {
    static func identifier(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 128, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }) else { return nil }
        return value
    }

    static func audioFormat(_ extensionName: String) -> String {
        let allowed = ["wav", "caf", "aac", "m4a", "mp4", "mp3", "flac", "ogg", "oga", "opus", "aif", "aiff"]
        return allowed.contains(extensionName) ? extensionName : "other"
    }
}

struct DiagnosticEnvironment: Codable, Sendable {
    let appVersion: String
    let build: String
    let macOS: String
    let chip: String?
    let ramBytes: UInt64?

    init(hardware: ModelHardware? = nil) {
        appVersion = DiagnosticField.identifier(AppInfo.version) ?? "unknown"
        build = DiagnosticField.identifier(AppInfo.build) ?? "unknown"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        macOS = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        chip = hardware.flatMap { value in
            let name = value.chip
            return name == "Apple Silicon" || name.range(of: #"^Apple M[0-9]+( (Pro|Max|Ultra))?$"#, options: .regularExpression) != nil ? name : nil
        }
        ramBytes = hardware?.memoryBytes
    }

}

struct DiagnosticWorkerExit: Codable, Sendable {
    enum Reason: String, Codable, Sendable { case exit, signal }
    enum Event: String, Codable, Sendable { case started, progress, warning, checkpoint, completed, failed, cancelled, diagnostic }

    let reason: Reason
    let status: Int32
    let lastEvent: Event?
    let elapsedMs: Int

    var signalName: String? {
        guard reason == .signal else { return nil }
        return [SIGILL: "SIGILL", SIGTRAP: "SIGTRAP", SIGABRT: "SIGABRT", SIGFPE: "SIGFPE",
                SIGKILL: "SIGKILL", SIGBUS: "SIGBUS", SIGSEGV: "SIGSEGV", SIGTERM: "SIGTERM"][status]
    }
}

struct DiagnosticEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case appStarted, appStopped, jobStarted, stageStarted, workerStarted, workerPhase, workerFinished
        case captureStarted, captureStopped, importStarted, downloadStarted
        case memoryWarning, memoryCritical, memoryNormal, capturePressure, sleep, error
    }

    let time: Date
    let session: UUID
    let kind: Kind
    var environment: DiagnosticEnvironment?
    var operation: DiagnosticOperation?
    var job: DiagnosticJob?
    var failure: DiagnosticFailure?
    var worker: DiagnosticWorkerExit?
}

struct DiagnosticReport: Codable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let time: Date
    let environment: DiagnosticEnvironment
    let operation: DiagnosticOperation
    let failure: DiagnosticFailure
    let job: DiagnosticJob?
    let worker: DiagnosticWorkerExit?
    let events: [DiagnosticEvent]

    var clipboardText: String {
        let header = [
            "LocalScribe \(environment.appVersion) (\(environment.build))",
            "macOS \(environment.macOS)",
            L10n.text("Время ошибки: %1$@", ISO8601DateFormatter().string(from: time)),
            [operation.rawValue, failure.phase?.rawValue, failure.code.rawValue].compactMap { $0 }.joined(separator: " / ")
        ]
        return (header + [worker?.signalName ?? "", "", DiagnosticJSON.text(self)]).joined(separator: "\n")
    }
}

enum DiagnosticJSON {
    static func data(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func text(_ value: some Encodable) -> String {
        guard let data = try? data(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Single writer and fixed retention. Disk I/O stays outside the main actor.
final class DiagnosticsJournal: @unchecked Sendable {
    struct History: Codable, Sendable {
        var schemaVersion = 1
        var reports: [DiagnosticReport] = []
        var events: [DiagnosticEvent] = []
    }

    private static let logger = Logger(subsystem: "local.localscribe.mac", category: "diagnostics")
    private let queue = DispatchQueue(label: "local.localscribe.mac.diagnostics")
    private let file: URL?
    private var history = History()

    init(root: URL?) {
        file = root?.appendingPathComponent("diagnostic-history.json")
        queue.async {
            guard let file = self.file,
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
                  let saved = try? Disk.read(History.self, at: file), saved.schemaVersion == 1 else { return }
            self.history = saved
        }
    }

    func append(event: DiagnosticEvent, report: DiagnosticReport? = nil) {
        queue.async {
            self.history.events.append(event)
            self.history.events = Array(self.history.events.suffix(80))
            if let report {
                self.history.reports.append(report)
                self.history.reports = Array(self.history.reports.suffix(30))
            }
            guard let file = self.file else { return }
            do {
                try Disk.write(self.history, to: file)
            } catch {
                // Best-effort persistence: log the failure, never drop the in-memory history.
                Self.logger.error("Could not persist diagnostic history: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func snapshot() async -> History {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.history) }
        }
    }
}
