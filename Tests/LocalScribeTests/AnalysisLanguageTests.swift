import XCTest
@testable import LocalScribeCore

final class AnalysisLanguageTests: XCTestCase {
    func testLanguageDetectsPureRussianAndEnglishText() {
        XCTAssertEqual(Analysis.language("Привет, это встреча команды", fallback: "auto"), "ru")
        XCTAssertEqual(Analysis.language("Запись 18.10.2026", fallback: "auto"), "ru")
        XCTAssertEqual(Analysis.language("The meeting starts now", fallback: "auto"), "en")
        XCTAssertEqual(Analysis.language("Recording (part 2)", fallback: "auto"), "en")
    }

    func testLanguageMarksCyrillicAndLatinMixAsMixed() {
        XCTAssertEqual(Analysis.language("Привет team, смотри README", fallback: "auto"), "mixed")
        XCTAssertEqual(Analysis.language("\u{0400}z", fallback: "auto"), "mixed")
    }

    func testLanguageFallsBackWithoutCyrillicOrLatinScalars() {
        XCTAssertEqual(Analysis.language("123 — 456,78!", fallback: "auto"), "auto")
        // CJK и расширенная латиница не входят ни в один из диапазонов функции.
        XCTAssertEqual(Analysis.language("中文会議", fallback: "auto"), "auto")
        XCTAssertEqual(Analysis.language("\u{00E9}", fallback: "auto"), "auto")
        XCTAssertEqual(Analysis.language("", fallback: "auto"), "auto")
    }

    func testLanguageUsesInclusiveScalarRangeBoundaries() {
        // Кириллица: 0x400 и 0x52F входят в диапазон, соседние скаляры — нет.
        XCTAssertEqual(Analysis.language("\u{0400}", fallback: "auto"), "ru")
        XCTAssertEqual(Analysis.language("\u{052F}", fallback: "auto"), "ru")
        XCTAssertEqual(Analysis.language("\u{03FF}", fallback: "auto"), "auto")
        XCTAssertEqual(Analysis.language("\u{0530}", fallback: "auto"), "auto")
        // ASCII-латиница: A/Z/a/z входят, соседние кодовые точки — нет.
        XCTAssertEqual(Analysis.language("AZ", fallback: "auto"), "en")
        XCTAssertEqual(Analysis.language("az", fallback: "auto"), "en")
        XCTAssertEqual(Analysis.language("@", fallback: "auto"), "auto")
        XCTAssertEqual(Analysis.language("[", fallback: "auto"), "auto")
        XCTAssertEqual(Analysis.language("`", fallback: "auto"), "auto")
        XCTAssertEqual(Analysis.language("{", fallback: "auto"), "auto")
    }

    func testUnavailableModelMessageTranslatesEachSemicolonSeparatedReason() {
        // Причина «нужно N ГБ рабочего объёма» сама содержит «; » — разделитель
        // причин проходит только перед «нужно » или «Некорректный рабочий объём».
        let stored = "Токенизатор Whisper large-v3 / turbo недоступна на этом Mac: требуется от 8 ГБ RAM, на этом Mac — 4 ГБ; нужно 12 ГБ рабочего объёма; бюджет RAM/Metal с резервом системы — 3.4 ГБ."
        XCTAssertEqual(
            L10n.englishMessages.translate(stored),
            "Whisper large-v3 / turbo tokenizer is unavailable on this Mac: requires at least 8 GB of RAM, and this Mac has 4 GB; requires 12 GB of working memory, and the RAM/Metal budget after the system reserve is 3.4 GB."
        )
    }

    func testUnavailableModelMessageKeepsSingleWorkingMemoryReasonWhole() {
        // Единственная причина переводится целиком: внутренняя «; » не подходит под lookahead.
        let stored = "Токенизатор Whisper large-v3 / turbo недоступна на этом Mac: нужно 12 ГБ рабочего объёма; бюджет RAM/Metal с резервом системы — 3.4 ГБ."
        XCTAssertEqual(
            L10n.englishMessages.translate(stored),
            "Whisper large-v3 / turbo tokenizer is unavailable on this Mac: requires 12 GB of working memory, and the RAM/Metal budget after the system reserve is 3.4 GB."
        )
    }

    func testUnavailableModelMessageSplitsInvalidWorkingMemoryReasonAndKeepsUnknownNames() {
        // «Пользовательская модель» нет в Interface.en — имя сохраняется дословно.
        // Точечные переводы причин не обрезаются, поэтому шаблон добавляет свою
        // финальную точку к уже завершённому предложению.
        let stored = "Пользовательская модель недоступна на этом Mac: Некорректные требования RAM в каталоге; Некорректный рабочий объём в каталоге."
        XCTAssertEqual(
            L10n.englishMessages.translate(stored),
            "Пользовательская модель is unavailable on this Mac: Invalid RAM requirements in the catalog.; Invalid working memory requirement in the catalog.."
        )
    }
}
