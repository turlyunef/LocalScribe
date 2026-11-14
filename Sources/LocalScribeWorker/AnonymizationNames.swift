import Foundation

/// Grammatical case of a Russian «Имя Фамилия» fragment. Dative and
/// prepositional feminine forms share endings in real names; both map to the
/// same surface endings, so the analysis never needs to tell them apart.
enum RussianNameCase: String, CaseIterable, Sendable {
    case nominative, genitive, dative, accusative, instrumental, prepositional
}

/// Base coordination of Russian full names «Имя Фамилия»: one fragment is
/// analyzed into a canonical key form (unifying all case forms of one name),
/// its grammatical case and gender. Canonicalization strips each word's case
/// ending and appends the unified base ending («а» for feminine words, nothing
/// for masculine), so every case form of one name yields the same key —
/// including soft feminine surnames («Заречная»/«Заречной» → «Заречна»).
enum AnonymizationNames {
    /// Common real first-name nominatives, used only to disambiguate patterns
    /// that endings alone cannot resolve: «Ивана Соколова» (masculine genitive)
    /// vs «Анна Петрова» (feminine nominative), and the shared «у»/«у» shape.
    static let maleFirstNames: Set<String> = [
        "Александр", "Алексей", "Анатолий", "Андрей", "Антон", "Артём", "Борис", "Валентин",
        "Валерий", "Василий", "Виктор", "Виталий", "Владимир", "Владислав", "Вячеслав", "Геннадий",
        "Георгий", "Григорий", "Данила", "Денис", "Дмитрий", "Евгений", "Егор", "Иван", "Игорь",
        "Илья", "Кирилл", "Константин", "Леонид", "Максим", "Михаил", "Никита", "Николай",
        "Олег", "Павел", "Пётр", "Роман", "Ростислав", "Руслан", "Сергей", "Станислав",
        "Степан", "Тарас", "Тимофей", "Фёдор", "Юрий", "Ярослав",
    ]
    static let femaleFirstNames: Set<String> = [
        "Аврора", "Алина", "Алла", "Анастасия", "Анна", "Валентина", "Вера", "Вероника",
        "Виктория", "Влада", "Галина", "Дарья", "Дина", "Евгения", "Екатерина", "Елена",
        "Елизавета", "Зинаида", "Зоя", "Инна", "Ирина", "Ксения", "Лариса", "Лидия",
        "Любовь", "Людмила", "Маргарита", "Марина", "Мария", "Надежда", "Наталья", "Нина",
        "Оксана", "Ольга", "Полина", "Раиса", "Светлана", "Софья", "Тамара", "Татьяна",
        "Ульяна", "Юлия",
    ]

    struct Analysis: Sendable, Equatable {
        let canonical: String
        let nameCase: RussianNameCase
        let feminine: Bool
    }

