import Foundation

/// In-memory title search. Distances use graphemes and restricted OSA, not unrestricted DL.
public enum RecordingTitleSearch {
    public struct Title: Equatable, Sendable {
        public let id: String
        public let title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }
    public struct Token: Equatable, Hashable, Sendable {
        public let text: String
        public let characters: [Character]
        public let budget: Int
        init(_ text: String) {
            self.text = text; characters = Array(text)
            let numeric = text.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
            budget = numeric || characters.count < 4 ? 0 : characters.count < 8 ? 1 : 2
        }
    }
    public static func tokens(_ text: String) -> [Token] {
        tokenize(text, check: {})
    }
    private static func tokenize(_ text: String, check: () throws -> Void) rethrows -> [Token] {
        try check()
        let normalized = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ё", with: "е")
        var words: [Token] = [], word = ""
        func flush() { if !word.isEmpty { words.append(Token(word)); word = "" } }
        var offset = 0
        for character in normalized {
            if offset & 63 == 0 { try check() }
            offset += 1
            if character.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }) {
                word.append(character)
            } else { flush() }
        }
        flush()
        var seen: Set<String> = []
        return words.filter { seen.insert($0.text).inserted }
    }
    public struct Index: Sendable {
        private struct Entry: Sendable {
            let source: Title
            let words: [Token]
        }
        private var entries: [Entry] = []
        private var words: [Token] = []
        private var wordIDs: [[Int]] = []
        private var prefixIDs: [[Int]] = []
        private struct PrefixKey: Hashable { let parent: Int; let character: Character }
        public init() {}
        /// Reuse unchanged titles, including across changes to membership or status.
        public init(titles: [Title], reusing previous: Index = Index()) throws {
            var old: [String: Entry] = [:]
            old.reserveCapacity(previous.entries.count)
            for entry in previous.entries {
                try Task.checkCancellation()
                old[entry.source.id] = entry
            }
            entries.reserveCapacity(titles.count)
            for title in titles {
                try Task.checkCancellation()
                if let entry = old[title.id], entry.source == title { entries.append(entry) }
                else { entries.append(Entry(source: title, words: try tokenize(title.title, check: { try Task.checkCancellation() }))) }
            }
            var positions: [String: Int] = [:]
            for entry in entries {
                try Task.checkCancellation()
                var ids: [Int] = []
                for word in entry.words {
                    if let id = positions[word.text] { ids.append(id) }
                    else {
                        let id = words.count
                        positions[word.text] = id; words.append(word); ids.append(id)
                    }
                }
                wordIDs.append(ids)
            }
            // Intern prefix paths once. Query-time memoization then uses integer keys
            // rather than repeatedly hashing long Unicode grapheme arrays.
            var paths: [PrefixKey: Int] = [:]
            var nextID = 1
            for word in words {
                try Task.checkCancellation()
                var parent = 0, ids: [Int] = []
                for (offset, character) in word.characters.enumerated() {
                    if offset & 63 == 0 { try Task.checkCancellation() }
                    let key = PrefixKey(parent: parent, character: character)
                    if let id = paths[key] { parent = id }
                    else { paths[key] = nextID; parent = nextID; nextID += 1 }
                    ids.append(parent)
                }
                prefixIDs.append(ids)
            }
            try Task.checkCancellation()
        }
        public func matches(_ query: [Token]) throws -> Set<String> {
            var result: Set<String> = []
            // A word shared by thousands of titles needs only one DP per query token.
            var cache = Array(repeating: Array(repeating: Int8(-1), count: words.count), count: query.count)
            var prefixes = Array(repeating: [Int: Bool](), count: query.count)
            var scratch = Scratch()
            for (position, entry) in entries.enumerated() {
                try Task.checkCancellation()
                var accepted = true
                for (offset, token) in query.enumerated() {
                    var found = false
                    for id in wordIDs[position] {
                        try Task.checkCancellation()
                        let match: Bool
                        if cache[offset][id] >= 0 { match = cache[offset][id] == 1 }
                        else {
                            let word = words[id]
                            if word.text.contains(token.text) { match = true }
                            else if token.budget == 0 || word.characters.count < token.characters.count - token.budget { match = false }
                            else {
                                // Once exact substring search fails, only this prefix can
                                // influence OSA. Equal prefixes safely share one DP result.
                                let prefix = prefixIDs[id][min(word.characters.count, token.characters.count + token.budget) - 1]
                                if let cached = prefixes[offset][prefix] { match = cached }
                                else {
                                    match = try scratch.prefixDistance(token.characters, word.characters, budget: token.budget) <= token.budget
                                    prefixes[offset][prefix] = match
                                }
                            }
                            cache[offset][id] = match ? 1 : 0
                        }
                        if match { found = true; break }
                    }
                    if !found { accepted = false; break }
                }
                if accepted { result.insert(entry.source.id) }
            }
            return result
        }
    }
    /// Internal entry point also checked against an independent full-matrix test oracle.
    static func prefixDistance(_ query: [Character], _ word: [Character], budget: Int) throws -> Int {
        var scratch = Scratch()
        return try scratch.prefixDistance(query, word, budget: budget)
    }
    private struct Scratch {
        var older: [Int] = [], previous: [Int] = [], current: [Int] = []
        mutating func prefixDistance(_ a: [Character], _ b: [Character], budget k: Int) throws -> Int {
            let m = a.count, lo = max(1, m - k), n = min(b.count, m + k), cap = k + 1
            guard m > 0, n >= lo else { return cap }
            if previous.count < n + 1 {
                older = Array(repeating: cap, count: n + 1)
                previous = older; current = older
            }
            // Only read initialized cells in the moving band. Clear its two boundaries,
            // rather than an entire row (important for very long pasted tokens).
            for j in 0...n {
                if j & 127 == 0 { try Task.checkCancellation() }
                previous[j] = min(j, cap); older[j] = cap
            }
            for i in 1...m {
                if i & 31 == 0 { try Task.checkCancellation() }
                let start = max(1, i - k), end = min(n, i + k)
                current[0] = min(i, cap)
                if start > 1 { current[start - 1] = cap }
                if end < n { current[end + 1] = cap }
                if start <= end {
                    for j in start...end {
                        var value = min(previous[j] + 1, current[j - 1] + 1,
                                        previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                        if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                            value = min(value, older[j - 2] + 1)
                        }
                        current[j] = min(value, cap)
                    }
                }
                swap(&older, &previous); swap(&previous, &current)
            }
            return (lo...n).reduce(cap) { min($0, previous[$1]) }
        }
    }
}
