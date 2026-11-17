import Foundation
import CryptoKit

public enum ScribeError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
public enum Disk {
    static let maximumJSONBytes = 64 * 1024 * 1024

    public static func directory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    public static func write<T: Encodable>(_ value: T, to url: URL, requireReadableSize: Bool = false) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard !requireReadableSize || data.count <= maximumJSONBytes else {
            throw ScribeError.message("Файл JSON превышает допустимый размер")
        }
        try directory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }
    public static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map({ $0 <= maximumJSONBytes }) == true else { throw ScribeError.message("Файл JSON превышает допустимый размер") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumJSONBytes else { throw ScribeError.message("Файл JSON превышает допустимый размер") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
    public static func hash(_ url: URL, checkCancellation: Bool = false) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        return try hash(file, checkCancellation: checkCancellation)
    }
    static func hash(_ file: FileHandle, checkCancellation: Bool = false) throws -> String {
        var hash = SHA256()
        while true {
            if checkCancellation { try Task.checkCancellation() }
            // Foundation's read buffers can outlive each iteration in an async
            // task's autorelease pool. Drain them here to keep large-file hashes bounded.
            let hasBytes = try autoreleasepool {
                guard let bytes = try file.read(upToCount: 4 * 1024 * 1024), !bytes.isEmpty else { return false }
                hash.update(data: bytes)
                return true
            }
            if !hasBytes { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func fingerprint(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func requireSpace(_ bytes: Int64, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard (values.volumeAvailableCapacityForImportantUsage ?? 0) > bytes else { throw ScribeError.message("Недостаточно свободного места. Требуется ещё \(bytes / 1_000_000) МБ.") }
    }
}
public enum Stage: String, Codable, Sendable { case preparingAudio, transcribing, diarizing, summarizing }
public enum JobState: String, Codable, Sendable {
    case recording, recorded, waitingForModels, queued, preparingAudio, transcribing, diarizing, summarizing, completed, completedWithWarnings, interrupted, cancelled, failed
    public var title: String {
        switch self {
        case .recording: return L10n.text("Идёт запись")
        case .recorded: return L10n.text("Сохранено")
        case .waitingForModels: return L10n.text("Ожидает модели")
        case .queued: return L10n.text("В очереди")
        case .preparingAudio: return L10n.text("Подготавливаем аудио")
        case .transcribing: return L10n.text("Распознаём речь")
        case .diarizing: return L10n.text("Определяем участников")
        case .summarizing: return L10n.text("Составляем итоги")
        case .completed: return L10n.text("Готово")
        case .completedWithWarnings: return L10n.text("Готово с предупреждениями")
        case .interrupted: return L10n.text("Прервано — можно продолжить")
        case .cancelled: return L10n.text("Отменено")
        case .failed: return L10n.text("Ошибка — можно повторить")
        }
    }
    public var processing: Bool { [.preparingAudio, .transcribing, .diarizing, .summarizing].contains(self) }
}
public struct Manifest: Codable, Identifiable, Sendable {
    public static let maximumDurationMs = 10_800_000
    public var schemaVersion = 1
    public var id: String
    public var sourceType: String
    public var displayTitle: String
    public var createdAt: Date
    public var recordedAt: Date?
    public var originalFilename: String
    public var originalRelativePath: String
    public var sha256 = ""
    public var durationMs = 0
    public var sampleRate: Double = 0
    public var channels = 0
    public var sourceComplete = false
    public var state: JobState = .recorded
    public var activeRunId: String?
    public var pendingRunId: String?
    public var captureProcessing: JobState?
    public var warnings: [String] = []
    public var lastError: String?
    public init(sourceType: String, title: String, filename: String) {
        id = UUID().uuidString; self.sourceType = sourceType; displayTitle = title; createdAt = Date()
        recordedAt = sourceType == "microphone" ? createdAt : nil
        originalFilename = filename; originalRelativePath = "source/original.\((filename as NSString).pathExtension.lowercased())"
    }
}
public struct RunInfo: Codable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var sourceHash: String
    public var profileHash: String
    public static let currentPipelineVersion = "1.0.0-audio2-asr14-live1-diarization4-summary17"
    public var pipelineVersion = RunInfo.currentPipelineVersion
    public var summaryLanguage: String?
    public var modelIDs: [String: String]?
    public var auxiliaryModelIDs: [String: String]?
    /// Normalized recognition dictionary snapshot pinned when the ASR job was
    /// created; nil for runs made without a dictionary (all older runs). Terms
    /// are single-line, so the joined fingerprint input is unambiguous.
    public var recognitionTerms: [String]?
    public var transcriptSourceRunID: String?
    /// Nil identifies archives written before explicit result provenance.
    public var manualEdits: Bool? = false
    public var liveCapture: Bool?
    public var createdAt = Date()
    public init(id: String = UUID().uuidString, sourceHash: String, profileHash: String, summaryLanguage: String? = nil) {
        self.id = id; self.sourceHash = sourceHash; self.profileHash = profileHash; self.summaryLanguage = summaryLanguage
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(String.self, forKey: .id)
        sourceHash = try values.decode(String.self, forKey: .sourceHash)
        profileHash = try values.decode(String.self, forKey: .profileHash)
        pipelineVersion = try values.decode(String.self, forKey: .pipelineVersion)
        summaryLanguage = try values.decodeIfPresent(String.self, forKey: .summaryLanguage)
        modelIDs = try values.decodeIfPresent([String: String].self, forKey: .modelIDs)
        auxiliaryModelIDs = try values.decodeIfPresent([String: String].self, forKey: .auxiliaryModelIDs)
        recognitionTerms = try values.decodeIfPresent([String].self, forKey: .recognitionTerms)
        transcriptSourceRunID = try values.decodeIfPresent(String.self, forKey: .transcriptSourceRunID)
        manualEdits = try values.decodeIfPresent(Bool.self, forKey: .manualEdits)
        liveCapture = try values.decodeIfPresent(Bool.self, forKey: .liveCapture)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        try RecognitionDictionary.validateSnapshot(recognitionTerms)
    }
    /// Runs without a dictionary keep the historical formula; a non-empty
    /// dictionary changes recognition and therefore the checkpoint identity.
    public var fingerprint: String {
        guard let terms = recognitionTerms, !terms.isEmpty else {
            return Disk.fingerprint(sourceHash + profileHash + pipelineVersion)
        }
        return Disk.fingerprint(sourceHash + profileHash + pipelineVersion + "recognition:" + terms.joined(separator: "\n"))
    }
    public func modelID(for role: ModelRole) throws -> String {
        let id = modelIDs?[role.rawValue] ?? role.rawValue
        guard ModelProfile.safeComponent(id) else { throw ScribeError.message("Недопустимый идентификатор модели") }
        return id
    }
}
public struct Word: Codable, Sendable, Equatable {
    public var text: String; public var startMs: Int; public var endMs: Int
    public init(text: String, startMs: Int, endMs: Int) { self.text = text; self.startMs = startMs; self.endMs = endMs }
}
public struct Segment: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var startMs: Int; public var endMs: Int
    public var speakerId: String?
    public var text: String; public var language: String
    public var overlap: Bool; public var uncertain: Bool
    public var words: [Word]
    public init(id: String, startMs: Int, endMs: Int, speakerId: String? = nil, text: String, language: String, overlap: Bool = false, uncertain: Bool = false, words: [Word] = []) {
        self.id = id; self.startMs = startMs; self.endMs = endMs; self.speakerId = speakerId; self.text = text; self.language = language; self.overlap = overlap; self.uncertain = uncertain; self.words = words
    }
}
public struct Transcript: Codable, Sendable, Equatable {
    public var schemaVersion = 1; public var fingerprint: String
    public var diarized: Bool; public var segments: [Segment]
    public init(fingerprint: String, diarized: Bool, segments: [Segment]) { self.fingerprint = fingerprint; self.diarized = diarized; self.segments = segments }
    public func validate(durationMs: Int) throws {
        guard (0...Manifest.maximumDurationMs).contains(durationMs), schemaVersion == 1, Set(segments.map(\.id)).count == segments.count,
              segments.allSatisfy({ !$0.id.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.startMs >= 0 && $0.endMs >= $0.startMs && $0.endMs <= durationMs && $0.words.allSatisfy { $0.startMs >= 0 && $0.endMs >= $0.startMs && $0.endMs <= durationMs } }) else {
            throw ScribeError.message("Некорректные таймкоды или идентификаторы расшифровки")
        }
    }
    public var primaryLanguage: String {
        var ru = 0, en = 0
        func count(_ text: String, duration: Int) {
            let cyr = text.unicodeScalars.filter { (0x400...0x52f).contains($0.value) }.count
            let lat = text.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) }.count
            if cyr + lat > 0 { ru += duration * cyr / (cyr + lat); en += duration * lat / (cyr + lat) }
        }
        for s in segments where !s.uncertain {
            if s.words.isEmpty { count(s.text,duration:max(0,s.endMs-s.startMs)) }
            else { for word in s.words { count(word.text,duration:max(0,word.endMs-word.startMs)) } }
        }
        return en > ru ? "en" : "ru"
    }
}
public struct Finding: Codable, Identifiable, Sendable, Equatable {
    public var id: String; public var text: String
    public var evidenceSegmentIds: [String]
    public var ownerSpeakerId: String?; public var ownerName: String?; public var dueText: String?
    public var uncertain: Bool
    public init(id: String, text: String, evidenceSegmentIds: [String], ownerSpeakerId: String? = nil, ownerName: String? = nil, dueText: String? = nil, uncertain: Bool = false) {
        self.id = id; self.text = text; self.evidenceSegmentIds = evidenceSegmentIds; self.ownerSpeakerId = ownerSpeakerId; self.ownerName = ownerName; self.dueText = dueText; self.uncertain = uncertain
    }
}
public struct Summary: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var language: String
    public var overview: [Finding]; public var decisions: [Finding]; public var tasks: [Finding]; public var openQuestions: [Finding]
    public init(language: String, overview: [Finding] = [], decisions: [Finding] = [], tasks: [Finding] = [], openQuestions: [Finding] = []) {
        self.language = language; self.overview = overview; self.decisions = decisions; self.tasks = tasks; self.openQuestions = openQuestions
    }
    /// Apply only after checking amendments. Different owners/deadlines stay distinct;
    /// repeated wording retains every source link and any uncertainty.
    public func coalescingExactRepeats() -> Summary {
        func merge(_ input: [Finding]) -> [Finding] {
            var result: [Finding] = [], indexes: [[String?]:Int] = [:]
            for item in input {
                let text = item.text.lowercased().trimmingCharacters(in:.whitespacesAndNewlines.union(CharacterSet(charactersIn:".!?")))
                let key: [String?] = [text,item.ownerSpeakerId,item.ownerName,item.dueText]
                if let index = indexes[key] {
                    for id in item.evidenceSegmentIds where !result[index].evidenceSegmentIds.contains(id) { result[index].evidenceSegmentIds.append(id) }
                    result[index].uncertain = result[index].uncertain || item.uncertain
                } else { indexes[key] = result.count; result.append(item) }
            }
            return result
        }
        return Summary(language:language,overview:merge(overview),decisions:merge(decisions),tasks:merge(tasks),openQuestions:merge(openQuestions))
    }
    /// Only manual result revisions may contain findings without source links.
    /// Generated summaries continue to require evidence by default.
    public func validate(against transcript: Transcript, allowingUnlinkedFindings: Bool = false) throws {
        let segmentsByID = Dictionary(grouping: transcript.segments, by: \.id)
        let ids = Set(segmentsByID.keys), speakers = Set(transcript.segments.compactMap(\.speakerId))
        guard schemaVersion == 1, ["ru", "en"].contains(language) else { throw ScribeError.message("Некорректная версия или язык итогов") }
        for f in overview + decisions + tasks + openQuestions {
            let unlinked = allowingUnlinkedFindings && f.evidenceSegmentIds.isEmpty
            guard !f.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, f.text.count <= 3000,
                  unlinked || !f.evidenceSegmentIds.isEmpty, Set(f.evidenceSegmentIds).isSubset(of: ids),
                  unlinked || f.ownerSpeakerId == nil || speakers.contains(f.ownerSpeakerId!),
                  f.ownerName == nil || !f.ownerName!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  f.dueText == nil || !f.dueText!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ScribeError.message("Итоги не прошли проверку ссылок и полей") }
            if unlinked { continue }
            let evidence = f.evidenceSegmentIds.flatMap { segmentsByID[$0] ?? [] }
            if let owner = f.ownerSpeakerId, !evidence.contains(where: { $0.speakerId == owner }) { throw ScribeError.message("Спикер ответственного отсутствует в основании") }
            if let name = f.ownerName, !evidence.contains(where: { $0.text.localizedCaseInsensitiveContains(name) }) { throw ScribeError.message("Имя ответственного отсутствует в основании") }
            if let due = f.dueText, !evidence.contains(where: { $0.text.localizedCaseInsensitiveContains(due) }) { throw ScribeError.message("Срок отсутствует в основании") }
            if !f.uncertain, evidence.contains(where: \.uncertain) { throw ScribeError.message("Неопределённость исходной реплики потеряна") }
        }
    }
    /// Reject unsupported optional claims conservatively, without rewriting the fact text,
    /// inventing replacements, or deleting a supported action because its deadline was wrong.
    public func groundingOptionalFields(against transcript: Transcript) -> (Summary, Bool) {
        var result = self, changed = false
        func ground(_ input: [Finding]) -> [Finding] {
            input.map { original in
                var item = original
                let evidence = transcript.segments.filter { item.evidenceSegmentIds.contains($0.id) }
                if let owner = item.ownerSpeakerId, !evidence.contains(where:{$0.speakerId == owner}) { item.ownerSpeakerId = nil }
                if let name = item.ownerName, name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !evidence.contains(where:{$0.text.localizedCaseInsensitiveContains(name)}) { item.ownerName = nil }
                if let due = item.dueText, due.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !evidence.contains(where:{$0.text.localizedCaseInsensitiveContains(due)}) { item.dueText = nil }
                if evidence.contains(where:{$0.uncertain}) { item.uncertain = true }
                if item != original { changed = true }; return item
            }
        }
        result.overview = ground(overview); result.decisions = ground(decisions); result.tasks = ground(tasks); result.openQuestions = ground(openQuestions)
        return (result,changed)
    }
}
public struct WorkerCommand: Codable, Sendable {
    public var version = 1
    /// Nil preserves the historical audio wire format; "diagram" and
    /// "anonymization" route to their own handlers. Unknown kinds exit 64.
    public var kind: String?
    public var jobId: String; public var runId: String
    public var stage: Stage?
    public var recordingPath: String?
    public var diagramPath: String?
    public var anonymizationPath: String?
    public var modelsPath: String
    public var toolsPath: String?
    public var liveCapture: Bool?
    public init(jobId: String, runId: String, stage: Stage, recordingPath: String, modelsPath: String, toolsPath: String) { self.jobId = jobId; self.runId = runId; self.stage = stage; self.recordingPath = recordingPath; self.modelsPath = modelsPath; self.toolsPath = toolsPath }
    public init(diagramJobId: String, runId: String, diagramPath: String, modelsPath: String, toolsPath: String? = nil) { kind = "diagram"; jobId = diagramJobId; self.runId = runId; self.diagramPath = diagramPath; self.modelsPath = modelsPath; self.toolsPath = toolsPath }
    /// Text anonymization: `anonymizationPath` names the attempt workspace whose
    /// local artifacts carry the document; the text never travels over JSONL.
    public init(anonymizationJobId: String, runId: String, anonymizationPath: String, modelsPath: String, toolsPath: String? = nil) { kind = "anonymization"; jobId = anonymizationJobId; self.runId = runId; self.anonymizationPath = anonymizationPath; self.modelsPath = modelsPath; self.toolsPath = toolsPath }
    public var isDiagram: Bool { kind == "diagram" }
    public var isAnonymization: Bool { kind == "anonymization" }
}
public struct WorkerEvent: Codable, Sendable {
    public var version = 1; public var jobId: String; public var runId: String
    /// Job-kind discriminator echoed from the command ("diagram", "anonymization");
    /// absent for the historical kindless audio events.
    public var kind: String?
    public var type: String; public var message: String; public var artifact: String?
    public var diagnosticFailure: DiagnosticFailure?
    public var diagnosticPhase: DiagnosticPhase?
    public init(command: WorkerCommand, type: String, message: String = "", artifact: String? = nil) { jobId = command.jobId; runId = command.runId; kind = command.kind; self.type = type; self.message = message; self.artifact = artifact }
    public var isDiagram: Bool { kind == "diagram" }
    public var isAnonymization: Bool { kind == "anonymization" }
}
public func timecode(_ ms: Int) -> String { let s = max(0, ms) / 1000; return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
public func speakerName(_ id: String?) -> String {
    guard let id else { return L10n.text("Спикер не определён") }
    return L10n.text("Спикер %1$@", id.replacingOccurrences(of: "speaker-", with: ""))
}
