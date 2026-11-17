import CoreMedia
import XCTest
@testable import LocalScribe

final class BilingualCaptionResultsTests: XCTestCase {
    func testOverlappingHypothesesKeepOneWordPerLanguageSwitch() {
        let words = [
            word(.russian, 0, 420, "Давай", 0.29),
            word(.russian, 420, 1_020, "обсудим", 0.73),
            word(.russian, 1_020, 1_170, "ты", 0.21),
            word(.russian, 1_170, 1_500, "Next", 0.4),
            word(.english, 0, 240, "The", 0.48),
            word(.english, 240, 420, "way", 0.16),
            word(.english, 420, 600, "up", 0.11),
            word(.english, 600, 1_260, "Sujim", 0.29),
            word(.english, 1_260, 1_440, "the", 0.75),
            word(.english, 1_440, 1_560, "next", 0.99),
            word(.english, 1_560, 2_280, "release.", 0.83),
            word(.russian, 2_730, 3_180, "Давай", 0.81)
        ]
        let merged = BilingualCaptionResults.merge(words, preferred: .russian)
        XCTAssertEqual(merged.map(\.text), ["Давай", "обсудим", "the", "next", "release.", "Давай"])
    }

    func testPreviewAndFinalizationUseACumulativeCommonBoundary() {
        var merger = BilingualCaptionResults(preferred: .russian)
        var text = LiveCaptionText()
        func apply(_ event: BilingualCaptionResults.Event) {
            merger.consume(event).forEach { text.receive($0) }
        }
        apply(.update(.russian, .init(range: range(0, 400), finalizedThrough: .zero, text: "Давай"), words: [], isFinal: false))
        XCTAssertEqual(text.tentative.map(\.text), ["Давай"])
        apply(.update(.english, .init(range: range(0, 800), finalizedThrough: time(800), text: ""), words: [
            word(.english, 405, 780, "review", 0.95)
        ], isFinal: true))
        XCTAssertTrue(text.phrases.isEmpty)
        apply(.update(.russian, .init(range: range(0, 950), finalizedThrough: time(950), text: ""), words: [
            word(.russian, 0, 400, "Давай", 0.85),
            word(.russian, 790, 950, "сейчас.", 0.9)
        ], isFinal: true))
        XCTAssertEqual(text.phrases, ["Давай review"])
        XCTAssertEqual(text.tentative.map(\.text), ["сейчас."])
        apply(.finished(.english))
        apply(.finished(.russian))
        XCTAssertEqual(text.phrases, ["Давай review", "сейчас."])
        XCTAssertTrue(text.tentative.isEmpty)
    }

    func testWeakEnglishTermSurvivesASmallOverlapWithAnAdjacentRussianWord() {
        let words = [
            word(.russian, 0, 600, "Открой", 0.55),
            word(.english, 780, 1_500, "GitHub", 0.28),
            word(.russian, 1_380, 1_560, "и", 0.90),
            word(.russian, 1_560, 1_920, "проверь", 0.95)
        ]
        let merged = BilingualCaptionResults.merge(words, preferred: .russian)
        XCTAssertEqual(merged.map(\.text), ["Открой", "GitHub", "и", "проверь"])
    }

    func testLatinTermFromRussianDictationSurvivesDraftFinalization() {
        var merger = BilingualCaptionResults(preferred: .russian)
        var text = LiveCaptionText()
        let phrase = "Открой GitHub и посмотри код там"
        let spoken = range(2_220, 6_480)
        merger.consume(.update(.russian, .init(range: spoken, finalizedThrough: .zero, text: phrase),
                               words: [], isFinal: false)).forEach { text.receive($0) }
        XCTAssertEqual(text.tentative.map(\.text), [phrase])

        let russian = [
            word(.russian, 2_220, 2_700, "Открой", 0.951),
            word(.russian, 2_700, 3_180, "GitHub", 0.737),
            word(.russian, 3_180, 3_270, "и", 0.939),
            word(.russian, 3_270, 3_750, "посмотри", 0.977),
            word(.russian, 3_750, 4_110, "код", 0.979),
            word(.russian, 4_110, 4_350, "там", 0.965)
        ]
        merger.consume(.update(.russian, .init(range: spoken, finalizedThrough: time(6_480), text: phrase),
                               words: russian, isFinal: true)).forEach { text.receive($0) }
        let english = [
            word(.english, 2_040, 2_340, "At", 0.515),
            word(.english, 2_340, 3_000, "crew,", 0.057),
            word(.english, 3_000, 3_360, "GitHub,", 0.192),
            word(.english, 3_360, 4_020, "Ipasmatri,", 0.129),
            word(.english, 4_020, 4_140, "got", 0.084),
            word(.english, 4_140, 4_920, "them.", 0.289)
        ]
        merger.consume(.update(.english, .init(range: range(2_040, 9_120), finalizedThrough: time(9_120), text: ""),
                               words: english, isFinal: true)).forEach { text.receive($0) }
        XCTAssertEqual(text.phrases, [phrase])
        XCTAssertTrue(text.tentative.isEmpty)
    }

    func testRussianDictationKeepsLatinAndMixedScriptNames() {
        XCTAssertTrue(BilingualCaptionLanguage.russian.matches("GitHub"))
        XCTAssertTrue(BilingualCaptionLanguage.russian.matches("GitHub’е"))
        XCTAssertTrue(BilingualCaptionLanguage.russian.matches("API-v2"))
        XCTAssertFalse(BilingualCaptionLanguage.english.matches("посмотри"))
        XCTAssertFalse(BilingualCaptionLanguage.russian.matches("..."))
    }

    private func word(_ language: BilingualCaptionLanguage, _ start: Int64, _ end: Int64,
                      _ text: String, _ confidence: Double) -> BilingualCaptionWord {
        BilingualCaptionWord(language: language, range: range(start, end), text: text, confidence: confidence)
    }

    private func range(_ start: Int64, _ end: Int64) -> CMTimeRange {
        CMTimeRange(start: time(start), end: time(end))
    }

    private func time(_ milliseconds: Int64) -> CMTime { CMTime(value: milliseconds, timescale: 1_000) }
}
