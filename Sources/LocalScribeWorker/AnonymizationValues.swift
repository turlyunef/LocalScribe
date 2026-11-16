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

/// Use the configured type when recognizable, and the confirmed fragment's
/// written form for custom types.
enum AnonymizationValueShape: Sendable, Equatable {
    case russianName(feminine: Bool)
    case russianFullName(feminine: Bool)
    case personalName(russian: Bool, feminine: Bool)
    case englishName
    case company(AnonymizationCompany)
    case phone
    case emailAddress
    case postalAddress(russian: Bool)
    /// A numeric calendar date with its component order and source separator.
    case date(order: DateOrder, separator: String)
    case writtenDate(month: String, forms: [String])
    case identifier
    case generic

    enum DateOrder: Sendable, Equatable {
        case dayMonthYear
        case monthDayYear
        case monthYear
        case yearMonthDay
    }

    enum DataKind: Sendable {
        case person, company, phone, email, address, date, identifier, custom

        init(wording: String) {
            let words = Set(wording.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            func starts(with prefixes: [String]) -> Bool {
                words.contains { word in prefixes.contains(where: word.hasPrefix) }
            }
            if starts(with: ["телефон", "phone", "telephone"]) { self = .phone }
            else if starts(with: ["email"]) || words.isSuperset(of: ["e", "mail"])
                || (starts(with: ["почт"]) && starts(with: ["электронн"])) { self = .email }
            else if starts(with: ["адрес", "address"]) { self = .address }
            else if starts(with: ["дата", "даты", "дату", "date"]) { self = .date }
            else if starts(with: ["номер", "идентификатор", "number", "identifi"])
                || !words.isDisjoint(with: ["id", "инн", "снилс", "огрн", "кпп"]) { self = .identifier }
            else if starts(with: ["компани", "организаци", "работодател", "предприяти",
                                  "compan", "organiz", "organis", "employer", "corporat", "business", "firm"])
                || words.isSuperset(of: ["юридических", "лиц"]) { self = .company }
            else if starts(with: ["имена", "имени", "фамили", "отчеств", "name", "surname"])
                || !words.isDisjoint(with: ["фио", "имя", "person", "people"]) { self = .person }
            else { self = .custom }
        }
    }

