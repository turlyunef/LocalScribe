import Foundation

/// Keeps a company's legal form and typography while replacing its entire brand.
struct AnonymizationCompany: Sendable, Equatable {
    private static let prefixPattern = #"""
    (?x)^(?:
        (?:ООО|ПАО|ЗАО|ОАО|АО|НАО|НКО|АНО|ГУП|МУП|ФГУП|ИП)\.?
        | (?:публичное\h+)?акционерное\h+общество
        | общество\h+с\h+ограниченной\h+ответственностью
        | индивидуальный\h+предприниматель
    )(?:\h+|(?=[«„"“'‘]))
    """#
    private static let suffixPattern = #"""
    (?x)(?:\h*,\h*|\h+)(?:
        GmbH\h*&\h*Co\.?\h+KG | GmbH | Co\.?\h*,?\h+Ltd | Ltd | Limited
        | LLC | L\.L\.C | LLP | LP | PLC | P\.L\.C
        | Inc | Incorporated | Corp | Corporation | Company | Co | AG
        | S\.A | S\.A\.S | S\.R\.L | B\.V | N\.V
    )\.?$
    """#
    private static let quotePairs: [(Character, Character)] = [
        ("«", "»"), ("\"", "\""), ("“", "”"), ("„", "“"), ("„", "”"), ("‘", "’"), ("'", "'"),
    ]

    private let opening: String
    private let closing: String
    private let russian: Bool
    private let needsDescriptor: Bool
    let hasLegalForm: Bool

    init(_ source: String) {
        var brand = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var trailingPeriod = ""
        if brand.hasSuffix("."), Self.legalSuffix(in: brand) == nil {
            brand.removeLast()
            trailingPeriod = "."
        }
        let outerQuotes = Self.removeQuotes(from: &brand)

        var prefix = ""
        if let range = brand.range(of: Self.prefixPattern, options: [.regularExpression, .caseInsensitive]),
           brand[range.upperBound...].unicodeScalars.contains(where: { $0.properties.isAlphabetic }) {
            prefix = String(brand[range])
            brand.removeSubrange(range)
        }

        var suffix = ""
        if let range = Self.legalSuffix(in: brand),
           brand[..<range.lowerBound].unicodeScalars.contains(where: { $0.properties.isAlphabetic }) {
            suffix = String(brand[range])
            brand.removeSubrange(range)
        }

        let brandQuotes = Self.removeQuotes(from: &brand)
        opening = outerQuotes.opening + prefix + brandQuotes.opening
        closing = brandQuotes.closing + suffix + outerQuotes.closing + trailingPeriod
        hasLegalForm = !prefix.isEmpty || !suffix.isEmpty
        let letters = brand.unicodeScalars.filter { $0.properties.isAlphabetic }
        let cyrillicCount = letters.filter(Self.isCyrillic).count
        russian = cyrillicCount > 0 && cyrillicCount * 2 >= letters.count
        needsDescriptor = brand.split(whereSeparator: \.isWhitespace).count > 1
    }

    func draw(using rng: inout SplitMix64) -> String {
        let starts = russian ? Self.russianStarts : Self.englishStarts
        let endings = russian ? Self.russianEndings : Self.englishEndings
        var brand = starts.randomElement(using: &rng)! + endings.randomElement(using: &rng)!
        if needsDescriptor {
            let descriptors = russian ? Self.russianDescriptors : Self.englishDescriptors
            brand += " " + descriptors.randomElement(using: &rng)!
        }
        return opening + brand + closing
    }

    private static func legalSuffix(in text: String) -> Range<String.Index>? {
        text.range(of: suffixPattern, options: [.regularExpression, .caseInsensitive])
    }

    private static func removeQuotes(from text: inout String) -> (opening: String, closing: String) {
        guard text.count >= 2, let first = text.first, let last = text.last,
              quotePairs.contains(where: { $0 == (first, last) }) else { return ("", "") }
        text = text.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(first), String(last))
    }

    private static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x052F).contains(scalar.value)
    }

    private static let russianStarts = ["Альво", "Арело", "Арти", "Астри", "Бранто", "Вельто", "Вердо", "Виаро",
                                        "Грандо", "Дари", "Дельво", "Зефиро", "Ильво", "Кедро", "Керно", "Лиаро",
                                        "Лори", "Люмо", "Мериди", "Невиро", "Ониксо", "Ори", "Праймо", "Раверо",
                                        "Ренто", "Руно", "Севиро", "Тальви", "Терраво", "Ферро", "Эланто", "Янтаро"]
    private static let russianEndings = ["вав", "вель", "вера", "вион", "вольт", "гард", "гент", "дара", "декс",
                                          "дори", "дрон", "зум", "лайн", "лар", "лек", "лис", "мер", "мир", "мод",
                                          "некс", "нер", "нор", "план", "рид", "рис", "сент", "тар", "тев", "тор",
                                          "трон", "фер", "флекс"]
    private static let russianDescriptors = ["Системы", "Инжиниринг", "Студия", "Аналитика", "Технологии", "Бюро",
                                              "Связь", "Групп", "Медиа", "Логистика", "Проекты", "Решения"]
    private static let englishStarts = ["Alvo", "Arlo", "Aven", "Astri", "Branto", "Briar", "Cando", "Daro", "Delvi",
                                         "Elanto", "Elvero", "Faro", "Ferno", "Helio", "Ivero", "Junova", "Kerno", "Lior",
                                         "Lumo", "Mero", "Neviro", "Noro", "Orven", "Prymo", "Ravelo", "Rento", "Runa",
                                         "Selvo", "Solvi", "Talvi", "Velto", "Verdo"]
    private static let englishEndings = ["bent", "borne", "crest", "dale", "dell", "dexa", "dris", "field", "ford",
                                           "gard", "glen", "hart", "helm", "lark", "lent", "mere", "mont", "nex", "nix",
                                           "port", "ridge", "rook", "sora", "stead", "stone", "tava", "thera", "vale",
                                           "vent", "view", "wick", "wood"]
    private static let englishDescriptors = ["Systems", "Engineering", "Studio", "Analytics", "Technologies", "Labs",
                                               "Networks", "Group", "Media", "Logistics", "Dynamics", "Ventures"]
}
