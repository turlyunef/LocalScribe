import XCTest
@testable import LocalScribeCore

final class ExportTests: XCTestCase {
    func testTranscriptModelFollowsStatusAndPreservesTimestampRanges() {
        let manifest = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        let transcript = Transcript(fingerprint: "f", diarized: true, segments: [
            Segment(id: "first", startMs: 1000, endMs: 2000, text: "Текст", language: "ru"),
        ])
        for markdown in [false, true] {
            let result = ExportService.renderResult(manifest: manifest, transcript: transcript, summary: nil,
                part: .transcript, markdown: markdown, transcriptionModel: "ASR [test]")
            let name = markdown ? "ASR \\[test\\]" : "ASR [test]"
            XCTAssertTrue(result.text.contains("Статус: \(manifest.state.title)\nМодель: \(name)\n"))
            XCTAssertEqual((result.text as NSString).substring(with: result.timestamps[0].range), "[00:00:01]")
        }
    }
    func testIndexedEvidencePreservesTranscriptOrderDeduplicatesIDsAndUsesUTF16() {
        let manifest = Manifest(sourceType: "import", title: "План 🧑🏽‍💻 [тест]", filename: "meeting.wav")
        let transcript = Transcript(fingerprint: "f", diarized: true, segments: [
            Segment(id: "first", startMs: 1000, endMs: 2000, text: "😀", language: "ru"),
            Segment(id: "same-time", startMs: 1000, endMs: 2000, text: "Одинаковое время", language: "ru"),
            Segment(id: "last", startMs: 76_000, endMs: 77_000, text: "Конец", language: "ru")
        ])
        let summary = Summary(language: "ru", overview: [Finding(id: "f", text: "Вывод 🧑🏽‍💻 *важно*",
            evidenceSegmentIds: ["last", "same-time", "missing", "first", "last"])])
        for markdown in [false, true] {
            let rendered = ExportService.renderResult(manifest: manifest, transcript: transcript, summary: summary, part: .summary, markdown: markdown)
            XCTAssertEqual(rendered.timestamps.map(\.segmentID), ["first", "same-time", "last"])
            XCTAssertEqual(rendered.timestamps.map { (rendered.text as NSString).substring(with: $0.range) },
                           ["[00:00:01]", "[00:00:01]", "[00:01:16]"])
            XCTAssertTrue(rendered.timestamps.allSatisfy { !$0.isTranscript })
        }
    }

    func testTranscriptUsesOnlyPhraseStartTimesInTextAndMarkdown() {
        var manifest = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        manifest.durationMs = 10_800_000
        let transcript = Transcript(fingerprint: "f", diarized: true, segments: [
            Segment(id: "zero", startMs: 0, endMs: 999, speakerId: "speaker-1", text: "Начало", language: "ru"),
            Segment(id: "phrase", startMs: 76_100, endMs: 77_900, speakerId: "speaker-2", text: "Фраза", language: "ru"),
            Segment(id: "last", startMs: 10_799_000, endMs: 10_800_000, text: "Конец", language: "ru")
        ])
        for markdown in [false, true] {
            for part in [ExportPart.transcript, .all] {
                let text = ExportService.render(manifest: manifest, transcript: transcript, summary: nil, part: part, markdown: markdown)
                XCTAssertTrue(text.contains("[00:00:00] Спикер 1\nНачало\n\n"))
                XCTAssertTrue(text.contains("[00:01:16] Спикер 2\nФраза\n\n"))
                XCTAssertTrue(text.contains("[02:59:59]"))
                XCTAssertFalse(text.contains("–"))
                XCTAssertFalse(text.contains("00:01:17"))
                XCTAssertTrue(text.contains("Длительность: 03:00:00"))
            }
        }
    }

    func testShortTimestampsPreserveSpeakerWarningsAndMarkdownEscaping() {
        var segment = Segment(id: "overlap", startMs: 76_000, endMs: 77_000, text: "  [план] *тест* 😀\n", language: "ru")
        segment.overlap = true
        segment.uncertain = true
        XCTAssertEqual(ExportService.renderSegment(segment, markdown: false),
                       "[00:01:16] Несколько голосов — сомнительный участок\n[план] *тест* 😀\n\n")
        XCTAssertEqual(ExportService.renderSegment(segment, markdown: true),
                       "[00:01:16] Несколько голосов — сомнительный участок\n\\[план\\] \\*тест\\* 😀\n\n")
        XCTAssertEqual(segment.endMs, 77_000)
    }

    func testSummaryEvidenceKeepsStartTimeWithoutIncludingTranscript() {
        let manifest = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        let transcript = Transcript(fingerprint: "f", diarized: true, segments: [
            Segment(id: "phrase", startMs: 76_000, endMs: 77_000, text: "Исходная фраза", language: "ru")
        ])
        let summary = Summary(language: "ru", overview: [Finding(id: "finding", text: "Вывод", evidenceSegmentIds: ["phrase"])])
        for markdown in [false, true] {
            let text = ExportService.render(manifest: manifest, transcript: transcript, summary: summary, part: .summary, markdown: markdown)
            XCTAssertTrue(text.contains("Вывод [00:01:16]"))
            XCTAssertFalse(text.contains("00:01:17"))
            XCTAssertFalse(text.contains("Исходная фраза"))
        }
    }

