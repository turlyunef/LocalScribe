import Foundation
public enum ExportPart: String, CaseIterable, Sendable { case transcript = "Расшифровка", summary = "Итоги", warnings = "Предупреждения", all = "Всё" }
public struct ExportTimestamp: Sendable, Equatable {
    public let segmentID: String
    public let range: NSRange
    public let isTranscript: Bool
}

public struct RenderedExport: Sendable, Equatable {
    public var text = ""
    public var timestamps: [ExportTimestamp] = []
    public init() {}
}

public enum ExportService {
    private static func clean(_ text: String, markdown: Bool) -> String {
        guard markdown else { return text }
        return text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "#", with: "\\#").replacingOccurrences(of: "|", with: "\\|")
    }

    public static func renderSegment(_ segment: Segment, markdown: Bool) -> String {
        "[\(timecode(segment.startMs))] \(segment.overlap ? "Несколько голосов" : speakerName(segment.speakerId))\(segment.uncertain ? " — сомнительный участок" : "")\n\(clean(segment.text.trimmingCharacters(in: .whitespacesAndNewlines), markdown: markdown))\n\n"
    }

    public static func render(manifest m: Manifest, transcript t: Transcript?, summary s: Summary?, part: ExportPart = .all, markdown: Bool) -> String {
        renderResult(manifest: m, transcript: t, summary: s, part: part, markdown: markdown).text
    }

    /// Ranges use UTF-16 offsets for AppKit. Record links while rendering so
    /// identical visible timestamps still refer to their own source segments.
    public static func renderResult(manifest m: Manifest, transcript t: Transcript?, summary s: Summary?, part: ExportPart = .all, markdown: Bool) -> RenderedExport {
        var result = RenderedExport()
        var offset = 0
        func append(_ text: String) {
            result.text += text
            offset += text.utf16.count
        }
        func timestamp(_ segment: Segment, isTranscript: Bool) {
            let text = "[\(timecode(segment.startMs))]"
            result.timestamps.append(ExportTimestamp(segmentID: segment.id, range: NSRange(location: offset, length: text.utf16.count), isTranscript: isTranscript))
        }
        func clean(_ text: String) -> String { Self.clean(text, markdown: markdown) }
        func heading(_ title: String) -> String { (markdown ? "## " : "") + title + "\n\n" }
        // Look up only the referenced segments per finding. Transcript position is
        // the stable chronological order, including segments with equal start times.
        var evidenceIndex: [String: Int] = [:]
        if part == .summary || part == .all, s != nil, let t {
            evidenceIndex.reserveCapacity(t.segments.count)
            for (index, segment) in t.segments.enumerated() { evidenceIndex[segment.id] = index }
        }
        let date = (m.recordedAt ?? m.createdAt).formatted(date: .numeric, time: .shortened)
        append((markdown ? "# " : "") + clean(m.displayTitle) + "\n\n")
        append("\(m.recordedAt == nil ? "Дата импорта" : "Дата записи"): \(date)\nДлительность: \(timecode(m.durationMs))\n")
        let state = m.activeRunId == nil ? m.state.title : m.warnings.isEmpty ? "Готово" : "Готово с предупреждениями"
        append("Статус: \(state)\nАвтоматическая локальная обработка. Возможны ошибки.\n")
        if m.activeRunId != nil && m.pendingRunId != nil { append("Показан предыдущий успешный результат; новая обработка ещё не завершена.\n") }
        if let s { append("Язык итогов: \(s.language == "ru" ? "русский" : "English")\n") }
        if !m.sourceComplete { append("Запись неполная.\n") }
        if let t, !t.diarized { append("Участники не определены. Промежуточная расшифровка.\n") }
        append("\n")
        if (part == .warnings || part == .all) && !m.warnings.isEmpty {
            append(heading("Предупреждения"))
            for warning in m.warnings { append("Предупреждение: \(clean(warning))\n\n") }
        }
        if part == .summary || part == .all {
            if let s {
                for (title, findings) in [("Краткое содержание", s.overview), ("Решения и договорённости", s.decisions), ("Задачи", s.tasks), ("Открытые вопросы", s.openQuestions)] {
                    append(heading(title))
                    if findings.isEmpty { append("Не обнаружены.\n\n"); continue }
                    for f in findings {
                        append((markdown ? "- " : "• ") + clean(f.text))
                        if title == "Задачи" { append(" — Ответственный: \(clean(f.ownerName ?? f.ownerSpeakerId.map { speakerName($0) } ?? "Не указано")); срок: \(clean(f.dueText ?? "Не указано"))") }
                        if f.uncertain { append(" (требует проверки)") }
                        append(" ")
                        let evidence = Set(f.evidenceSegmentIds).compactMap { evidenceIndex[$0] }.sorted().compactMap { t?.segments[$0] }
                        for (index, segment) in evidence.enumerated() {
                            if index > 0 { append(" ") }
                            timestamp(segment, isTranscript: false)
                            append("[\(timecode(segment.startMs))]")
                        }
                        append("\n")
                    }
                    append("\n")
                }
            } else { append("Итоги ещё не готовы.\n\n") }
        }
        if part == .transcript || part == .all {
            append(heading("Расшифровка"))
            if let t {
                if t.segments.isEmpty { append("Речь не обнаружена.\n") }
                for seg in t.segments {
                    timestamp(seg, isTranscript: true)
                    append(renderSegment(seg, markdown: markdown))
                }
            } else { append("Расшифровка ещё не готова.\n") }
        }
        return result
    }
}
