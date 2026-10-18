import Foundation

public enum SummarySection: String, CaseIterable, Sendable {
    case overview, decisions, tasks, openQuestions

    public var instruction: String {
        let definition: String
        switch self {
        case .overview:
            definition = "Summarize material facts and outcomes as concise standalone statements, not just topic labels. Preserve explicitly stated names, relationships and statuses, including substantive facts in a short informal conversation. Write in third person, naming anonymous participants as Спикер N or Speaker N in the text using their source speaker IDs; do not copy first-person quotations. Merge repeated statements about the same fact or relationship into one point. Omit greetings and filler; distinguish facts about different speakers."
        case .decisions:
            definition = "Extract ALL concrete choices, adopted plans and agreements. Agreement can span turns: a proposal followed by acceptance is a decision; cite BOTH turns. State the adopted choice itself, resolving pronouns from the context; never output a bare acknowledgement as the decision text. No special word such as 'decided' is required. An unaccepted suggestion or a bare acknowledgement without a concrete proposition is not a decision. Confirmation of an existing fact or relationship is not a newly adopted decision."
        case .tasks:
            definition = "Extract ALL concrete follow-up work: first-person commitments, assigned work, accepted requests and agreed next steps. An agreed action is a task even without a named owner or deadline: leave those fields null. Resolve short replies using neighbouring turns and cite the action AND its acceptance. Do not turn hypothetical suggestions or general observations into assignments. Keep distinct actions separate. Include only work remaining after the conversation; omit completed actions, requests already fulfilled in the passage and conversational invitations such as introducing oneself."
        case .openQuestions:
            definition = "Extract ALL material unresolved questions, pending choices, blockers and issues explicitly left for clarification or later discussion. They need not end in a question mark. Include only issues still unresolved in this source passage; omit rhetorical questions and questions answered in the passage."
        }
        return "Fill ONLY the \(rawValue) array. Review EVERY focus segment for this section even if its topic also belongs in another section. \(definition) Empty arrays are correct only when this section has no supported facts."
    }

    public func append(from value: Summary, to result: inout Summary) {
        switch self {
        case .overview: result.overview += value.overview
        case .decisions: result.decisions += value.decisions
        case .tasks: result.tasks += value.tasks
        case .openQuestions: result.openQuestions += value.openQuestions
        }
    }

