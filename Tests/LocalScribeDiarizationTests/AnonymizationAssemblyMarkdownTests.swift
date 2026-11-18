import XCTest
@testable import LocalScribeCore
@testable import LocalScribeWorker

/// Scalar-subsequence search of `needle` in `text` (the same locating
/// technique the recognizer fake of AnonymizationEngineTests uses).
private func scalarRange(of needle: String, in text: String) -> Range<Int>? {
    let haystack = Array(text.unicodeScalars)
    let target = Array(needle.unicodeScalars)
    guard !target.isEmpty, haystack.count >= target.count else { return nil }
    var start = 0
    while start + target.count <= haystack.count {
        if (start..<(start + target.count)).allSatisfy({ haystack[$0] == target[$0 - start] }) {
            return start..<(start + target.count)
        }
        start += 1
    }
    return nil
}

/// Coverage of the Markdown structure scanner of AnonymizationAssembly:
/// fenced code blocks, inline code, reference definitions, autolinks,
/// escaped brackets and the conservative refusal on ambiguous brackets.
/// A missed construct silently corrupts user Markdown during
/// anonymization, so every branch of the scan is asserted directly and
/// through `assemble`.
final class AnonymizationAssemblyMarkdownTests: XCTestCase {
    private func markdownSpans(in text: String) -> [AnonymizationAssembly.MarkdownSpan] {
        AnonymizationAssembly.markdownSpans(in: Array(text.unicodeScalars), format: .markdown)
    }

    /// Assembles `source` with `(scalar range, substitute)` pairs.
    private func assemble(_ source: String, _ replacements: (Range<Int>, String)...,
                          format: AnonymizationSourceFormat = .markdown) throws -> AnonymizationAssemblyOutput {
        try AnonymizationAssembly.assemble(scalars: Array(source.unicodeScalars),
            replacements: replacements.map { AnonymizationAssemblyReplacement(range: $0.0, text: $0.1) },
            format: format)
    }

