import AVFoundation
import CoreAudio
import XCTest
@testable import LocalScribe

final class CaptureIngressTests: XCTestCase {
    @MainActor func testStoppedStartupEngineRequiresNewMicrophonePacketAfterRestart() async throws {
        let ingress = CaptureIngress(meter: { _ in }, failure: { XCTFail($0) }, pressure: {})
        let token = try XCTUnwrap(ingress.beginMicrophoneAttempt())
        let oldTap = try XCTUnwrap(ingress.replaceMicrophoneTap(token))
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        try XCTUnwrap(buffer.floatChannelData?[0]).update(repeating: 0, count: 1024)
        func submitSilence(from tap: UUID) {
            ingress.submitMicrophone(buffer.audioBufferList, format: format, frameCount: 1024,
                                     hostTime: AudioGetCurrentHostTime(), token: token, tap: tap)
        }

        // The old engine can send one packet and then stop before activation.
        submitSilence(from: oldTap)
        var restarts = 0
        try await MicrophoneRecorder.waitForFirstMicrophonePacket(until: .now + .seconds(2), ingress: ingress, token: token) {
            restarts > 0
        } restart: {
            restarts += 1
            let restartedTap = try XCTUnwrap(ingress.replaceMicrophoneTap(token))
            submitSilence(from: oldTap)
            XCTAssertNil(ingress.lastMicrophoneCallbackHostTime(for: token))
            XCTAssertFalse(ingress.activateMicrophone(token))
            submitSilence(from: restartedTap)
        }
        XCTAssertEqual(restarts, 1)
        XCTAssertTrue(ingress.activateMicrophone(token))
    }

