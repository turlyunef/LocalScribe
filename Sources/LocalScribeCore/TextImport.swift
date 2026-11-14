import Foundation

/// Encoding of one import candidate, the `ImportItem.encoding` value of the
/// domain design. BOM handling is strict: UTF-16 variants exist only with the
/// corresponding BOM, UTF-8 exists with and without it, and Windows-1251 is a
/// BOM-less single-byte encoding.
public enum TextImportEncoding: String, Codable, CaseIterable, Sendable {
    case utf8 = "UTF_8"
    case utf8BOM = "UTF_8_BOM"
    case utf16LEBOM = "UTF_16_LE_BOM"
    case utf16BEBOM = "UTF_16_BE_BOM"
    case windows1251 = "WINDOWS_1251"

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return L10n.text("UTF-8 (с BOM)")
        case .utf16LEBOM: return L10n.text("UTF-16 LE (с BOM)")
        case .utf16BEBOM: return L10n.text("UTF-16 BE (с BOM)")
        case .windows1251: return "Windows-1251"
        }
    }
}

/// One admissible decoding of the same original byte sequence.
public struct TextDecodingOption: Equatable, Sendable {
    public let encoding: TextImportEncoding
    public let text: String
    public init(encoding: TextImportEncoding, text: String) {
        self.encoding = encoding
        self.text = text
    }
}

/// Result of decoding import bytes. Duplicate identity stays byte-exact and
/// independent of the chosen encoding (AC-35, AC-49).
public enum TextImportDecoding: Equatable, Sendable {
    /// Exactly one admissible text: a BOM identified the encoding, only one
    /// supported encoding accepts the bytes, or every admissible decoding
    /// produced the same text — no confirmation required.
    case resolved(TextDecodingOption)
    /// Several admissible decodings with different texts: the user must pick
    /// one with a preview; only the confirmed decoding creates a card.
    case ambiguous([TextDecodingOption])
    /// No supported encoding decodes the bytes.
    case undecodable
}

/// Pure byte-to-text resolution of a text-import candidate. All decisions are
/// value-based so the Core decoding rules are testable without GUI.
public enum TextImportDecoder {
    public static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    public static let utf16LEBOM: [UInt8] = [0xFF, 0xFE]
    public static let utf16BEBOM: [UInt8] = [0xFE, 0xFF]

    public static func decode(_ bytes: Data) -> TextImportDecoding {
        if bytes.starts(with: utf8BOM) {
            return strict(Data(bytes.dropFirst(utf8BOM.count)), encoding: .utf8, tag: .utf8BOM)
        }
        if bytes.starts(with: utf16LEBOM) {
            return strict(Data(bytes.dropFirst(utf16LEBOM.count)), encoding: .utf16LittleEndian, tag: .utf16LEBOM)
        }
        if bytes.starts(with: utf16BEBOM) {
            return strict(Data(bytes.dropFirst(utf16BEBOM.count)), encoding: .utf16BigEndian, tag: .utf16BEBOM)
        }
        let utf8 = String(data: bytes, encoding: .utf8)
        let windows1251 = String(data: bytes, encoding: .windowsCP1251)
        switch (utf8, windows1251) {
        case let (text?, same?) where text == same:
            // Identical text for every admissible encoding (pure ASCII): one
            // acceptable variant, confirmation not required (AC-49).
            return .resolved(TextDecodingOption(encoding: .utf8, text: text))
        case (nil, let text?):
            return .resolved(TextDecodingOption(encoding: .windows1251, text: text))
        case (let text?, nil):
            return .resolved(TextDecodingOption(encoding: .utf8, text: text))
        case let (utf8?, windows1251?):
            return .ambiguous([
                TextDecodingOption(encoding: .utf8, text: utf8),
                TextDecodingOption(encoding: .windows1251, text: windows1251)
            ])
        case (nil, nil):
            return .undecodable
        }
    }

    private static func strict(_ payload: Data, encoding: String.Encoding, tag: TextImportEncoding) -> TextImportDecoding {
        // Foundation tolerates a dangling byte of UTF-16; a BOM-carrying file
        // with an odd payload is a damaged encoding, not an empty text.
        let isUTF16 = tag == .utf16LEBOM || tag == .utf16BEBOM
        if isUTF16, payload.count % 2 != 0 { return .undecodable }
        guard let text = String(data: payload, encoding: encoding) else { return .undecodable }
        return .resolved(TextDecodingOption(encoding: tag, text: text))
    }
}

public extension AnonymizationSourceFormat {
    /// TXT and Markdown are recognized by the file extension. Everything else
    /// is an unsupported-format rejection before any bytes are read (AC-9).
    static func importFormat(pathExtension: String) -> AnonymizationSourceFormat? {
        switch pathExtension.lowercased() {
        case "txt": return .txt
        case "md", "markdown": return .markdown
        default: return nil
        }
    }
}
