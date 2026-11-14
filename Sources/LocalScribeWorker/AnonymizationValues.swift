import Foundation
import LocalScribeCore

/// Deterministic SplitMix64 generator: identical inputs and history always
/// produce identical substitution draws, while different cards diverge through
/// the seed. Never use the system RNG here — reproducibility is contractual.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// The value shape a substitute must take: chosen from the confirmed source
/// value itself, never from the type wording, so arbitrary user wordings work
/// without configuration.
enum AnonymizationValueShape: Sendable, Equatable {
    case russianName(feminine: Bool)
    case englishName
    case phone
    case emailAddress
    case postalAddress(russian: Bool)
    /// A numeric calendar date with its component order and source separator.
    case date(order: DateOrder, separator: String)
    case generic

    enum DateOrder: Sendable, Equatable {
        case dayMonthYear
        case monthYear
        case yearMonthDay
    }

    /// Deterministic shape classification of one confirmed value.
    static func of(_ value: String) -> AnonymizationValueShape {
        if isEmailAddress(value) { return .emailAddress }
        if let date = dateComponents(value) { return date }
        if isPhoneNumber(value) { return .phone }
        if let analysis = AnonymizationNames.analyze(value) {
            return .russianName(feminine: analysis.feminine)
        }
        if isEnglishName(value) { return .englishName }
        if isPostalAddress(value) { return .postalAddress(russian: value.unicodeScalars.contains { (0x0410...0x044F).contains($0.value) }) }
        return .generic
    }

    /// Numeric date recognition before the phone classifier: an eight-digit
    /// dotted value like «12.11.2026» is a date, not a phone number. Month
    /// ranges bound the components, so IDs such as «1234.5678.90» stay out.
    private static func dateComponents(_ value: String) -> AnonymizationValueShape? {
        let scalars = Array(value.unicodeScalars)
        guard scalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57) || $0 == "." || $0 == "/" || $0 == "-" }) else { return nil }
        for separator in [".", "/", "-"] {
            let parts = value.components(separatedBy: separator).filter { !$0.isEmpty }
            guard parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { continue }
            if parts.count == 3, (1...2).contains(parts[0].count), parts[1].count == 2, parts[2].count == 4,
               let month = Int(parts[1]), (1...12).contains(month) {
                return .date(order: .dayMonthYear, separator: separator)
            }
            if parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
               let month = Int(parts[1]), (1...12).contains(month) {
                return .date(order: .yearMonthDay, separator: separator)
            }
            if parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 4,
               let month = Int(parts[0]), (1...12).contains(month) {
                return .date(order: .monthYear, separator: separator)
            }
        }
        return nil
    }

    private static func isEmailAddress(_ value: String) -> Bool {
        guard !value.unicodeScalars.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return false }
        guard let at = value.firstIndex(of: "@") else { return false }
        let local = value[value.startIndex..<at], domain = value[value.index(after: at)...]
        return !local.isEmpty && domain.contains(".") && !domain.hasSuffix(".") && !domain.hasPrefix(".")
    }

    private static func isPhoneNumber(_ value: String) -> Bool {
        let digits = value.unicodeScalars.filter { ($0.value >= 48 && $0.value <= 57) }
        let separators = value.unicodeScalars.filter { "+()-. \t\u{00A0}\u{2011}\u{2012}\u{2013}\u{2014}".unicodeScalars.contains($0) }
        let letters = value.unicodeScalars.count - digits.count - separators.count
        return letters == 0 && (7...15).contains(digits.count) && digits.count >= 7
    }

    private static func isEnglishName(_ value: String) -> Bool {
        let parts = value.split(separator: " ").map(String.init)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.first!.isUppercase
                && part.unicodeScalars.allSatisfy { ($0.properties.isAlphabetic && $0.value < 0x0250) || $0 == "-" || $0 == "'" }
        }
    }

    private static func isPostalAddress(_ value: String) -> Bool {
        guard value.contains(where: \.isNumber),
              value.unicodeScalars.contains(where: { $0.properties.isAlphabetic }),
              value.contains(" ") else { return false }
        return value.contains(",") || value.lowercased().contains("street") || value.lowercased().contains("ул")
    }
}

/// Injectable source of fictional substitute values. The default draws from
/// curated safe lists with the seeded generator and regenerates on collisions
/// with the source value or with occupied substitutes of the same type.
protocol AnonymizationValueSourcing: Sendable {
    /// One unused fictional value of the source's own shape: never equal to
    /// `source`, never present in `occupied`.
    func value(for source: String, shape: AnonymizationValueShape, occupied: Set<String>) -> String
}

