import XCTest
@testable import LocalScribeCore

final class LocalizationTests: XCTestCase {
    func testSystemLanguageUsesFirstSupportedPreference() {
        XCTAssertEqual(ApplicationLanguage.system.resolved(preferredLanguages: ["fr-CA", "en-GB", "ru-RU"]), .english)
        XCTAssertEqual(ApplicationLanguage.system.resolved(preferredLanguages: ["ru-RU", "en"]), .russian)
        XCTAssertEqual(ApplicationLanguage.system.resolved(preferredLanguages: ["fr-CA"]), .russian)
        XCTAssertEqual(ApplicationLanguage.english.resolved(preferredLanguages: ["ru-RU"]), .english)
    }

    func testPackagedCatalogsAndInterpolatedMessages() {
        XCTAssertEqual(L10n.englishInterface["Язык системы"], "System Language")
        XCTAssertEqual(
            L10n.englishMessages.translate("Недостаточно свободного места. Требуется ещё 64 МБ."),
            "Not enough free disk space. Free up another 64 MB."
        )
        XCTAssertEqual(L10n.englishMessages.translate("Личный текст встречи"), "Личный текст встречи")
        XCTAssertEqual(L10n.format("%2$@ · %1$@", arguments: ["👋 %2$@", "Name"]), "Name · 👋 %2$@")
    }

    func testKnownNestedDiagnosticIsTranslated() {
        let message = "Не удалось продолжить: Оригинал не совпадает с незавершённым заданием схемы. Задание сохранено; для нового задания с выбранными моделями нажмите «Распознать заново»."
        XCTAssertEqual(
            L10n.englishMessages.translate(message),
            "Could not resume: The original does not match the pending diagram job. The job was kept. Choose “Recognize Again” to start a new job with the selected model."
        )
    }

    func testAllPackagedTranslationsPreserveTheirArguments() {
        for name in ["Interface.en", "Messages.en"] {
            let catalog = L10n.loadCatalog(name)
            XCTAssertFalse(catalog.isEmpty)
            for (key, translation) in catalog {
                let arguments = Set(L10n.placeholders(in: key).map { L10n.argumentIndex($0, in: key as NSString) })
                let translated = Set(L10n.placeholders(in: translation).map { L10n.argumentIndex($0, in: translation as NSString) })
                XCTAssertEqual(translated, arguments, "\(name): \(key)")
                XCTAssertFalse(translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
            }
        }
    }

    func testNestedModelDiagnosticLocalizesNameButPreservesFilename() {
        let message = "Не удалось продолжить: Модель Токенизатор Whisper large-v3 / turbo: отсутствует или повреждён Скопировано. Задание и контрольные точки сохранены. Для создания нового задания с выбранными моделями нажмите «Обработать заново»."
        XCTAssertTrue(L10n.englishMessages.translate(message).contains("Whisper large-v3 / turbo tokenizer: Скопировано is missing or damaged."))
    }
}
