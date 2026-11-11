import Foundation

/// Diagram jobs never reuse audio JobState: their statuses, recovery and
/// presentation are independent, and the archives must not share manifests.
public enum DiagramState: String, Codable, Sendable {
    case waitingForModels, queued, recognizing, completed, completedWithWarnings, interrupted, cancelled, failed
    public var title: String {
        switch self {
        case .waitingForModels: return L10n.text("Ожидает модель")
        case .queued: return L10n.text("В очереди")
        case .recognizing: return L10n.text("Распознаётся")
        case .completed: return L10n.text("Распознана")
        case .completedWithWarnings: return L10n.text("Распознана с предупреждениями")
        case .interrupted: return L10n.text("Прервана — можно повторить")
        case .cancelled: return L10n.text("Отменена")
        case .failed: return L10n.text("Ошибка — можно повторить")
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
    public static let currentPipelineVersion = "1.0.0-diagram3"
    public static let currentPromptVersion = "diagram-prompt-v3"
    public static let currentPreprocessingVersion = "diagram-preprocess-v2"
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

    public var symbol: String {
        switch self {
        case .forward: return "→"
        case .backward: return "←"
        case .both: return "↔"
        case .none: return "—"
        }
    }
}

public enum DiagramKind: String, Codable, Sendable {
    case graph, sequence, state
}

public enum DiagramConnectionKind: String, Codable, Sendable {
    case association, aggregation, composition, generalization, realization, dependency, containment
    case message, reply, transition, dashed

    public var title: String {
        switch self {
        case .association: return L10n.text("Ассоциация")
        case .aggregation: return L10n.text("Агрегация")
        case .composition: return L10n.text("Композиция")
        case .generalization: return L10n.text("Обобщение")
        case .realization: return L10n.text("Реализация")
        case .dependency: return L10n.text("Зависимость")
        case .containment: return L10n.text("Вложенность")
        case .message: return L10n.text("Сообщение")
        case .reply: return L10n.text("Ответное сообщение")
        case .transition: return L10n.text("Переход")
        case .dashed: return L10n.text("Пунктирная связь")
        }
    }

    var endpointSymbol: String? {
        switch self {
        case .aggregation: return "◇"
        case .composition: return "◆"
        case .generalization, .realization: return "△"
        case .containment: return "⊕"
        case .association, .dependency, .message, .reply, .transition, .dashed: return nil
        }
    }
}

public struct DiagramNode: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var uncertain: Bool
    public init(id: String, label: String, uncertain: Bool = false) { self.id = id; self.label = label; self.uncertain = uncertain }
}

public struct DiagramEdge: Codable, Sendable, Hashable {
    public var from: String
    public var to: String
    /// Forward puts the arrowhead or UML endpoint decoration on `to`.
    public var direction: DiagramEdgeDirection
    public var label: String?
    public var uncertain: Bool
    public var kind: DiagramConnectionKind?
    public init(from: String, to: String, direction: DiagramEdgeDirection, label: String? = nil,
                uncertain: Bool = false, kind: DiagramConnectionKind? = nil) {
        self.from = from; self.to = to; self.direction = direction; self.label = label; self.uncertain = uncertain; self.kind = kind
    }

    public var symbol: String {
        guard let mark = kind?.endpointSymbol else { return direction.symbol }
        switch direction {
        case .forward: return "—" + mark
        case .backward: return mark + "—"
        case .none, .both: return direction.symbol
        }
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
    public var kind: DiagramKind?
    public var nodes: [DiagramNode]
    public var edges: [DiagramEdge]
    public init(fingerprint: String, language: String? = nil, kind: DiagramKind? = nil, nodes: [DiagramNode], edges: [DiagramEdge]) {
        self.fingerprint = fingerprint; self.language = language; self.kind = kind; self.nodes = nodes; self.edges = edges
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
            if (kind == .sequence || edge.kind?.endpointSymbol != nil),
               edge.direction == .none || edge.direction == .both {
                throw ScribeError.message("Для этой связи нужно указать один конец со стрелкой или маркером")
            }
            if kind == .sequence, let connection = edge.kind, connection != .message && connection != .reply {
                throw ScribeError.message("Некорректный тип сообщения на диаграмме последовательности")
            }
        }
    }
}
