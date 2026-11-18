import Foundation
public enum ExportPart: String, CaseIterable, Sendable {
    case transcript = "Расшифровка", summary = "Итоги", warnings = "Предупреждения", all = "Всё"

    public var title: String { L10n.text(rawValue) }
}
public struct ExportTimestamp: Sendable, Equatable {
    public let segmentID: String
    public let range: NSRange
    public let isTranscript: Bool
    public let startMs: Int
    public let endMs: Int
    public let segmentRange: NSRange?
}

public struct RenderedExport: Sendable, Equatable {
    public var text = ""
    public var timestamps: [ExportTimestamp] = []
    public init() {}
}

public enum ExportService {
    /// Untrusted text must stay on one rendered line: embedded line breaks
    /// would otherwise forge markdown structure (lists, code blocks). Same
    /// policy as DiagramExport.singleLine.
    private static func singleLine(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { scalars.append(isControl(scalar) ? " " : scalar) }
        return String(scalars)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)
            || scalar.value == 0x2028 || scalar.value == 0x2029
    }

    private static func clean(_ text: String, markdown: Bool) -> String {
        guard markdown else { return text }
        return singleLine(text).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "#", with: "\\#").replacingOccurrences(of: "|", with: "\\|")
    }

    public static func renderSegment(_ segment: Segment, markdown: Bool) -> String {
        let speaker = segment.overlap ? L10n.text("Несколько голосов") : speakerName(segment.speakerId)
        let uncertainty = segment.uncertain ? L10n.text(" — сомнительный участок") : ""
        return "[\(timecode(segment.startMs))] \(clean(speaker, markdown: markdown))\(uncertainty)\n\(clean(segment.text.trimmingCharacters(in: .whitespacesAndNewlines), markdown: markdown))\n\n"
    }

    public static func render(manifest m: Manifest, transcript t: Transcript?, summary s: Summary?, part: ExportPart = .all, markdown: Bool) -> String {
        renderResult(manifest: m, transcript: t, summary: s, part: part, markdown: markdown).text
    }

    /// Ranges use UTF-16 offsets for AppKit. Record links while rendering so
    /// identical visible timestamps still refer to their own source segments.
    public static func renderResult(manifest m: Manifest, transcript t: Transcript?, summary s: Summary?, part: ExportPart = .all, markdown: Bool, transcriptionModel: String? = nil) -> RenderedExport {
        var result = RenderedExport()
        var offset = 0
        func append(_ text: String) {
            result.text += text
            offset += text.utf16.count
        }
        func timestamp(_ segment: Segment, blockLength: Int? = nil) {
            let text = "[\(timecode(segment.startMs))]"
            result.timestamps.append(ExportTimestamp(
                segmentID: segment.id, range: NSRange(location: offset, length: text.utf16.count),
                isTranscript: blockLength != nil, startMs: segment.startMs, endMs: segment.endMs,
                segmentRange: blockLength.map { NSRange(location: offset, length: $0) }
            ))
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
        let date = (m.recordedAt ?? m.createdAt).formatted(
            Date.FormatStyle(date: .numeric, time: .shortened, locale: L10n.locale)
        )
        append((markdown ? "# " : "") + clean(m.displayTitle) + "\n\n")
        append((m.recordedAt == nil ? L10n.text("Дата импорта: %1$@", date) : L10n.text("Дата записи: %1$@", date)) + "\n")
        append(L10n.text("Длительность: %1$@", timecode(m.durationMs)) + "\n")
        let state: JobState = m.activeRunId == nil ? m.state : m.warnings.isEmpty ? .completed : .completedWithWarnings
        append(L10n.text("Статус: %1$@", state.title) + "\n")
        if t != nil, part == .transcript || part == .all {
            append(L10n.text("Модель: %1$@", clean(transcriptionModel ?? L10n.text("Не указано"))) + "\n")
        }
        append(L10n.text("Автоматическая локальная обработка. Возможны ошибки.") + "\n")
        if m.activeRunId != nil && m.pendingRunId != nil {
            append(L10n.text("Показан предыдущий успешный результат; новая обработка ещё не завершена.") + "\n")
        }
        if let s {
            let summaryLanguage = s.language == "ru" ? L10n.text("русский") : L10n.text("английский")
            append(L10n.text("Язык итогов: %1$@", summaryLanguage) + "\n")
        }
        if !m.sourceComplete { append(L10n.text("Запись неполная.") + "\n") }
        if let t, !t.diarized { append(L10n.text("Участники не определены. Промежуточная расшифровка.") + "\n") }
        append("\n")
        if (part == .warnings || part == .all) && !m.warnings.isEmpty {
            append(heading(ExportPart.warnings.title))
            for warning in m.warnings {
                append(L10n.text("Предупреждение: %1$@", clean(L10n.message(warning))) + "\n\n")
            }
        }
        if part == .summary || part == .all {
            if let s {
                let sections = [
                    (L10n.text("Краткое содержание"), s.overview, false),
                    (L10n.text("Решения и договорённости"), s.decisions, false),
                    (L10n.text("Задачи"), s.tasks, true),
                    (L10n.text("Открытые вопросы"), s.openQuestions, false),
                ]
                for (title, findings, showsAssignment) in sections {
                    append(heading(title))
                    if findings.isEmpty { append(L10n.text("Не обнаружены.") + "\n\n"); continue }
                    for f in findings {
                        append((markdown ? "- " : "• ") + clean(f.text))
                        if showsAssignment {
                            let unspecified = L10n.text("Не указано")
                            let owner = f.ownerName ?? f.ownerSpeakerId.map { speakerName($0) } ?? unspecified
                            append(L10n.text(" — Ответственный: %1$@; срок: %2$@", clean(owner), clean(f.dueText ?? unspecified)))
                        }
                        if f.uncertain { append(L10n.text(" (требует проверки)")) }
                        append(" ")
                        let evidence = Set(f.evidenceSegmentIds).compactMap { evidenceIndex[$0] }.sorted().compactMap { t?.segments[$0] }
                        for (index, segment) in evidence.enumerated() {
                            if index > 0 { append(" ") }
                            timestamp(segment)
                            append("[\(timecode(segment.startMs))]")
                        }
                        append("\n")
                    }
                    append("\n")
                }
            } else { append(L10n.text("Итоги ещё не готовы.") + "\n\n") }
        }
        if part == .transcript || part == .all {
            append(heading(ExportPart.transcript.title))
            if let t {
                if t.segments.isEmpty { append(L10n.text("Речь не обнаружена.") + "\n") }
                for seg in t.segments {
                    let block = renderSegment(seg, markdown: markdown)
                    timestamp(seg, blockLength: block.utf16.count - 2)
                    append(block)
                }
            } else { append(L10n.text("Расшифровка ещё не готова.") + "\n") }
        }
        return result
    }
}
