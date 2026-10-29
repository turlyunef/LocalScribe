import XCTest
import AVFoundation
import LocalScribeCore
import CWorkerIsolation
@testable import LocalScribeWorker

/// Explicit technical probe only. Its launcher denies network and discards SDK
/// stdout/stderr. Transcripts are artifacts under TestResults, never diagnostics.
final class ASRMatrixProbeTests: XCTestCase {
    private struct Input: Codable {
        var schemaVersion: Int
        var sourceType: String
        var sourceHash: String
        var waveHash: String
        var codeHash: String
        var wavePath: String
        var modelsPath: String
        var run: RunInfo
        var catalog: ModelCatalog
    }

    private struct Measurement: Codable {
        var schemaVersion = 1
        var variant: String
        var windowPolicy: String
        var recoverInteriorGaps: Bool
        var reviewContext: Bool
        var sourceHash: String
        var waveHash: String
        var codeHash: String
        var profileHash: String
        var durationMs: Int
        var completedParts: Int
        var partLengthMs = 300_000
        var thermalStateBefore: Int
        var thermalStateAfter: Int
        var networkDenied = true
    }

    private struct WordRepairReplay: Codable {
        var schemaVersion = 1
        var algorithmVersion: String
        var sourceHash: String
        var waveHash: String
        var inputBatchHashes: [String: String]
        var reviewedWindows: Int
        var proposedEdits: Int
        var networkDenied = true
        var newModelCalls = 0
    }

