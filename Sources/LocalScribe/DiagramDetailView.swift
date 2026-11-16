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
                    Label(L10n.text("Схема не выбрана"), systemImage: "square.grid.2x2")
                } description: {
                    Text(L10n.text("Загрузите изображение блок-схемы или архитектурной схемы (PNG или JPEG)"))
                } actions: {
                    Button(L10n.text("Загрузить изображение"), action: workspace.presentImportPanel)
                        .accessibilityIdentifier("diagrams.emptyImport")
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil) { workspace.importProviders($0) }
    }

    @ViewBuilder private func diagramDetail(_ diagram: DiagramManifest) -> some View {
        VStack(spacing: 0) {
            ArchiveDetailHeader {
                RecordingTitleView(title: diagram.displayTitle, itemName: L10n.text("схемы"), reservesTwoLines: true) { title in
                    Task { await model.renameDiagram(diagram.id, title: title) }
                }
                .id(diagram.id)
            } actions: {
                diagramActions(diagram)
            } result: {
                Text("\(diagram.pixelWidth)×\(diagram.pixelHeight) · \(diagram.byteSize.formatted(.byteCount(style: .file).locale(L10n.locale))) · \(diagram.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } resultActions: {
                if workspace.result != nil { resultActions }
            }
            Divider()
            diagramContent(diagram)
                .padding(20)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func diagramActions(_ diagram: DiagramManifest) -> some View {
        HStack(spacing: 8) {
            Button(L10n.text("Показать изображение в Finder")) {
                workspace.showImageInFinder(diagram)
            }
            .help(L10n.text("Показать исходное изображение в Finder"))
            .accessibilityIdentifier("diagrams.showImageInFinder")
            statusActions(diagram)
            Button(role: .destructive) {
                requestDeletion(diagram.id)
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .disabled(model.deletingDiagramJobs)
            .help(L10n.text("Удалить открытую схему"))
            .accessibilityLabel(L10n.text("Удалить схему"))
            .accessibilityIdentifier("diagrams.detail.delete")
        }
        .controlSize(.small)
        .fixedSize()
    }

    private func diagramContent(_ diagram: DiagramManifest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if workspace.showsPreviousVersion {
                Label(L10n.text("Идёт повторное распознавание: показана предыдущая проверенная версия"), systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("diagrams.previousVersion")
            }
            if let message = diagram.lastError {
                Label(L10n.message(message), systemImage: "exclamationmark.bubble").font(.caption).foregroundStyle(.secondary)
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
        HStack(spacing: 8) {
            if model.diagramQueuePosition(for: diagram.id) != nil {
                Button(L10n.text("Поднять на верх очереди")) { model.moveToFrontOfQueue(.diagram(diagram.id)) }
                    .help(L10n.text("Распознать эту схему следующей после текущего задания"))
                    .accessibilityIdentifier("diagrams.moveToFront")
            }
            switch diagram.state {
            case .waitingForModels:
                Button {
                    model.settingsWindow.show(tab: .diagrams)
                } label: {
                    Label(L10n.text("Открыть настройки"), systemImage: "gear")
                }
                .accessibilityIdentifier("diagrams.openSettings")
                Button(L10n.text("Распознать")) { Task { await model.recognizeDiagram(diagram.id) } }
                    .disabled(!model.diagramModelsReady)
                    .help(model.diagramModelsReady ? L10n.text("Распознать схему локально") : L10n.text("Сначала загрузите модель схем в настройках"))
                    .accessibilityIdentifier("diagrams.recognize")
            case .queued, .recognizing:
                Button(L10n.text("Отменить"), role: .destructive) { Task { await model.cancelDiagram(diagram.id) } }
                    .accessibilityIdentifier("diagrams.cancel")
            case .completed, .completedWithWarnings, .failed, .interrupted, .cancelled:
                Button(diagram.activeRunId == nil ? L10n.text("Распознать") : L10n.text("Распознать заново")) { Task { await model.recognizeDiagram(diagram.id) } }
                    .disabled(!model.diagramModelsReady)
                    .help(model.diagramModelsReady ? L10n.text("Создать новую попытку распознавания") : L10n.text("Сначала загрузите модель схем в настройках"))
                    .accessibilityIdentifier("diagrams.rerun")
            }
        }
    }

    @ViewBuilder private var resultActions: some View {
        let parts = workspace.resultTabs + [.all]
        ArchiveResultMenu(icon: "doc.on.doc", title: L10n.text("Копировать"),
                          help: L10n.text("Копировать результат"), identifier: "diagrams.copy") {
            ForEach(parts, id: \.self) { part in
                Button(part.title) { workspace.copy(part) }
            }
        }
        ArchiveResultMenu(icon: "square.and.arrow.up", title: L10n.text("Экспорт"),
                          help: L10n.text("Экспорт"), identifier: "diagrams.save") {
            ForEach(parts, id: \.self) { part in
                Menu(part.title) {
                    Button("Markdown (.md)") { workspace.presentExportPanel(part: part, format: .markdown) }
                    Button(L10n.text("Текст (.txt)")) { workspace.presentExportPanel(part: part, format: .plainText) }
                }
            }
            Button("PlantUML (.puml)") { workspace.presentExportPanel(part: .all, format: .plantuml) }
        }
    }

    @ViewBuilder private func previewSection(_ diagram: DiagramManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Оригинал")).font(.headline)
            if let preview = workspace.preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(L10n.text("Предпросмотр схемы %1$@", diagram.displayTitle))
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
            Text(L10n.text("Распознанная структура")).font(.headline)
            if let result = workspace.result {
                Picker(L10n.text("Раздел результата"), selection: Binding(
                    get: { workspace.resultTab }, set: workspace.selectResultTab
                )) {
                    ForEach(workspace.resultTabs, id: \.self) { part in
                        Text(part.title).tag(part)
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
                                    if node.uncertain { Text(L10n.text("подпись нечитаема")).font(.caption2).foregroundStyle(.orange) }
                                }.accessibilityIdentifier("diagrams.node.\(node.id)")
                            }
                        case .edges:
                            if result.edges.isEmpty {
                                Text(L10n.text("Связи не распознаны")).foregroundStyle(.secondary)
                            }
                            ForEach(Array(result.edges.enumerated()), id: \.offset) { _, edge in edgeRow(edge) }
                        case .warnings:
                            ForEach(Array(diagram.warnings.enumerated()), id: \.offset) { _, warning in
                                Label(L10n.message(warning), systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        case .all:
                            EmptyView()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(workspace.resultTab)
            } else if let error = workspace.resultError {
                Label(L10n.message(error), systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    .accessibilityIdentifier("diagrams.resultError.\(diagram.id)")
            } else if diagram.state.processing || diagram.state == .queued {
                Label(L10n.text("Структура появится после распознавания"), systemImage: "sparkles")
                    .foregroundStyle(.secondary)
            } else if diagram.activeRunId == nil {
                Text(L10n.text("Схема ещё не распознана")).foregroundStyle(.secondary)
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
            if edge.uncertain { Text(L10n.text("не подтверждена")).font(.caption2).foregroundStyle(.orange) }
        }.font(.callout)
    }
}
