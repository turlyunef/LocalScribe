import AVFoundation
import XCTest
import LocalScribeCore
@testable import LocalScribe

@MainActor
final class RecordingPlaybackTests: XCTestCase {
    func testSummaryStartsPlaybackAndTranscriptClickPreservesPause() async throws {
        let repository = try temporaryRepository()
        var manifest = try saveWAV(in: repository, seconds: 12)
        let run = RunInfo(sourceHash: manifest.sha256, profileHash: "test")
        manifest.activeRunId = run.id
        manifest.state = .completed
        try repository.save(manifest)
        let path = repository.run(manifest.id, run.id)
        let segments = [
            Segment(id: "first", startMs: 1_231, endMs: 2_400, text: "Первая реплика", language: "ru"),
            Segment(id: "second", startMs: 5_781, endMs: 6_822, text: "Вторая реплика", language: "ru"),
        ]
        try Disk.write(run, to: path.appendingPathComponent("run.json"))
        try Disk.write(Transcript(fingerprint: run.fingerprint, diarized: true, segments: segments),
                       to: path.appendingPathComponent("transcript.json"))
        let summary = Summary(language: "ru", decisions: [
            Finding(id: "decision", text: "Вывод", evidenceSegmentIds: ["second"]),
        ])
        try Disk.write(summary, to: path.appendingPathComponent("summary.json"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = AppModel(repository: repository, startServices: false, userDefaults: defaults)
        model.selection = manifest.id
        model.tab = .summary
        await waitUntil { model.resultPresentation.result.timestamps.count == 1 }

        model.activateResultSegment("second", recordingID: manifest.id, from: .summary)
        XCTAssertEqual(model.tab, .transcript)
        XCTAssertEqual(model.jumpTo?.segmentID, "second")
        XCTAssertEqual(model.playback.position, 5.781)
        XCTAssertTrue(model.playback.isPlaying)

        // Pausing during preparation also cancels the intention to start.
        model.playback.toggle()
        await waitUntil { model.playback.state != .loading && !model.resultPresentation.isRendering }
        XCTAssertEqual(model.playback.state, .ready)
        model.activateResultSegment("first", recordingID: manifest.id, from: .transcript)
        XCTAssertEqual(model.playback.position, 1.231)
        XCTAssertFalse(model.playback.isPlaying)
        // Timing is attached to the recording, independently of the visible tab.
        model.tab = .summary
        await model.playback.transcriptTask?.value
        model.playback.skipsPauses = true
        model.playback.seek(to: 3, play: true)
        XCTAssertEqual(model.playback.position, 5.781)
        await model.playback.shutdown()
    }

    func testPauseIndexUsesWholeParagraphsAndOneSecondThreshold() {
        let segments = [
            paragraph("first", 1000, 2000),
            paragraph("shortGap", 2999, 3500),
            paragraph("exactGap", 4500, 5000),
            paragraph("longGap", 8000, 9000),
        ]
        let index = PlaybackPauseIndex(segments)
        for time in [0.0, 0.999, 1, 1.999, 2, 2.5, 2.999, 3.499, 4.5, 4.999, 8, 9, 20] {
            XCTAssertNil(index.nextSpeech(at: time), "At \(time)")
        }
        XCTAssertEqual(index.nextSpeech(at: 3.5), 4.5)
        XCTAssertEqual(index.nextSpeech(at: 4.499), 4.5)
        XCTAssertEqual(index.nextSpeech(at: 5), 8)
        XCTAssertEqual(index.nextSpeech(at: 7.99), 8)
        XCTAssertNil(index.nextSpeech(at: .nan))
        XCTAssertNil(index.nextSpeech(at: .infinity))
        XCTAssertNil(PlaybackPauseIndex().nextSpeech(at: 2))
        XCTAssertNil(PlaybackPauseIndex([segments[0]]).nextSpeech(at: 3))
    }

    func testPauseIndexMergesNestedAndEqualStartOverlapsInUnsortedInput() {
        let index = PlaybackPauseIndex([
            paragraph("last", 7000, 8000),
            paragraph("nested", 2000, 2500),
            paragraph("long", 1000, 5000),
            paragraph("sameStart", 1000, 1500),
            paragraph("overlap", 4000, 6000),
        ])
        for time in [1.0, 1.5, 2.5, 3, 5, 5.999, 7, 8] {
            XCTAssertNil(index.nextSpeech(at: time), "At \(time)")
        }
        XCTAssertEqual(index.nextSpeech(at: 6), 7)
        XCTAssertEqual(index.nextSpeech(at: 6.999), 7)
    }

    func testSkipPausesIsOffByDefaultAndPausedSeekRemainsExact() async throws {
        let repository = try temporaryRepository()
        let manifest = try saveWAV(in: repository, seconds: 10)
        let playback = RecordingPlayback()
        select(manifest, in: repository, playback)
        playback.updateTranscript(transcript([paragraph("first", 1000, 2000), paragraph("next", 6000, 7000)]))
        await playback.transcriptTask?.value
        XCTAssertFalse(playback.skipsPauses)
        playback.seek(to: 3, play: true)
        XCTAssertEqual(playback.position, 3)
        playback.toggle()
        await waitUntil { playback.state == .ready }
        playback.skipsPauses = true
        playback.seek(to: 4)
        XCTAssertEqual(playback.position, 4)
        XCTAssertFalse(playback.isPlaying)
        playback.toggle()
        XCTAssertEqual(playback.position, 6)
        XCTAssertTrue(playback.isPlaying)
        playback.skipsPauses = false
        playback.seek(to: 3)
        XCTAssertEqual(playback.position, 3)
        await playback.shutdown()
    }

    func testPlaybackClockAutomaticallySkipsGapAndKeepsSpeed() async throws {
        let repository = try temporaryRepository()
        let manifest = try saveWAV(in: repository, seconds: 10)
        let playback = RecordingPlayback()
        select(manifest, in: repository, playback)
        playback.updateTranscript(transcript([paragraph("first", 500, 1000), paragraph("next", 6000, 7000)]))
        await playback.transcriptTask?.value
        playback.skipsPauses = true
        playback.speed = 1.5
        playback.seek(to: 0.6, play: true)
        await waitUntil { (playback.position ?? 0) >= 6 }
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.speed, 1.5)
        await waitUntil { (playback.position ?? 0) >= 6.2 }
        playback.toggle()
        XCTAssertFalse(playback.isPlaying)
        await playback.shutdown()
    }

    func testEnablingSkipDuringPlaybackJumpsButMissingTranscriptDoesNot() async throws {
        let repository = try temporaryRepository()
        let manifest = try saveWAV(in: repository, seconds: 10)
        let playback = RecordingPlayback()
        select(manifest, in: repository, playback)
        playback.updateTranscript(transcript([paragraph("first", 0, 1000), paragraph("next", 6000, 7000)]))
        await playback.transcriptTask?.value
        playback.seek(to: 2, play: true)
        await waitUntil { (playback.position ?? 0) > 2.1 }
        playback.skipsPauses = true
        XCTAssertEqual(playback.position, 6)
        playback.updateTranscript(nil)
        playback.seek(to: 3)
        XCTAssertEqual(playback.position, 3)
        await playback.shutdown()
    }

    func testSourceSwitchAndTranscriptReplacementDiscardOldPauses() async throws {
        let repository = try temporaryRepository()
        let first = try saveWAV(in: repository, seconds: 10)
        let second = try saveWAV(in: repository, seconds: 10)
        let playback = RecordingPlayback()
        select(first, in: repository, playback)
        playback.skipsPauses = true
        let old = transcript([paragraph("first", 0, 1000), paragraph("next", 6000, 7000)])
        playback.updateTranscript(old)
        await playback.transcriptTask?.value
        playback.seek(to: 2, play: true)
        XCTAssertEqual(playback.position, 6)
        // Also invalidate a build that has not published yet.
        playback.updateTranscript(old)
        let obsolete = playback.transcriptTask
        select(second, in: repository, playback)
        await obsolete?.value
        playback.seek(to: 2, play: true)
        XCTAssertEqual(playback.position, 2)
        playback.updateTranscript(transcript([paragraph("new", 0, 3000), paragraph("next", 8000, 9000)]))
        await playback.transcriptTask?.value
        playback.seek(to: 2)
        XCTAssertEqual(playback.position, 2)
        playback.seek(to: 4)
        XCTAssertEqual(playback.position, 8)
        await playback.shutdown()
    }

    func testClosingAndReopeningCardRestoresParagraphTiming() async throws {
        let repository = try temporaryRepository()
        let manifest = try saveWAV(in: repository, seconds: 10)
        let playback = RecordingPlayback()
        let source = RecordingPlayback.Source(manifest, folder: repository.folder(manifest.id), tools: projectTools())
        let cardID = UUID()
        let text = transcript([paragraph("first", 0, 1000), paragraph("next", 6000, 7000)])
        playback.cardAppeared(cardID, source: source, transcript: text)
        playback.skipsPauses = true
        await playback.transcriptTask?.value
        playback.cardDisappeared(cardID)
        playback.cardAppeared(cardID, source: source, transcript: text)
        await playback.transcriptTask?.value
        playback.seek(to: 2, play: true)
        XCTAssertEqual(playback.position, 6)
        await playback.shutdown()
    }

    private func paragraph(_ id: String, _ start: Int, _ end: Int) -> Segment {
        Segment(id: id, startMs: start, endMs: end, text: "Реплика \(id)", language: "ru")
    }

    private func transcript(_ segments: [Segment]) -> Transcript {
        Transcript(fingerprint: "test", diarized: true, segments: segments)
    }

    func testSeekClampsAndLatestCommandSurvivesSourceSwitch() async throws {
        let repository = try temporaryRepository()
        let first = try saveWAV(in: repository, seconds: 15)
        let second = try saveWAV(in: repository, seconds: 7)
        let playback = RecordingPlayback()
        select(first, in: repository, playback)
        playback.seek(to: 6, play: true)
        select(second, in: repository, playback)
        XCTAssertNil(playback.position)
        XCTAssertFalse(playback.isPlaying)
        playback.seek(to: 3)
        playback.seek(to: 300)
        XCTAssertEqual(playback.position, 7)
        await waitUntil { playback.state != .loading }
        XCTAssertEqual(playback.state, .ready)
        XCTAssertEqual(playback.duration, 7, accuracy: 0.001)
        playback.skipSeconds = 5
        playback.skip(-1)
        XCTAssertEqual(playback.position, 2)
        playback.skip(-1)
        XCTAssertEqual(playback.position, 0)
        XCTAssertFalse(playback.isPlaying)
        await playback.shutdown()
        XCTAssertNil(playback.position)
        XCTAssertEqual(playback.state, .idle)
    }

    func testPlaybackClockAdvancesAndPausesAtSelectedSpeed() async throws {
        let repository = try temporaryRepository()
        let manifest = try saveWAV(in: repository, seconds: 8)
        let playback = RecordingPlayback()
        select(manifest, in: repository, playback)
        playback.speed = 2
        playback.seek(to: 1, play: true)
        await waitUntil { (playback.position ?? 0) > 1.15 }
        playback.toggle()
        try await Task.sleep(for: .milliseconds(200))
        let paused = try XCTUnwrap(playback.position)
        XCTAssertGreaterThan(paused, 1.15)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(try XCTUnwrap(playback.position), paused, accuracy: 0.03)
        XCTAssertFalse(playback.isPlaying)
        await playback.shutdown()
    }

    func testMissingOriginalBecomesAnInlinePlaybackError() async throws {
        let repository = try temporaryRepository()
        let manifest = Manifest(sourceType: "import", title: "Missing", filename: "missing.wav")
        let playback = RecordingPlayback()
        select(manifest, in: repository, playback)
        playback.toggle()
        await waitUntil { playback.state != .loading }
        XCTAssertEqual(playback.state, .failed(L10n.text("Исходный аудиофайл недоступен.")))
        XCTAssertFalse(playback.isPlaying)
        await playback.shutdown()
    }

    func testImportedAudioFormatsOpenAndSeekInAVPlayer() async throws {
        let tools = projectTools()
        let fixtures = tools.deletingLastPathComponent().appendingPathComponent("format-fixtures")
        let staticNames = ["sample.mp3", "sample-vorbis.ogg", "sample-opus.ogg", "sample.opus"]
        let fm = FileManager.default
        try XCTSkipUnless(fm.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path)
            && staticNames.allSatisfy { fm.fileExists(atPath: fixtures.appendingPathComponent($0).path) },
                          "Requires local Assets/tools and Assets/format-fixtures")

        let repository = try temporaryRepository()
        let manifest = try saveWAV(in: repository, seconds: 3)
        let wave = repository.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        var samples = staticNames.map { fixtures.appendingPathComponent($0) }
        for (container, codec, name) in [("adts", "aac", "aac.aac"), ("m4af", "aac", "aac.m4a"),
                                          ("m4af", "alac", "alac.m4a"), ("flac", "flac", "lossless.flac"),
                                          ("caff", "LEI16", "capture.caf")] {
            let destination = repository.root.appendingPathComponent(name)
            _ = try Media.execute(URL(fileURLWithPath: "/usr/bin/afconvert"),
                                  [wave.path, destination.path, "-f", container, "-d", codec])
            samples.append(destination)
        }

        let playback = RecordingPlayback()
        for sample in samples {
            let info = try Media.probe(sample, tools: tools)
            let manifest = try repository.importFile(sample, info: info, allowDuplicate: true)
            select(manifest, in: repository, playback)
            playback.seek(to: info.duration / 2)
            await waitUntil { playback.state != .loading }
            XCTAssertEqual(playback.state, .ready, sample.lastPathComponent)
            // Wait for the underlying seek callback so a late fallback is observable.
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(playback.state, .ready, sample.lastPathComponent)
            XCTAssertFalse(playback.isPlaying)
            XCTAssertEqual(try XCTUnwrap(playback.position), info.duration / 2, accuracy: 0.03, sample.lastPathComponent)
            let original = repository.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
            XCTAssertEqual(try Disk.hash(original), manifest.sha256, sample.lastPathComponent)
        }
        await playback.shutdown()
    }

    private func temporaryRepository() throws -> RecordingRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try RecordingRepository(root: root)
    }

    private func saveWAV(in repository: RecordingRepository, seconds: Int) throws -> Manifest {
        var manifest = Manifest(sourceType: "import", title: "Sample", filename: "meeting.wav")
        let destination = repository.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(destination.deletingLastPathComponent())
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds)))
        buffer.frameLength = buffer.frameCapacity
        buffer.int16ChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let file = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
            try file.write(from: buffer)
        }
        manifest.sourceComplete = true
        manifest.durationMs = seconds * 1000
        manifest.channels = 1
        manifest.sampleRate = 16_000
        manifest.sha256 = try Disk.hash(destination)
        try repository.save(manifest)
        return manifest
    }

    private func projectTools() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets/tools")
    }

    private func select(_ manifest: Manifest, in repository: RecordingRepository, _ playback: RecordingPlayback) {
        playback.select(.init(manifest, folder: repository.folder(manifest.id), tools: projectTools()))
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Timed out waiting for playback", file: file, line: line)
    }
}