    func testExplicitWordRepairReplay() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LOCALSCRIBE_ASR_WORD_REPAIR_REPLAY"] == "technical-probe",
              let outputPath = env["LOCALSCRIBE_ASR_MATRIX_OUTPUT"] else {
            throw XCTSkip("Use --repair-replay with a fresh technical output directory")
        }
        let output = URL(fileURLWithPath: outputPath)
        do {
            guard !FileManager.default.fileExists(atPath: output.appendingPathComponent("word-repair-info.json").path),
                  localscribe_deny_network() == 0 else { throw ScribeError.message("Нужен новый технический прогон с запретом сети") }
            let input = try Disk.read(Input.self, at: output.appendingPathComponent("input.json"))
            let wave = output.appendingPathComponent("input.wav")
            let measurement = try Disk.read(Measurement.self, at: output.appendingPathComponent("E/measurement.json"))
            let metrics = try Disk.read(ASRMetrics.self, at: output.appendingPathComponent("E/metrics-asr.json"))
            let file = try AVAudioFile(forReading: wave)
            let duration = Int((Double(file.length) / 16).rounded())
            guard input.schemaVersion == 1, input.sourceType == "technical-probe", input.sourceHash == input.run.sourceHash,
                  measurement.sourceHash == input.sourceHash, measurement.waveHash == input.waveHash,
                  measurement.codeHash == input.codeHash, measurement.profileHash == input.run.profileHash,
                  measurement.windowPolicy == "late-pause-context-review", measurement.networkDenied,
                  metrics.status == "completed", metrics.checkpointHits == 0,
                  metrics.plannedWindows.totalMs == duration, duration == measurement.durationMs,
                  duration > 0, duration <= 10_800_000, file.processingFormat.sampleRate == 16000,
                  file.processingFormat.channelCount == 1, try Disk.hash(wave) == input.waveHash else {
                throw ScribeError.message("Некорректные исходники технического повтора")
            }
            let folder = output.appendingPathComponent("E/context-reviews")
            let paths = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !paths.isEmpty else { throw ScribeError.message("Нет сохранённых вариантов ASR") }
            var hashes: [String: String] = [:], edits = 0
            for path in paths {
                hashes[path.lastPathComponent] = try Disk.hash(path)
                var batch = try Disk.read(ASRContextReviewBatch.self, at: path)
                guard batch.schemaVersion == 1, 0 <= batch.coreStartMs, batch.coreStartMs < batch.coreEndMs,
                      batch.coreEndMs <= duration else { throw ScribeError.message("Некорректное окно ASR") }
                for index in batch.reviews.indices {
                    try Task.checkCancellation()
                    let review = batch.reviews[index], request = review.request
                    guard 0 <= request.contextStartMs, request.contextStartMs <= request.startMs,
                          request.startMs < request.endMs, request.endMs <= request.contextEndMs,
                          request.contextEndMs <= duration else { throw ScribeError.message("Некорректная цель повтора") }
                    for segments in [review.original, review.candidate] {
                        var validation = segments
                        for i in validation.indices { validation[i].id = "validation-\(i)" }
                        try Transcript(fingerprint: "validation", diarized: false, segments: validation).validate(durationMs: duration)
                    }
                    let repaired = ASRWordRepair.propose(original: review.original, candidate: review.candidate,
                        startMs: request.startMs, endMs: request.endMs)
                    var validation = repaired.proposed
                    for i in validation.indices { validation[i].id = "validation-\(i)" }
                    try Transcript(fingerprint: "validation", diarized: false, segments: validation).validate(durationMs: duration)
                    edits += repaired.edits.count
                    batch.reviews[index].wordRepair = repaired
                }
                try Disk.write(batch, to: path)
            }
            try Disk.write(WordRepairReplay(algorithmVersion: ASRWordRepair.version, sourceHash: input.sourceHash,
                waveHash: input.waveHash, inputBatchHashes: hashes, reviewedWindows: paths.count, proposedEdits: edits),
                to: output.appendingPathComponent("word-repair-info.json"))
        } catch {
            XCTFail("Word repair replay failed; no model output is logged")
        }
    }

    func testExplicitOfflineMatrixVariant() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LOCALSCRIBE_ASR_MATRIX_PROBE"] == "technical-probe",
              let inputPath = env["LOCALSCRIBE_ASR_MATRIX_INPUT"],
              let outputPath = env["LOCALSCRIBE_ASR_MATRIX_OUTPUT"],
              let variant = env["LOCALSCRIBE_ASR_MATRIX_VARIANT"] else {
            throw XCTSkip("Run scripts/probe_asr_matrix.py with explicit local source and model paths")
        }
        let policies: [String: WhisperRecognitionPolicy] = [
            "A": .production,
            "B": .init(window: .firstPause, recoverInteriorGaps: true),
            "C": .init(window: .latePause, recoverInteriorGaps: false),
            "D": .init(window: .latePause, recoverInteriorGaps: true),
            "E": .init(window: .latePause, reviewContext: true)
        ]
        let policy = try XCTUnwrap(policies[variant])
        let output = URL(fileURLWithPath: outputPath)
        // A fresh directory is required; no previous ASR part is ever reused.
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ScribeError.message("Каталог варианта уже существует") }
        try Disk.write(["stage": "network-check"], to: output.appendingPathComponent("probe-state.json"))
        guard localscribe_deny_network() == 0 else { throw ScribeError.message("Не удалось запретить сеть техническому probe") }
        try Disk.write(["stage": "validating-inputs"], to: output.appendingPathComponent("probe-state.json"))
        let input = try Disk.read(Input.self, at: URL(fileURLWithPath: inputPath))
        guard input.schemaVersion == 1, input.sourceType == "technical-probe",
              input.sourceHash == input.run.sourceHash else { throw ScribeError.message("Некорректный вход технического сравнения") }
        let wave = URL(fileURLWithPath: input.wavePath), models = URL(fileURLWithPath: input.modelsPath)
        guard try Disk.hash(wave) == input.waveHash else { throw ScribeError.message("Изменился технический WAV") }
        let pinned = try input.catalog.pinned(to: input.run)
        for model in pinned.models where model.purpose == .asr || model.purpose == .tokenizer {
            try model.validate(at: models)
        }
        let file = try AVAudioFile(forReading: wave)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else {
            throw ScribeError.message("Нужен mono PCM 16 кГц")
        }
        let duration = Int((Double(file.length) / 16).rounded())
        guard duration > 0, duration <= 10_800_000 else { throw ScribeError.message("Недопустимая длительность") }
        let fingerprint = Disk.fingerprint("asr-matrix-v1:" + input.sourceHash + input.waveHash + input.codeHash + input.run.profileHash + policy.metricsName)
        let before = ProcessInfo.processInfo.thermalState.rawValue
        let metrics = ASRMetricsRecorder(run: output, liveCapture: false, windowPolicy: policy.metricsName)
        do {
            try Disk.write(WhisperASREngine.decodingOptions, to: output.appendingPathComponent("decoding-options.json"))
            try Disk.write(["stage": "loading-model"], to: output.appendingPathComponent("probe-state.json"))
            let recognizer = try await WhisperASREngine(info: input.run, models: models, metrics: metrics, policy: policy,
                contextReview: { batch in
                    try Disk.write(batch, to: output.appendingPathComponent("context-reviews/window-\(batch.coreStartMs).json"))
                }, warning: { _ in })
            var parts: [ASRPart] = []
            for start in stride(from: 0, to: duration, by: 300_000) {
                try Disk.write(["stage": "recognizing", "part": String(parts.count)], to: output.appendingPathComponent("probe-state.json"))
                let end = min(duration, start + 300_000)
                var segments = try await recognizer.recognize(wave: wave, coreStart: start, coreEnd: end, durationMs: duration)
                for index in segments.indices { segments[index].id = "part-\(parts.count)-seg-\(index)" }
                let part = ASRPart(fingerprint: fingerprint, index: parts.count, startMs: start, endMs: end, segments: segments)
                try Disk.write(part, to: output.appendingPathComponent("parts/part-\(parts.count).json"))
                parts.append(part)
            }
            let transcript = Analysis.mergeParts(parts, fingerprint: fingerprint)
            try transcript.validate(durationMs: duration)
            guard try Disk.hash(wave) == input.waveHash else { throw ScribeError.message("Изменился технический WAV") }
            for model in pinned.models where model.purpose == .asr || model.purpose == .tokenizer {
                try model.validate(at: models)
            }
            try Disk.write(transcript, to: output.appendingPathComponent("transcript.json"))
            let measurement = Measurement(variant: variant, windowPolicy: policy.metricsName,
                recoverInteriorGaps: policy.recoverInteriorGaps, reviewContext: policy.reviewContext, sourceHash: input.sourceHash,
                waveHash: input.waveHash, codeHash: input.codeHash, profileHash: input.run.profileHash,
                durationMs: duration, completedParts: parts.count,
                thermalStateBefore: before, thermalStateAfter: ProcessInfo.processInfo.thermalState.rawValue)
            try Disk.write(measurement, to: output.appendingPathComponent("measurement.json"))
            metrics.finish(status: "completed")
            try Disk.write(["stage": "completed"], to: output.appendingPathComponent("probe-state.json"))
            XCTAssertEqual(metrics.value.checkpointHits, 0)
            XCTAssertEqual(metrics.value.plannedWindows.totalMs, duration)
            if !policy.recoverInteriorGaps { XCTAssertEqual(metrics.value.gapRecovery.inputs.count, 0) }
        } catch {
            metrics.finish(status: error is CancellationError ? "cancelled" : "failed")
            try? Disk.write(["stage": "failed", "errorType": String(reflecting: type(of: error)),
                             "errorCode": String((error as NSError).code)], to: output.appendingPathComponent("probe-state.json"))
            // The launcher discards SDK output; don't put private SDK errors into XCTest diagnostics either.
            XCTFail("ASR matrix variant failed; inspect numeric metrics")
        }
    }
}
