import Foundation

public enum DiagramExportPart: String, CaseIterable, Sendable {
    case nodes = "Узлы", edges = "Связи", warnings = "Предупреждения", all = "Всё"

    public var title: String { L10n.text(rawValue) }

    public static func sections(includingWarnings: Bool) -> [Self] {
        includingWarnings ? [.nodes, .edges, .warnings] : [.nodes, .edges]
    }
}

/// Deterministic UTF-8 serializers for a verified DiagramResult. The code owns
/// the syntax: the recognition model never generates markup, node and edge
/// labels are untrusted text and are neutralized before reaching the output.
public enum DiagramExport {
    // MARK: - Markdown and plain text

    public static func markdown(_ result: DiagramResult, title: String, warnings: [String] = [],
                                part: DiagramExportPart = .all) -> String {
        text(result, title: title, warnings: warnings, part: part, markdown: true)
    }

    public static func plainText(_ result: DiagramResult, title: String, warnings: [String] = [],
                                 part: DiagramExportPart = .all) -> String {
        text(result, title: title, warnings: warnings, part: part, markdown: false)
    }

    private static func text(_ result: DiagramResult, title: String, warnings: [String],
                             part: DiagramExportPart, markdown: Bool) -> String {
        let sections = DiagramExportPart.sections(includingWarnings: !warnings.isEmpty)
        let escape = markdown ? escapeMarkdown : singleLine
        var lines = [(markdown ? "# " : "") + escape(title)]
        for section in sections where part == .all || part == section {
            lines += ["", (markdown ? "## " : "") + section.title, ""]
            switch section {
            case .nodes:
                for node in result.nodes {
                    lines.append("- " + escape(node.label) + (node.uncertain ? L10n.text(" (подпись нечитаема)") : ""))
                }
            case .edges:
                let labels = Dictionary(result.nodes.map { ($0.id, escape($0.label)) }, uniquingKeysWith: { first, _ in first })
                for edge in result.edges {
                    guard let from = labels[edge.from], let to = labels[edge.to] else { continue }
                    var line = "- " + from + " " + edge.symbol + " " + to
                    if let edgeLabel = edge.label { line += " (" + escape(edgeLabel) + ")" }
                    if let kind = edge.kind { line += " · " + kind.title }
                    if edge.uncertain { line += L10n.text(" ⚠ не подтверждена") }
                    lines.append(line)
                }
            case .warnings:
                for warning in warnings { lines.append("- " + escape(L10n.message(warning))) }
            case .all:
                break
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Control characters and line breaks never create new markdown lines;
    /// markdown-active punctuation is backslash-escaped.
    static func escapeMarkdown(_ text: String) -> String {
        var escaped = singleLine(text)
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
        let sequence = result.kind == .sequence
        let declaration = sequence ? "participant" : "rectangle"
        let aliases = Dictionary(uniqueKeysWithValues: result.nodes.enumerated().map { ($1.id, "n\($0)") })
        for (index, node) in result.nodes.enumerated() {
            let label = node.label.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map { plantumlSafe(String($0), warnings: &warnings) }.joined(separator: "\\n")
            lines.append("\(declaration) \"\(label)\" as n\(index)")
        }
        for edge in result.edges {
            guard let from = aliases[edge.from], let to = aliases[edge.to] else { continue }
            var line: String
            if sequence || edge.kind?.endpointSymbol != nil {
                let (source, target) = edge.direction == .backward ? (to, from) : (from, to)
                let arrow = sequence ? messageConnector(edge) : endpointConnector(edge)
                line = source + " " + arrow + " " + target
            } else {
                line = from + " " + connector(edge) + " " + to
            }
            if let edgeLabel = edge.label { line += " : " + plantumlSafe(edgeLabel, warnings: &warnings) }
            lines.append(line)
        }
        lines.append("@enduml")
        return (lines.joined(separator: "\n") + "\n", warnings)
    }

    private static func messageConnector(_ edge: DiagramEdge) -> String {
        let color = edge.uncertain ? "[#orange]" : ""
        return edge.kind == .reply ? "--" + color + ">>" : "-" + color + ">"
    }

    private static func endpointConnector(_ edge: DiagramEdge) -> String {
        let solid = edge.uncertain ? "-[#orange]-" : "--"
        switch edge.kind {
        case .composition: return solid + "*"
        case .aggregation: return solid + "o"
        case .containment: return solid + "+"
        case .generalization: return solid + "|>"
        case .realization: return edge.uncertain ? "-[#orange,dashed]-|>" : "..|>"
        default: return connector(edge)
        }
    }

    private static func connector(_ edge: DiagramEdge) -> String {
        if let kind = edge.kind {
            let dashed = kind == .dependency || kind == .reply || kind == .dashed
            let stroke = dashed ? ".." : "--"
            let style = dashed ? "[#orange,dashed]" : "[#orange]"
            let line = edge.uncertain ? "-" + style + "-" : stroke
            switch edge.direction {
            case .forward: return line + ">"
            case .backward: return "<" + line
            case .both: return "<" + line + ">"
            case .none: return line
            }
        }
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
            } else if let entity = plantumlLiteralPunctuation[scalar] {
                output.append(contentsOf: entity.unicodeScalars)
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
    // Emit renderer escapes for visible UML punctuation that could otherwise
    // be interpreted as markup. The escapes themselves never come from input.
    private static let plantumlLiteralPunctuation: [UnicodeScalar: String] = [
        "*": "<U+002A>", ":": "<U+003A>", "#": "<U+0023>", "[": "<U+005B>", "]": "<U+005D>",
        "«": "<U+00AB>", "»": "<U+00BB>",
    ]
    private static func isPlantumlAllowed(_ scalar: UnicodeScalar) -> Bool {
        if scalar.properties.isAlphabetic { return true }
        if scalar.properties.numericType == .decimal { return true }
        return plantumlAllowedPunctuation.contains(scalar)
    }

    // MARK: - Shared

    private static func singleLine(_ text: String) -> String {
        var neutral = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            neutral.append(isControl(scalar) ? " " : scalar)
        }
        return String(neutral)
    }

    /// C0/C1 control characters and Unicode line separators never continue to
    /// the output as structural characters.
    private static func isControl(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)
            || scalar.value == 0x2028 || scalar.value == 0x2029
    }
}
