import XCTest
@testable import LocalScribeWorker

final class AnonymizationFullNameTests: XCTestCase {
    func testMasculineNameAndPatronymicKeepCaseAndOrder() throws {
        let canonical = "Иван Петрович Сидоров"
        let substitute = "Павел Романович Лебедев"
        let examples = [
            (canonical, substitute),
            ("Ивана Петровича Сидорова", "Павла Романовича Лебедева"),
            ("Ивану Петровичу Сидорову", "Павлу Романовичу Лебедеву"),
            ("Иваном Петровичем Сидоровым", "Павлом Романовичем Лебедевым"),
            ("Иване Петровиче Сидорове", "Павле Романовиче Лебедеве"),
            ("Сидоров Иван Петрович", "Лебедев Павел Романович"),
            ("Сидорова Ивана Петровича", "Лебедева Павла Романовича"),
        ]
        for (source, expected) in examples {
            let name = try XCTUnwrap(AnonymizationNames.analyze(source), source)
            XCTAssertTrue(name.hasPatronymic)
            XCTAssertFalse(name.feminine)
            XCTAssertEqual(name.canonical, canonical)
            XCTAssertEqual(AnonymizationNames.decline(base: substitute, for: name), expected)
            XCTAssertEqual(AnonymizationNames.analyze(expected)?.canonical, substitute)
        }
    }

    func testFeminineNameAndPatronymicKeepCaseAndOrder() throws {
        let canonical = "Анна Ивановна Петрова"
        let substitute = "Вера Олеговна Соколова"
        let examples = [
            (canonical, substitute),
            ("Анны Ивановны Петровой", "Веры Олеговны Соколовой"),
            ("Анне Ивановне Петровой", "Вере Олеговне Соколовой"),
            ("Анну Ивановну Петрову", "Веру Олеговну Соколову"),
            ("Анной Ивановной Петровой", "Верой Олеговной Соколовой"),
            ("Петрова Анна Ивановна", "Соколова Вера Олеговна"),
            ("Петровой Анне Ивановне", "Соколовой Вере Олеговне"),
        ]
        for (source, expected) in examples {
            let name = try XCTUnwrap(AnonymizationNames.analyze(source), source)
            XCTAssertTrue(name.hasPatronymic)
            XCTAssertTrue(name.feminine)
            XCTAssertEqual(name.canonical, canonical)
            XCTAssertEqual(AnonymizationNames.decline(base: substitute, for: name), expected)
        }
    }

    func testLegacyAnalysisRetainsTwoPartLookup() throws {
        let name = try XCTUnwrap(AnonymizationNames.analyze("Анна Петрова", legacy: true))
        XCTAssertFalse(name.hasPatronymic)
        XCTAssertEqual(name.canonical, "Анна Петрова")
        XCTAssertNil(AnonymizationNames.analyze("Петрова Анна Ивановна", legacy: true))
        XCTAssertNil(AnonymizationNames.analyze("Северная Энергия Сервис"))
    }
}