    private func expectUnrepresentable<T>(_ expression: @autoclosure () throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case AnonymizationAssemblyError.unrepresentable = error else {
                return XCTFail("Ожидалась unrepresentable, получена \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - markdownSpans: format gate

    func testMarkdownSpansReturnsNothingForPlainTextFormat() {
        let text = "Пишите [Иван](mailto:x@y.org) и <http://x.org>"
        XCTAssertTrue(AnonymizationAssembly.markdownSpans(in: Array(text.unicodeScalars), format: .txt).isEmpty,
                      "для формата TXT сканер Markdown не работает")
        XCTAssertTrue(markdownSpans(in: "").isEmpty)
    }

    // MARK: - markdownSpans: inline links and inline code

    func testMarkdownSpansRecordsInlineLinkTextAndDestination() throws {
        let text = "[Иван](mailto:x@y.org)"
        let spans = markdownSpans(in: text)
        XCTAssertEqual(spans, [
            .init(range: try XCTUnwrap(scalarRange(of: "Иван", in: text)), kind: .linkText),
            .init(range: try XCTUnwrap(scalarRange(of: "mailto:x@y.org", in: text)), kind: .destination),
        ], "текст ссылки и адрес (включая схему) фиксируются отдельными участками")
    }

    func testMarkdownSpansSkipsInlineCodeSpans() throws {
        let wrapped = "`[Внутри](a@b.org)` и [Снаружи](c@d.org)"
        let spans = markdownSpans(in: wrapped)
        XCTAssertEqual(spans, [
            .init(range: try XCTUnwrap(scalarRange(of: "Снаружи", in: wrapped)), kind: .linkText),
            .init(range: try XCTUnwrap(scalarRange(of: "c@d.org", in: wrapped)), kind: .destination),
        ], "конструкции внутри обратных кавычек не читаются")

        // Незакрытая обратная кавычка проглатывает остаток ввода.
        XCTAssertTrue(markdownSpans(in: "незакрытый ` код [Ссылка](a@b.org)").isEmpty)
    }

    // MARK: - markdownSpans: fenced code blocks

    func testMarkdownSpansFenceSkipsContentUntilCleanFenceLine() throws {
        // Открытие с информационной строкой; строка с посторонним текстом
        // после маркеров не закрывает блок; закрывает только «чистая» строка.
        let text = "```python\n[Внутри](a@b.org)\n``` хвост\n[Ещё внутри](c@d.org)\n```\n[Снаружи](e@f.org)\n"
        let spans = markdownSpans(in: text)
        XCTAssertEqual(spans, [
            .init(range: try XCTUnwrap(scalarRange(of: "Снаружи", in: text)), kind: .linkText),
            .init(range: try XCTUnwrap(scalarRange(of: "e@f.org", in: text)), kind: .destination),
        ], "всё до чистой закрывающей строки остаётся вне сканирования")
    }

    func testMarkdownSpansFenceWithThreeLeadingSpacesOpensAndCloses() throws {
        let text = "   ```\n[Внутри](a@b.org)\n   ```\n[Снаружи](e@f.org)\n"
        let spans = markdownSpans(in: text)
        XCTAssertEqual(spans.map(\.kind), [.linkText, .destination])
        XCTAssertEqual(spans.first?.range, scalarRange(of: "Снаружи", in: text))
        XCTAssertEqual(spans.last?.range, scalarRange(of: "e@f.org", in: text))
    }

    /// Four leading spaces exceed the fence budget, so the line does not open
    /// a fenced block. The stray backticks pair as inline code instead: the
    /// second stray backtick swallows the «Внутри» line, and the dirty «```x»
    /// line closes nothing — the link after it is still scanned. Had the
    /// indented line opened a fence, «```x» would not be a clean closing line
    /// and «Снаружи» would stay hidden.
    func testMarkdownSpansFourLeadingSpacesDoNotOpenFence() throws {
        let text = "    ```\n[Внутри](a@b.org)\n```x\n[Снаружи](e@f.org)\n"
        let spans = markdownSpans(in: text)
        XCTAssertEqual(spans, [
            .init(range: try XCTUnwrap(scalarRange(of: "Снаружи", in: text)), kind: .linkText),
            .init(range: try XCTUnwrap(scalarRange(of: "e@f.org", in: text)), kind: .destination),
        ], "отступ в четыре пробела не открывает блок кода")
    }

    func testMarkdownSpansTildeFenceSkipsContent() throws {
        let text = "~~~\n[Внутри](a@b.org)\n~~~\n[Снаружи](e@f.org)\n"
        let spans = markdownSpans(in: text)
        XCTAssertEqual(spans.map(\.kind), [.linkText, .destination])
        XCTAssertEqual(spans.first?.range, scalarRange(of: "Снаружи", in: text))
    }

    func testMarkdownSpansUnclosedFenceSkipsRestOfInput() {
        XCTAssertTrue(markdownSpans(in: "```\n[Внутри](a@b.org)\nбез закрытия").isEmpty,
                      "незакрытый блок кода прячет остаток текста")
    }

    // MARK: - markdownSpans: reference definitions

    func testMarkdownSpansReferenceDefinitionRecordsDestination() throws {
        let plain = "[Яков]: mailto:y@x.org\nдалее"
        XCTAssertEqual(markdownSpans(in: plain), [
            .init(range: try XCTUnwrap(scalarRange(of: "mailto:y@x.org", in: plain)), kind: .destination),
        ])

        // Табуляция после двоеточия и хвостовые пробелы не входят в адрес.
        let tabbed = "[Яков]:\tmailto:y@x.org   \nдалее"
        XCTAssertEqual(markdownSpans(in: tabbed), [
            .init(range: try XCTUnwrap(scalarRange(of: "mailto:y@x.org", in: tabbed)), kind: .destination),
        ])

        // Форма с угловыми скобками: адрес фиксируется без скобок.
        let bracketed = "[Яков]: <mailto:y@x.org>\nдалее"
        XCTAssertEqual(markdownSpans(in: bracketed), [
            .init(range: try XCTUnwrap(scalarRange(of: "mailto:y@x.org", in: bracketed)), kind: .destination),
        ])

        // Адрес определение поглощает остаток строки целиком.
        let rest = "[a]: http://x.org [b](c@d.org)\n"
        XCTAssertEqual(markdownSpans(in: rest), [
            .init(range: try XCTUnwrap(scalarRange(of: "http://x.org [b](c@d.org)", in: rest)), kind: .destination),
        ])
    }

    func testMarkdownSpansIgnoresMidLineAndEscapedReferenceDefinitions() {
        XCTAssertTrue(markdownSpans(in: "текст [Яков]: mailto:y@x.org").isEmpty,
                      "определение распознаётся только с начала строки")
        XCTAssertTrue(markdownSpans(in: "\\[Яков]: mailto:y@x.org").isEmpty,
                      "экранированная скобка не начинает определение")
        XCTAssertTrue(markdownSpans(in: "[Яков]:\n").isEmpty, "пустого адреса нет")
    }

    // MARK: - markdownSpans: escaped brackets and autolinks

    func testMarkdownSpansEscapedBracketIsNotALink() throws {
        XCTAssertTrue(markdownSpans(in: "\\[Иван](mailto:x@y.org)").isEmpty,
                      "экранированная скобка не начинает ссылку")

        // Двойной обратный слэш экранирует сам себя: скобка живая.
        let live = "\\\\[Иван](mailto:x@y.org)"
        XCTAssertEqual(markdownSpans(in: live), [
            .init(range: try XCTUnwrap(scalarRange(of: "Иван", in: live)), kind: .linkText),
            .init(range: try XCTUnwrap(scalarRange(of: "mailto:x@y.org", in: live)), kind: .destination),
        ])
    }

    func testMarkdownSpansAutolinkRequiresClosingBracketWithSchemeOrAddress() throws {
        let mailto = "<mailto:a@b.org>"
        XCTAssertEqual(markdownSpans(in: mailto), [
            .init(range: try XCTUnwrap(scalarRange(of: "mailto:a@b.org", in: mailto)), kind: .destination),
        ])
        let http = "<http://x.org>"
        XCTAssertEqual(markdownSpans(in: http), [
            .init(range: try XCTUnwrap(scalarRange(of: "http://x.org", in: http)), kind: .destination),
        ])

        XCTAssertTrue(markdownSpans(in: "<просто>").isEmpty, "без «:» или «@» это не автолинк")
        XCTAssertTrue(markdownSpans(in: "<a b@c.org>").isEmpty, "пробел внутри недопустим")
        XCTAssertTrue(markdownSpans(in: "\\<a@b.org>").isEmpty, "экранированная «<» не начинает автолинк")
        XCTAssertTrue(markdownSpans(in: "<a@b\n.org>").isEmpty, "перенос строки до «>» отменяет автолинк")
    }

    // MARK: - markdownSpans: conservative handling of ambiguous brackets

    func testMarkdownSpansConservativeOnNestedAndUnbalancedBrackets() throws {
        XCTAssertTrue(markdownSpans(in: "[Иван [Петров]](mailto:x@y.org)").isEmpty,
                      "вложенная скобка в тексте ссылки — консервативный отказ")

        // Незакрытая скобка адреса: фиксируется только текст ссылки.
        let unclosed = "[Иван](mailto:x@y.org"
        XCTAssertEqual(markdownSpans(in: unclosed), [
            .init(range: try XCTUnwrap(scalarRange(of: "Иван", in: unclosed)), kind: .linkText),
        ])
        let empty = "[Иван]()"
        XCTAssertEqual(markdownSpans(in: empty), [
            .init(range: try XCTUnwrap(scalarRange(of: "Иван", in: empty)), kind: .linkText),
        ])
        let multiline = "[Иван](mail\nto: x@y.org)"
        XCTAssertEqual(markdownSpans(in: multiline), [
            .init(range: try XCTUnwrap(scalarRange(of: "Иван", in: multiline)), kind: .linkText),
        ], "перенос строки внутри скобок адреса оставляет только текст ссылки")

        XCTAssertTrue(markdownSpans(in: "[Иван] текст").isEmpty, "без круглых скобок это не инлайн-ссылка")
    }

    // MARK: - assemble: context representations

    func testAssembleEscapesReplacementInsideLinkText() throws {
        let output = try assemble("[Иван](http://x.org)",
                                  (try XCTUnwrap(scalarRange(of: "Иван", in: "[Иван](http://x.org)")), "X [Y] Z"))
        XCTAssertEqual(output.text, "[X \\[Y\\] Z](http://x.org)",
                       "квадратные скобки подстановки экранируются в тексте ссылки")
        let generatedRange = try XCTUnwrap(scalarRange(of: "X \\[Y\\] Z", in: output.text))
        XCTAssertEqual(output.replacementRanges, [generatedRange])
        XCTAssertEqual(output.sourceToGenerated[0], 0)
        XCTAssertEqual(output.sourceToGenerated[1], generatedRange.lowerBound)
        XCTAssertEqual(output.sourceToGenerated[4], generatedRange.lowerBound)
        XCTAssertEqual(output.sourceToGenerated[5], generatedRange.upperBound)
    }

    /// A non-ASCII substitute inside a partially preserved destination is
    /// percent-encoded so the link keeps working.
    func testAssembleEncodesNonASCIIReplacementInsideDestination() throws {
        let source = "[Пётр](mailto:anna@example.org)"
        let output = try assemble(source, (try XCTUnwrap(scalarRange(of: "anna", in: source)), "Вера"))
        XCTAssertEqual(output.text, "[Пётр](mailto:%D0%92%D0%B5%D1%80%D0%B0@example.org)")
        XCTAssertFalse(output.text.contains("Вера"), "кириллица в адресе обязана быть закодирована")
    }

    func testAssembleEncodesAutolinkReplacement() throws {
        let source = "<mailto:ivan@example.org>"
        let output = try assemble(source, (try XCTUnwrap(scalarRange(of: "ivan@example.org", in: source)), "Вера Соколова"))
        XCTAssertEqual(output.text,
                       "<mailto:%D0%92%D0%B5%D1%80%D0%B0%20%D0%A1%D0%BE%D0%BA%D0%BE%D0%BB%D0%BE%D0%B2%D0%B0>")
    }

    func testAssembleEncodesReferenceDefinitionDestination() throws {
        let plain = "[контакт]: mailto:anna@example.org\nтекст"
        let plainOutput = try assemble(plain, (try XCTUnwrap(scalarRange(of: "anna@example.org", in: plain)), "Вера Соколова"))
        XCTAssertEqual(plainOutput.text,
                       "[контакт]: mailto:%D0%92%D0%B5%D1%80%D0%B0%20%D0%A1%D0%BE%D0%BA%D0%BE%D0%BB%D0%BE%D0%B2%D0%B0\nтекст")

        let bracketed = "[контакт]: <mailto:anna@example.org>\nтекст"
        let bracketedOutput = try assemble(bracketed, (try XCTUnwrap(scalarRange(of: "anna@example.org", in: bracketed)), "Вера Соколова"))
        XCTAssertEqual(bracketedOutput.text,
                       "[контакт]: <mailto:%D0%92%D0%B5%D1%80%D0%B0%20%D0%A1%D0%BE%D0%BA%D0%BE%D0%BB%D0%BE%D0%B2%D0%B0>\nтекст",
                       "угловые скобки вокруг адреса сохраняются")
    }

    // MARK: - assemble: unrepresentable refusals

    /// Even escaped brackets must stay balanced inside link text: the
    /// structural check counts raw brackets, so a one-sided bracket in the
    /// substitute fails the whole attempt instead of corrupting the link.
    func testAssembleRejectsUnbalancedBracketInLinkTextReplacement() throws {
        let source = "[Иван](http://x.org)"
        let range = try XCTUnwrap(scalarRange(of: "Иван", in: source))
        expectUnrepresentable(try assemble(source, (range, "[X")))
        expectUnrepresentable(try assemble(source, (range, "X]")))
    }

    /// The substitute is percent-encoded, but the original destination span
    /// may already carry a raw space or balanced parentheses: the surviving
    /// construct cannot stay valid, so the attempt fails safely.
    func testAssembleRejectsDestinationKeepingRawWhitespaceOrParens() throws {
        let spaced = "[Позвонить](tel: 79001234567)"
        expectUnrepresentable(try assemble(spaced, (try XCTUnwrap(scalarRange(of: "tel", in: spaced)), "phone")))
        let parenthesized = "[Позвонить](tel:(7900))"
        expectUnrepresentable(try assemble(parenthesized, (try XCTUnwrap(scalarRange(of: "tel", in: parenthesized)), "phone")))
    }

    // MARK: - assemble: swallowed constructs and verbatim contexts

    /// A replacement that covers a whole link construct simply removes it:
    /// no escaping or encoding is applied to the substitute.
    func testAssembleSwallowsWholeLinkConstructVerbatim() throws {
        let source = "Пишите [Иван Иванов](mailto:x@y.org) сюда."
        let output = try assemble(source, (try XCTUnwrap(scalarRange(of: "[Иван Иванов](mailto:x@y.org)", in: source)), "Вера Соколова"))
        XCTAssertEqual(output.text, "Пишите Вера Соколова сюда.")
    }

    /// For the plain-text format the Markdown scan does not run at all:
    /// substitutes land verbatim even inside link-like text.
    func testAssemblePlainFormatLeavesMarkdownConstructsVerbatim() throws {
        let source = "[Иван](mailto:x@y.org)"
        let output = try assemble(source, (try XCTUnwrap(scalarRange(of: "Иван", in: source)), "[X]"), format: .txt)
        XCTAssertEqual(output.text, "[[X]](mailto:x@y.org)")
    }

    /// Replacements inside a fenced code block are plain text: no encoding,
    /// spaces survive, the fences themselves stay untouched.
    func testAssembleLeavesFencedCodeReplacementsVerbatim() throws {
        let source = "```\n[Иван](mailto:x@y.org)\n```\n[Анна](mailto:a@b.org)\n"
        let output = try assemble(source,
                                  (try XCTUnwrap(scalarRange(of: "Иван", in: source)), "+7 900 111-22-33"),
                                  (try XCTUnwrap(scalarRange(of: "Анна", in: source)), "Вера"))
        XCTAssertEqual(output.text, "```\n[+7 900 111-22-33](mailto:x@y.org)\n```\n[Вера](mailto:a@b.org)\n")
    }

    // MARK: - assemble: scalar mapping across shifted spans

    /// Two replacements change lengths; the structural re-check of the
    /// second link's spans must map through the accumulated shift, and the
    /// mapping follows the documented rules (inside a replacement every
    /// scalar maps to its start).
    func testAssembleMapsBoundariesThroughReplacementShift() throws {
        let source = "[Пётр](tel:111) и [Анна](tel:222)"
        let scalars = Array(source.unicodeScalars)
        let phone = try XCTUnwrap(scalarRange(of: "111", in: source))
        let name = try XCTUnwrap(scalarRange(of: "Анна", in: source))
        let output = try assemble(source, (phone, "+79001112233"), (name, "X [Y]"))
        let expected = "[Пётр](tel:+79001112233) и [X \\[Y\\]](tel:222)"
        XCTAssertEqual(output.text, expected)

        let phoneRange = try XCTUnwrap(scalarRange(of: "+79001112233", in: expected))
        let nameRange = try XCTUnwrap(scalarRange(of: "X \\[Y\\]", in: expected))
        XCTAssertEqual(output.replacementRanges, [phoneRange, nameRange])

        XCTAssertEqual(output.sourceToGenerated.count, scalars.count)
        for index in 0..<phone.lowerBound {
            XCTAssertEqual(output.sourceToGenerated[index], index, "до первой замены смещения нет")
        }
        for index in phone {
            XCTAssertEqual(output.sourceToGenerated[index], phoneRange.lowerBound, "внутри замены — её начало")
        }
        XCTAssertEqual(output.sourceToGenerated[phone.upperBound], phoneRange.upperBound)
        for index in name {
            XCTAssertEqual(output.sourceToGenerated[index], nameRange.lowerBound)
        }
        XCTAssertEqual(output.sourceToGenerated[scalars.count - 1], expected.unicodeScalars.count - 1,
                       "последний скаляр отображается в конец сгенерированного текста")
    }

    // MARK: - Pure helpers

    func testPercentEncodeKeepsURIReservedAndEncodesBreakers() {
        XCTAssertEqual(AnonymizationAssembly.percentEncode("mailto:a+b.c@example.org"),
                       "mailto:a+b.c@example.org")
        XCTAssertEqual(AnonymizationAssembly.percentEncode("http://x.org/path?q=1&r=2#frag"),
                       "http://x.org/path?q=1&r=2#frag")
        XCTAssertEqual(AnonymizationAssembly.percentEncode("a~b_c-d"), "a~b_c-d")
        XCTAssertEqual(AnonymizationAssembly.percentEncode("[x]"), "[x]")
        XCTAssertEqual(AnonymizationAssembly.percentEncode("100%"), "100%", "готовый процент не кодируется повторно")
        XCTAssertEqual(AnonymizationAssembly.percentEncode("a(b)c"), "a%28b%29c", "круглые скобки кодируются")
        XCTAssertEqual(AnonymizationAssembly.percentEncode("a b"), "a%20b")
        XCTAssertEqual(AnonymizationAssembly.percentEncode("Вера"), "%D0%92%D0%B5%D1%80%D0%B0")
    }

    func testEscapeLinkTextEscapesBackslashAndBrackets() {
        XCTAssertEqual(AnonymizationAssembly.escapeLinkText("без изменений"), "без изменений")
        XCTAssertEqual(AnonymizationAssembly.escapeLinkText("a\\b"), "a\\\\b")
        XCTAssertEqual(AnonymizationAssembly.escapeLinkText("[x]"), "\\[x\\]")
        XCTAssertEqual(AnonymizationAssembly.escapeLinkText("["), "\\[")
        XCTAssertEqual(AnonymizationAssembly.escapeLinkText("]"), "\\]")
    }
}
