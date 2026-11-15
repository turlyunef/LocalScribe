import XCTest
@testable import LocalScribeCore

/// Pure decoding rules of a text-import candidate (AC-49 and the distinct
/// invalid-encoding rejection of AC-9): strict BOM accounting, the supported
/// encodings, ambiguity without a BOM and the no-confirmation cases.
final class TextImportTests: XCTestCase {
    private func decode(_ bytes: Data) -> TextImportDecoding { TextImportDecoder.decode(bytes) }

    // MARK: - UTF-8 (criterion 49)

    func testUTF8WithoutBOMResolvesWithoutConfirmation() {
        XCTAssertEqual(decode(Data("Plain ASCII report".utf8)),
                       .resolved(TextDecodingOption(encoding: .utf8, text: "Plain ASCII report")))
        // The emoji encoding contains the undefined Windows-1251 position
        // 0x98, so only UTF-8 accepts these bytes.
        let emoji = Data("Заметка 😀 встреча".utf8)
        XCTAssertNil(String(data: emoji, encoding: .windowsCP1251))
        XCTAssertEqual(decode(emoji),
                       .resolved(TextDecodingOption(encoding: .utf8, text: "Заметка 😀 встреча")),
                       "valid UTF-8 that Windows-1251 cannot represent resolves directly")
    }

    func testUTF8BOMIsRecognizedAndKeptOutOfText() {
        let payload = Data("Текст с BOM".utf8)
        let bytes = Data(TextImportDecoder.utf8BOM) + payload
        XCTAssertEqual(decode(bytes), .resolved(TextDecodingOption(encoding: .utf8BOM, text: "Текст с BOM")))
    }

    func testBrokenPayloadAfterBOMIsUndecodable() {
        let broken = Data([0xD0, 0x41, 0x41]) // lead byte without continuation
        XCTAssertEqual(decode(Data(TextImportDecoder.utf8BOM) + broken), .undecodable)
        XCTAssertEqual(decode(Data(TextImportDecoder.utf16LEBOM) + Data([0x41])), .undecodable,
                       "odd UTF-16 payload is not a supported encoding")
        XCTAssertEqual(decode(Data(TextImportDecoder.utf16LEBOM) + Data([0x00, 0xD8, 0x41, 0x00])), .undecodable,
                       "unpaired surrogate makes the strict decoding fail")
    }

    // MARK: - UTF-16 with BOM (criterion 49)

    func testUTF16LEAndBEBOMResolveToSameText() {
        let text = "Протокол встречи"
        let units = Array(text.utf16)
        let littleEndian = Data(TextImportDecoder.utf16LEBOM)
            + units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let bigEndian = Data(TextImportDecoder.utf16BEBOM)
            + units.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        XCTAssertEqual(decode(littleEndian), .resolved(TextDecodingOption(encoding: .utf16LEBOM, text: text)))
        XCTAssertEqual(decode(bigEndian), .resolved(TextDecodingOption(encoding: .utf16BEBOM, text: text)))
        // The same text in UTF-8 is a different byte sequence — and thus a
        // different import identity (AC-35).
        XCTAssertNotEqual(littleEndian, Data(text.utf8))
    }

    // MARK: - Windows-1251 (criterion 49)

    func testWindows1251OnlyBytesResolveWithoutConfirmation() throws {
        let bytes = try XCTUnwrap("Отчёт".data(using: .windowsCP1251))
        XCTAssertNil(String(data: bytes, encoding: .utf8), "fixture must not be valid UTF-8")
        XCTAssertEqual(decode(bytes), .resolved(TextDecodingOption(encoding: .windows1251, text: "Отчёт")))
    }

    func testUndefinedWindows1251PositionsMakeUndecodable() {
        // 0x98 is undefined in Windows-1251 and a stray continuation in UTF-8.
        XCTAssertEqual(decode(Data([0x98, 0x98])), .undecodable)
        XCTAssertEqual(decode(Data([0x41, 0x98])), .undecodable)
    }

    // MARK: - Ambiguity without BOM (criterion 49)

