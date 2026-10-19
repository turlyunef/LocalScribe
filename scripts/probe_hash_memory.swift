// Compile with the built LocalScribeCore objects; see docs/StartupHashMemory.md.
// Uses only a temporary sparse file, without models or the user's archive.
import Foundation
import Darwin
import LocalScribeCore

private func footprint() throws -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { throw ScribeError.message("task_info failed: \(status)") }
    return info.phys_footprint
}

private func maxResident() throws -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw ScribeError.message("getrusage failed: \(errno)") }
    return UInt64(usage.ru_maxrss)
}

private struct Measurement: Encodable, Sendable {
    let inputBytes: UInt64
    let iterations: Int
    let beforeFootprintBytes: UInt64
    let peakFootprintBytes: UInt64
    let growthBytes: UInt64
    let residentGrowthBytes: UInt64
    let limitBytes: UInt64
    let sha256: String
    var passed: Bool { growthBytes <= limitBytes && residentGrowthBytes <= limitBytes }
}

@main struct HashMemoryProbe {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("zeros.bin")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw ScribeError.message("Cannot create hash fixture")
        }
        let inputBytes: UInt64 = 256 * 1024 * 1024
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: inputBytes)
        try writer.close()
        let result = try await Task.detached(priority: .utility) {
            // Keep the caller's pool alive across hashes, as in model verification.
            try autoreleasepool {
                let before = try footprint()
                let beforeResident = try maxResident()
                var peak = before
                let expected = "a6d72ac7690f53be6ae46ba88506bd97302a093f7108472bd9efc3cefda06484"
                for _ in 0..<3 {
                    guard try Disk.hash(file) == expected else { throw ScribeError.message("SHA-256 mismatch") }
                    peak = max(peak, try footprint())
                }
                return Measurement(inputBytes: inputBytes, iterations: 3, beforeFootprintBytes: before,
                    peakFootprintBytes: peak, growthBytes: peak - before,
                    residentGrowthBytes: try maxResident() - beforeResident,
                    limitBytes: 64 * 1024 * 1024, sha256: expected)
            }
        }.value
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(result) + Data([10]))
        if !result.passed {
            try FileManager.default.removeItem(at: folder)
            fputs("Hash buffers exceeded the 64 MiB growth budget.\n", stderr)
            exit(1)
        }
    }
}
