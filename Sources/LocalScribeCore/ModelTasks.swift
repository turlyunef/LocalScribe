import Foundation

/// Recording summaries, diagram recognition and text anonymization each have
/// their own model assignment. Speech recognition and speaker diarization use
/// the separate role-based settings in `ModelLibrary`.
public enum ModelTask: String, Codable, CaseIterable, Sendable, Hashable {
    case summary = "SUMMARY"
    case diagramRecognition = "DIAGRAM_RECOGNITION"
    case anonymization = "ANONYMIZATION"

    public var title: String {
        switch self {
        case .summary: return L10n.text("Итоги")
        case .diagramRecognition: return L10n.text("Схемы")
        case .anonymization: return L10n.text("Обезличивание")
        }
    }
    /// The audio role whose selection the task reuses in the historical
    /// settings: summaries and diagrams already have saved assignments that the
    /// additive migration copies into the new settings record.
    public var legacyRole: ModelRole? {
        switch self {
        case .summary: return .summary
        case .diagramRecognition: return .diagram
        case .anonymization: return nil
        }
    }
}

public extension ModelProfile {
    /// The effective task set: an explicit catalog value wins (filled by
    /// qualification, work 13); without one the set is derived from the role —
    /// summary profiles serve summaries, diagram profiles serve diagrams, and
    /// no profile serves anonymization until it is qualified.
    var effectiveSupportedTasks: Set<ModelTask> {
        if let supportedTasks { return supportedTasks }
        switch purpose {
        case .summary: return [.summary]
        case .diagram: return [.diagramRecognition]
        default: return []
        }
    }
    func supports(_ task: ModelTask) -> Bool { effectiveSupportedTasks.contains(task) }
    /// The effective immutable file-set reference: an explicit `packageID`
    /// wins; otherwise the identity is derived from the pinned files, so
    /// several profiles over one file set share a single physical installation.
    var effectivePackageID: String { packageID ?? ModelPackage.identity(ofFiles: files) }
}

/// Task support and Mac compatibility of one profile, following
/// `ModelHardware`. A profile incompatible for the task or the Mac cannot be
/// assigned; an assigned-but-not-installed profile keeps the assignment while
/// its jobs wait for readiness.
public enum ModelTaskSupport {
    /// Reasons are safe machine messages translated with `L10n.message`.
    public static func compatibility(task: ModelTask, profile: ModelProfile, hardware: ModelHardware) -> ModelCompatibility {
        var reasons = hardware.compatibility(for: profile).reasons
        if !profile.supports(task) {
            reasons.insert("Модель не поддерживает эту задачу", at: 0)
        }
        return ModelCompatibility(reasons: reasons)
    }
}

/// One resolved task slot: the saved assignment, its
/// compatibility for the task on this Mac, and whether the referenced package
/// has a published verified installation. A compatible profile without
/// installation keeps its assignment and only lacks readiness.
public struct ModelTaskReadiness: Sendable, Equatable {
    public let task: ModelTask
    public let profile: ModelProfile?
    public let packageID: String?
    public let compatibility: ModelCompatibility
    public let packageReady: Bool

    /// Profiles have no synthesized equality; the pinned id carries the slot.
    public static func == (lhs: ModelTaskReadiness, rhs: ModelTaskReadiness) -> Bool {
        lhs.task == rhs.task && lhs.profile?.id == rhs.profile?.id && lhs.packageID == rhs.packageID
            && lhs.compatibility == rhs.compatibility && lhs.packageReady == rhs.packageReady
    }
    public var noAssignment: Bool { profile == nil }
    public var installed: Bool { profile != nil && packageReady }
    /// Ready to start new jobs: an assigned, compatible profile plus a
    /// verified package installation.
    public var isReady: Bool { profile != nil && packageID != nil && compatibility.isCompatible && packageReady }
    /// The assignment exists and fits the task and Mac, but its package has no
    /// published verified installation (jobs wait for the model).
    public var waitingForInstall: Bool { profile != nil && compatibility.isCompatible && !packageReady }

    static func unresolved(_ task: ModelTask) -> ModelTaskReadiness {
        ModelTaskReadiness(task: task, profile: nil, packageID: nil,
                           compatibility: ModelCompatibility(reasons: []), packageReady: false)
    }
}

/// Pure resolution of saved assignments against the catalog, hardware and the
/// set of packages with a published verified installation.
public enum ModelAssignments {
    public static func readiness(for task: ModelTask, settings: AnonymizationSettings,
                                 catalog: ModelCatalog, hardware: ModelHardware,
                                 readyPackageIDs: Set<String>) -> ModelTaskReadiness {
        guard let id = settings.profileID(for: task),
              let profile = catalog.models.first(where: { $0.id == id }) else {
            return .unresolved(task)
        }
        let compatibility = ModelTaskSupport.compatibility(task: task, profile: profile, hardware: hardware)
        let packageID = profile.effectivePackageID
        return ModelTaskReadiness(task: task, profile: profile, packageID: packageID,
                                  compatibility: compatibility, packageReady: readyPackageIDs.contains(packageID))
    }

    /// Assignments whose profiles reference this package. Recompute after a
    /// settings change to refresh the removal confirmation.
    public static func affectedTasks(packageID: String, settings: AnonymizationSettings,
                                     catalog: ModelCatalog) -> Set<ModelTask> {
        Set(ModelTask.allCases.filter { task in
            guard let profileID = settings.profileID(for: task),
                  let profile = catalog.models.first(where: { $0.id == profileID }) else { return false }
            return profile.effectivePackageID == packageID
        })
    }
}

/// The single byte limit of a full anonymization pass for the pair «profile
/// and Mac». Import measures the file bytes including the BOM; admission
/// measures the run text in UTF-8 without BOM against the same limit.
///
/// Sources, in priority order:
/// 1. injected overrides — the qualification seam (work 13 measured values on
///    a target Mac) and the test seam;
/// 2. the catalog value `anonymizationInputLimitBytes`, capped by the
///    conservative ceiling of this Mac;
/// 3. the conservative ceiling alone — the default estimate until
///    qualification publishes measured values.
public struct AnonymizationInputLimit: Sendable, Equatable {
    public static let kib: UInt = 1024
    public let overrides: [String: UInt]

    public init(overrides: [String: UInt] = [:]) {
        self.overrides = overrides
    }

    /// Conservative estimate by the RAM/Metal working budget with the system
    /// reserve (see `ModelHardware.modelBudgetBytes`). Real limits are
    /// confirmed by qualification on target Macs; until then the estimate
    /// stays deliberately small.
    public static func conservativeCeiling(for hardware: ModelHardware) -> UInt {
        let gib: UInt64 = 1_073_741_824
        let budget = hardware.modelBudgetBytes
        guard budget > 0 else { return 0 }
        if budget >= 32 * gib { return 1024 * kib }
        if budget >= 16 * gib { return 512 * kib }
        return 256 * kib
    }

    public func limitBytes(profile: ModelProfile, hardware: ModelHardware) -> UInt {
        if let override = overrides[profile.id] { return override }
        let ceiling = Self.conservativeCeiling(for: hardware)
        guard let catalogValue = profile.anonymizationInputLimitBytes, catalogValue > 0 else { return ceiling }
        return min(UInt(clamping: catalogValue), ceiling)
    }
}