    func testSystemAudioStartsWhileMicrophoneIsStillPending() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ingress = CaptureIngress(meter: { _ in }, failure: { XCTFail($0) }, pressure: {})
        try await ingress.start(folder: folder, sources: [.microphone, .systemAudio], originAtFirstPacket: true)
        let microphone = try XCTUnwrap(ingress.beginMicrophoneAttempt())
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        input.frameLength = 1600
        try XCTUnwrap(input.floatChannelData?[0]).update(repeating: 0.25, count: 1600)
        ingress.submitSystemAudio(input.audioBufferList, format: format.streamDescription.pointee,
                                  hostTime: AudioGetCurrentHostTime())
        XCTAssertFalse(ingress.activateMicrophone(microphone))
        let frames = try await ingress.finish()
        XCTAssertEqual(frames, 1600)
        let file = try AVAudioFile(forReading: folder.appendingPathComponent("part-000000.caf"))
        let probe = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
        try file.read(into: probe)
        XCTAssertEqual(try XCTUnwrap(probe.floatChannelData?[0][0]), 0.25, accuracy: 0.001)
    }

    func testParallelProbeDoesNotInterruptCurrentMicrophone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ingress = CaptureIngress(meter: { _ in }, failure: { XCTFail($0) }, pressure: {})
        try await ingress.start(folder: folder, sources: [.microphone], originAtFirstPacket: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        input.frameLength = 1600
        let samples = try XCTUnwrap(input.floatChannelData?[0])
        let origin = AudioGetCurrentHostTime()
        func submit(_ token: UUID, sample: Float, offset: Double) {
            samples.update(repeating: sample, count: 1600)
            ingress.submitMono(.microphone, list: input.audioBufferList, sampleRate: 16_000,
                               hostTime: origin + AVAudioTime.hostTime(forSeconds: offset), microphoneToken: token)
        }
        let active = try XCTUnwrap(ingress.beginMicrophoneAttempt())
        submit(active, sample: 0, offset: 0)
        XCTAssertTrue(ingress.activateMicrophone(active))
        let failed = try XCTUnwrap(ingress.beginMicrophoneAttempt(whileActive: true))
        XCTAssertFalse(ingress.activateMicrophone(failed))
        submit(active, sample: 0.25, offset: 0)
        ingress.suspendMicrophone(failed)
        let replacement = try XCTUnwrap(ingress.beginMicrophoneAttempt(whileActive: true))
        submit(replacement, sample: 0.9, offset: 0.1)
        submit(active, sample: 0.25, offset: 0.1)
        XCTAssertTrue(ingress.activateMicrophone(replacement))
        submit(active, sample: 0.9, offset: 0.2)
        submit(replacement, sample: -0.5, offset: 0.2)
        let frames = try await ingress.finish()
        XCTAssertEqual(frames, 4800)
        let file = try AVAudioFile(forReading: folder.appendingPathComponent("part-000000.caf"))
        let probe = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
        for (offset, expected) in [(800, Float(0.25)), (2400, 0.25), (4000, -0.5)] {
            file.framePosition = Int64(offset)
            try file.read(into: probe)
            XCTAssertEqual(try XCTUnwrap(probe.floatChannelData?[0][0]), expected, accuracy: 0.001)
        }
    }

    @MainActor func testRunningEngineWithoutPacketsStillTimesOut() async throws {
        let ingress = CaptureIngress(meter: { _ in }, failure: { XCTFail($0) }, pressure: {})
        let token = try XCTUnwrap(ingress.beginMicrophoneAttempt())
        do {
            try await MicrophoneRecorder.waitForFirstMicrophonePacket(until: .now + .milliseconds(100), ingress: ingress, token: token) {
                true
            } restart: {
                XCTFail("A running engine must not be restarted")
            }
            XCTFail("A microphone must deliver a packet before startup succeeds")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Выбранный микрофон не передал аудиоданные при запуске.")
        }
    }

    func testHardwareMuteNoticeChangesWhileSystemAudioIsSilent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let muted = expectation(description: "Microphone mute notice shown")
        let unmuted = expectation(description: "Microphone mute notice cleared")
        let ingress = CaptureIngress(meter: { reading in
            XCTAssertTrue(reading.waitingForSystemAudio)
            if reading.soundNotice == "Микрофон выключен в macOS." { muted.fulfill() }
            else if reading.soundNotice == nil { unmuted.fulfill() }
        }, failure: { XCTFail($0) }, pressure: {})
        let token = try XCTUnwrap(ingress.beginMicrophoneAttempt())
        try await ingress.start(folder: folder, sources: [.microphone, .systemAudio])
        ingress.setMicrophoneMuted(true, token: token)
        ingress.setMicrophoneMuted(false, token: token)
        await fulfillment(of: [muted, unmuted], timeout: 2, enforceOrder: true)
        ingress.closeAdmission()
        _ = try await ingress.finish()
    }

    func testMicrophoneMeterMovesWhileWriterWaitsForSystemAudio() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let meter = expectation(description: "Microphone level while mixer is waiting")
        let ingress = CaptureIngress(meter: { reading in
            XCTAssertEqual(reading.level, (20 * log10(0.5) + 60) / 60, accuracy: 0.001)
            XCTAssertEqual(reading.elapsed, 0)
            XCTAssertTrue(reading.waitingForSystemAudio)
            meter.fulfill()
        }, failure: { XCTFail($0) }, pressure: {})
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        input.frameLength = 4800
        let samples = try XCTUnwrap(input.floatChannelData?[0])
        samples.update(repeating: 0, count: 4800)

        let token = try XCTUnwrap(ingress.beginMicrophoneAttempt())
        ingress.submitMicrophone(input.audioBufferList, format: format, frameCount: 4801, hostTime: AudioGetCurrentHostTime(), token: token)
        XCTAssertNil(ingress.lastMicrophoneCallbackHostTime(for: token))
        XCTAssertFalse(ingress.activateMicrophone(token))
        ingress.submitMicrophone(input.audioBufferList, format: format, frameCount: 4800, hostTime: AudioGetCurrentHostTime(), token: token)
        XCTAssertNotNil(ingress.lastMicrophoneCallbackHostTime(for: token))
        XCTAssertTrue(ingress.activateMicrophone(token))

        try await ingress.start(folder: folder, sources: [.microphone, .systemAudio])
        samples.update(repeating: 0.5, count: 4800)
        ingress.submitMicrophone(input.audioBufferList, format: format, frameCount: 4800, hostTime: AudioGetCurrentHostTime(), token: token)
        await fulfillment(of: [meter], timeout: 2)
        ingress.closeAdmission()
        _ = try await ingress.finish()
    }

    func testOversizedMicrophoneCallbackPreservesBothSlicesAndChannelLayouts() async throws {
        for interleaved in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let ingress = CaptureIngress(meter: { _ in }, failure: { XCTFail($0) }, pressure: {})
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 96_000,
                                                     channels: 2, interleaved: interleaved))
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600))
            input.frameLength = 9600
            let buffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            for channel in 0..<2 {
                let samples = try XCTUnwrap(buffers[interleaved ? 0 : channel].mData).assumingMemoryBound(to: Float.self)
                for frame in 0..<9600 {
                    let index = interleaved ? frame * 2 + channel : frame
                    let base: Float = frame < 8192 ? 0.2 : 0.6
                    samples[index] = base + Float(channel) * 0.2
                }
            }

            let token = try XCTUnwrap(ingress.beginMicrophoneAttempt())
            ingress.submitMicrophone(input.audioBufferList, format: format, frameCount: 9600, hostTime: AudioGetCurrentHostTime(), token: token)
            XCTAssertTrue(ingress.activateMicrophone(token))
            try await ingress.start(folder: folder, sources: [.microphone])
            ingress.submitMicrophone(input.audioBufferList, format: format, frameCount: 9600, hostTime: AudioGetCurrentHostTime(), token: token)
            ingress.closeAdmission()
            let frames = try await ingress.finish()
            let file = try AVAudioFile(forReading: folder.appendingPathComponent("part-000000.caf"))
            XCTAssertEqual(file.length, frames)
            XCTAssertGreaterThanOrEqual(frames, 1600)
            let probe = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
            file.framePosition = frames - 1000
            try file.read(into: probe)
            XCTAssertEqual(try XCTUnwrap(probe.floatChannelData?[0][0]), 0.3, accuracy: 0.001)
            file.framePosition = frames - 100
            try file.read(into: probe)
            XCTAssertEqual(try XCTUnwrap(probe.floatChannelData?[0][0]), 0.7, accuracy: 0.001)
        }
    }

    func testReplacingMicrophoneRejectsLatePacketsAndPreservesGap() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ingress = CaptureIngress(meter: { _ in }, failure: { XCTFail($0) }, pressure: {})
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        input.frameLength = 1600
        let samples = try XCTUnwrap(input.floatChannelData?[0])
        func submit(_ token: UUID, _ value: Float, at hostTime: UInt64) {
            samples.update(repeating: value, count: 1600)
            ingress.submitMono(.microphone, list: input.audioBufferList, sampleRate: 16_000, hostTime: hostTime,
                               microphoneToken: token)
        }

        let first = try XCTUnwrap(ingress.beginMicrophoneAttempt())
        submit(first, 0, at: AudioGetCurrentHostTime())
        XCTAssertTrue(ingress.activateMicrophone(first))
        try await ingress.start(folder: folder, sources: [.microphone])
        let start = AudioGetCurrentHostTime()
        submit(first, 0.25, at: start)
        ingress.suspendMicrophone(first)

        let second = try XCTUnwrap(ingress.beginMicrophoneAttempt())
        submit(first, 0.9, at: start + AVAudioTime.hostTime(forSeconds: 0.1))
        XCTAssertNil(ingress.lastMicrophoneCallbackHostTime(for: first))
        XCTAssertNil(ingress.lastMicrophoneCallbackHostTime(for: second))
        XCTAssertFalse(ingress.activateMicrophone(second))
        let restart = start + AVAudioTime.hostTime(forSeconds: 0.2)
        submit(second, 0.9, at: start + AVAudioTime.hostTime(forSeconds: 0.1))
        XCTAssertNotNil(ingress.lastMicrophoneCallbackHostTime(for: second))
        XCTAssertTrue(ingress.activateMicrophone(second))
        submit(second, -0.5, at: restart)
        submit(first, 0.9, at: start + AVAudioTime.hostTime(forSeconds: 0.6))

        let frames = try await ingress.finish()
        let file = try AVAudioFile(forReading: folder.appendingPathComponent("part-000000.caf"))
        XCTAssertEqual(file.length, frames)
        XCTAssertGreaterThanOrEqual(frames, 4800)
        let probe = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
        for (offset, expected) in [(4000, Float(0.25)), (2400, 0), (800, -0.5)] {
            file.framePosition = frames - Int64(offset)
            try file.read(into: probe)
            XCTAssertEqual(try XCTUnwrap(probe.floatChannelData?[0][0]), expected, accuracy: 0.001)
        }
    }

    func testCloseDuringMicrophoneGapCannotReopenAdmission() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ingress = CaptureIngress(meter: { _ in }, failure: { XCTFail($0) }, pressure: {})
        let first = try XCTUnwrap(ingress.beginMicrophoneAttempt())
        try await ingress.start(folder: folder, sources: [.microphone])
        ingress.suspendMicrophone(first)
        let second = try XCTUnwrap(ingress.beginMicrophoneAttempt())
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        input.frameLength = 1600
        ingress.submitMicrophone(input.audioBufferList, format: format, frameCount: 1600, hostTime: AudioGetCurrentHostTime(), token: second)
        XCTAssertNotNil(ingress.lastMicrophoneCallbackHostTime(for: second))

        XCTAssertTrue(ingress.closeAdmission())
        XCTAssertFalse(ingress.closeAdmission())
        XCTAssertFalse(ingress.activateMicrophone(second))
        XCTAssertNil(ingress.beginMicrophoneAttempt())
        ingress.submitMicrophone(input.audioBufferList, format: format, frameCount: 1600, hostTime: AudioGetCurrentHostTime(), token: second)
        XCTAssertNil(ingress.lastMicrophoneCallbackHostTime(for: second))
        let frames = try await ingress.finish()
        XCTAssertEqual(frames, 0)
    }
}
