import Foundation
import os

public enum ApplicationLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case russian = "ru"

    public static let defaultsKey = "applicationLanguage"

    public static func selection(in defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    public func resolved(preferredLanguages: [String]) -> Self {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
            if let code, let language = Self(rawValue: code), language != .system { return language }
        }
        return .russian
    }

    public var title: String {
        switch self {
        case .system: return L10n.text("Язык системы")
        case .english: return "English"
        case .russian: return "Русский"
        }
    }
}

public enum L10n {
    private static let current = OSAllocatedUnfairLock(initialState: ApplicationLanguage.russian)

    /// Set by the GUI before building views. Helpers keep producing the same
    /// messages regardless of the user's interface language.
    public static func configure(_ language: ApplicationLanguage) {
        let resolved = language.resolved(preferredLanguages: Locale.preferredLanguages)
        current.withLock { $0 = resolved }
    }

    public static var locale: Locale {
        Locale(identifier: current.withLock { $0.rawValue })
    }

    public static func text(_ key: String, _ arguments: String...) -> String {
        let template = current.withLock { $0 } == .english ? englishInterface[key] ?? key : key
        return format(template, arguments: arguments)
    }

    /// Warnings and errors in existing manifests and events are plain strings.
    /// Translate known application messages when presenting them.
    public static func message(_ stored: String) -> String {
        guard current.withLock({ $0 }) == .english else { return stored }
        return englishMessages.translate(stored)
    }

    static let englishInterface = loadCatalog("Interface.en")
    static let englishMessages = MessageCatalog(loadCatalog("Messages.en"))

    private static func loadCatalog(_ name: String) -> [String: String] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return catalog
    }

    private static let placeholder = try! NSRegularExpression(pattern: #"%([1-9][0-9]?)\$@"#)

    static func placeholders(in template: String) -> [NSTextCheckingResult] {
        placeholder.matches(in: template, range: NSRange(template.startIndex..., in: template))
    }

    static func argumentIndex(_ match: NSTextCheckingResult, in template: NSString) -> Int {
        Int(template.substring(with: match.range(at: 1)))! - 1
    }

    static func format(_ template: String, arguments: [String]) -> String {
        guard !arguments.isEmpty else { return template }
        let source = template as NSString
        let result = NSMutableString(string: template)
        for match in placeholders(in: template).reversed() {
            let index = argumentIndex(match, in: source)
            if arguments.indices.contains(index) {
                result.replaceCharacters(in: match.range, with: arguments[index])
            }
        }
        return result as String
    }
}

struct MessageCatalog: Sendable {
    private struct Template: Sendable {
        let key: String
        let pattern: NSRegularExpression
        let arguments: [Int]
        let translation: String
    }

    private let exact: [String: String]
    private let templates: [Template]

    init(_ translations: [String: String]) {
        var exact: [String: String] = [:]
        var templates: [Template] = []
        for (key, translation) in translations.sorted(by: { lhs, rhs in
            lhs.key.count == rhs.key.count ? lhs.key < rhs.key : lhs.key.count > rhs.key.count
        }) {
            let placeholders = L10n.placeholders(in: key)
            guard !placeholders.isEmpty else { exact[key] = translation; continue }
            let source = key as NSString
            var expression = "\\A"
            var start = 0
            for match in placeholders {
                expression += NSRegularExpression.escapedPattern(for: source.substring(with: NSRange(location: start, length: match.range.location - start)))
                expression += "(.*?)"
                start = NSMaxRange(match.range)
            }
            expression += NSRegularExpression.escapedPattern(for: source.substring(from: start)) + "\\z"
            if let pattern = try? NSRegularExpression(pattern: expression, options: .dotMatchesLineSeparators) {
                templates.append(Template(key: key, pattern: pattern,
                                          arguments: placeholders.map { L10n.argumentIndex($0, in: source) },
                                          translation: translation))
            }
        }
        self.exact = exact
        self.templates = templates
    }

    func translate(_ message: String) -> String {
        translate(message, remainingDepth: 2)
    }

    private func translate(_ message: String, remainingDepth: Int) -> String {
        if let translation = exact[message] { return translation }
        let range = NSRange(message.startIndex..., in: message)
        for template in templates {
            guard let match = template.pattern.firstMatch(in: message, range: range),
                  let lastIndex = template.arguments.max() else { continue }
            var arguments = Array(repeating: "", count: lastIndex + 1)
            for (offset, index) in template.arguments.enumerated() {
                arguments[index] = (message as NSString).substring(with: match.range(at: offset + 1))
            }
            if remainingDepth > 0 {
                translateEmbeddedArguments(in: template.key, arguments: &arguments, remainingDepth: remainingDepth - 1)
            }
            return L10n.format(template.translation, arguments: arguments)
        }
        return message
    }

    private func translateEmbeddedArguments(in key: String, arguments: inout [String], remainingDepth: Int) {
        // These arguments contain other application messages. Keep values such
        // as filenames and IDs in all other templates verbatim.
        func embedded(_ text: String) -> String { translate(text, remainingDepth: remainingDepth) }
        switch key {
        case "Не удалось продолжить: %1$@. Задание и контрольные точки сохранены. Для создания нового задания с выбранными моделями нажмите «Обработать заново».",
             "Не удалось продолжить: %1$@. Задание сохранено; для нового задания с выбранными моделями нажмите «Распознать заново».",
             "Некорректное выравнивание Qwen: %1$@. Текст части не опубликован; вымышленные таймкоды не создаются.":
            let cause = embedded(arguments[0])
            arguments[0] = cause.hasSuffix(".") ? String(cause.dropLast()) : cause
        case "Не удалось прочитать группы: %1$@", "Проверяем основания: %1$@ %2$@ из %3$@":
            arguments[0] = embedded(arguments[0])
        case "Составляем итоги — часть %1$@ из %2$@: %3$@":
            arguments[2] = embedded(arguments[2])
        case "Модель %1$@: отсутствует или повреждён %2$@":
            arguments[0] = L10n.englishInterface[arguments[0]] ?? arguments[0]
        case "%1$@ недоступна на этом Mac: %2$@.":
            arguments[0] = L10n.englishInterface[arguments[0]] ?? arguments[0]
            let reasons = arguments[1]
            // The working-memory reason itself contains a semicolon.
            if let separator = reasons.range(of: #"; (?=нужно |Некорректный рабочий объём)"#, options: .regularExpression) {
                arguments[1] = embedded(String(reasons[..<separator.lowerBound])) + "; "
                    + embedded(String(reasons[separator.upperBound...]))
            } else {
                arguments[1] = embedded(reasons)
            }
        default:
            break
        }
    }
}
