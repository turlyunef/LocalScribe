import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

/// Right-hand area of the diagrams mode: preview of the archived original,
/// recognized structure with warnings, and export.
struct DiagramDetailColumn: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: DiagramWorkspaceModel
    var requestDeletion: (String) -> Void

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil) { workspace.importProviders($0) }
    }

    @ViewBuilder private func diagramDetail(_ diagram: DiagramManifest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    RecordingTitleView(title: diagram.displayTitle, itemName: "схемы") { title in
                        Task { await model.renameDiagram(diagram.id, title: title) }
                    }
                    .id(diagram.id)
                    Button("Удалить схему", systemImage: "trash", role: .destructive) {
                        requestDeletion(diagram.id)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.deletingDiagramJobs)
                    .help("Удалить открытую схему")
                    .accessibilityIdentifier("diagrams.detail.delete")
                }
                Text("\(diagram.pixelWidth)×\(diagram.pixelHeight) · \(ByteCountFormatter.string(fromByteCount: diagram.byteSize, countStyle: .file)) · \(diagram.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                statusActions(diagram)
                Spacer()
                if workspace.result != nil { resultActions }
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
            if model.diagramQueuePosition(for: diagram.id) != nil {
                Button("Поднять на верх очереди") { model.moveToFrontOfQueue(.diagram(diagram.id)) }
                    .help("Распознать эту схему следующей после текущего задания")
                    .accessibilityIdentifier("diagrams.moveToFront")
            }
            switch diagram.state {
            case .waitingForModels:
                Button {
                    model.settingsWindow.show(tab: .diagrams)
                } label: {
                    Label("Открыть настройки", systemImage: "gear")
                }
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
        }
    }

    private var resultActions: some View {
        let parts = workspace.resultTabs + [.all]
        return HStack {
            Menu {
                ForEach(parts, id: \.self) { part in
                    Button(part.rawValue) { workspace.copy(part) }
                }
            } label: {
                Label("Копировать", systemImage: "doc.on.doc")
            } primaryAction: {
                workspace.copy(workspace.resultTab)
            }
            .accessibilityIdentifier("diagrams.copy")
            .help("Скопировать открытую вкладку")
            Menu("Сохранить", systemImage: "square.and.arrow.down") {
                ForEach(parts, id: \.self) { part in
                    Menu(part.rawValue) {
                        Button("Markdown (.md)") { workspace.presentExportPanel(part: part, format: .markdown) }
                        Button("Текст (.txt)") { workspace.presentExportPanel(part: part, format: .plainText) }
                    }
                }
                Button("PlantUML (.puml)") { workspace.presentExportPanel(part: .all, format: .plantuml) }
            }
            .accessibilityIdentifier("diagrams.save")
        }
        .controlSize(.small)
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
            Button("Показать изображение в Finder", systemImage: "folder") {
                workspace.showImageInFinder(diagram)
            }
            .controlSize(.small)
            .accessibilityIdentifier("diagrams.showImageInFinder")
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func structureSection(_ diagram: DiagramManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Распознанная структура").font(.headline)
            if let result = workspace.result {
                Picker("Раздел результата", selection: Binding(
                    get: { workspace.resultTab }, set: workspace.selectResultTab
                )) {
                    ForEach(workspace.resultTabs, id: \.self) { part in
                        Text(part.rawValue).tag(part)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .accessibilityIdentifier("diagrams.resultTabs")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        switch workspace.resultTab {
                        case .nodes:
                            ForEach(result.nodes) { node in
                                HStack(spacing: 6) {
                                    Image(systemName: node.uncertain ? "questionmark.square.dashed" : "square")
                                        .foregroundStyle(node.uncertain ? .orange : .secondary)
                                    Text(node.label)
                                    if node.uncertain { Text("подпись нечитаема").font(.caption2).foregroundStyle(.orange) }
                                }.accessibilityIdentifier("diagrams.node.\(node.id)")
                            }
                        case .edges:
                            if result.edges.isEmpty {
                                Text("Связи не распознаны").foregroundStyle(.secondary)
                            }
                            ForEach(Array(result.edges.enumerated()), id: \.offset) { _, edge in edgeRow(edge) }
                        case .warnings:
                            ForEach(Array(diagram.warnings.enumerated()), id: \.offset) { _, warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        case .all:
                            EmptyView()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(workspace.resultTab)
            } else if let error = workspace.resultError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    .accessibilityIdentifier("diagrams.resultError.\(diagram.id)")
            } else if diagram.state.processing || diagram.state == .queued {
                Label("Структура появится после распознавания", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
            } else if diagram.activeRunId == nil {
                Text("Схема ещё не распознана").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func edgeRow(_ edge: DiagramEdge) -> some View {
        HStack(spacing: 6) {
            Text("\(workspace.edgeLabel(edge.from)) \(edge.symbol) \(workspace.edgeLabel(edge.to))")
            if let text = edge.label { Text("(\(text))").foregroundStyle(.secondary) }
            if let kind = edge.kind { Text(kind.title).font(.caption).foregroundStyle(.secondary) }
            if edge.uncertain { Text("не подтверждена").font(.caption2).foregroundStyle(.orange) }
        }.font(.callout)
    }
}