    func testTimestampRangesMatchRenderedTextInEveryExportPart() {
        let manifest = Manifest(sourceType: "import", title: "Встреча 😀 [00:01:16]", filename: "meeting.wav")
        let transcript = Transcript(fingerprint: "f", diarized: true, segments: [
            Segment(id: "first", startMs: 76_100, endMs: 76_300, text: "😀 [пример]", language: "ru"),
            Segment(id: "second", startMs: 76_400, endMs: 77_000, text: "Вторая", language: "ru")
        ])
        let summary = Summary(language: "ru", tasks: [Finding(id: "task", text: "Задача 😀 [тест]", evidenceSegmentIds: ["second"], ownerSpeakerId: "speaker-1")])
        for markdown in [false, true] {
            for part in ExportPart.allCases {
                let rendered = ExportService.renderResult(manifest: manifest, transcript: transcript, summary: summary, part: part, markdown: markdown)
                let expectedIDs: [String]
                switch part {
                case .transcript: expectedIDs = ["first", "second"]
                case .summary: expectedIDs = ["second"]
                case .warnings: expectedIDs = []
                case .all: expectedIDs = ["second", "first", "second"]
                }
                XCTAssertEqual(rendered.timestamps.map(\.segmentID), expectedIDs)
                XCTAssertEqual(rendered.timestamps.filter(\.isTranscript).count, part == .transcript || part == .all ? 2 : 0)
                for timestamp in rendered.timestamps {
                    XCTAssertEqual((rendered.text as NSString).substring(with: timestamp.range), "[00:01:16]")
                }
            }
        }
    }

    func testWarningsHaveDedicatedSectionAndRemainInCompleteExport() {
        var manifest = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        manifest.warnings = ["00:02:09–00:02:11", "00:06:42–00:07:00", "00:16:00–00:16:02",
                             "00:25:00–00:25:03", "00:26:58–00:27:00", "00:27:00–00:27:01",
                             "00:27:28–00:27:30"].map {
            "В интервале \($0) есть звук, но начало речи не распознано. Прослушайте исходник; можно повторить обработку другой моделью."
        } + ["Неподтверждённые поля ответственных и сроков оставлены как «Не указано»; неопределённость источника сохранена.",
             "Проверить [план] *позже* 😀"]
        let transcript = Transcript(fingerprint: "f", diarized: true, segments: [
            Segment(id: "s", startMs: 1000, endMs: 2000, text: "Исходная реплика", language: "ru")
        ])
        let summary = Summary(language: "ru", overview: [Finding(id: "f", text: "Вывод встречи", evidenceSegmentIds: ["s"])])
        for markdown in [false, true] {
            for part in ExportPart.allCases {
                let result = ExportService.renderResult(manifest: manifest, transcript: transcript, summary: summary, part: part, markdown: markdown)
                let includesWarnings = part == .warnings || part == .all
                XCTAssertEqual(result.text.contains("Предупреждения\n\n"), includesWarnings)
                XCTAssertEqual(result.text.components(separatedBy: "Предупреждение: ").count - 1,
                               includesWarnings ? manifest.warnings.count : 0)
                if includesWarnings {
                    var end = result.text.startIndex
                    for warning in manifest.warnings.dropLast() {
                        guard let range = result.text.range(of: "Предупреждение: \(warning)", range: end..<result.text.endIndex) else {
                            XCTFail("Пропущено предупреждение или нарушен порядок: \(warning)"); continue
                        }
                        end = range.upperBound
                    }
                    XCTAssertTrue(result.text.contains(markdown ? "Проверить \\[план\\] \\*позже\\* 😀" : "Проверить [план] *позже* 😀"))
                }
                if part == .warnings {
                    XCTAssertTrue(result.timestamps.isEmpty)
                    XCTAssertFalse(result.text.contains("Исходная реплика"))
                    XCTAssertFalse(result.text.contains("Вывод встречи"))
                    XCTAssertFalse(result.text.contains("Расшифровка\n"))
                    XCTAssertFalse(result.text.contains("Краткое содержание"))
                }
            }
        }
    }

    func testEmptyWarningsDoNotAddSectionOrUnrelatedPlaceholders() {
        let manifest = Manifest(sourceType: "import", title: "Встреча", filename: "meeting.wav")
        for markdown in [false, true] {
            for part in ExportPart.allCases {
                let result = ExportService.renderResult(manifest: manifest, transcript: nil, summary: nil, part: part, markdown: markdown)
                XCTAssertFalse(result.text.contains("Предупреждения"))
                XCTAssertFalse(result.text.contains("Предупреждение:"))
                if part == .warnings {
                    XCTAssertFalse(result.text.contains("ещё не готовы"))
                    XCTAssertFalse(result.text.contains("ещё не готова"))
                    XCTAssertTrue(result.timestamps.isEmpty)
                }
            }
        }
    }
}
