import XCTest
@testable import LocalScribeWorker

/// Classification of configured type wordings and the generic-substitute
/// formatter. `DataKind(wording:)` picks the substitution shape for a custom
/// type before any value is drawn, so its prefix matching, exact-word special
/// cases and category precedence decide e.g. that «Номера телефонов» yields a
/// phone-shaped substitute. `matchingFormat` (reached through
/// `AnonymizationValueFactory.draw` with `.generic`/`.identifier`) must keep
/// the casing of every letter run and the separator skeleton of the source.
final class AnonymizationValuesKindTests: XCTestCase {

    // MARK: - DataKind classifier

    func testWordingPrefixesAndExactWordsClassifyEachKind() {
        let cases: [(wording: String, kind: AnonymizationValueShape.DataKind)] = [
            // Phone wording wins over the identifier prefix «номер».
            ("Телефоны", .phone),
            ("Phone numbers", .phone),
            ("Telephone", .phone),
            // «E-mail» splits into the exact words e+mail; email wins over
            // address, which «Адреса электронной почты» relies on.
            ("Email", .email),
            ("E-mail", .email),
            ("Рабочие email", .email),
            // Address keeps «почтовые» because «электронн» is absent.
            ("Почтовые адреса", .address),
            ("Домашние адреса", .address),
            ("Home addresses", .address),
            // Date prefixes in several inflections.
            ("Даты", .date),
            ("Дата рождения", .date),
            ("date of birth", .date),
            // Identifier prefixes and exact registry words.
            ("внутренние номера заявок", .identifier),
            ("Идентификаторы", .identifier),
            ("Passport numbers", .identifier),
            ("ID", .identifier),
            ("ИНН и ОГРН", .identifier),
            ("СНИЛС", .identifier),
            // Company prefixes plus the genitive exact-word special case.
            ("Названия компаний", .company),
            ("Наименования организаций", .company),
            ("Работодатели", .company),
            ("Предприятия", .company),
            ("юридических лиц", .company),
            ("Companies", .company),
            ("Organisations", .company),
            // Person prefixes and exact words.
            ("Имена и фамилии", .person),
            ("Имя", .person),
            ("Фамилии и отчества", .person),
            ("ФИО", .person),
            ("Full names", .person),
            ("Surnames", .person),
            ("People", .person),
            // Wordings outside every category stay custom.
            ("журнал один", .custom),
            ("Внутренние коды", .custom),
            ("Питомцы сотрудников", .custom),
        ]
        for c in cases {
            XCTAssertEqual(AnonymizationValueShape.DataKind(wording: c.wording), c.kind,
                           "формулировка «\(c.wording)»")
        }
    }

    /// Only the genitive wording «юридических лиц» is the exact-word company
    /// special case: the nominative «Юридические лица» matches no prefix and
    /// no exact word, so it stays custom.
    func testNominativeLegalEntitiesWordingStaysCustom() {
        XCTAssertEqual(AnonymizationValueShape.DataKind(wording: "Юридические лица"), .custom)
        XCTAssertEqual(AnonymizationValueShape.DataKind(wording: "юридических лиц"), .company)
    }

    /// The wording is lowercased and split on every non-letter non-number
    /// scalar before matching, so case, punctuation and padding are ignored.
    func testClassifierIgnoresCaseWhitespaceAndPunctuation() {
        XCTAssertEqual(AnonymizationValueShape.DataKind(wording: "  ТЕЛЕФОНЫ  "), .phone)
        XCTAssertEqual(AnonymizationValueShape.DataKind(wording: "Телефоны:"), .phone)
        XCTAssertEqual(AnonymizationValueShape.DataKind(wording: "Инн/Огрн/Кпп"), .identifier)
    }

