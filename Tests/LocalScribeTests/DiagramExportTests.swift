import XCTest
@testable import LocalScribeCore

final class DiagramExportTests: XCTestCase {
    private func result(nodes: [DiagramNode], edges: [DiagramEdge]) -> DiagramResult {
        DiagramResult(fingerprint: "abc", nodes: nodes, edges: edges)
    }

    private var bannedInLabels: Set<Character> { ["!", "%", "@", "<", ">", "&", "*", "\"", "\\", ";", ":", "#", "`", "|", "{", "}", "[", "]", "/"] }

    /// Every line that carries untrusted text must be free of PlantUML-active characters.
    private func labelLines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .filter { $0.hasPrefix("rectangle") || $0.range(of: #"^n\d"#, options: .regularExpression) != nil }
            .map(String.init)
    }

    /// Untrusted payload of a PlantUML line: the label inside `rectangle "…" as nX`
    /// or the text after ` : ` on an edge line. Structural quotes and arrows are
    /// produced by the exporter itself and are not part of the payload.
    private func payloads(_ text: String) -> [String] {
        labelLines(text).map { line in
            if line.hasPrefix("rectangle") {
                let inner = line.dropFirst("rectangle \"".count)
                return String(inner.prefix(while: { $0 != "\"" }))
            }
            let parts = line.components(separatedBy: " : ")
            return parts.count > 1 ? parts[1] : ""
        }
    }

    func testMarkdownStructureAllDirectionsAndMarkers() {
        let nodes = [
            DiagramNode(id: "a", label: "Клиент"),
            DiagramNode(id: "b", label: "Сервер", uncertain: true),
            DiagramNode(id: "c", label: "Очередь"),
        ]
        let edges = [
            DiagramEdge(from: "a", to: "b", direction: .forward, label: "запрос"),
            DiagramEdge(from: "a", to: "c", direction: .backward),
            DiagramEdge(from: "b", to: "c", direction: .both, label: "обмен", uncertain: true),
            DiagramEdge(from: "a", to: "c", direction: .none),
        ]
        let text = DiagramExport.markdown(result(nodes: nodes, edges: edges), title: "Архитектура", warnings: ["Неточные подписи"])
        XCTAssertTrue(text.hasPrefix("# Архитектура\n"))
        XCTAssertTrue(text.contains("## Узлы"))
        XCTAssertTrue(text.contains("- Клиент\n"))
        XCTAssertTrue(text.contains("- Сервер (подпись нечитаема)"))
        XCTAssertTrue(text.contains("- Очередь"))
        XCTAssertTrue(text.contains("- Клиент → Сервер (запрос)"))
        XCTAssertTrue(text.contains("- Клиент ← Очередь"))
        XCTAssertTrue(text.contains("- Сервер ↔ Очередь (обмен) ⚠ не подтверждена"))
        XCTAssertTrue(text.contains("- Клиент — Очередь"))
        XCTAssertTrue(text.contains("## Предупреждения"))
        XCTAssertTrue(text.contains("- Неточные подписи"))
    }

    func testMarkdownOmitsWarningsSectionWhenEmpty() {
        let text = DiagramExport.markdown(result(nodes: [DiagramNode(id: "a", label: "Один")], edges: []),
                                          title: "Один узел")
        XCTAssertFalse(text.contains("Предупреждения"))
        XCTAssertTrue(text.contains("- Один"))
    }

    func testMarkdownEscapesUntrustedTextWithoutNewLines() {
        let nasty = "звёздочка * решётка # [скобки] <угол> `код` _подчёрк_ \nвторая строка"
        let text = DiagramExport.markdown(result(nodes: [DiagramNode(id: "a", label: nasty)], edges: []),
                                          title: nasty)
        XCTAssertTrue(text.contains("\\*"))
        XCTAssertTrue(text.contains("\\#"))
        XCTAssertTrue(text.contains("\\[скобки\\]"))
        XCTAssertTrue(text.contains("\\<угол\\>"))
        XCTAssertTrue(text.contains("\\`код\\`"))
        XCTAssertTrue(text.contains("\\_подчёрк\\_"))
        // The injected newline never creates an extra markdown line for the node.
        let nodeLine = text.split(separator: "\n").first { $0.hasPrefix("- ") }.map(String.init)!
        XCTAssertEqual(nodeLine, "- звёздочка \\* решётка \\# \\[скобки\\] \\<угол\\> \\`код\\` \\_подчёрк\\_  вторая строка")
        XCTAssertEqual(DiagramExport.markdown(result(nodes: [DiagramNode(id: "a", label: nasty)], edges: []), title: nasty),
                       DiagramExport.markdown(result(nodes: [DiagramNode(id: "a", label: nasty)], edges: []), title: nasty))
    }

    func testPlantumlStructureDirectionsAndDeterminism() {
        let nodes = [
            DiagramNode(id: "a", label: "Клиент"),
            DiagramNode(id: "b", label: "Сервер"),
            DiagramNode(id: "c", label: "База", uncertain: true),
        ]
        let edges = [
            DiagramEdge(from: "a", to: "b", direction: .forward, label: "запрос"),
            DiagramEdge(from: "b", to: "a", direction: .backward),
            DiagramEdge(from: "b", to: "c", direction: .both),
            DiagramEdge(from: "a", to: "c", direction: .none, label: "связь", uncertain: true),
        ]
        let (text, warnings) = DiagramExport.plantuml(result(nodes: nodes, edges: edges), title: "Архитектура")
        XCTAssertTrue(warnings.isEmpty)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "@startuml")
        XCTAssertEqual(lines.last, "@enduml")
        XCTAssertEqual(lines[1], "' Архитектура")
        XCTAssertEqual(lines[2], "rectangle \"Клиент\" as n0")
        XCTAssertEqual(lines[3], "rectangle \"Сервер\" as n1")
        XCTAssertEqual(lines[4], "rectangle \"База\" as n2")
        XCTAssertTrue(text.contains("n0 --> n1 : запрос"))
        XCTAssertTrue(text.contains("n1 <-- n0"))
        XCTAssertTrue(text.contains("n1 <--> n2"))
        XCTAssertTrue(text.contains("n0 .. n2 : связь"))
        let repeatExport = DiagramExport.plantuml(result(nodes: nodes, edges: edges), title: "Архитектура")
        XCTAssertEqual(text, repeatExport.text)
        XCTAssertEqual(warnings, repeatExport.warnings)
    }