    func testAmbiguousRussianBytesOfferDistinctPreviews() {
        let bytes = Data("Проверка кодировки".utf8)
        let asCP1251 = String(data: bytes, encoding: .windowsCP1251)
        XCTAssertNotNil(asCP1251, "fixture must stay decodable in Windows-1251")
        if case .ambiguous(let options) = decode(bytes) {
            XCTAssertEqual(options.map(\.encoding), [.utf8, .windows1251])
            XCTAssertEqual(options.map(\.text), [String(data: bytes, encoding: .utf8), asCP1251])
            XCTAssertNotEqual(options[0].text, options[1].text)
        } else {
            XCTFail("Russian UTF-8 without BOM must stay ambiguous")
        }
    }

    func testIdenticalTextInEveryEncodingNeedsNoConfirmation() {
        let bytes = Data("Meeting notes 2026".utf8)
        XCTAssertEqual(decode(bytes), .resolved(TextDecodingOption(encoding: .utf8, text: "Meeting notes 2026")),
                       "pure ASCII decodes to one text in every supported encoding")
    }

    // MARK: - Empty and whitespace payloads

    func testEmptyAndBOMOnlyBytesDecodeToEmptyText() {
        XCTAssertEqual(decode(Data()), .resolved(TextDecodingOption(encoding: .utf8, text: "")))
        XCTAssertEqual(decode(Data(TextImportDecoder.utf8BOM)),
                       .resolved(TextDecodingOption(encoding: .utf8BOM, text: "")))
        XCTAssertEqual(decode(Data(TextImportDecoder.utf16BEBOM)),
                       .resolved(TextDecodingOption(encoding: .utf16BEBOM, text: "")))
    }

    func testWhitespaceOnlyTextIsDecodableButNotImportable() {
        let option = TextDecodingOption(encoding: .utf8, text: " \n\t  \r\n")
        XCTAssertEqual(decode(Data(" \n\t  \r\n".utf8)), .resolved(option))
        XCTAssertFalse(option.text.contains(where: { !$0.isWhitespace }),
                       "the import pipeline rejects this payload before a card exists")
    }

    // MARK: - Format by extension (criterion 9)

    func testImportFormatByExtension() {
        XCTAssertEqual(AnonymizationSourceFormat.importFormat(pathExtension: "txt"), .txt)
        XCTAssertEqual(AnonymizationSourceFormat.importFormat(pathExtension: "TXT"), .txt)
        XCTAssertEqual(AnonymizationSourceFormat.importFormat(pathExtension: "md"), .markdown)
        XCTAssertEqual(AnonymizationSourceFormat.importFormat(pathExtension: "markdown"), .markdown)
        XCTAssertNil(AnonymizationSourceFormat.importFormat(pathExtension: "rtf"))
        XCTAssertNil(AnonymizationSourceFormat.importFormat(pathExtension: "docx"))
        XCTAssertNil(AnonymizationSourceFormat.importFormat(pathExtension: ""))
    }

    // MARK: - Pre-commit card-size ceiling (review C7)

    /// `card.json` embeds the import bytes base64-encoded next to the decoded
    /// text and must stay within the JSON read limit: the ceiling is the
    /// limit divided by the base64 factor, and the projection adds the
    /// base64 term (4 characters per 3 bytes), the source text and a fixed
    /// allowance. An import above the ceiling can never be committed and is
    /// rejected before any disk write.
    func testCardSizeCeilingAndProjection() {
        XCTAssertEqual(AnonymizationInputLimit.maximumCardBytes, UInt(Disk.maximumJSONBytes / 4 * 3))
        // Base64 inflates 3 bytes to one 4-character block, padding included.
        XCTAssertEqual(AnonymizationInputLimit.projectedCardBytes(importBytes: 3, sourceUTF8Bytes: 0), 4 + 64 * 1024)
        XCTAssertEqual(AnonymizationInputLimit.projectedCardBytes(importBytes: 4, sourceUTF8Bytes: 10), 8 + 10 + 64 * 1024)
        // A UTF-8 file pays the base64 term and its own text size: 20 MiB
        // still fits, and one byte above the ceiling can never fit even
        // with no text at all.
        let fileBytes = 20 * 1024 * 1024
        let projected = AnonymizationInputLimit.projectedCardBytes(importBytes: fileBytes, sourceUTF8Bytes: fileBytes)
        XCTAssertLessThanOrEqual(projected, Int64(Disk.maximumJSONBytes))
        let over = Int(AnonymizationInputLimit.maximumCardBytes) + 1
        XCTAssertGreaterThan(AnonymizationInputLimit.projectedCardBytes(importBytes: over, sourceUTF8Bytes: 0),
                             Int64(Disk.maximumJSONBytes))
    }
}
