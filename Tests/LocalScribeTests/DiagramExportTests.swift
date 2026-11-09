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

    func testMarkdownAndPlainTextExportEachSectionAndAllWithWarnings() {
        let diagram = result(
            nodes: [DiagramNode(id: "a", label: "Узел *A*"), DiagramNode(id: "b", label: "Узел B")],
            edges: [DiagramEdge(from: "a", to: "b", direction: .forward, label: "Обмен", uncertain: true)]
        )
        let sections = DiagramExportPart.sections(includingWarnings: true)
        let warnings = ["Сверьте [стрелку]\nс оригиналом"]
        for markdown in [false, true] {
            func render(_ part: DiagramExportPart, warnings: [String]) -> String {
                if markdown { return DiagramExport.markdown(diagram, title: "Схема", warnings: warnings, part: part) }
                return DiagramExport.plainText(diagram, title: "Схема", warnings: warnings, part: part)
            }
            for part in sections + [.all] {
                let rendered = render(part, warnings: warnings)
                let included = sections.filter { part == .all || $0 == part }
                XCTAssertEqual(rendered.split(separator: "\n").map(String.init).filter { line in
                    sections.contains { line == (markdown ? "## " : "") + $0.rawValue }
                }, included.map { (markdown ? "## " : "") + $0.rawValue })
                XCTAssertEqual(rendered.contains(markdown ? "- Узел \\*A\\*\n" : "- Узел *A*\n"), included.contains(.nodes))
                XCTAssertEqual(rendered.contains("(Обмен) ⚠ не подтверждена"), included.contains(.edges))
                let warning = markdown ? "- Сверьте \\[стрелку\\] с оригиналом" : "- Сверьте [стрелку] с оригиналом"
                XCTAssertEqual(rendered.components(separatedBy: warning).count - 1, included.contains(.warnings) ? 1 : 0)
            }
            XCTAssertFalse(render(.all, warnings: []).contains("Предупреждения"))
        }
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

    func testUMLConnectorsKeepMarkedEndpointsAndMultilineLabels() throws {
        let nodes = [
            DiagramNode(id: "house", label: "House\n- wall1 : Wall"),
            DiagramNode(id: "wall", label: "Wall"),
            DiagramNode(id: "bird", label: "«interface»\nBird\n+ fly()"),
            DiagramNode(id: "raven", label: "Raven"),
        ]
        let edges = [
            DiagramEdge(from: "house", to: "wall", direction: .backward, label: "4 .. *", kind: .composition),
            DiagramEdge(from: "bird", to: "house", direction: .forward, kind: .aggregation),
            DiagramEdge(from: "raven", to: "bird", direction: .forward, uncertain: true, kind: .realization),
            DiagramEdge(from: "raven", to: "house", direction: .forward, kind: .generalization),
            DiagramEdge(from: "wall", to: "raven", direction: .forward, kind: .dependency),
            DiagramEdge(from: "wall", to: "house", direction: .forward, kind: .containment),
            DiagramEdge(from: "house", to: "bird", direction: .none, kind: .association),
        ]
        let graph = result(nodes: nodes, edges: edges)
        try graph.validate(expectedFingerprint: graph.fingerprint)
        let output = DiagramExport.plantuml(graph, title: "UML")
        XCTAssertTrue(output.warnings.isEmpty)
        for line in [
            #"rectangle "House\n- wall1 <U+003A> Wall" as n0"#,
            #"rectangle "<U+00AB>interface<U+00BB>\nBird\n+ fly()" as n2"#,
            "n1 --* n0 : 4 .. <U+002A>", "n2 --o n0", "n3 -[#orange,dashed]-|> n2",
            "n3 --|> n0", "n1 ..> n3", "n1 --+ n0", "n0 -- n2",
        ] {
            XCTAssertTrue(output.text.split(separator: "\n").contains(Substring(line)), line)
        }
        let markdown = DiagramExport.markdown(graph, title: "UML")
        XCTAssertTrue(markdown.contains("◆— Wall (4 .. \\*) · Композиция"))
        XCTAssertTrue(markdown.contains("Реализация ⚠ не подтверждена"))
    }

    func testSequenceExportsOrderedRequestsAndReturns() throws {
        let graph = Self.sequenceSample
        try graph.validate(expectedFingerprint: graph.fingerprint)
        let output = DiagramExport.plantuml(graph, title: "Обмен")
        XCTAssertEqual(output.text.split(separator: "\n").dropFirst(2).map(String.init), [
            "participant \"Браузер\" as n0", "participant \"Балансировщик\" as n1", "participant \"Сервер\" as n2",
            "n0 -> n1 : Запрос", "n1 -> n2 : Запрос", "n2 -->> n1 : Ответ", "n1 --[#orange]>> n0 : Ответ", "@enduml",
        ])
        XCTAssertTrue(output.warnings.isEmpty)
    }

    static var sequenceSample: DiagramResult {
        DiagramResult(fingerprint: "abc", kind: .sequence, nodes: [
            DiagramNode(id: "browser", label: "Браузер"),
            DiagramNode(id: "balancer", label: "Балансировщик"),
            DiagramNode(id: "server", label: "Сервер"),
        ], edges: [
            DiagramEdge(from: "browser", to: "balancer", direction: .forward, label: "Запрос", kind: .message),
            DiagramEdge(from: "balancer", to: "server", direction: .forward, label: "Запрос", kind: .message),
            DiagramEdge(from: "balancer", to: "server", direction: .backward, label: "Ответ", kind: .reply),
            DiagramEdge(from: "balancer", to: "browser", direction: .forward, label: "Ответ", uncertain: true, kind: .reply),
        ])
    }

    func testLegacyResultWithoutKindsStillDecodesAndExports() throws {
        let json = #"""
        {"schemaVersion":1,"fingerprint":"legacy","nodes":[{"id":"a","label":"A","uncertain":false}],
         "edges":[{"from":"a","to":"a","direction":"none","uncertain":false}]}
        """#
        let graph = try JSONDecoder().decode(DiagramResult.self, from: Data(json.utf8))
        try graph.validate(expectedFingerprint: "legacy")
        XCTAssertNil(graph.kind)
        XCTAssertNil(graph.edges.first?.kind)
        XCTAssertTrue(DiagramExport.plantuml(graph, title: "Legacy").text.contains("n0 -- n0"))
    }

    func testPlantumlNeutralizesInjectionsAndReportsWarnings() {
        let injections = ["!include /tmp/secret", "%getenv(PWD)", "@enduml\nskinparam backgroundColor red",
                          "<b>жирный</b>", "<U+0021>include", "a&amp;b", "**важно**", "кавычка\"слэш\\", "таб\tперенос\nконец"]
        var nodes = injections.enumerated().map { DiagramNode(id: "n\($0.offset)", label: $0.element) }
        nodes.append(DiagramNode(id: "ok", label: "Кириллица сохраняется"))
        let edges = [DiagramEdge(from: "n0", to: "ok", direction: .forward, label: "метка с ! директивой")]
        let (text, warnings) = DiagramExport.plantuml(result(nodes: nodes, edges: edges), title: "инъекция ' \\ \" @end")
        XCTAssertFalse(warnings.isEmpty)
        for payload in payloads(text) {
            let input = payload.replacingOccurrences(of: #"\\n|<U\+(?:002A|003A|0023|005B|005D|00AB|00BB)>"#,
                                                     with: "", options: .regularExpression)
            XCTAssertNil(input.first(where: { bannedInLabels.contains($0) }), "не нейтрализовано: \(payload)")
        }
        // The injected @enduml never terminates the diagram early: exactly one terminator at the end.
        XCTAssertEqual(text.components(separatedBy: "@enduml").count - 1, 1)
        XCTAssertTrue(text.hasSuffix("@enduml\n"))
        // The exporter owns the newline escape; raw tabs are removed.
        XCTAssertTrue(text.contains("rectangle \"Кириллица сохраняется\""))
        XCTAssertTrue(text.contains(#"перенос\nконец"#))
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
            "sequence": DiagramExport.plantuml(DiagramExportTests.sequenceSample, title: "Обмен").text,
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