    /// When one wording combines categories the earlier check wins: phone
    /// over identifier, email over address, date over identifier, identifier
    /// over person, company over person.
    func testEarlierCategoryWinsForCombinedWordings() {
        let cases: [(wording: String, kind: AnonymizationValueShape.DataKind)] = [
            ("Номера телефонов", .phone),
            ("Адреса электронной почты", .email),
            ("даты и номера", .date),
            ("Имена и номера", .identifier),
            ("имена компаний", .company),
        ]
        for c in cases {
            XCTAssertEqual(AnonymizationValueShape.DataKind(wording: c.wording), c.kind,
                           "формулировка «\(c.wording)»")
        }
    }

    // MARK: - matchingFormat through the value factory

    /// A generic substitute preserves the case of each letter run: an
    /// all-lower run draws a lowercase invented word, a multi-letter
    /// all-upper run an uppercase one, and a capitalized or single-uppercase
    /// run a capitalized word.
    func testGenericSubstitutePreservesLetterRunCase() throws {
        let cases: [(source: String, pattern: String)] = [
            ("формат", "^[а-яё]+$"),
            ("ФОРМАТ", "^[А-ЯЁ]+$"),
            ("Формат", "^[А-ЯЁ][а-яё]+$"),
            ("format", "^[a-z]+$"),
            ("FORMAT", "^[A-Z]+$"),
            ("Format", "^[A-Z][a-z]+$"),
        ]
        for c in cases {
            for seed in [UInt64(1), 7, 4096] {
                var rng = SplitMix64(seed: seed)
                let drawn = AnonymizationValueFactory.draw(for: c.source, shape: .generic, using: &rng)
                XCTAssertNotEqual(drawn, c.source, "буквенный блок обязан измениться")
                let match = try XCTUnwrap(drawn.range(of: c.pattern, options: .regularExpression),
                                          "«\(drawn)» не сохраняет регистр «\(c.source)»")
                XCTAssertEqual(match.lowerBound, drawn.startIndex)
                XCTAssertEqual(match.upperBound, drawn.endIndex)
            }
        }
    }

    /// Letter runs are redrawn independently and the skeleton between them
    /// survives verbatim: separators keep their positions and every source
    /// digit becomes a digit again.
    func testGenericSubstitutePreservesSkeletonBetweenLetterRuns() throws {
        let source = "USD/евро 2024"
        var rng = SplitMix64(seed: 11)
        let drawn = AnonymizationValueFactory.draw(for: source, shape: .generic, using: &rng)
        let parts = drawn.components(separatedBy: "/")
        XCTAssertEqual(parts.count, 2, "разделитель сохранён: \(drawn)")
        XCTAssertNotNil(parts[0].range(of: "^[A-Z]+$", options: .regularExpression),
                        "верхний латинский блок остаётся верхним: \(drawn)")
        let tail = parts[1].components(separatedBy: " ")
        XCTAssertEqual(tail.count, 2, "пробел сохранён: \(drawn)")
        XCTAssertNotNil(tail[0].range(of: "^[а-яё]+$", options: .regularExpression),
                        "нижний кириллический блок остаётся нижним: \(drawn)")
        XCTAssertNotNil(tail[1].range(of: "^[0-9]{4}$", options: .regularExpression),
                        "каждая цифра заменяется цифрой: \(drawn)")
    }

    /// Whitespace, punctuation and the specials `-+№=@` pass through
    /// untouched, so phone-like and document-like skeletons stay readable.
    func testGenericSubstituteKeepsPunctuationSpecialsAndWhitespace() throws {
        let cases: [(source: String, pattern: String)] = [
            ("№ 8-800-555-35-35", "^№ [0-9]-[0-9]{3}-[0-9]{3}-[0-9]{2}-[0-9]{2}$"),
            ("A - Z", "^[A-Z][a-z]+ - [A-Z][a-z]+$"),
        ]
        for c in cases {
            var rng = SplitMix64(seed: 31)
            let drawn = AnonymizationValueFactory.draw(for: c.source, shape: .generic, using: &rng)
            XCTAssertNotNil(drawn.range(of: c.pattern, options: .regularExpression),
                            "«\(c.source)» → «\(drawn)»")
        }
    }