final class SeededAnonymizationValueSource: AnonymizationValueSourcing, @unchecked Sendable {
    private var rng: SplitMix64
    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    func value(for source: String, shape: AnonymizationValueShape, occupied: Set<String>) -> String {
        for _ in 0..<64 {
            let candidate = AnonymizationValueFactory.draw(shape: shape, using: &rng)
            if candidate != source, !occupied.contains(candidate) { return candidate }
        }
        // A pathological number of collisions unblocks through a marker with
        // a fresh serial index; it stays safe and distinguishable.
        var index = UInt64(10_000)
        while true {
            index += 1
            let candidate = "X-\(index)"
            if candidate != source, !occupied.contains(candidate) { return candidate }
        }
    }
}

/// Curated fictional value lists. Russian name stems avoid velar/hushing
/// stems, -ия first names and adjectival surnames, so `AnonymizationNames`
/// ending tables are exact for every generated value.
enum AnonymizationValueFactory {
    static let maleFirstNames = ["Борис", "Виктор", "Роман", "Денис", "Павел", "Артём", "Максим",
                                 "Валентин", "Станислав", "Вадим", "Егор", "Тарас", "Мартин", "Рудольф", "Феликс"]
    static let femaleFirstNames = ["Вера", "Галина", "Нина", "Тамара", "Лариса", "Марина", "Полина",
                                   "Оксана", "Инна", "Алла", "Раиса", "Зинаида", "Дарья", "Алина", "Дина", "Влада"]
    static let surnameStems = ["Соколов", "Морозов", "Лебедев", "Волков", "Кузнецов", "Назаров", "Виноградов",
                               "Богданов", "Зайцев", "Комаров", "Мельников", "Фёдоров", "Трофимов", "Селиванов", "Воронцов"]
    static let englishFirstNames = ["Emily", "James", "Olivia", "Henry", "Grace", "Samuel", "Alice", "Peter",
                                    "Laura", "David", "Clara", "Owen", "Rosa", "Felix", "Marta", "Hugo"]
    static let englishLastNames = ["Turner", "Walker", "Bennett", "Carroll", "Dawson", "Emerson", "Fletcher",
                                   "Grant", "Harrison", "Jennings", "Lawson", "Mitchell", "Palmer", "Reynolds", "Sutton"]
    static let russianStreets = ["Лесная", "Сосновая", "Набережная", "Полевая", "Речная", "Дорожная", "Верхняя", "Садовая"]
    static let englishStreets = ["Maple", "Cedar", "Birch", "Willow", "Aspen", "Laurel", "Rowan", "Hazel"]
    static let asciiLocalParts = ["anna", "paul", "olga", "victor", "nina", "david", "laura", "sam",
                                  "vera", "max", "polina", "roman", "dina", "egor", "alina", "taras"]

    static func draw(shape: AnonymizationValueShape, using rng: inout SplitMix64) -> String {
        switch shape {
        case .russianName(let feminine):
            let first = feminine ? femaleFirstNames.randomElement(using: &rng)! : maleFirstNames.randomElement(using: &rng)!
            let last = surnameStems.randomElement(using: &rng)! + (feminine ? "а" : "")
            return first + " " + last
        case .englishName:
            return englishFirstNames.randomElement(using: &rng)! + " " + englishLastNames.randomElement(using: &rng)!
        case .phone:
            return "+7 9" + digits(2, using: &rng) + " " + digits(3, using: &rng) + "-" + digits(2, using: &rng) + "-" + digits(2, using: &rng)
        case .emailAddress:
            let local = asciiLocalParts.randomElement(using: &rng)! + "." + asciiLocalParts.randomElement(using: &rng)!
            return local + String(Int.random(in: 10...999, using: &rng)) + "@example.org"
        case .postalAddress(let russian):
            if russian {
                return "ул. " + russianStreets.randomElement(using: &rng)! + ", д. " + String(Int.random(in: 1...199, using: &rng))
            }
            return String(Int.random(in: 1...999, using: &rng)) + " " + englishStreets.randomElement(using: &rng)! + " Street"
        case .date(let order, let separator):
            // Days stay within 28 so every drawn month keeps the date valid.
            let day = String(Int.random(in: 1...28, using: &rng))
            let month = String(Int.random(in: 1...12, using: &rng))
            let year = String(Int.random(in: 1990...2035, using: &rng))
            switch order {
            case .dayMonthYear: return day + separator + month + separator + year
            case .monthYear: return month + separator + year
            case .yearMonthDay: return year + separator + month + separator + day
            }
        case .generic:
            return "X-" + String(Int.random(in: 1000...9999, using: &rng))
        }
    }

    private static func digits(_ count: Int, using rng: inout SplitMix64) -> String {
        String((0..<count).map { _ in Character(Unicode.Scalar(UInt8.random(in: 48...57, using: &rng))) })
    }
}
