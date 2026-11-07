import SwiftUI
import AppKit
import LocalScribeCore

/// Right-hand area of the diagrams mode: preview of the archived original,
/// recognized structure with warnings, and export.
struct DiagramDetailColumn: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: DiagramWorkspaceModel
    var body: some View {
        Group {
            if let diagram = workspace.selected {
                diagramDetail(diagram)
            } else {
                ContentUnavailableView {
                    Label("Схема не выбрана", systemImage: "square.grid.2x2")
                } description: {
                    Text("Загрузите изображение блок-схемы или архитектурной схемы (PNG или JPEG)")
                } actions: {
                    Button("Загрузить изображение", action: workspace.presentImportPanel)
                        .accessibilityIdentifier("diagrams.emptyImport")
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder private func diagramDetail(_ diagram: DiagramManifest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(diagram.displayTitle).font(.title2.weight(.semibold)).lineLimit(2)
                    Text("\(diagram.pixelWidth)×\(diagram.pixelHeight) · \(ByteCountFormatter.string(fromByteCount: diagram.byteSize, countStyle: .file)) · \(diagram.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusActions(diagram)
            }
            if workspace.showsPreviousVersion {
                Label("Идёт повторное распознавание: показана предыдущая проверенная версия", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("diagrams.previousVersion")
            }
            if let message = diagram.lastError {
                Label(message, systemImage: "exclamationmark.bubble").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("diagrams.lastError.\(diagram.id)")
            }
            HStack(alignment: .top, spacing: 16) {
                previewSection(diagram)
                structureSection(diagram)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func statusActions(_ diagram: DiagramManifest) -> some View {
        HStack(spacing: 10) {
            switch diagram.state {
            case .waitingForModels:
                SettingsLink { Label("Открыть настройки", systemImage: "gear") }
                    .accessibilityIdentifier("diagrams.openSettings")
                Button("Распознать") { Task { await model.recognizeDiagram(diagram.id) } }
                    .disabled(!model.diagramModelsReady)
                    .help(model.diagramModelsReady ? "Распознать схему локально" : "Сначала загрузите модель схем в настройках")
                    .accessibilityIdentifier("diagrams.recognize")
            case .queued, .recognizing:
                Button("Отменить", role: .destructive) { Task { await model.cancelDiagram(diagram.id) } }
                    .accessibilityIdentifier("diagrams.cancel")
            case .completed, .completedWithWarnings, .failed, .interrupted, .cancelled:
                Button(diagram.activeRunId == nil ? "Распознать" : "Распознать заново") { Task { await model.recognizeDiagram(diagram.id) } }
                    .disabled(!model.diagramModelsReady)
                    .help(model.diagramModelsReady ? "Создать новую попытку распознавания" : "Сначала загрузите модель схем в настройках")
                    .accessibilityIdentifier("diagrams.rerun")
            }
            if workspace.result != nil {
                Menu("Сохранить", systemImage: "square.and.arrow.down") {
                    ForEach(DiagramExportFormat.allCases, id: \.rawValue) { format in
                        Button(format.title) { workspace.presentExportPanel(format: format) }
                    }
                }.accessibilityIdentifier("diagrams.save")
            }
        }
    }

    @ViewBuilder private func previewSection(_ diagram: DiagramManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Оригинал").font(.headline)
            if let preview = workspace.preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Предпросмотр схемы \(diagram.displayTitle)")
                    .accessibilityIdentifier("diagrams.preview.\(diagram.id)")
            } else if workspace.previewError != nil {
                Label(workspace.previewError ?? "", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func structureSection(_ diagram: DiagramManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Распознанная структура").font(.headline)
                Spacer()
                if diagram.state == .completedWithWarnings || !diagram.warnings.isEmpty {
                    Label("с предупреждениями", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if diagram.state.processing || diagram.state == .queued {
                Label("Структура появится после распознавания", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
            } else if let result = workspace.result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(result.nodes) { node in
                            HStack(spacing: 6) {
                                Image(systemName: node.uncertain ? "questionmark.square.dashed" : "square")
                                    .foregroundStyle(node.uncertain ? .orange : .secondary)
                                Text(node.label)
                                if node.uncertain { Text("подпись нечитаема").font(.caption2).foregroundStyle(.orange) }
                            }.accessibilityIdentifier("diagrams.node.\(node.id)")
                        }
                        Divider()
                        ForEach(Array(result.edges.enumerated()), id: \.offset) { _, edge in
                            edgeRow(result, edge)
                        }
                        if !diagram.warnings.isEmpty {
                            Divider()
                            ForEach(Array(diagram.warnings.enumerated()), id: \.offset) { _, warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let error = workspace.resultError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    .accessibilityIdentifier("diagrams.resultError.\(diagram.id)")
            } else if diagram.activeRunId == nil {
                Text("Схема ещё не распознана").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func edgeRow(_ result: DiagramResult, _ edge: DiagramEdge) -> some View {
        func label(_ id: String) -> String {
            result.nodes.first { $0.id == id }?.label ?? id
        }
        let arrow: String
        switch edge.direction {
        case .forward: arrow = "→"
        case .backward: arrow = "←"
        case .both: arrow = "↔"
        case .none: arrow = "—"
        }
        return HStack(spacing: 6) {
            Image(systemName: edge.uncertain ? "arrow.triangle.2.circlepath.dashed" : "arrow.right")
                .foregroundStyle(edge.uncertain ? .orange : .secondary)
            Text("\(label(edge.from)) \(arrow) \(label(edge.to))")
            if let text = edge.label { Text("(\(text))").foregroundStyle(.secondary) }
            if edge.uncertain { Text("не подтверждена").font(.caption2).foregroundStyle(.orange) }
        }.font(.callout)
    }
}