    /// A symbol that is neither letter, number, punctuation, whitespace nor
    /// one of the preserved specials is replaced by a digit so the output
    /// stays within the ASCII-safe substitution alphabet.
    func testGenericSubstituteReplacesForeignSymbolsWithDigits() throws {
        var rng = SplitMix64(seed: 13)
        let drawn = AnonymizationValueFactory.draw(for: "валюта €", shape: .generic, using: &rng)
        let parts = drawn.components(separatedBy: " ")
        XCTAssertEqual(parts.count, 2, drawn)
        XCTAssertNotNil(parts[0].range(of: "^[а-яё]+$", options: .regularExpression), drawn)
        XCTAssertNotNil(parts[1].range(of: "^[0-9]$", options: .regularExpression),
                        "валютный символ заменён цифрой: \(drawn)")
    }

    /// A single uppercase letter is a capitalized run: the uppercase-only
    /// branch requires more than one letter, so «X-123» draws a capitalized
    /// word plus fresh digits around the preserved hyphen.
    func testSingleUppercaseLetterDrawsCapitalizedWord() throws {
        var rng = SplitMix64(seed: 17)
        let drawn = AnonymizationValueFactory.draw(for: "X-123", shape: .generic, using: &rng)
        XCTAssertNotNil(drawn.range(of: "^[A-Z][a-z]+-[0-9]{3}$", options: .regularExpression), drawn)
    }

    /// A source without letters and numbers leaves nothing changed, and the
    /// fallback then invents a latin brand-like word instead of returning
    /// the source unchanged.
    func testGenericFallbackInventsWordWhenNothingChanges() throws {
        for source in ["!!!", "№№", " - "] {
            var rng = SplitMix64(seed: 5)
            let drawn = AnonymizationValueFactory.draw(for: source, shape: .generic, using: &rng)
            XCTAssertNotEqual(drawn, source)
            XCTAssertNotNil(drawn.range(of: "^[A-Z][a-z]+$", options: .regularExpression),
                            "запасное слово для «\(source)»: \(drawn)")
        }
    }

    /// Identifier mode keeps the case of every single letter: the uppercase
    /// alphabet is drawn per letter and lowercased only for lowercase source
    /// letters, in both scripts.
    func testIdentifierSubstitutePreservesPerLetterCase() throws {
        let cases: [(source: String, pattern: String)] = [
            ("AB-2741", "^[A-Z]{2}-[0-9]{4}$"),
            ("ab-2741", "^[a-z]{2}-[0-9]{4}$"),
            ("Ab-2741", "^[A-Z][a-z]-[0-9]{4}$"),
            ("аб-2741", "^[а-я]{2}-[0-9]{4}$"),
        ]
        for c in cases {
            var rng = SplitMix64(seed: 21)
            let drawn = AnonymizationValueFactory.draw(for: c.source, shape: .identifier, using: &rng)
            XCTAssertNotNil(drawn.range(of: c.pattern, options: .regularExpression),
                            "«\(c.source)» → «\(drawn)»")
        }
    }

    /// The seeded generator makes every draw reproducible: two fresh
    /// generators with the same seed produce byte-identical substitutes.
    func testDrawIsDeterministicForSameSeed() {
        var first = SplitMix64(seed: 77)
        var second = SplitMix64(seed: 77)
        XCTAssertEqual(AnonymizationValueFactory.draw(for: "формат 2026", shape: .generic, using: &first),
                       AnonymizationValueFactory.draw(for: "формат 2026", shape: .generic, using: &second))
        XCTAssertEqual(AnonymizationValueFactory.draw(for: "формат 2026", shape: .generic, using: &first),
                       AnonymizationValueFactory.draw(for: "формат 2026", shape: .generic, using: &second),
                       "последовательные обращения продолжают одну цепочку")
    }
}
