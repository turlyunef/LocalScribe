import Foundation

/// Only model preferences live here. Installing, selecting and removing models
/// never writes to the recording archive or creates analysis jobs.
public struct ModelLibrary: Codable, Sendable {
    public private(set) var installedAt: [String: Date] = [:]
    public private(set) var selectedByRole: [String: String] = [:]
    public init() {}
    public static func load(at root: URL, catalog: ModelCatalog, hardware: ModelHardware? = nil,
                            verifyContents: Bool = true) throws -> ModelLibrary {
        let url = root.appendingPathComponent("selection.json")
        var library = FileManager.default.fileExists(atPath: url.path) ? try Disk.read(Self.self, at: url) : Self()
        var verified: [String: Date] = [:]
        for profile in catalog.models {
            if (try? profile.validateFiles(at: root, verifyContents: verifyContents)) != nil {
                let modified = try? root.appendingPathComponent(profile.id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                verified[profile.id] = library.installedAt[profile.id] ?? modified ?? .distantPast
            }
        }
        library.installedAt = verified
        library.reconcile(catalog: catalog, hardware: hardware)
        try library.save(at: root)
        return library
    }
    public func save(at root: URL) throws { try Disk.write(self, to: root.appendingPathComponent("selection.json")) }
    public func isInstalled(_ profile: ModelProfile) -> Bool { installedAt[profile.id] != nil }
    public func isSelected(_ profile: ModelProfile) -> Bool { profile.purpose.map { selectedByRole[$0.rawValue] == profile.id } ?? false }
    public mutating func installed(_ profile: ModelProfile, at date: Date = Date(), catalog: ModelCatalog, hardware: ModelHardware? = nil) {
        installedAt[profile.id] = date
        if let role = profile.purpose, hardware?.compatibility(for: profile).isCompatible != false { selectedByRole[role.rawValue] = profile.id }
        reconcile(catalog: catalog, hardware: hardware)
    }
    public mutating func select(_ profile: ModelProfile, catalog: ModelCatalog, hardware: ModelHardware? = nil) throws {
        try hardware?.requireCompatibility(for: profile)
        guard isInstalled(profile), let role = profile.purpose else { throw ScribeError.message("Сначала загрузите модель") }
        if role == .asr, let tokenizerID = profile.tokenizerID, installedAt[tokenizerID] == nil {
            throw ScribeError.message("Сначала загрузите токенизатор для этой модели речи")
        }
        if let alignerID = profile.alignerID, installedAt[alignerID] == nil {
            throw ScribeError.message("Сначала загрузите модель выравнивания для этой модели речи")
        }
        selectedByRole[role.rawValue] = profile.id
        reconcile(catalog: catalog, hardware: hardware)
    }
    public mutating func remove(_ profile: ModelProfile, at root: URL, catalog: ModelCatalog, hardware: ModelHardware? = nil) throws {
        try profile.validatePaths()
        for name in [profile.id, profile.id + ".partial"] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        installedAt.removeValue(forKey: profile.id)
        reconcile(catalog: catalog, hardware: hardware)
        try save(at: root)
    }
    private mutating func reconcile(catalog: ModelCatalog, hardware: ModelHardware?) {
        for role in ModelRole.allCases {
            let candidates = catalog.models.filter { $0.purpose == role && isInstalled($0) }
            if !candidates.contains(where: { $0.id == selectedByRole[role.rawValue] }) {
                selectedByRole[role.rawValue] = candidates.filter { hardware?.compatibility(for: $0).isCompatible != false }.max {
                    let left = installedAt[$0.id] ?? .distantPast, right = installedAt[$1.id] ?? .distantPast
                    return left == right ? $0.id > $1.id : left < right
                }?.id
            }
        }
        if let asr = catalog.models.first(where: { $0.id == selectedByRole[ModelRole.asr.rawValue] }), let tokenizerID = asr.tokenizerID {
            selectedByRole[ModelRole.tokenizer.rawValue] = installedAt[tokenizerID] != nil ? tokenizerID : nil
        }
    }
    public func activeCatalog(from catalog: ModelCatalog, summary: ModelProfile? = nil) -> ModelCatalog? {
        var profiles = ModelRole.audioRoles.compactMap { role in
            if role == .summary, var summary {
                summary.role = .summary
                return summary
            }
            return catalog.models.first { $0.purpose == role && $0.id == selectedByRole[role.rawValue] && isInstalled($0) }
        }
        guard profiles.count == ModelRole.audioRoles.count else { return nil }
        if let id = profiles.first(where: { $0.purpose == .asr })?.alignerID {
            guard let aligner = catalog.models.first(where: { $0.id == id && $0.purpose == nil }),
                  isInstalled(aligner) else { return nil }
            profiles.append(aligner)
        }
        return ModelCatalog(models: profiles)
    }
    /// Diagram readiness is independent: it never gates or completes the audio complect.
    public func diagramProfile(from catalog: ModelCatalog) -> ModelProfile? {
        guard let id = selectedByRole[ModelRole.diagram.rawValue],
              let profile = catalog.models.first(where: { $0.id == id && $0.purpose == .diagram }),
              isInstalled(profile) else { return nil }
        return profile
    }
}
