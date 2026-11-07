import Foundation

/// Deterministic UTF-8 serializers for a verified DiagramResult. The code owns
/// the syntax: the recognition model never generates markup, node and edge
/// labels are untrusted text and are neutralized before reaching the output.
public enum DiagramExport {
    // MARK: - Markdown

    public static func markdown(_ result: DiagramResult, title: String, warnings: [String] = []) -> String {
        var lines: [String] = []
        lines.append("# " + escapeMarkdown(title))
        lines.append("")
        lines.append("## Узлы")
        lines.append("")
        for node in result.nodes {
            lines.append("- " + escapeMarkdown(node.label) + (node.uncertain ? " (подпись нечитаема)" : ""))
        }
        lines.append("")
        lines.append("## Связи")
        lines.append("")
        for edge in result.edges {
            guard let from = label(of: edge.from, in: result), let to = label(of: edge.to, in: result) else { continue }
            var line = "- " + escapeMarkdown(from) + " " + markdownArrow(edge.direction) + " " + escapeMarkdown(to)
            if let edgeLabel = edge.label { line += " (" + escapeMarkdown(edgeLabel) + ")" }
            if edge.uncertain { line += " ⚠ не подтверждена" }
            lines.append(line)
        }
        if !warnings.isEmpty {
            lines.append("")
            lines.append("## Предупреждения")
            lines.append("")
            for warning in warnings { lines.append("- " + escapeMarkdown(warning)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func markdownArrow(_ direction: DiagramEdgeDirection) -> String {
        switch direction {
        case .forward: return "→"
        case .both: return "↔"
        case .backward: return "←"
        case .none: return "—"
        }
    }

    /// Control characters and line breaks never create new markdown lines;
    /// markdown-active punctuation is backslash-escaped.
    static func escapeMarkdown(_ text: String) -> String {
        var neutral = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            neutral.append(isControl(scalar) ? " " : scalar)
        }
        var escaped = String(neutral)
        for (raw, replacement) in [("\\", "\\\\"), ("`", "\\`"), ("*", "\\*"), ("_", "\\_"),
                                   ("[", "\\["), ("]", "\\]"), ("<", "\\<"), (">", "\\>"), ("#", "\\#")] {
            escaped = escaped.replacingOccurrences(of: raw, with: replacement)
        }
        return escaped
    }

    // MARK: - PlantUML

    public static func plantuml(_ result: DiagramResult, title: String) -> (text: String, warnings: [String]) {
        var warnings: [String] = []
        var lines: [String] = []
        lines.append("@startuml")
        lines.append("' " + plantumlSafe(title, warnings: &warnings))
        let aliases = Dictionary(uniqueKeysWithValues: result.nodes.enumerated().map { ($1.id, "n\($0)") })
        for (index, node) in result.nodes.enumerated() {
            lines.append("rectangle \"\(plantumlSafe(node.label, warnings: &warnings))\" as n\(index)")
        }
        for edge in result.edges {
            guard let from = aliases[edge.from], let to = aliases[edge.to] else { continue }
            var line = from + " " + connector(edge) + " " + to
            if let edgeLabel = edge.label { line += " : " + plantumlSafe(edgeLabel, warnings: &warnings) }
            lines.append(line)
        }
        lines.append("@enduml")
        return (lines.joined(separator: "\n") + "\n", warnings)
    }

    private static func connector(_ edge: DiagramEdge) -> String {
        switch (edge.direction, edge.uncertain) {
        case (.forward, false): return "-->"
        case (.backward, false): return "<--"
        case (.both, false): return "<-->"
        case (.none, false): return "--"
        case (.forward, true): return ".->"
        case (.backward, true): return ".<-"
        case (.both, true): return "<.>"
        case (.none, true): return ".."
        }
    }

    /// Whitelist-based PlantUML label sanitizer. Anything that cannot be passed
    /// safely — control characters, quotes, backslashes, Creole/HTML markup,
    /// directive and delimiter sequences (@, !, %, <, >, &, *, /, …) — becomes
    /// «?» and a single warning is reported.
    static func plantumlSafe(_ text: String, warnings: inout [String]) -> String {
        var output = String.UnicodeScalarView()
        var replacedUnsafe = false
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            if isControl(scalar) || scalar == " " || scalar == "\t" {
                // Newlines, tabs, control characters and long space runs collapse
                // into a single space.
                if !lastWasSpace { output.append(" "); lastWasSpace = true }
                continue
            }
            if isPlantumlAllowed(scalar) {
                output.append(scalar)
            } else {
                output.append("?")
                replacedUnsafe = true
            }
            lastWasSpace = false
        }
        let result = String(output).trimmingCharacters(in: .whitespaces)
        if result.isEmpty { return "?" }
        if replacedUnsafe, !warnings.contains(unsafeSymbolWarning) {
            warnings.append(unsafeSymbolWarning)
        }
        return result
    }

    private static let unsafeSymbolWarning = "Подписи схемы содержат символы, которые нельзя безопасно передать в PlantUML; они заменены на «?»"

    private static let plantumlAllowedPunctuation: Set<UnicodeScalar> = ["-", "+", ",", ".", "(", ")", "?", "_", "="]
    private static func isPlantumlAllowed(_ scalar: UnicodeScalar) -> Bool {
        if scalar.properties.isAlphabetic { return true }
        if scalar.properties.numericType == .decimal { return true }
        return plantumlAllowedPunctuation.contains(scalar)
    }

    // MARK: - Shared

    private static func label(of id: String, in result: DiagramResult) -> String? {
        result.nodes.first { $0.id == id }?.label
    }

    /// C0/C1 control characters and Unicode line separators never continue to
    /// the output as structural characters.
    private static func isControl(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)
            || scalar.value == 0x2028 || scalar.value == 0x2029
    }
}