    /// Analyzes «Имя Фамилия». Returns nil when the fragment is not a
    /// two-word capitalized Cyrillic pair with recognized endings — those
    /// values keep their raw form as the substitution key and never decline.
    static func analyze(_ fragment: String) -> Analysis? {
        let parts = fragment.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let first = parts[0], last = parts[1]
        guard isCyrillicWord(first), isCyrillicWord(last),
              isCapitalized(first), isCapitalized(last),
              first.unicodeScalars.count >= 2, last.unicodeScalars.count >= 3 else { return nil }
        // Stems drop the case ending; feminine words rebuild on «а», masculine
        // words on nothing. normalizeMaleFirst restores a known nominative
        // («Никиты» → «Никита») so all case forms of one name share one key.
        // Feminine surnames drop their two-scalar adjectival endings
        // («Заречной» → «Заречн») so hard and soft forms unify on one key.
        func feminineCanonical(_ stem1: String, _ stem2: String) -> String { stem1 + "а " + stem2 + "а" }
        func masculineCanonical(_ stem1: String, _ stem2: String) -> String { (normalizeMaleFirst(stem1) ?? stem1) + " " + stem2 }
        func drop(_ word: String, _ scalars: Int) -> String { String(word.unicodeScalars.dropLast(scalars)) }
        func feminineSurnameStem(_ word: String) -> String {
            for suffix in ["ая", "яя", "ой", "ей", "ую", "юю"] where word.hasSuffix(suffix) { return drop(word, 2) }
            return drop(word, 1) // «а»/«я»/«у»/«ю»/«ы»/«и» single-scalar endings
        }
        func feminineFirstStem(_ word: String) -> String {
            if word.hasSuffix("ой") || word.hasSuffix("ей") { return drop(word, 2) }
            return drop(word, 1)
        }

        // Feminine surname declension: the surname ends in «ой»/«ей» and the
        // first name ending tells the case.
        if last.hasSuffix("ой") || last.hasSuffix("ей") {
            let surnameStem = feminineSurnameStem(last)
            if first.hasSuffix("ы") || first.hasSuffix("и") {
                return Analysis(canonical: feminineCanonical(feminineFirstStem(first), surnameStem), nameCase: .genitive, feminine: true)
            }
            if first.hasSuffix("е") {
                return Analysis(canonical: feminineCanonical(feminineFirstStem(first), surnameStem), nameCase: .dative, feminine: true)
            }
            if first.hasSuffix("ой") || first.hasSuffix("ей") {
                return Analysis(canonical: feminineCanonical(feminineFirstStem(first), surnameStem), nameCase: .instrumental, feminine: true)
            }
            return nil
        }
        // Feminine nominative/accusative and masculine genitive/dative share
        // surface endings; the first-name stem resolves the gender.
        if last.hasSuffix("а") || last.hasSuffix("я") {
            let surnameStem = feminineSurnameStem(last)
            let firstStem = drop(first, 1)
            if first.hasSuffix("а") || first.hasSuffix("я") {
                // «Анна Петрова» (feminine nominative) vs «Ивана Соколова»
                // (masculine genitive): the dictionary decides, feminine wins ties.
                if let name = normalizeMaleFirst(firstStem) {
                    return Analysis(canonical: name + " " + surnameStem, nameCase: .genitive, feminine: false)
                }
                return Analysis(canonical: feminineCanonical(firstStem, surnameStem), nameCase: .nominative, feminine: true)
            }
            if first.hasSuffix("у") || first.hasSuffix("ю") {
                // A «у» first name before an «а» surname is the accusative of
                // a «Никита»-type male name («Никиту Соколова»); the feminine
                // accusative takes «у» endings on both words and never
                // reaches this branch.
                if let name = normalizeMaleFirst(firstStem) {
                    return Analysis(canonical: name + " " + surnameStem, nameCase: .accusative, feminine: false)
                }
                return Analysis(canonical: feminineCanonical(firstStem, surnameStem), nameCase: .accusative, feminine: true)
            }
            if first.hasSuffix("ы") || first.hasSuffix("и") {
                // A masculine surname takes «а»/«я» only in genitive/accusative.
                return Analysis(canonical: masculineCanonical(firstStem, surnameStem), nameCase: .genitive, feminine: false)
            }
            return nil
        }
        if last.hasSuffix("у") || last.hasSuffix("ю") {
            // «Анну Петрову» (feminine accusative) vs «Ивану Соколову»
            // (masculine dative): the dictionary resolves the gender, the
            // output endings coincide either way.
            let surnameStem = feminineSurnameStem(last)
            let firstStem = drop(first, 1)
            if let name = normalizeMaleFirst(firstStem) {
                return Analysis(canonical: name + " " + surnameStem, nameCase: .dative, feminine: false)
            }
            return Analysis(canonical: feminineCanonical(firstStem, surnameStem), nameCase: .accusative, feminine: true)
        }
        if first.hasSuffix("а") || first.hasSuffix("я") {
            // «Никита Соколов» is a nominative male name in «а»; every other
            // «а» first name before a consonant surname is a genitive
            // («Ивана Соколова»).
            let nameCase: RussianNameCase = maleFirstNames.contains(first) ? .nominative : .genitive
            return Analysis(canonical: masculineCanonical(drop(first, 1), last), nameCase: nameCase, feminine: false)
        }
        if first.hasSuffix("у") || first.hasSuffix("ю") {
            return Analysis(canonical: masculineCanonical(drop(first, 1), last), nameCase: .dative, feminine: false)
        }
        if first.hasSuffix("ом") || first.hasSuffix("ем") || first.hasSuffix("ым") || first.hasSuffix("им") {
            return Analysis(canonical: masculineCanonical(drop(first, 2), last), nameCase: .instrumental, feminine: false)
        }
        if first.hasSuffix("е") {
            return Analysis(canonical: masculineCanonical(drop(first, 1), last), nameCase: .prepositional, feminine: false)
        }
        // Bare consonant endings on both words: nominative masculine.
        return Analysis(canonical: masculineCanonical(first, last), nameCase: .nominative, feminine: false)
    }