    public func decodeResponse(_ data: Data) throws -> Summary {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String:Any] else {
            throw ScribeError.message("Ожидался JSON-объект итогов")
        }
        // Require the requested array; supply only the arrays absent from this model pass.
        // An answer to a different section must never silently become an empty result.
        for other in Self.allCases where other != self { object[other.rawValue] = [] as [String] }
        return try JSONDecoder().decode(Summary.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

public struct SummaryExtractionPass: Sendable {
    public let section: SummarySection
    public let spokenLanguage: String
    public let focusSegmentIds: [String]
    public let segments: [Segment]
}

public enum SummaryExtraction {
    public static func extract(_ segments: [Segment], language: String,
                               generate: @Sendable (SummaryExtractionPass) async throws -> Summary) async throws -> Summary {
        var languages: [String] = []
        for segment in segments where !languages.contains(segment.language) { languages.append(segment.language) }
        var result = Summary(language: language)
        for section in SummarySection.allCases {
            for spokenLanguage in languages {
                let pass = SummaryExtractionPass(section: section, spokenLanguage: spokenLanguage,
                    focusSegmentIds: segments.filter { $0.language == spokenLanguage }.map(\.id), segments: segments)
                let value = try await generate(pass)
                guard value.language == language else { throw ScribeError.message("Неверный язык итогов") }
                try value.validate(against: Transcript(fingerprint: "", diarized: false, segments: segments))
                section.append(from: value, to: &result)
            }
        }
        return result
    }
}

public enum SummarySource {
    /// Models may straighten quotation marks. Recover the actual source substring;
    /// words, punctuation other than quote glyphs, and segment identity still have to match.
    public static func verbatimQuote(_ quote: String, in text: String) -> String? {
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let quotes: [Character:Character] = ["‘":"'", "’":"'", "ʼ":"'", "＇":"'", "“":"\"", "”":"\"", "„":"\"", "‟":"\"", "＂":"\""]
        let source = String(text.map { quotes[$0] ?? $0 })
        let target = String(quote.map { quotes[$0] ?? $0 })
        guard let range = source.range(of: target, options: .caseInsensitive) else { return nil }
        let start = text.index(text.startIndex, offsetBy: source.distance(from: source.startIndex, to: range.lowerBound))
        let end = text.index(text.startIndex, offsetBy: source.distance(from: source.startIndex, to: range.upperBound))
        return String(text[start..<end])
    }

    /// Overlap turns at chunk boundaries so a proposal and its acceptance can be read together.
    /// Token counts include the rendered source labels, not only the speech text.
    public static func groups(_ segments: [Segment], tokenCounts: [Int], limit: Int = 3500) throws -> [[Segment]] {
        guard tokenCounts.count == segments.count, limit > 0,
              tokenCounts.allSatisfy({ $0 > 0 && $0 < limit }) else {
            throw ScribeError.message("Одна реплика превышает контекст итогов. Требуется повтор распознавания.")
        }
        var result: [[Segment]] = [], current: [Int] = [], tokens = 0
        for index in segments.indices {
            let count = tokenCounts[index]
            if tokens + count > limit && !current.isEmpty {
                result.append(current.map { segments[$0] })
                let previous = current.suffix(2)
                current = []; tokens = 0
                for carried in previous.reversed() {
                    guard tokens + tokenCounts[carried] + count <= limit else { break }
                    current.insert(carried, at: 0); tokens += tokenCounts[carried]
                }
            }
            current.append(index); tokens += count
        }
        if !current.isEmpty { result.append(current.map { segments[$0] }) }
        return result
    }

    public static func evidenceContext(for finding: Finding, in transcript: Transcript) -> [Segment] {
        var indexes: Set<Int> = []
        for (index, segment) in transcript.segments.enumerated() where finding.evidenceSegmentIds.contains(segment.id) {
            for neighbour in max(0, index - 2)...min(transcript.segments.count - 1, index + 2) { indexes.insert(neighbour) }
        }
        return indexes.sorted().map { transcript.segments[$0] }
    }
}

public struct SummaryEvidenceVerdict: Codable, Sendable {
    public var supported: Bool
    public var sourceSegmentId: String?
    public var quote: String?
    public var ownerSupported: Bool
    public var deadlineSupported: Bool

    public init(supported: Bool, sourceSegmentId: String? = nil, quote: String? = nil, ownerSupported: Bool = false, deadlineSupported: Bool = false) {
        self.supported = supported; self.sourceSegmentId = sourceSegmentId; self.quote = quote
        self.ownerSupported = ownerSupported; self.deadlineSupported = deadlineSupported
    }

    /// Preserve the neighbouring proposition used by the verifier as actual evidence.
    public func applying(to finding: Finding, context: [Segment]) throws -> Finding? {
        guard supported else { return nil }
        guard let id = sourceSegmentId, let quote, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              context.contains(where: { $0.id == id && SummarySource.verbatimQuote(quote, in: $0.text) != nil }) else {
            throw ScribeError.message("Не удалось проверить основание по точной цитате; прежние результаты сохранены")
        }
        var result = finding
        if !result.evidenceSegmentIds.contains(id) { result.evidenceSegmentIds.append(id) }
        if !ownerSupported { result.ownerName = nil; result.ownerSpeakerId = nil }
        if !deadlineSupported { result.dueText = nil }
        if context.contains(where: { result.evidenceSegmentIds.contains($0.id) && $0.uncertain }) { result.uncertain = true }
        return result
    }
}