    func testPlantumlUncertainEdgesAreDotted() {
        let nodes = [DiagramNode(id: "a", label: "A"), DiagramNode(id: "b", label: "B")]
        let edges = [
            DiagramEdge(from: "a", to: "b", direction: .forward, uncertain: true),
            DiagramEdge(from: "b", to: "a", direction: .backward, uncertain: true),
            DiagramEdge(from: "a", to: "b", direction: .both, uncertain: true),
        ]
        let (text, _) = DiagramExport.plantuml(result(nodes: nodes, edges: edges), title: "T")
        XCTAssertTrue(text.contains("n0 .-> n1"))
        XCTAssertTrue(text.contains("n1 .<- n0"))
        XCTAssertTrue(text.contains("n0 <.> n1"))
    }

    func testPlantumlNeutralizesInjectionsAndReportsWarnings() {
        let injections = ["!include /tmp/secret", "%getenv(PWD)", "@enduml\nskinparam backgroundColor red",
                          "<b>жирный</b>", "a&amp;b", "**важно**", "кавычка\"слэш\\", "таб\tперенос\nконец"]
        var nodes = injections.enumerated().map { DiagramNode(id: "n\($0.offset)", label: $0.element) }
        nodes.append(DiagramNode(id: "ok", label: "Кириллица сохраняется"))
        let edges = [DiagramEdge(from: "n0", to: "ok", direction: .forward, label: "метка с ! директивой")]
        let (text, warnings) = DiagramExport.plantuml(result(nodes: nodes, edges: edges), title: "инъекция ' \\ \" @end")
        XCTAssertFalse(warnings.isEmpty)
        for payload in payloads(text) {
            XCTAssertNil(payload.first(where: { bannedInLabels.contains($0) }), "не нейтрализовано: \(payload)")
        }
        // The injected @enduml never terminates the diagram early: exactly one terminator at the end.
        XCTAssertEqual(text.components(separatedBy: "@enduml").count - 1, 1)
        XCTAssertTrue(text.hasSuffix("@enduml\n"))
        // Cyrillic survives; newlines and tabs collapse to a single space.
        XCTAssertTrue(text.contains("rectangle \"Кириллица сохраняется\""))
        XCTAssertTrue(text.contains("перенос конец"))
        XCTAssertFalse(text.contains("\t"))
    }

    func testPlantumlDistinguishesIdenticalLabelsByAlias() {
        let nodes = [DiagramNode(id: "a", label: "Блок"), DiagramNode(id: "b", label: "Блок")]
        let (text, warnings) = DiagramExport.plantuml(result(nodes: nodes, edges: [DiagramEdge(from: "a", to: "b", direction: .forward)]), title: "T")
        XCTAssertTrue(text.contains("rectangle \"Блок\" as n0"))
        XCTAssertTrue(text.contains("rectangle \"Блок\" as n1"))
        XCTAssertTrue(text.contains("n0 --> n1"))
        XCTAssertTrue(warnings.isEmpty)
    }

