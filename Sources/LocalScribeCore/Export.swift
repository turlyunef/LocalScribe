import Foundation
public enum ExportPart: String, CaseIterable { case transcript = "Расшифровка", summary = "Итоги", all = "Всё" }
public enum ExportService {
    public static func render(manifest m: Manifest, transcript t: Transcript?, summary s: Summary?, part: ExportPart = .all, markdown: Bool) -> String {
        func clean(_ text: String) -> String {
            guard markdown else { return text }
            return text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "#", with: "\\#").replacingOccurrences(of: "|", with: "\\|")
        }
        func heading(_ title: String) -> String { (markdown ? "## " : "") + title + "\n\n" }
        let date = (m.recordedAt ?? m.createdAt).formatted(date: .numeric, time: .shortened)
        var out = (markdown ? "# " : "") + clean(m.displayTitle) + "\n\n"
        out += "\(m.recordedAt == nil ? "Дата импорта" : "Дата записи"): \(date)\nДлительность: \(timecode(m.durationMs))\n"
        let state = m.activeRunId == nil ? m.state.title : m.warnings.isEmpty ? "Готово" : "Готово с предупреждениями"
        out += "Статус: \(state)\nАвтоматическая локальная обработка. Возможны ошибки.\n"
        if m.activeRunId != nil && m.pendingRunId != nil { out += "Показан предыдущий успешный результат; новая обработка ещё не завершена.\n" }
        if let s { out += "Язык итогов: \(s.language == "ru" ? "русский" : "English")\n" }
        for warning in m.warnings { out += "Предупреждение: \(clean(warning))\n" }
        if !m.sourceComplete { out += "Запись неполная.\n" }
        if let t, !t.diarized { out += "Участники не определены. Промежуточная расшифровка.\n" }
        out += "\n"
        func evidence(_ f: Finding) -> String {
            let segments = t?.segments.filter { f.evidenceSegmentIds.contains($0.id) } ?? []
            return segments.map { "[\(timecode($0.startMs))]" }.joined(separator: " ")
        }
        if part != .transcript {
            if let s {
                for (title, findings) in [("Краткое содержание", s.overview), ("Решения и договорённости", s.decisions), ("Задачи", s.tasks), ("Открытые вопросы", s.openQuestions)] {
                    out += heading(title)
                    if findings.isEmpty { out += "Не обнаружены.\n\n"; continue }
                    for f in findings {
                        out += (markdown ? "- " : "• ") + clean(f.text)
                        if title == "Задачи" { out += " — Ответственный: \(clean(f.ownerName ?? f.ownerSpeakerId.map { speakerName($0) } ?? "Не указано")); срок: \(clean(f.dueText ?? "Не указано"))" }
                        if f.uncertain { out += " (требует проверки)" }
                        out += " \(evidence(f))\n"
                    }
                    out += "\n"
                }
            } else { out += "Итоги ещё не готовы.\n\n" }
        }
        if part != .summary {
            out += heading("Расшифровка")
            if let t {
                if t.segments.isEmpty { out += "Речь не обнаружена.\n" }
                for seg in t.segments {
                    out += "[\(timecode(seg.startMs))–\(timecode(seg.endMs))] \(seg.overlap ? "Несколько голосов" : speakerName(seg.speakerId))\(seg.uncertain ? " — сомнительный участок" : "")\n\(clean(seg.text.trimmingCharacters(in: .whitespacesAndNewlines)))\n\n"
                }
            } else { out += "Расшифровка ещё не готова.\n" }
        }
        return out
    }
}
