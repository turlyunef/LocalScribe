import AVFoundation
import Darwin
import XCTest
@testable import LocalScribeCore

final class CleanupTests: XCTestCase {
    func testDeletionRemovesStaleRecordingMetadataFromIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let removed = Manifest(sourceType: "import", title: "Remove metadata", filename: "a.wav")
        let retained = Manifest(sourceType: "import", title: "Keep", filename: "b.wav")
        try repo.save(removed); try repo.save(retained)
        try repo.delete(removed)
        let index = try Disk.read([Manifest].self, at: root.appendingPathComponent("index.json"))
        XCTAssertEqual(index.map(\.id), [retained.id])
    }

    func testMediaToolInheritsCancellationProcessGroup() throws {
        let output = try Media.execute(URL(fileURLWithPath: "/bin/sh"), ["-c", "exec /bin/ps -o pgid= -p $$"])
        let group = Int32(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(group, getpgrp())
    }

    func testMediaToolClosesDescriptorsAfterSuccessAndLaunchFailure() throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        // Warm up Foundation before measuring process-owned descriptors.
        _ = try Media.execute(shell, ["-c", "printf ok"])
        let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0..<10 {
            let output = try Media.execute(shell, ["-c", "if read -r input; then exit 9; fi; printf ok; printf diagnostic >&2"])
            XCTAssertEqual(output, Data("ok".utf8))
            XCTAssertThrowsError(try Media.execute(URL(fileURLWithPath: "/nonexistent/localscribe-tool"), []))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, before)
        XCTAssertThrowsError(try Media.execute(shell, ["-c", "exit 7"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("код 7"))
        }
    }

    func testMediaToolRestoresTerminationSignalEvenIfCallerBlocksIt() async throws {
        try await Task.detached {
            var blocked = sigset_t(), previous = sigset_t()
            sigemptyset(&blocked); sigaddset(&blocked, SIGTERM)
            XCTAssertEqual(pthread_sigmask(SIG_BLOCK, &blocked, &previous), 0)
            defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
            XCTAssertThrowsError(try Media.execute(URL(fileURLWithPath: "/bin/sh"), ["-c", "kill -TERM $$; printf survived"])) { error in
                XCTAssertTrue(error.localizedDescription.contains("код 15"))
            }
        }.value
    }

    func testFailedImportRollsBackUnpublishedFolderAndPreservesExternalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Disk.directory(root)
        let original = root.appendingPathComponent("original.wav"), link = root.appendingPathComponent("import.wav")
        try Data("external original".utf8).write(to: original)
        let hash = try Disk.hash(original)
        // Copying this relative symlink into the archive makes its target missing,
        // so verification fails after the import folder and partial were created.
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "original.wav")
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        XCTAssertThrowsError(try repo.importFile(link, info: AudioInfo(duration: 1, sampleRate: 16000, channels: 1, codec: "pcm_s16le")))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: repo.root.appendingPathComponent("recordings").path).isEmpty)
        XCTAssertEqual(try Disk.hash(original), hash)
        XCTAssertEqual(try Disk.hash(link), hash)
    }

    func testFailedSummaryRunRollsBackDirectoryAndKeepsManifestAndActiveRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "import", title: "Keep", filename: "audio.wav")
        manifest.durationMs = 1000
        let old = try repo.beginRun(&manifest, catalog: ModelCatalog(models: []))
        manifest.activeRunId = old.id; manifest.pendingRunId = nil; manifest.state = .completed
        try repo.save(manifest)
        let transcript = Transcript(fingerprint: old.fingerprint, diarized: true,
                                    segments: [Segment(id: "s", startMs: 0, endMs: 2000, text: "invalid checkpoint", language: "en")])
        let checkpoint = repo.run(manifest.id, old.id).appendingPathComponent("transcript.json")
        try Disk.write(transcript, to: checkpoint)
        let file = repo.folder(manifest.id).appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: file), resultBefore = try Data(contentsOf: checkpoint)
        XCTAssertThrowsError(try repo.beginRun(&manifest, catalog: ModelCatalog(models: []), summaryOnly: true))
        XCTAssertEqual(manifest.activeRunId, old.id); XCTAssertNil(manifest.pendingRunId)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try Data(contentsOf: checkpoint), resultBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repo.folder(manifest.id).appendingPathComponent("runs").path), [old.id])
    }

    func testRecoveryRemovesReproducibleAudioAndKeepsCheckpointsAndActiveResult() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "microphone", title: "Keep", filename: "original.caf")
        let original = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent())
        try Data("verified original".utf8).write(to: original)
        manifest.sha256 = try Disk.hash(original); manifest.sourceComplete = true; manifest.durationMs = 1000
        let old = try repo.beginRun(&manifest, catalog: ModelCatalog(models: []))
        manifest.activeRunId = old.id
        let pending = try repo.beginRun(&manifest, catalog: ModelCatalog(models: []))
        manifest.state = .transcribing; try repo.save(manifest)
        var temporary: [URL] = []
        var checkpoints: [URL] = []
        for info in [old, pending] {
            let run = repo.run(manifest.id, info.id), work = run.appendingPathComponent("work")
            try Disk.directory(work)
            for name in ["audio.wav", "audio.partial.wav"] {
                let url = work.appendingPathComponent(name); try Data("cache".utf8).write(to: url); temporary.append(url)
            }
            let url = run.appendingPathComponent("asr/part-0.json")
            try Disk.write(["checkpoint": "keep"], to: url); checkpoints.append(url)
        }
        let capture = repo.folder(manifest.id).appendingPathComponent("capture")
        try Disk.directory(capture)
        let fragment = capture.appendingPathComponent("part-000000.caf")
        let assembly = original.appendingPathExtension("assembling.caf")
        try Data("redundant fragment".utf8).write(to: fragment); try Data("incomplete assembly".utf8).write(to: assembly)
        temporary += [fragment, assembly]
        // A corrupt run is preserved for inspection, including anything in its work directory.
        let corrupt = repo.run(manifest.id, UUID().uuidString)
        try Disk.write(RunInfo(sourceHash: manifest.sha256, profileHash: ""), to: corrupt.appendingPathComponent("run.json"))
        let corruptWork = corrupt.appendingPathComponent("work/audio.wav")
        try Disk.directory(corruptWork.deletingLastPathComponent()); try Data("keep".utf8).write(to: corruptWork)

        try repo.recover()
        try repo.recover() // Cleanup and recovery are idempotent.

        for url in temporary { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path) }
        for url in checkpoints { XCTAssertEqual(try Disk.read([String: String].self, at: url), ["checkpoint": "keep"]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptWork.path))
        XCTAssertEqual(try Disk.hash(original), manifest.sha256)
        let recovered = try repo.load(manifest.id)
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertEqual(recovered.activeRunId, old.id); XCTAssertEqual(recovered.pendingRunId, pending.id)
    }

    func testCleanupKeepsUnfinishedCaptureAndCachesWhenOriginalIsDamaged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        var manifest = Manifest(sourceType: "microphone", title: "Recover", filename: "original.caf")
        manifest.state = .recording
        try repo.save(manifest)
        let capture = repo.folder(manifest.id).appendingPathComponent("capture/part-000000.caf")
        try Disk.directory(capture.deletingLastPathComponent()); try Data("only audio".utf8).write(to: capture)
        try repo.recover()
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.path))

        let original = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent()); try Data("changed".utf8).write(to: original)
        manifest.sourceComplete = true; manifest.sha256 = "different hash"; manifest.state = .cancelled
        let info = try repo.beginRun(&manifest, catalog: ModelCatalog(models: []))
        let wave = repo.run(manifest.id, info.id).appendingPathComponent("work/audio.wav")
        try Disk.directory(wave.deletingLastPathComponent()); try Data("cache".utf8).write(to: wave)
        try repo.recover()
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wave.path))
    }

    func testCleanupDoesNotFollowRunSymlinkOutsideArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root.appendingPathComponent("archive"))
        var manifest = Manifest(sourceType: "import", title: "Keep", filename: "audio.wav")
        let original = repo.folder(manifest.id).appendingPathComponent(manifest.originalRelativePath)
        try Disk.directory(original.deletingLastPathComponent()); try Data("original".utf8).write(to: original)
        manifest.sha256 = try Disk.hash(original); manifest.sourceComplete = true; try repo.save(manifest)
        let info = RunInfo(sourceHash: manifest.sha256, profileHash: "")
        let external = root.appendingPathComponent("external")
        try Disk.write(info, to: external.appendingPathComponent("run.json"))
        let externalAudio = external.appendingPathComponent("work/audio.wav")
        try Disk.directory(externalAudio.deletingLastPathComponent()); try Data("external audio".utf8).write(to: externalAudio)
        let link = repo.run(manifest.id, info.id)
        try Disk.directory(link.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        try repo.cleanupTemporaryFiles(manifest.id)
        XCTAssertEqual(try Data(contentsOf: externalAudio), Data("external audio".utf8))
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testFailedCaptureAssemblyRemovesTemporaryButKeepsFragmentsAndOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = root.appendingPathComponent("capture"); try Disk.directory(capture)
        for (index, rate) in [16000.0, 48000.0].enumerated() {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let file = try AVAudioFile(forWriting: capture.appendingPathComponent("part-\(index).caf"), settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
            buffer.frameLength = 100; memset(buffer.floatChannelData![0], 0, 400); try file.write(from: buffer)
        }
        let original = root.appendingPathComponent("original.caf")
        try Data("previous original".utf8).write(to: original)
        let hash = try Disk.hash(original)
        XCTAssertThrowsError(try Media.assembleCapture(capture, destination: original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.appendingPathExtension("assembling.caf").path))
        XCTAssertEqual(try Disk.hash(original), hash)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: capture.path).count, 2)
    }

    func testFailedDecoderRemovesPartialWave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = root.appendingPathComponent("tools"); try Disk.directory(tools)
        let probe = "#!/bin/sh\nprintf '%s' '{\"streams\":[{\"codec_type\":\"audio\",\"codec_name\":\"pcm_s16le\",\"channels\":1}],\"format\":{\"duration\":\"1\"}}'\n"
        let decoder = "#!/bin/sh\nfor destination in \"$@\"; do :; done\nprintf broken > \"$destination\"\nexit 1\n"
        for (name, script) in [("ffprobe", probe), ("ffmpeg", decoder)] {
            let url = tools.appendingPathComponent(name)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let destination = root.appendingPathComponent("work/audio.wav")
        XCTAssertThrowsError(try Media.prepare(root.appendingPathComponent("source.wav"), to: destination, tools: tools))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("work/audio.partial.wav").path))
    }
}
