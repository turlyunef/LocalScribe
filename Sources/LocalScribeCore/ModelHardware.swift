import Darwin
import Foundation
import Metal

public struct ModelCompatibility: Sendable, Equatable {
    public let reasons: [String]
    public var isCompatible: Bool { reasons.isEmpty }
    public var explanation: String? { isCompatible ? nil : reasons.joined(separator: "; ") }
}

/// Conservative resource policy, not a benchmark or a guarantee of model quality.
public struct ModelHardware: Sendable {
    private static let gib: UInt64 = 1_073_741_824
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

    public static var current: Self {
        let gpu = MTLCreateSystemDefaultDevice()
        var size = 0
        var chip = "Apple Silicon"
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var name = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0) == 0 { chip = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return Self(chip: chip, memoryBytes: ProcessInfo.processInfo.physicalMemory,
                    cpuCores: ProcessInfo.processInfo.processorCount, gpuWorkingSetBytes: gpu?.recommendedMaxWorkingSetSize ?? 0,
                    appleSilicon: appleSilicon, supportsMetal: gpu != nil)
    }

    public var reservedMemoryBytes: UInt64 { max(3 * Self.gib, memoryBytes / 5) }
    public var modelBudgetBytes: UInt64 {
        guard appleSilicon, supportsMetal, memoryBytes > reservedMemoryBytes, gpuWorkingSetBytes > 0 else { return 0 }
        return min(memoryBytes - reservedMemoryBytes, gpuWorkingSetBytes)
    }

    public func compatibility(for profile: ModelProfile) -> ModelCompatibility {
        guard profile.purpose != .tokenizer else { return ModelCompatibility(reasons: []) }
        guard appleSilicon, supportsMetal else {
            return ModelCompatibility(reasons: ["Нужен Mac с Apple Silicon и поддержкой Metal"])
        }
        guard modelBudgetBytes > 0 else {
            return ModelCompatibility(reasons: ["Не удалось подтвердить доступный бюджет RAM и Metal"])
        }
        var reasons: [String] = []
        if let ram = profile.recommendedMemoryGB {
            if ram < 0 || ram > 1_048_576 { reasons.append("Некорректные требования RAM в каталоге") }
            else if memoryBytes < UInt64(ram) * Self.gib {
                reasons.append("требуется от \(ram) ГБ RAM, на этом Mac — \(memoryBytes / Self.gib) ГБ")
            }
        }
        if let working = profile.workingMemoryGB {
            if working < 0 || working > 1_048_576 { reasons.append("Некорректный рабочий объём в каталоге") }
            else if UInt64(working) * Self.gib > modelBudgetBytes {
                reasons.append("нужно \(working) ГБ рабочего объёма; бюджет RAM/Metal с резервом системы — \(String(format: "%.1f", Double(modelBudgetBytes) / Double(Self.gib))) ГБ")
            }
        }
        return ModelCompatibility(reasons: reasons)
    }

    public func warning(for profile: ModelProfile) -> String? {
        let reasons = compatibility(for: profile).reasons
        guard !reasons.isEmpty else { return nil }
        let explanation = reasons.map { L10n.message($0) }.joined(separator: "; ")
        return L10n.text("%1$@ недоступна на этом Mac: %2$@.", profile.displayName, explanation)
    }

    public func requireCompatibility(for profile: ModelProfile) throws {
        if let explanation = compatibility(for: profile).explanation {
            throw ScribeError.message("\(profile.catalogName) недоступна на этом Mac: \(explanation).")
        }
    }

    public func recommendedProfile(for role: ModelRole, in catalog: ModelCatalog) -> ModelProfile? {
        guard role == .asr || role == .summary || role == .diagram else { return nil }
        return catalog.models.filter {
            $0.purpose == role && ($0.recommendationRank ?? 0) > 0 && compatibility(for: $0).isCompatible
        }.sorted {
            if $0.recommendationRank != $1.recommendationRank { return ($0.recommendationRank ?? 0) > ($1.recommendationRank ?? 0) }
            return $0.id < $1.id
        }.first
    }
}
