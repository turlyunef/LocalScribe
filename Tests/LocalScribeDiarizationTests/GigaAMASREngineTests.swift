import AVFoundation
@testable import LocalScribeCore
import XCTest
@testable import LocalScribeWorker

final class GigaAMASREngineTests: XCTestCase {
    func testFactoryRoutesPinnedGigaAMAndDeclinesClosedFragments() async throws {
        var profiles = ModelRole.audioRoles.map {
            ModelProfile(id: $0.rawValue, repository: "fixture/local", revision: "r", license: "test", files: [], role: $0)
        }
        profiles[0].asrBackend = "gigaam"
        profiles[0].asrPolicy = GigaAMASREngine.policyID
        profiles[0].tokenizerID = "tokenizer"
        let catalog = ModelCatalog(models: profiles)
        let factory = ASREngineFactory(loadWhisper: { _, _, _, _ in
            XCTFail("GigaAM used the Whisper loader")
            throw CancellationError()
        }, loadGigaAM: { _, _, _, _ in
            GigaAMASREngine { _ in
                XCTFail("GigaAM tried to open closed fragments")
                return .init(tokens: [], timestamps: [])
            }
        })
        let recognizer = try await factory.make(info: RunInfo(sourceHash: "source", profileHash: catalog.fingerprint),
            catalog: catalog, models: URL(fileURLWithPath: "/missing"), metrics: nil, warning: { _ in })
        XCTAssertEqual(recognizer.capabilities.inputModes, [.offline])
        XCTAssertEqual(recognizer.capabilities.wordTimings, .available)
        let request = try ASRRequest(audioURL: URL(fileURLWithPath: "/missing.wav"),
            availableEndMs: 1000, coreRange: 0..<1000, mode: .closedFragments)
        do {
            _ = try await recognizer.recognize(request)
            XCTFail("GigaAM accepted background audio")
        } catch is ScribeError {
            // The normal recognizer boundary rejected the mode before inference.
        }
    }

    func testCharacterTimesKeepWholeWordsAtSeamsAndClipTerminalFrame() throws {
        let response = GigaAMASREngine.Hypothesis(tokens: ["д", "а", " ", "я", " ", "и"],
            timestamps: [0.16, 0.24, 0.28, 0.32, 0.36, 0.48])
        let left = try GigaAMASREngine.words(response, readStart: 1000, readEnd: 1500, core: 1000..<1200)
        let right = try GigaAMASREngine.words(response, readStart: 1000, readEnd: 1500, core: 1200..<1500)
        XCTAssertTrue(left.isEmpty)
        XCTAssertEqual(right, [
            Word(text: " да", startMs: 1160, endMs: 1280),
            Word(text: " я", startMs: 1320, endMs: 1360),
            Word(text: " и", startMs: 1480, endMs: 1500)
        ])
        XCTAssertThrowsError(try GigaAMASREngine.words(.init(tokens: ["а", "б"], timestamps: [0.24, 0.16]),
            readStart: 1000, readEnd: 1500, core: 1000..<1500))
    }

    func testOfflineWindowsBoundContextAndKeepRealShortTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Disk.directory(root)
        let wave = root.appendingPathComponent("input.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames = 48 * 16_000 + 5
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0.2, count: frames)
        do {
            let file = try AVAudioFile(forWriting: wave, settings: format.settings)
            try file.write(from: buffer)
        }
        var calls: [Int] = []
        let engine = GigaAMASREngine { samples in
            calls.append(samples.count)
            return .init(tokens: [], timestamps: [])
        }
        _ = try await engine.recognize(ASRRequest(audioURL: wave, originMs: 50_000, availableEndMs: 98_001,
            coreRange: 50_000..<98_001, mode: .offline))
        XCTAssertEqual(calls, [24 * 16_000, 25 * 16_000, 3 * 16_000 + 5])
    }
}
