import Foundation

/// Only model preferences live here. Installing, selecting and removing models
/// never writes to the recording archive or creates analysis jobs.
public struct ModelLibrary: Codable, Sendable {
    public private(set) var installedAt: [String: Date] = [:]
    public private(set) var selectedByRole: [String: String] = [:]
    public init() {}
    public static func load(at root: URL, catalog: ModelCatalog) throws -> ModelLibrary {
        let url = root.appendingPathComponent("selection.json")
        var library = FileManager.default.fileExists(atPath: url.path) ? try Disk.read(Self.self, at: url) : Self()
        var verified: [String: Date] = [:]
        for profile in catalog.models {
            if (try? profile.validate(at: root)) != nil {
                let modified = try? root.appendingPathComponent(profile.id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                verified[profile.id] = library.installedAt[profile.id] ?? modified ?? .distantPast
            }
        }
        library.installedAt = verified
        library.reconcile(catalog: catalog)
        try library.save(at: root)
        return library
    }
    public func save(at root: URL) throws { try Disk.write(self, to: root.appendingPathComponent("selection.json")) }
    public func isInstalled(_ profile: ModelProfile) -> Bool { installedAt[profile.id] != nil }
    public func isSelected(_ profile: ModelProfile) -> Bool { profile.purpose.map { selectedByRole[$0.rawValue] == profile.id } ?? false }
    public mutating func installed(_ profile: ModelProfile, at date: Date = Date(), catalog: ModelCatalog) {
        installedAt[profile.id] = date
        if let role = profile.purpose { selectedByRole[role.rawValue] = profile.id }
        reconcile(catalog: catalog)
    }
    public mutating func select(_ profile: ModelProfile, catalog: ModelCatalog) throws {
        guard isInstalled(profile), let role = profile.purpose else { throw ScribeError.message("Сначала загрузите модель") }
        if role == .asr, let tokenizerID = profile.tokenizerID, installedAt[tokenizerID] == nil {
            throw ScribeError.message("Сначала загрузите токенизатор для этой модели речи")
        }
        selectedByRole[role.rawValue] = profile.id
        reconcile(catalog: catalog)
    }
    public mutating func remove(_ profile: ModelProfile, at root: URL, catalog: ModelCatalog) throws {
        try profile.validatePaths()
        for name in [profile.id, profile.id + ".partial"] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        installedAt.removeValue(forKey: profile.id)
        reconcile(catalog: catalog)
        try save(at: root)
    }
    private mutating func reconcile(catalog: ModelCatalog) {
        for role in ModelRole.allCases {
            let candidates = catalog.models.filter { $0.purpose == role && isInstalled($0) }
            if !candidates.contains(where: { $0.id == selectedByRole[role.rawValue] }) {
                selectedByRole[role.rawValue] = candidates.max {
                    let left = installedAt[$0.id] ?? .distantPast, right = installedAt[$1.id] ?? .distantPast
                    return left == right ? $0.id > $1.id : left < right
                }?.id
            }
        }
        if let asr = catalog.models.first(where: { $0.id == selectedByRole[ModelRole.asr.rawValue] }), let tokenizerID = asr.tokenizerID {
            selectedByRole[ModelRole.tokenizer.rawValue] = installedAt[tokenizerID] != nil ? tokenizerID : nil
        }
    }
    public func activeCatalog(from catalog: ModelCatalog) -> ModelCatalog? {
        let profiles = ModelRole.allCases.compactMap { role in
            catalog.models.first { $0.purpose == role && $0.id == selectedByRole[role.rawValue] && isInstalled($0) }
        }
        guard profiles.count == ModelRole.allCases.count else { return nil }
        return ModelCatalog(models: profiles)
    }
}

/// Conservative estimates, not a benchmark or a guarantee that a model will fit.
public struct ModelHardware: Sendable {
    public let chip: String
    public let memoryBytes: UInt64
    public let cpuCores: Int
    public let gpuWorkingSetBytes: UInt64
    public let appleSilicon: Bool
    public let supportsMetal: Bool
    public init(chip: String, memoryBytes: UInt64, cpuCores: Int, gpuWorkingSetBytes: UInt64, appleSilicon: Bool, supportsMetal: Bool) {
        self.chip = chip; self.memoryBytes = memoryBytes; self.cpuCores = cpuCores
        self.gpuWorkingSetBytes = gpuWorkingSetBytes; self.appleSilicon = appleSilicon; self.supportsMetal = supportsMetal
    }
    public func warning(for profile: ModelProfile) -> String? {
        guard profile.purpose == .asr || profile.purpose == .summary else { return nil }
        if !appleSilicon || !supportsMetal { return "Для этой модели нужен Mac с Apple Silicon и поддержкой Metal." }
        let gib: UInt64 = 1_073_741_824
        var reasons: [String] = []
        if let recommended = profile.recommendedMemoryGB, memoryBytes < UInt64(recommended) * gib {
            reasons.append("рекомендуется от \(recommended) ГБ оперативной памяти, на этом Mac — \(memoryBytes / gib) ГБ")
        }
        if let working = profile.workingMemoryGB, gpuWorkingSetBytes > 0, gpuWorkingSetBytes < UInt64(working) * gib {
            reasons.append("рабочий объём модели оценивается в \(working) ГБ, доступный бюджет Metal — \(String(format: "%.1f", Double(gpuWorkingSetBytes) / Double(gib))) ГБ")
        }
        guard !reasons.isEmpty else { return nil }
        return "Этот Mac может быть слишком слабым для \(profile.displayName): " + reasons.joined(separator: "; ") + ". Возможны медленная обработка, нехватка памяти и остановка. Оценка ориентировочная и зависит от длины записи и других приложений."
    }
}
