import AVFoundation
import XCTest
@testable import LocalScribeCore

final class AACImportTests: XCTestCase {
    private func fixture(_ root: URL, format: String = "aac", estimate: String = "1",
                         timeBase: String = "1/28224000", packets: String) throws -> URL {
        try Disk.directory(root)
        let metadata: [String: Any] = [
            "streams": [["codec_type": "audio", "codec_name": "aac", "sample_rate": "16000",
                         "channels": 1, "time_base": timeBase]],
            "format": ["format_name": format, "duration": estimate]
        ]
        try JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent("metadata.json"))
        try Data(packets.utf8).write(to: root.appendingPathComponent("packets.txt"))
        let probe = root.appendingPathComponent("ffprobe")
        try Data("""
        #!/bin/sh
        cd "$(dirname "$0")" || exit 1
        case "$*" in
          *-show_streams*) cat metadata.json ;;
          *) cat packets.txt ;;
        esac
        """.utf8).write(to: probe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
        return root
    }

    func testADTSDurationUsesPacketTimeBaseInsteadOfBitrateEstimate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (denominator, packet, expected) in [(28224000, 1806336, 0.192), (44100, 1024, 3072.0 / 44100)] {
            let tools = try fixture(root, estimate: "20000", timeBase: "1/\(denominator)", packets: "\(packet)\n\(packet)\n\(packet)\n")
            let info = try Media.probe(root.appendingPathComponent("original.aac"), tools: tools)
            XCTAssertEqual(info.codec, "aac")
            XCTAssertEqual(info.duration, expected, accuracy: 0.0000001)
        }
    }

    func testADTSRejectsMissingInvalidAndOverflowingPacketDurations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for packets in ["", "N/A\n", "0\n", "-1\n", "1\ngarbage\n", "9223372036854775807\n1\n"] {
            let tools = try fixture(root, packets: packets)
            XCTAssertThrowsError(try Media.probe(root.appendingPathComponent("original.aac"), tools: tools), packets)
        }
    }

    func testADTSRejectsInvalidTimeBases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for base in ["", "0/1", "1/0", "-1/2", "1/-2", "1/2/3", "N/A"] {
            let tools = try fixture(root, timeBase: base, packets: "1024\n")
            XCTAssertThrowsError(try Media.probe(root.appendingPathComponent("original.aac"), tools: tools), base)
        }
    }

    func testADTSChecksThreeHourLimitAgainstActualPackets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.aac")
        let tools = try fixture(root, timeBase: "1/16000", packets: "172800000\n")
        XCTAssertEqual(try Media.probe(source, tools: tools).duration, 10800)
        _ = try fixture(root, timeBase: "1/16000", packets: "172800016\n")
        XCTAssertThrowsError(try Media.probe(source, tools: tools)) {
            XCTAssertEqual(($0 as? ScribeError)?.localizedDescription, "Запись длиннее 3 часов. Автоматическое усечение отключено.")
        }
    }

    func testM4AKeepsContainerDuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = try fixture(root, format: "mov,mp4,m4a,3gp,3g2,mj2", estimate: "12.345", packets: "invalid")
        XCTAssertEqual(try Media.probe(root.appendingPathComponent("original.m4a"), tools: tools).duration, 12.345)
    }

    @MainActor
    func testCancellationDuringADTSPacketScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = try fixture(root, packets: "1024\n")
        let probe = root.appendingPathComponent("ffprobe")
        try Data("""
        #!/bin/sh
        cd "$(dirname "$0")" || exit 1
        case "$*" in
          *-show_streams*) cat metadata.json ;;
          *) touch scanning; exec /bin/sleep 60 ;;
        esac
        """.utf8).write(to: probe)
        let task = Task.detached { try Media.probe(root.appendingPathComponent("original.aac"), tools: tools, cancellable: true) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("scanning").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("scanning").path))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled AAC scan succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testBundledToolsImportAndPrepareADTSWithoutChangingOriginal() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = project.appendingPathComponent("Assets/tools")
        guard ["ffmpeg", "ffprobe"].allSatisfy({ FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Сначала соберите аудиоинструменты: bash scripts/build_ffmpeg.sh")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Disk.directory(root)
        let wave = root.appendingPathComponent("fixture.wav")
        let source = root.appendingPathComponent("Встреча.aac")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: wave, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 5))
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 {
                for frame in 0..<Int(buffer.frameLength) {
                    let time = Double(frame) / 44100
                    buffer.floatChannelData![channel][frame] = time < 2 ? 0 : Float(0.2 * sin(2 * .pi * 440 * time))
                }
            }
            try file.write(from: buffer)
        }
        _ = try Media.execute(URL(fileURLWithPath: "/usr/bin/afconvert"), ["-f", "adts", "-d", "aac", wave.path, source.path])
        let digest = try Disk.hash(source)
        let info = try Media.probe(source, tools: tools, cancellable: true)
        XCTAssertEqual(info.codec, "aac")
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.sampleRate, 44100)
        XCTAssertEqual(info.duration, 5, accuracy: 0.15)
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        let manifest = try repo.importFile(source, info: info)
        let original = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        XCTAssertEqual(manifest.sha256, digest)
        XCTAssertEqual(manifest.durationMs, Int((info.duration * 1000).rounded()))
        XCTAssertEqual(original.pathExtension, "aac")
        let prepared = root.appendingPathComponent("prepared.wav")
        _ = try Media.prepare(original, to: prepared, tools: tools)
        let file = try AVAudioFile(forReading: prepared)
        XCTAssertEqual(file.processingFormat.sampleRate, 16000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / 16000, info.duration, accuracy: 0.001)
        XCTAssertEqual(try Disk.hash(original), digest)
        try repo.delete(manifest)
        XCTAssertEqual(try Disk.hash(source), digest)
    }
}
