import Foundation

/// Fast paths for exact, standard settings labels. Custom wording can narrow
/// the meaning of a type, so it keeps its own model pass.
enum AnonymizationStructuredDetection {
    struct Scan {
        var candidates: [AnonymizationCandidate] = []
        var needsModel = false
    }

    static let names = "Имена и фамилии"
    static let emails = "Адреса электронной почты"
    static let phones = "Телефоны"
    static let addresses = "Почтовые адреса"

    private static let emailPattern = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}.!#$%&'*+/=?^_`{|}~@-])[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,63}(?![\p{L}\p{N}_@-]|\.[\p{L}\p{N}])"#)
    private static let phonePattern = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}_+.-])\+?(?:\([0-9]{2,4}\)[ \u00a0\u202f.-]*)?[0-9](?:[ \u00a0\u202f().\u2010-\u2014-]*[0-9]){6,}(?![\p{L}\p{N}_]|[.-][0-9])"#)
    private static let phoneLabel = try! NSRegularExpression(pattern:
        #"(?i)(?:\btel(?:ephone)?\b|\bphone\b|\bmobile\b|\bтел(?:ефон)?\b|\bмоб\b)[. :\t]*$"#)
    private static let nonPhoneLabel = try! NSRegularExpression(pattern:
        #"(?i)(?:\border\b|\binvoice\b|\bID\b|\bзаказ\p{L}*|\bзаявк\p{L}*|\bсч[её]т\p{L}*)[ :#№\t]*$"#)
    private static let extensionLabel = try! NSRegularExpression(pattern:
        #"(?i)^[ \t,;]*(?:ext\b|x[0-9]|доб\b)"#)

    static func scan(text: String, dataType: String) -> Scan? {
        let pattern: NSRegularExpression
        switch dataType {
        case emails: pattern = emailPattern
        case phones: pattern = phonePattern
        default: return nil
        }

        var result = Scan()
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else {
                result.needsModel = true
                continue
            }
            let value = String(text[range])
            if dataType == phones {
                if case .date = AnonymizationValueShape.of(value) { continue }
                let prefix = String(text[..<range.lowerBound].suffix(40))
                let suffix = String(text[range.upperBound...].prefix(30))
                if matches(nonPhoneLabel, in: prefix) { continue }
                let digitCount = value.utf8.filter { (48...57).contains($0) }.count
                let labeled = matches(phoneLabel, in: prefix)
                let international = value.hasPrefix("+") && value.utf8.dropFirst().first.map { (49...57).contains($0) } == true
                guard (7...15).contains(digitCount), labeled || (international && digitCount >= 10),
                      !matches(extensionLabel, in: suffix) else {
                    result.needsModel = true
                    continue
                }
            }
            let start = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.lowerBound)
            result.candidates.append(AnonymizationCandidate(dataType: dataType, start: UInt(start),
                end: UInt(start + value.unicodeScalars.count), fragment: value, doubtful: false))
        }
        if dataType == emails {
            result.needsModel = text.utf8.filter { $0 == 64 }.count > result.candidates.count
                || text.localizedCaseInsensitiveContains("%40")
        }
        return result
    }

    static func promptExample(for dataType: String) -> String {
        switch dataType {
        case names:
            return """
            Example for names:
            1 | Алексей Иванов написал отчёт, согласованный с Алексеем Ивановым.
            2 | Отчёт прочитала Анна Петрова.
            3 | Документ приложен.
            {"schemaVersion":1,"status":"ok","matches":[{"line":1,"fragment":"Алексей Иванов","doubtful":false},{"line":1,"fragment":"Алексеем Ивановым","doubtful":false},{"line":2,"fragment":"Анна Петрова","doubtful":false}]}
            """
        case phones:
            return "Example: include +7 900 555-01-02 after «телефон». Exclude dates and order numbers.\n"
        case emails:
            return "Example: include anna@example.org in mailto:anna@example.org. Exclude a username without a domain.\n"
        case addresses:
            return "Example: include the whole postal address, including street and house number. Exclude a city mentioned by itself.\n"
        default:
            return ""
        }
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
