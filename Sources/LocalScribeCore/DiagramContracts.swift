import Foundation

/// Diagram jobs never reuse audio JobState: their statuses, recovery and
/// presentation are independent, and the archives must not share manifests.
public enum DiagramState: String, Codable, Sendable {
    case waitingForModels, queued, recognizing, completed, completedWithWarnings, interrupted, cancelled, failed
    public var title: String {
        switch self {
        case .waitingForModels: return "Ожидает модель"
        case .queued: return "В очереди"
        case .recognizing: return "Распознаётся"
        case .completed: return "Распознана"
        case .completedWithWarnings: return "Распознана с предупреждениями"
        case .interrupted: return "Прервана — можно повторить"
        case .cancelled: return "Отменена"
        case .failed: return "Ошибка — можно повторить"
        }
    }
    public var processing: Bool { self == .recognizing }
}

/// A stored diagram image. The original bytes are kept without re-encoding;
/// recognition works on the archived copy only.
public struct DiagramManifest: Codable, Identifiable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var displayTitle: String
    public var createdAt = Date()
    public var originalFilename: String
    public var originalRelativePath: String
    public var uti: String
    public var byteSize: Int64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var orientation: Int
    public var sha256 = ""
    public var state: DiagramState = .waitingForModels
    public var activeRunId: String?
    public var pendingRunId: String?
    public var warnings: [String] = []
    public var lastError: String?
    public init(title: String, filename: String, ext: String, uti: String) {
        id = UUID().uuidString; displayTitle = title; originalFilename = filename
        originalRelativePath = "original.\(ext)"; self.uti = uti
        byteSize = 0; pixelWidth = 0; pixelHeight = 0; orientation = 1
    }
}

/// One recognition attempt. A retry always creates a new run; diagram runs
/// never promise token-level continuation like audio checkpoints.
public struct DiagramRunInfo: Codable, Sendable {
    public static let currentPipelineVersion = "1.0.0-diagram1"
    public static let currentPromptVersion = "diagram-prompt-v1"
    public static let currentPreprocessingVersion = "diagram-preprocess-v1"
    public var schemaVersion = 1
    public var id: String
    public var sourceHash: String
    public var modelID: String
    public var profileHash: String
    public var pipelineVersion = DiagramRunInfo.currentPipelineVersion
    public var promptVersion = DiagramRunInfo.currentPromptVersion
    public var preprocessingVersion = DiagramRunInfo.currentPreprocessingVersion
    public var createdAt = Date()
    public init(id: String = UUID().uuidString, sourceHash: String, modelID: String, profileHash: String) {
        self.id = id; self.sourceHash = sourceHash; self.modelID = modelID; self.profileHash = profileHash
    }
    public var fingerprint: String {
        Disk.fingerprint(sourceHash + profileHash + pipelineVersion + promptVersion + preprocessingVersion)
    }
}

public enum DiagramEdgeDirection: String, Codable, Sendable {
    case forward, backward, both, none
}

public struct DiagramNode: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var uncertain: Bool
    public init(id: String, label: String, uncertain: Bool = false) { self.id = id; self.label = label; self.uncertain = uncertain }
}

public struct DiagramEdge: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    public var direction: DiagramEdgeDirection
    public var label: String?
    public var uncertain: Bool
    public init(from: String, to: String, direction: DiagramEdgeDirection, label: String? = nil, uncertain: Bool = false) {
        self.from = from; self.to = to; self.direction = direction; self.label = label; self.uncertain = uncertain
    }
}

/// The single structural answer of a diagram run. A single confidently
/// recognized node without edges is a valid result; a broken reference,
/// truncated JSON or an empty graph is not.
public struct DiagramResult: Codable, Sendable, Equatable {
    public static let maxJSONBytes = 256 * 1024
    public static let maxNodes = 200
    public static let maxEdges = 400
    public static let maxLabelLength = 500
    public var schemaVersion = 1
    public var fingerprint: String
    public var language: String?
    public var nodes: [DiagramNode]
    public var edges: [DiagramEdge]
    public init(fingerprint: String, language: String? = nil, nodes: [DiagramNode], edges: [DiagramEdge]) {
        self.fingerprint = fingerprint; self.language = language; self.nodes = nodes; self.edges = edges
    }
    public func validate(expectedFingerprint: String) throws {
        guard schemaVersion == 1, fingerprint == expectedFingerprint else {
            throw ScribeError.message("Неверная версия или fingerprint результата схемы")
        }
        guard !nodes.isEmpty else { throw ScribeError.message("Результат схемы не содержит узлов") }
        guard nodes.count <= Self.maxNodes, edges.count <= Self.maxEdges else {
            throw ScribeError.message("Схема превышает лимит: не более \(Self.maxNodes) узлов и \(Self.maxEdges) связей")
        }
        let ids = Set(nodes.map(\.id))
        guard ids.count == nodes.count,
              nodes.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 64 && !$0.label.isEmpty && $0.label.count <= Self.maxLabelLength }) else {
            throw ScribeError.message("Некорректные идентификаторы или подписи узлов схемы")
        }
        for edge in edges {
            guard ids.contains(edge.from), ids.contains(edge.to) else {
                throw ScribeError.message("Связь схемы ссылается на отсутствующий узел")
            }
            if let label = edge.label, (label.isEmpty || label.count > Self.maxLabelLength) {
                throw ScribeError.message("Некорректная подпись связи схемы")
            }
        }
    }
}
