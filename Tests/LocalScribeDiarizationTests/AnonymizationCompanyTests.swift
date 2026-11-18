import XCTest
@testable import LocalScribeWorker

/// Legal-form parsing and drawing of `AnonymizationCompany`: Russian and
/// spelled-out prefixes, foreign suffixes (kept verbatim, case-insensitively
/// detected), quote pairs including German low-high marks, the trailing
/// period, brand language by the share of Cyrillic letters, the descriptor
/// for multi-word brands, and the reproducibility of the seeded SplitMix64
/// stream that every draw consumes.
final class AnonymizationCompanyTests: XCTestCase {

    // MARK: - SplitMix64 determinism

    /// Reference sequence computed independently from the SplitMix64
    /// constants in the source: identical inputs must always produce the
    /// identical stream, and different seeds must diverge from the first
    /// draw. Reproducibility is contractual — the system RNG is forbidden.
    func testSplitMix64MatchesReferenceSequence() {
        let seedZero: [UInt64] = [16294208416658607535, 7960286522194355700,
                                  487617019471545679, 17909611376780542444]
        var generator = SplitMix64(seed: 0)
        XCTAssertEqual((0..<4).map { _ in generator.next() }, seedZero)

        let seedFortyTwo: [UInt64] = [13679457532755275413, 2949826092126892291,
                                      5139283748462763858, 6349198060258255764]
        var other = SplitMix64(seed: 42)
        XCTAssertEqual((0..<4).map { _ in other.next() }, seedFortyTwo)
        // Different seeds diverge from the first value (both constants above
        // are verified references, not draws).
        XCTAssertNotEqual(seedZero[0], seedFortyTwo[0])
    }

    func testSplitMix64SameSeedRepeatsWholeSequence() {
        var first = SplitMix64(seed: 9)
        var second = SplitMix64(seed: 9)
        let left = (0..<8).map { _ in first.next() }
        let right = (0..<8).map { _ in second.next() }
        XCTAssertEqual(left, right)
    }

    // MARK: - Legal form detection

    func testLegalFormPrefixesAndSuffixes() {
        let legal: [String] = [
            "ООО «Ромашка»", "ПАО Ромашка", "ЗАО Ромашка", "АО Ромашка", "ИП Иванов",
            "публичное акционерное общество Ромашка",
            "Общество с ограниченной ответственностью Ромашка",
            "индивидуальный предприниматель Иванов",
            "Ромашка GmbH", "Ромашка GmbH & Co. KG", "Ромашка GMBH",
            "Romashka, Ltd", "Acme Inc.", "Romashka PLC", "Romashka S.A.S.", "Foo B.V.",
        ]
        for source in legal {
            XCTAssertTrue(AnonymizationCompany(source).hasLegalForm, "«\(source)» должна иметь юрформу")
        }
        let plain: [String] = [
            "Ромашка", "Ромашка и партнёры", "Северный Ветер",
            // A prefix with nothing alphabetic after it is not consumed, and
            // a suffix with no brand in front of it stays part of the brand.
            "ООО", "Ltd",
        ]
        for source in plain {
            XCTAssertFalse(AnonymizationCompany(source).hasLegalForm, "«\(source)» не должна иметь юрформу")
        }
    }

    // MARK: - Prefixes, quotes and typography in draw

    func testDrawKeepsPrefixQuotesAndInnerSpacing() throws {
        let cases: [(source: String, pattern: String)] = [
            ("ООО «Ромашка»", "^ООО «[А-ЯЁ][а-яё]+»$"),
            // The spelled-out prefix is preserved verbatim, including its
            // capitalization, and the guillemets around the brand.
            ("Публичное акционерное общество «Ромашка»",
             "^Публичное акционерное общество «[А-ЯЁ][а-яё]+»$"),
            ("Общество с ограниченной ответственностью Ромашка",
             "^Общество с ограниченной ответственностью [А-ЯЁ][а-яё]+$"),
            // Two-word brands also draw a descriptor; the lowercase prefix
            // spelling survives as written.
            ("индивидуальный предприниматель Иванов Иван",
             "^индивидуальный предприниматель [А-ЯЁ][а-яё]+ [А-ЯЁ][а-яё]+$"),
            // Quotes around the whole prefixed name nest into the output.
            ("«ООО «Ромашка»»", "^«ООО «[А-ЯЁ][а-яё]+»»$"),
            // Spaces inside the quotes are trimmed before the brand is drawn.
            ("ООО « Ромашка »", "^ООО «[А-ЯЁ][а-яё]+»$"),
        ]
        for c in cases {
            var rng = SplitMix64(seed: 3)
            let drawn = AnonymizationCompany(c.source).draw(using: &rng)
            XCTAssertNotNil(drawn.range(of: c.pattern, options: .regularExpression),
                            "«\(c.source)» → «\(drawn)»")
        }
    }

    func testDrawKeepsEveryQuotePair() throws {
        let cases: [(source: String, pattern: String)] = [
            ("«Ромашка»", "^«[А-ЯЁ][а-яё]+»$"),
            ("\"Ромашка\"", "^\"[А-ЯЁ][а-яё]+\"$"),
            ("“Ромашка”", "^“[А-ЯЁ][а-яё]+”$"),
            ("„Ромашка“", "^„[А-ЯЁ][а-яё]+“$"),
            ("„Ромашка”", "^„[А-ЯЁ][а-яё]+”$"),
            ("‘Ромашка’", "^‘[А-ЯЁ][а-яё]+’$"),
            ("'Ромашка'", "^'[А-ЯЁ][а-яё]+'$"),
        ]
        for c in cases {
            var rng = SplitMix64(seed: 23)
            let drawn = AnonymizationCompany(c.source).draw(using: &rng)
            XCTAssertNotNil(drawn.range(of: c.pattern, options: .regularExpression),
                            "«\(c.source)» → «\(drawn)»")
        }
    }