    func testPlantumlSingleNodeWithoutEdges() {
        let (text, warnings) = DiagramExport.plantuml(result(nodes: [DiagramNode(id: "solo", label: "Единственный")], edges: []), title: "Единственный узел")
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(text, "@startuml\n' Единственный узел\nrectangle \"Единственный\" as n0\n@enduml\n")
    }

    func testPlantumlCollapsesLongSpaceRunsAndEmptyLabels() {
        var warnings: [String] = []
        XCTAssertEqual(DiagramExport.plantumlSafe("  несколько   пробелов \n\t здесь ", warnings: &warnings), "несколько пробелов здесь")
        XCTAssertTrue(warnings.isEmpty)
        // Control characters are removed without a warning; an empty label still renders a placeholder.
        XCTAssertEqual(DiagramExport.plantumlSafe("\n\t \u{0001}", warnings: &warnings), "?")
        XCTAssertTrue(warnings.isEmpty)
        // An unmappable character becomes «?» with exactly one warning.
        XCTAssertEqual(DiagramExport.plantumlSafe("цитата \"кавычки\"", warnings: &warnings), "цитата ?кавычки?")
        XCTAssertEqual(warnings.count, 1)
    }
}

/// Developer helper: writes representative .puml exports (Cyrillic labels,
/// escaped injections, all four directions, uncertain edges) for validation
/// with a local PlantUML CLI. Enabled only via LOCALSCRIBE_PUML_OUT.
final class DiagramPlantUMLSamplesTests: XCTestCase {
    func testWritePlantUMLSamplesForLocalValidation() throws {
        let output = ProcessInfo.processInfo.environment["LOCALSCRIBE_PUML_OUT"].map { URL(fileURLWithPath: $0) }
        let samples: [String: String] = [
            "cyrillic": DiagramExport.plantuml(DiagramResult(fingerprint: "f", language: "ru", nodes: [
                DiagramNode(id: "n1", label: "Начало"),
                DiagramNode(id: "n2", label: "Проверка данных"),
                DiagramNode(id: "n3", label: "Готово")
            ], edges: [
                DiagramEdge(from: "n1", to: "n2", direction: .forward, label: "запуск"),
                DiagramEdge(from: "n2", to: "n3", direction: .forward, label: "верно"),
                DiagramEdge(from: "n2", to: "n1", direction: .backward, label: "неверно")
            ]), title: "Русская блок-схема").text,
            "directions": DiagramExport.plantuml(DiagramResult(fingerprint: "f", language: "en", nodes: [
                DiagramNode(id: "n1", label: "Client"),
                DiagramNode(id: "n2", label: "API Gateway"),
                DiagramNode(id: "n3", label: "Database"),
                DiagramNode(id: "n4", label: "Cache")
            ], edges: [
                DiagramEdge(from: "n1", to: "n2", direction: .forward, label: "HTTPS"),
                DiagramEdge(from: "n2", to: "n3", direction: .both, label: "SQL"),
                DiagramEdge(from: "n3", to: "n4", direction: .none, label: "replication"),
                DiagramEdge(from: "n2", to: "n4", direction: .forward, label: "invalidate", uncertain: true)
            ]), title: "Architecture").text,
            "injections": DiagramExport.plantuml(DiagramResult(fingerprint: "f", language: "en", nodes: [
                DiagramNode(id: "n1", label: "!include /tmp/secret"),
                DiagramNode(id: "n2", label: "%getenv(PWD)"),
                DiagramNode(id: "n3", label: "@enduml skinparam backgroundColor red"),
                DiagramNode(id: "n4", label: "<b>bold</b> &amp; **creole** 'quote' \"quote\" \\backslash\ntab\there")
            ], edges: [
                DiagramEdge(from: "n1", to: "n2", direction: .forward, label: "label with ] bracket and | pipe")
            ]), title: "Injections").text,
            "single-node": DiagramExport.plantuml(DiagramResult(fingerprint: "f", language: "ru", nodes: [
                DiagramNode(id: "n1", label: "Единственный узел", uncertain: true)
            ], edges: []), title: "Один узел").text
        ]
        guard let output else { throw XCTSkip("Set LOCALSCRIBE_PUML_OUT to write samples") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, text) in samples {
            try text.data(using: .utf8)!.write(to: output.appendingPathComponent("\(name).puml"), options: .atomic)
        }
    }
}
