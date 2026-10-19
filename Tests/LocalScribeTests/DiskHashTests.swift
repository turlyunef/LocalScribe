import CryptoKit
import XCTest
@testable import LocalScribeCore

final class DiskHashTests: XCTestCase {
    func testHashMatchesSHA256ForEmptySmallAndMultipleChunkFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input.bin")
        for size in [0, 3, 4 * 1024 * 1024 - 1, 4 * 1024 * 1024, 4 * 1024 * 1024 + 1, 8 * 1024 * 1024 + 31] {
            let bytes = Data((0..<size).map { UInt8($0 % 251) })
            try bytes.write(to: file)
            let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(try Disk.hash(file), expected, "File length: \(size)")
        }
    }

    func testDescriptorHashPreservesOwnershipAndUsesCurrentOffset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Disk.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input.bin")
        try Data("prefixabc".utf8).write(to: file)
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        try reader.seek(toOffset: 6)
        XCTAssertEqual(try Disk.hash(reader), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try reader.offset(), 9)
        try reader.seek(toOffset: 0)
        XCTAssertEqual(try reader.readToEnd(), Data("prefixabc".utf8))
    }
}
