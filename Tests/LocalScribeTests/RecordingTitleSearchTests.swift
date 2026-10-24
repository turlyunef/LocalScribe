import XCTest
@testable import LocalScribeCore

final class RecordingTitleSearchTests: XCTestCase {
    private func matches(_ title: String, _ query: String) throws -> Bool {
        let index = try RecordingTitleSearch.Index(titles: [.init(id: "a", title: title)])
        return try index.matches(RecordingTitleSearch.tokens(query)).contains("a")
    }
    func testSpecificationExamples() throws {
        let cases: [(String, [String], [String])] = [
            ("Встреча с командой", ["в", "вс", "вст", "встр", "ВСТРЕЧА", "встеча", "встрчеа", "встрееча", "фстреча", "встеч"], ["вч", "dcnhtxf", "вхххххх"]),
            ("Планирование релиза", ["планирваине"], ["планхххххх"]),
            ("Обсуждение бюджета", ["бюдж обс", "обсуждние", "обс бюджет", "бюдж бюДЖ"], ["бюдж отпуск"]),
            ("Отчёт по проекту", ["отчет"], []),
            ("Проект Альфа", ["ект", "проект альф", "альфа проект"], ["проект бета", "кето"]),
            ("Проект‑Альфа", ["проект альфа"], []),
            ("Проект", ["проект про", "про ект"], []),
            ("Итоги Q4 2026", ["q4 2026", "202"], ["q3 2026", "2025"]),
            ("Любое название", ["", "  ", "---", "😀"], [])
        ]
        for (title, yes, no) in cases {
            for query in yes { XCTAssertTrue(try matches(title, query), "Expected match") }
            for query in no { XCTAssertFalse(try matches(title, query), "Unexpected match") }
        }
    }
    func testNormalizationAndGraphemes() throws {
        func texts(_ value: String) -> [String] { RecordingTitleSearch.tokens(value).map(\.text) }
        XCTAssertEqual(texts("  ВСТРЕЧА—по_проекту  "), ["встреча", "по", "проекту"])
        XCTAssertEqual(texts("Отчёт / Q4 2026"), ["отчет", "q4", "2026"])
        XCTAssertEqual(texts("😀Проект‑Альфа.\nбета/гамма"), ["проект", "альфа", "бета", "гамма"])
        XCTAssertTrue(try matches("ＣＡＦÉ", "cafe\u{301}"))
        XCTAssertTrue(try matches("ёлка", "е\u{308}лка"))
        XCTAssertFalse(try matches("й", "и"))
        XCTAssertFalse(try matches("café", "féx"))
    }
    func testBudgetsNumbersBoundariesAndAnchoredStart() throws {
        XCTAssertEqual(RecordingTitleSearch.tokens("abc abcd abcdefg abcdefgh sprint2026 2026").map(\.budget), [0, 1, 1, 2, 0, 0])
        XCTAssertFalse(try matches("abc", "axc"))
        XCTAssertTrue(try matches("abcd", "axcd"))
        XCTAssertFalse(try matches("abcdefg", "axcxefg"))
        XCTAssertTrue(try matches("abcdefgh", "axcxefgh"))
        XCTAssertFalse(try matches("abcdefgh", "axcxezgh"))
        XCTAssertFalse(try matches("sprint2026", "sprnit2026"))
        XCTAssertFalse(try matches("xxabcdef", "abxdef"))
        XCTAssertTrue(try matches("xxabcdef", "abcdef"))
        XCTAssertFalse(try matches("café", "afe"))
    }
    func testDuplicateTitlesPreserveAllIDsAndInputOrderWhenFiltered() throws {
        let sources: [RecordingTitleSearch.Title] = [.init(id: "z", title: "Отчёт"), .init(id: "a", title: "Other"), .init(id: "b", title: "Отчёт")]
        let ids = try RecordingTitleSearch.Index(titles: sources).matches(RecordingTitleSearch.tokens("отчет"))
        XCTAssertEqual(sources.filter { ids.contains($0.id) }.map(\.id), ["z", "b"])
    }
    // Independent full-matrix oracle, including whole-word OSA counterexamples.
    private func osa(_ a: [Character], _ b: [Character]) -> Int {
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        if !a.isEmpty && !b.isEmpty {
            for i in 1...a.count { for j in 1...b.count {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            } }
        }
        return d[a.count][b.count]
    }
    func testPreparedIndexAndPrefixCachesAgainstOracle() throws {
        var seed: UInt64 = 3177
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(bound))
        }
        let alphabet = Array("абвabc")
        let titles = (0..<250).map { number in
            RecordingTitleSearch.Title(id: String(number), title: String((0..<1 + random(14)).map { _ in alphabet[random(alphabet.count)] }))
        }
        let index = try RecordingTitleSearch.Index(titles: titles)
        for _ in 0..<150 {
            let query = RecordingTitleSearch.tokens(String((0..<1 + random(12)).map { _ in alphabet[random(alphabet.count)] }))
            let q = query[0], k = q.budget
            let expected = Set(titles.filter { title in
                let word = Array(title.title), lo = max(1, q.characters.count - k), hi = min(word.count, q.characters.count + k)
                if title.title.contains(q.text) { return true }
                return k > 0 && lo <= hi && (lo...hi).contains { osa(q.characters, Array(word.prefix($0))) <= k }
            }.map(\.id))
            XCTAssertEqual(try index.matches(query), expected)
        }
        let replacement = try RecordingTitleSearch.Index(titles: [.init(id: "0", title: "новое")], reusing: index)
        XCTAssertEqual(try replacement.matches(RecordingTitleSearch.tokens("новое")), ["0"])
        XCTAssertTrue(try replacement.matches(RecordingTitleSearch.tokens("alpha")).isEmpty)
    }
    func testBandedPrefixAgainstFullOSAOracle() throws {
        XCTAssertEqual(osa(Array("CA"), Array("AC")), 1)
        XCTAssertEqual(osa(Array("CA"), Array("ABC")), 3)
        var seed: UInt64 = 98231
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(bound))
        }
        let alphabet = Array("абйéabc")
        for _ in 0..<5000 {
            let a = (0..<1 + random(12)).map { _ in alphabet[random(alphabet.count)] }
            let b = (0..<1 + random(15)).map { _ in alphabet[random(alphabet.count)] }
            for k in 0...2 {
                let lo = max(1, a.count - k), hi = min(b.count, a.count + k)
                let expected = lo > hi ? k + 1 : min(k + 1, (lo...hi).map { osa(a, Array(b.prefix($0))) }.min()!)
                XCTAssertEqual(try RecordingTitleSearch.prefixDistance(a, b, budget: k), expected)
            }
        }
    }
}