    static func isCyrillic(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) }
    }

    static func of(_ value: String, kind: DataKind = .custom) -> AnonymizationValueShape {
        let russian = isCyrillic(value)
        switch kind {
        case .company: return .company(AnonymizationCompany(value))
        case .phone: return .phone
        case .email: return .emailAddress
        case .address: return .postalAddress(russian: russian)
        case .date: return dateComponents(value) ?? writtenDate(value) ?? .generic
        case .identifier: return .identifier
        case .person, .custom: break
        }
        let company = AnonymizationCompany(value)
        if kind == .custom, company.hasLegalForm { return .company(company) }
        if let analysis = AnonymizationNames.analyze(value) {
            return name(analysis)
        }
        if kind == .person {
            let feminine = value.split(whereSeparator: \.isWhitespace)
                .contains { AnonymizationNames.femaleFirstNames.contains(String($0).capitalized) }
                || value.lowercased().hasSuffix("ова") || value.lowercased().hasSuffix("ева")
                || value.lowercased().hasSuffix("ина")
            return .personalName(russian: russian, feminine: feminine)
        }
        if isEmailAddress(value) { return .emailAddress }
        if let date = dateComponents(value) { return date }
        if isPhoneNumber(value) { return .phone }
        if isEnglishName(value) { return .englishName }
        if isPostalAddress(value) { return .postalAddress(russian: russian) }
        if value.contains(where: \.isNumber), !value.contains(where: \.isWhitespace) { return .identifier }
        return .generic
    }

    static func name(_ analysis: AnonymizationNames.Analysis) -> AnonymizationValueShape {
        analysis.hasPatronymic ? .russianFullName(feminine: analysis.feminine)
            : .russianName(feminine: analysis.feminine)
    }

    /// Numeric date recognition before the phone classifier: an eight-digit
    /// dotted value like «12.11.2026» is a date, not a phone number. Month
    /// ranges bound the components, so IDs such as «1234.5678.90» stay out.
    private static func dateComponents(_ value: String) -> AnonymizationValueShape? {
        let scalars = Array(value.unicodeScalars)
        guard scalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57) || $0 == "." || $0 == "/" || $0 == "-" }) else { return nil }
        for separator in [".", "/", "-"] {
            let parts = value.components(separatedBy: separator)
            guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { continue }
            if parts.count == 3, parts[0].count <= 2, parts[1].count <= 2, parts[2].count == 4,
               let first = Int(parts[0]), let second = Int(parts[1]) {
                if (1...31).contains(first), (1...12).contains(second) {
                    return .date(order: .dayMonthYear, separator: separator)
                }
                if separator == "/", (1...12).contains(first), (1...31).contains(second) {
                    return .date(order: .monthDayYear, separator: separator)
                }
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

    private static let monthForms = [
        "январь февраль март апрель май июнь июль август сентябрь октябрь ноябрь декабрь",
        "января февраля марта апреля мая июня июля августа сентября октября ноября декабря",
        "January February March April May June July August September October November December",
        "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec",
    ].map { $0.split(separator: " ").map(String.init) }

    private static func writtenDate(_ value: String) -> AnonymizationValueShape? {
        for word in value.split(whereSeparator: { !$0.isLetter }) {
            if let forms = monthForms.first(where: { forms in
                forms.contains { $0.caseInsensitiveCompare(String(word)) == .orderedSame }
            }) {
                return .writtenDate(month: String(word), forms: forms)
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
        return letters == 0 && (7...15).contains(digits.count)
            && (value.hasPrefix("+") || value.contains("("))
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
    func value(for source: String, shape: AnonymizationValueShape, occupied: Set<String>) throws -> String
}

final class SeededAnonymizationValueSource: AnonymizationValueSourcing, @unchecked Sendable {
    private var rng: SplitMix64
    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    func value(for source: String, shape: AnonymizationValueShape, occupied: Set<String>) throws -> String {
        for _ in 0..<256 {
            let candidate = AnonymizationValueFactory.draw(for: source, shape: shape, using: &rng)
            if candidate != source, !occupied.contains(candidate), !Self.isLegacyMarker(candidate) { return candidate }
        }
        throw ScribeError.message("Не удалось подобрать уникальную подстановку")
    }

    static func isLegacyMarker(_ value: String) -> Bool {
        let digits = value.utf8.dropFirst(2)
        return value.hasPrefix("X-") && digits.count >= 4
            && digits.first != 48 && digits.allSatisfy { (48...57).contains($0) }
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
                               "Богданов", "Зайцев", "Комаров", "Мельников", "Фёдоров", "Трофимов", "Селиванов",
                               "Воронцов", "Рубинов", "Луговин", "Миронов", "Осипов", "Платонов", "Нестеров",
                               "Терентьев", "Лаврентьев", "Уваров", "Рябов", "Мартынов", "Васнецов", "Лукин"]
    private static let patronymicStems = ["Андреев", "Борисов", "Викторов", "Денисов", "Иванов", "Максимов",
                                          "Олегов", "Петров", "Романов", "Сергеев", "Юрьев", "Ярославов"]
    static let englishFirstNames = ["Emily", "James", "Olivia", "Henry", "Grace", "Samuel", "Alice", "Peter",
                                    "Laura", "David", "Clara", "Owen", "Rosa", "Felix", "Marta", "Hugo"]
    static let englishLastNames = ["Turner", "Walker", "Bennett", "Carroll", "Dawson", "Emerson", "Fletcher",
                                   "Grant", "Harrison", "Jennings", "Lawson", "Mitchell", "Palmer", "Reynolds", "Sutton"]
    static let russianStreets = ["Лесная", "Сосновая", "Набережная", "Полевая", "Речная", "Дорожная", "Верхняя", "Садовая"]
    static let englishStreets = ["Maple", "Cedar", "Birch", "Willow", "Aspen", "Laurel", "Rowan", "Hazel"]
    static let asciiLocalParts = ["anna", "paul", "olga", "victor", "nina", "david", "laura", "sam",
                                  "vera", "max", "polina", "roman", "dina", "egor", "alina", "taras"]

    static func draw(for source: String, shape: AnonymizationValueShape, using rng: inout SplitMix64) -> String {
        switch shape {
        case .russianName(let feminine):
            return russianFirstName(feminine, using: &rng) + " " + russianSurname(feminine, using: &rng)
        case .russianFullName(let feminine):
            let first = russianFirstName(feminine, using: &rng)
            let patronymic = patronymicStems.randomElement(using: &rng)! + (feminine ? "на" : "ич")
            return first + " " + patronymic + " " + russianSurname(feminine, using: &rng)
        case .personalName(let russian, let feminine):
            return personalName(like: source, russian: russian, feminine: feminine, using: &rng)
        case .englishName:
            return englishFirstNames.randomElement(using: &rng)! + " " + englishLastNames.randomElement(using: &rng)!
        case .company(let company):
            return company.draw(using: &rng)
        case .phone:
            // E.164 reserves code 0. Keep a phone-shaped number and avoid
            // drawing from a subscriber numbering range.
            return "+0 " + digits(3, using: &rng) + " " + digits(3, using: &rng) + "-" + digits(2, using: &rng) + "-" + digits(2, using: &rng)
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
            let components: [String]
            switch order {
            case .dayMonthYear: components = [day, month, year]
            case .monthDayYear: components = [month, day, year]
            case .monthYear: components = [month, year]
            case .yearMonthDay: components = [year, month, day]
            }
            return zip(components, source.components(separatedBy: separator)).map { value, original in
                padded(value, to: original.count)
            }.joined(separator: separator)
        case .writtenDate(let month, let forms):
            return writtenDate(like: source, month: month, forms: forms, using: &rng)
        case .identifier:
            return matchingFormat(of: source, asIdentifier: true, using: &rng)
        case .generic:
            return matchingFormat(of: source, asIdentifier: false, using: &rng)
        }
    }

    private static func russianFirstName(_ feminine: Bool, using rng: inout SplitMix64) -> String {
        (feminine ? femaleFirstNames : maleFirstNames).randomElement(using: &rng)!
    }

    private static func russianSurname(_ feminine: Bool, using rng: inout SplitMix64) -> String {
        surnameStems.randomElement(using: &rng)! + (feminine ? "а" : "")
    }

    private static func writtenDate(like source: String, month: String, forms: [String],
                                    using rng: inout SplitMix64) -> String {
        let drawnMonth = forms.randomElement(using: &rng)!
        let monthWord = source.split(whereSeparator: { !$0.isLetter }).first { $0 == month }
        let monthRange = monthWord.map { $0.startIndex..<$0.endIndex }
        let edits = source.ranges(of: #/[0-9]+/#) + (monthRange.map { [$0] } ?? [])
        var result = ""
        var cursor = source.startIndex
        for range in edits.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            result += source[cursor..<range.lowerBound]
            if range == monthRange {
                if month == month.lowercased() { result += drawnMonth.lowercased() }
                else if month == month.uppercased() { result += drawnMonth.uppercased() }
                else { result += drawnMonth.capitalized }
            } else {
                let width = source[range].count
                let number = width <= 2 ? Int.random(in: 1...28, using: &rng)
                    : Int.random(in: 1990...2035, using: &rng)
                result += padded(String(number), to: width)
            }
            cursor = range.upperBound
        }
        return result + source[cursor...]
    }

    private static func padded(_ value: String, to width: Int) -> String {
        String(repeating: "0", count: max(0, width - value.count)) + value
    }

    private static func personalName(like source: String, russian: Bool, feminine: Bool,
                                     using rng: inout SplitMix64) -> String {
        let parts = source.split(whereSeparator: \.isWhitespace)
        func initials(in part: Substring) -> Int {
            let letters = part.split(separator: ".", omittingEmptySubsequences: false)
            guard letters.count > 1, letters.last?.isEmpty == true,
                  letters.dropLast().allSatisfy({ $0.count == 1 && $0.first?.isLetter == true }) else { return 0 }
            return letters.count - 1
        }
        let surnameFirst = parts.count > 1 && parts.dropFirst().allSatisfy { initials(in: $0) > 0 }
        let surnameIndex = surnameFirst ? 0 : parts.count - 1
        return parts.enumerated().map { index, part -> String in
            let initialCount = initials(in: part)
            if initialCount > 0 {
                return (0..<initialCount).map { _ in
                    let first = russian ? russianFirstName(feminine, using: &rng)
                        : englishFirstNames.randomElement(using: &rng)!
                    return String(first.prefix(1)) + "."
                }.joined()
            }
            let surnameEnding = ["ов", "ев", "ин", "ын", "ова", "ева", "ина", "ына", "ский", "ская"]
                .contains(where: part.lowercased().hasSuffix)
            let surname = index == surnameIndex && (parts.count > 1 || (russian && surnameEnding))
            let value: String
            if russian {
                value = surname ? russianSurname(feminine, using: &rng) : russianFirstName(feminine, using: &rng)
            } else {
                value = (surname ? englishLastNames : englishFirstNames).randomElement(using: &rng)!
            }
            return value
        }.joined(separator: " ")
    }

    private static let latinLetters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let cyrillicLetters = Array("АБВГДЕЖЗИКЛМНОПРСТУФХЦЧШЭЮЯ")
    private static let latinWordStarts = ["Aven", "Brel", "Cav", "Dalen", "Eld", "Fenn", "Lor", "Mor", "Ner", "Tav", "Vel"]
    private static let latinWordEnds = ["ara", "aris", "elia", "eron", "essa", "ira", "oran", "orin", "una", "yra"]
    private static let cyrillicWordStarts = ["Авел", "Бер", "Вел", "Гор", "Далин", "Зор", "Лир", "Мел", "Нер", "Рав", "Тар"]
    private static let cyrillicWordEnds = ["ана", "ария", "елла", "ерон", "есса", "ина", "иса", "ора", "орис", "уна"]

    private static func matchingFormat(of source: String, asIdentifier: Bool, using rng: inout SplitMix64) -> String {
        var output = ""
        var letters = ""
        var changed = false
        func flushLetters() {
            guard !letters.isEmpty else { return }
            let russian = AnonymizationValueShape.isCyrillic(letters)
            if asIdentifier {
                let alphabet = russian ? cyrillicLetters : latinLetters
                for letter in letters {
                    let drawn = alphabet.randomElement(using: &rng)!
                    output += letter.isLowercase ? drawn.lowercased() : String(drawn)
                }
            } else {
                let starts = russian ? cyrillicWordStarts : latinWordStarts
                let ends = russian ? cyrillicWordEnds : latinWordEnds
                let drawn = starts.randomElement(using: &rng)! + ends.randomElement(using: &rng)!
                if letters == letters.lowercased() { output += drawn.lowercased() }
                else if letters.count > 1, letters == letters.uppercased() { output += drawn.uppercased() }
                else { output += drawn }
            }
            letters = ""
            changed = true
        }
        for character in source {
            if character.isLetter {
                letters.append(character)
                continue
            }
            flushLetters()
            if character.isNumber {
                output += digits(1, using: &rng)
                changed = true
            } else if character.isWhitespace || character.isPunctuation || "-+№=@".contains(character) {
                output.append(character)
            } else {
                output += digits(1, using: &rng)
                changed = true
            }
        }
        flushLetters()
        return changed ? output : latinWordStarts.randomElement(using: &rng)! + latinWordEnds.randomElement(using: &rng)!
    }

    private static func digits(_ count: Int, using rng: inout SplitMix64) -> String {
        String((0..<count).map { _ in Character(Unicode.Scalar(UInt8.random(in: 48...57, using: &rng))) })
    }
}