    func testDrawKeepsLegalSuffixesAndTrailingPeriod() throws {
        let cases: [(source: String, pattern: String)] = [
            // The suffix is detected case-insensitively but kept verbatim,
            // including the comma form and the compound KG form.
            ("Ромашка GmbH", "^[А-ЯЁ][а-яё]+ GmbH$"),
            ("Ромашка GMBH", "^[А-ЯЁ][а-яё]+ GMBH$"),
            ("Ромашка GmbH & Co. KG", "^[А-ЯЁ][а-яё]+ GmbH & Co\\. KG$"),
            ("Romashka, Ltd", "^[A-Z][a-z]+, Ltd$"),
            ("Acme Inc.", "^[A-Z][a-z]+ Inc\\.$"),
            ("Romashka PLC", "^[A-Z][a-z]+ PLC$"),
            ("Romashka S.A.S.", "^[A-Z][a-z]+ S\\.A\\.S\\.$"),
            ("Foo B.V.", "^[A-Z][a-z]+ B\\.V\\.$"),
            // A trailing period without a legal suffix is stripped and then
            // re-appended after the invented brand; with a suffix the period
            // belongs to the suffix match.
            ("Ромашка.", "^[А-ЯЁ][а-яё]+\\.$"),
            ("Ромашка GmbH.", "^[А-ЯЁ][а-яё]+ GmbH\\.$"),
        ]
        for c in cases {
            var rng = SplitMix64(seed: 29)
            let drawn = AnonymizationCompany(c.source).draw(using: &rng)
            XCTAssertNotNil(drawn.range(of: c.pattern, options: .regularExpression),
                            "«\(c.source)» → «\(drawn)»")
        }
    }

    // MARK: - Brand language and descriptor

    /// The brand language follows the share of Cyrillic letters: Cyrillic
    /// majority (a tie counts as majority) draws Russian starts and endings,
    /// a Latin majority draws English ones.
    func testBrandLanguageFollowsCyrillicShare() throws {
        let cases: [(source: String, pattern: String)] = [
            ("Ромашка", "^[А-ЯЁ][а-яё]+$"),
            ("Romashka", "^[A-Z][a-z]+$"),
            // 7 Cyrillic vs 7 Latin letters: 14 >= 14 keeps Russian.
            ("Ромашка Trading", "^[А-ЯЁ][а-яё]+ [А-ЯЁ][а-яё]+$"),
            // 3 Cyrillic vs 7 Latin letters tips the brand to English.
            ("Ром Trading", "^[A-Z][a-z]+ [A-Z][a-z]+$"),
        ]
        for c in cases {
            var rng = SplitMix64(seed: 41)
            let drawn = AnonymizationCompany(c.source).draw(using: &rng)
            XCTAssertNotNil(drawn.range(of: c.pattern, options: .regularExpression),
                            "«\(c.source)» → «\(drawn)»")
        }
    }

    /// A brand of several words always draws a descriptor after the invented
    /// name; a single-word brand never does, and the prefix or suffix around
    /// the brand does not change that.
    func testDescriptorAddedOnlyForMultiWordBrands() throws {
        let cases: [(source: String, pattern: String)] = [
            ("Ромашка", "^[А-ЯЁ][а-яё]+$"),
            ("Северный Ветер", "^[А-ЯЁ][а-яё]+ [А-ЯЁ][а-яё]+$"),
            ("ООО «Северный Ветер»", "^ООО «[А-ЯЁ][а-яё]+ [А-ЯЁ][а-яё]+»$"),
        ]
        for c in cases {
            var rng = SplitMix64(seed: 47)
            let drawn = AnonymizationCompany(c.source).draw(using: &rng)
            XCTAssertNotNil(drawn.range(of: c.pattern, options: .regularExpression),
                            "«\(c.source)» → «\(drawn)»")
        }
    }

    // MARK: - Determinism

    /// Identical seeds produce identical brands, and the invented brand
    /// depends only on the shape and the generator: two equal-shape sources
    /// draw the same value, so run-level uniqueness comes from the occupied
    /// set at the engine, not from the company itself.
    func testDrawIsDeterministicForSameSeed() {
        let company = AnonymizationCompany("ООО «Ромашка»")
        var first = SplitMix64(seed: 9)
        var second = SplitMix64(seed: 9)
        XCTAssertEqual(company.draw(using: &first), company.draw(using: &second))
        XCTAssertEqual(company, AnonymizationCompany("ООО «Ромашка»"))

        var left = SplitMix64(seed: 3)
        var right = SplitMix64(seed: 3)
        XCTAssertEqual(AnonymizationCompany("Ромашка").draw(using: &left),
                       AnonymizationCompany("Василёк").draw(using: &right),
                       "одна форма и один сид дают одну марку")
    }

    /// A source that is only a bare prefix keeps no legal form, and the draw
    /// still replaces it with an invented single word.
    func testBarePrefixDrawsPlainInventedWord() throws {
        let company = AnonymizationCompany("ООО")
        XCTAssertFalse(company.hasLegalForm)
        var rng = SplitMix64(seed: 51)
        let drawn = company.draw(using: &rng)
        XCTAssertNotNil(drawn.range(of: "^[А-ЯЁ][а-яё]+$", options: .regularExpression), drawn)
    }
}