    /// The nominative form of a known male name: the word itself, or a stem
    /// completed with «а»/«я» («Никит» → «Никита»); nil for everything else.
    private static func normalizeMaleFirst(_ stemOrWord: String) -> String? {
        if maleFirstNames.contains(stemOrWord) { return stemOrWord }
        if maleFirstNames.contains(stemOrWord + "а") { return stemOrWord + "а" }
        if maleFirstNames.contains(stemOrWord + "я") { return stemOrWord + "я" }
        return nil
    }

    /// Declines a fictional nominative «Имя Фамилия» to the requested case.
    /// The first name and the surname follow different feminine tables
    /// («Анне», but «Соколовой»), and masculine words ending in a consonant
    /// take their endings on top of the full word. The generated lists contain
    /// only stems for which these tables are exact (no velar or hushing
    /// stems, no -ия first names, no adjectival surnames).
    static func decline(base: String, feminine: Bool, to nameCase: RussianNameCase) -> String {
        let parts = base.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return base }
        return declineFirst(parts[0], feminine: feminine, to: nameCase)
            + " " + declineSurname(parts[1], feminine: feminine, to: nameCase)
    }

    private static func declineFirst(_ word: String, feminine: Bool, to nameCase: RussianNameCase) -> String {
        let scalars = Array(word.unicodeScalars)
        guard let last = scalars.last, isCyrillicLetter(last) else { return word }
        if feminine {
            // Nominative in «а» (hard) or «я» incl. «ья» (soft).
            let stem = String(String.UnicodeScalarView(scalars.dropLast()))
            if last == "я" {
                switch nameCase {
                case .nominative: return word
                case .genitive: return stem + "и"
                case .dative, .prepositional: return stem + "е"
                case .accusative: return stem + "ю"
                case .instrumental: return stem + "ей"
                }
            }
            switch nameCase {
            case .nominative: return word
            case .genitive: return stem + "ы"
            case .dative, .prepositional: return stem + "е"
            case .accusative: return stem + "у"
            case .instrumental: return stem + "ой"
            }
        }
        guard isConsonant(last) else { return word } // «Никита»-type bases stay as-is
        switch nameCase {
        case .nominative: return word
        case .genitive, .accusative: return word + "а"
        case .dative: return word + "у"
        case .instrumental: return word + "ом"
        case .prepositional: return word + "е"
        }
    }

    private static func declineSurname(_ word: String, feminine: Bool, to nameCase: RussianNameCase) -> String {
        let scalars = Array(word.unicodeScalars)
        guard let last = scalars.last, isCyrillicLetter(last) else { return word }
        if feminine {
            // Possessive -ова/-ева/-ина surnames share one «ой» form in every
            // oblique case and take «у» in the accusative.
            let stem = String(String.UnicodeScalarView(scalars.dropLast()))
            switch nameCase {
            case .nominative: return word
            case .accusative: return stem + "у"
            default: return stem + "ой"
            }
        }
        guard isConsonant(last) else { return word }
        switch nameCase {
        case .nominative: return word
        case .genitive, .accusative: return word + "а"
        case .dative: return word + "у"
        // Possessive -ов/-ев/-ин surnames take «ым» in the instrumental.
        case .instrumental: return word + "ым"
        case .prepositional: return word + "е"
        }
    }

    private static func isConsonant(_ scalar: Unicode.Scalar) -> Bool {
        guard isCyrillicLetter(scalar) else { return false }
        return !"аеёиоуыэюяьъ".unicodeScalars.contains(scalar)
    }

    /// The canonical key form of a fragment: nil when it is not a recognized
    /// Russian full name (the raw string is then used as its own key).
    static func canonicalKey(of fragment: String) -> String? {
        analyze(fragment)?.canonical
    }

    private static func isCapitalized(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first else { return false }
        return String(first).first?.isUppercase == true
    }

    private static func isCyrillicWord(_ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        guard scalars.allSatisfy({ isCyrillicLetter($0) || $0 == "-" }) else { return false }
        return scalars.contains(where: isCyrillicLetter)
    }

    private static func isCyrillicLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0410...0x044F).contains(scalar.value) || scalar.value == 0x0401 || scalar.value == 0x0451
    }
}
