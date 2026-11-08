import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

struct DiagramGroupsSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: DiagramWorkspaceModel
    @ObservedObject private var search: RecordingSearch
    @Binding private var mode: WorkspaceMode
    @Binding private var deletingDiagrams: SidebarDiagramDeletion?
    init(model: AppModel, workspace: DiagramWorkspaceModel, mode: Binding<WorkspaceMode>,
         deletion: Binding<SidebarDiagramDeletion?>) {
        self.model = model; self.workspace = workspace; self.search = model.diagramSearch
        _mode = mode
        _deletingDiagrams = deletion
    }
    @State private var editor: GroupNameDraft?
    @State private var deletingGroup: RecordingGroup?
    @State private var renaming: DiagramManifest?
    @State private var draggedDiagram: String?
    @State private var draggedGroup: String?

    var body: some View {
        VStack(spacing: 0) {
            SidebarWorkspaceHeader(mode: $mode) {
                expansionButton(expanded: true)
                expansionButton(expanded: false)
                SidebarActionButton(icon: "folder.badge.plus", title: "Добавить группу схем", identifier: "diagrams.groups.add") {
                    if editor == nil { editor = GroupNameDraft(groupID: nil, name: "") }
                }
                .disabled(model.deletingDiagramJobs)
            } archiveActions: {
                SidebarActionButton(icon: "photo.badge.plus", title: "Загрузить изображение", identifier: "diagrams.import",
                                    iconVerticalOffset: 2, action: workspace.presentImportPanel)
                SidebarEmptyAction()
            }
            RecordingSearchField(search: search, identifierPrefix: "diagrams", placeholder: "Поиск по названиям",
                                 label: "Поиск по названиям схем", shortcutActive: true)
                .padding(.horizontal, 12).padding(.bottom, 8)
            if search.active && search.completed {
                SidebarSearchStatus(
                    countTitle: "Найдено: \(search.matchingIDs.count)",
                    countIdentifier: "diagrams.search.count",
                    emptyTitle: "Схемы не найдены",
                    emptyHint: "Попробуйте другое название или очистите поиск",
                    emptyIdentifier: "diagrams.search.empty",
                    empty: search.matchingIDs.isEmpty)
            }
            SidebarLazyScrollColumn(focusTarget: editor?.id, revealTarget: workspace.sidebarRevealID) {
                if let draft = editor, draft.groupID == nil { nameEditor(draft).id(draft.id) }
                ForEach(workspace.sidebarGroups(editing: editor?.groupID)) { group in
                    if !search.active {
                        DiagramGroupInsertionLine(workspace: workspace, before: group.id, draggedGroup: $draggedGroup)
                    }
                    SidebarDropArea(of: [DiagramTransferTypes.diagram]) { targeted in
                        DiagramGroupDrop(workspace: workspace, groupID: group.id, draggedDiagram: draggedDiagram, targeted: targeted)
                    } content: { targeted in
                        if let draft = editor, draft.groupID == group.id {
                            nameEditor(draft).id(draft.id)
                        } else {
                            DiagramGroupHeader(workspace: workspace, group: group,
                                draggedGroup: $draggedGroup, dropTargeted: targeted,
                                rename: { editor = GroupNameDraft(groupID: group.id, name: group.name) },
                                delete: { deletingGroup = group })
                        }
                        if search.expanded(group) {
                            let members = workspace.visibleDiagrams(in: group.id)
                            if members.isEmpty {
                                Text("Загрузите изображение, чтобы добавить схему")
                                    .accessibilityIdentifier("diagrams.groups.empty.\(group.id)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 10)
                            }
                            ForEach(members) { diagram in
                                SidebarDiagramRow(model: model, diagram: diagram)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 28).padding(.trailing, 10)
                                .contentShape(Rectangle())
                                .onTapGesture {}
                                .focusable()
                                .focusEffectDisabled()
                                .onKeyPress(.return) { workspace.selectSidebarDiagram(diagram.id); return .handled }
                                .onKeyPress(.space) { workspace.selectSidebarDiagram(diagram.id); return .handled }
                                .accessibilityElement(children: .contain)
                                .accessibilityAction { workspace.selectSidebarDiagram(diagram.id) }
                                .accessibilityAddTraits(workspace.sidebarSelection.ids.contains(diagram.id) ? .isSelected : [])
                                .background(workspace.sidebarSelection.ids.contains(diagram.id) ? Color.accentColor.opacity(0.16) : Color.clear)
                                .background(SidebarMouseSelection { event in
                                    if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                                        workspace.selectSidebarContext(diagram.id)
                                    } else {
                                        workspace.selectSidebarDiagram(diagram.id,
                                            command: event.modifierFlags.contains(.command),
                                            shift: event.modifierFlags.contains(.shift))
                                    }
                                })
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityIdentifier("diagrams.sidebar.diagram.\(diagram.id)")
                                .onDrag {
                                    workspace.selectSidebarContext(diagram.id)
                                    draggedGroup = nil; draggedDiagram = diagram.id
                                    return SidebarItemTransfer.provider(diagram.id, type: DiagramTransferTypes.diagram)
                                }
                                .dragConfiguration(DragConfiguration(allowMove: true))
                                .contextMenu {
                                    DiagramContextMenuItems(workspace: workspace, diagramID: diagram.id,
                                        rename: { renaming = diagram },
                                        delete: { ids in
                                            SidebarDiagramDeletion.request(ids, model: model, presentation: $deletingDiagrams)
                                        })
                                }
                                .id(diagram.id)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $deletingGroup) { group in
            DeleteDiagramGroupView(workspace: workspace, model: model, group: group) { deletingGroup = nil }
        }
        .sheet(item: $deletingDiagrams) { deletion in
            DeleteDiagramsView(workspace: workspace, ids: deletion.ids) { deletingDiagrams = nil }
        }
        .sheet(item: $renaming) { diagram in
            RenameDiagramView(workspace: workspace, diagram: diagram) { renaming = nil }
        }
    }
    private func nameEditor(_ draft: GroupNameDraft) -> some View {
        GroupNameEditor(draft: draft, placeholder: "Название группы схем",
            fieldIdentifier: "diagrams.groups.name", errorIdentifier: "diagrams.groups.name.error",
            save: { name in
                try await workspace.saveGroupName(name, id: draft.groupID)
                editor = nil
            }, cancel: { editor = nil }).id(draft.id)
    }
    private func expansionButton(expanded: Bool) -> some View {
        SidebarExpansionButton(
            expanded: expanded,
            title: expanded ? "Развернуть все группы схем" : "Свернуть все группы схем",
            identifier: expanded ? "diagrams.groups.expandAll" : "diagrams.groups.collapseAll",
            disabled: model.deletingDiagramJobs) {
            Task { await workspace.setAllSidebarExpanded(expanded) }
        }
    }
}

private struct SidebarDiagramRow: View {
    @ObservedObject var model: AppModel
    let diagram: DiagramManifest
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(diagram.displayTitle).lineLimit(2).fontWeight(.medium)
            Text("\(diagram.pixelWidth)×\(diagram.pixelHeight) · \(diagram.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if diagram.state == .queued, let position = model.diagramQueuePosition(for: diagram.id) {
                    Text("\(position)").foregroundStyle(.red).accessibilityLabel("Место в очереди: \(position)").accessibilityIdentifier("diagrams.queuePosition.\(diagram.id)")
                }
                Label(diagram.state.title, systemImage: statusIcon)
                    .foregroundStyle(diagram.state == .failed ? .red : .secondary)
                    .accessibilityIdentifier("diagrams.status.\(diagram.id)")
            }.font(.caption)
        }.padding(.vertical, 5)
    }
    private var statusIcon: String {
        switch diagram.state {
        case .recognizing: return "sparkles"
        case .completed, .completedWithWarnings: return "checkmark.circle"
        case .waitingForModels: return "arrow.down.circle"
        case .queued: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        case .interrupted, .cancelled: return "clock.badge.exclamationmark"
        }
    }
}

private struct DiagramContextMenuItems: View {
    @ObservedObject var workspace: DiagramWorkspaceModel
    let diagramID: String
    let rename: () -> Void
    let delete: (Set<String>) -> Void
    var body: some View {
        Menu("Переместить в") {
            let ids = workspace.sidebarActionIDs(for: diagramID)
            ForEach(workspace.model.diagramGroups.groups.filter { target in
                ids.contains { workspace.model.diagramGroups.groupID(for: $0) != target.id }
            }) { target in
                Button(target.name) { Task { await workspace.model.moveDiagrams(ids, to: target.id) } }
            }
        }
        Divider()
        Button("Переименовать…", action: rename)
        let ids = workspace.sidebarActionIDs(for: diagramID)
        Button(ids.count > 1 ? "Удалить выбранные схемы…" : "Удалить схему…", role: .destructive) {
            delete(ids)
        }
    }
}

private struct DiagramGroupHeader: View {
    @ObservedObject var workspace: DiagramWorkspaceModel
    let group: RecordingGroup
    @Binding var draggedGroup: String?
    let dropTargeted: Bool
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 5) {
            if !group.isSystem && !workspace.search.active {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 14).opacity(hovered ? 1 : 0)
                    .help("Перетащите, чтобы изменить порядок групп")
                    .accessibilityLabel("Переставить группу \(group.name)")
                    .onDrag {
                        draggedGroup = group.id
                        return SidebarItemTransfer.provider(group.id, type: DiagramTransferTypes.group)
                    }
                    .dragConfiguration(DragConfiguration(allowMove: true))
            } else { Color.clear.frame(width: 14, height: 14) }
            Button {
                Task { await workspace.setSidebarExpanded(group) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: workspace.search.expanded(group) ? "chevron.down" : "chevron.right").frame(width: 10)
                    Text(dropTargeted ? "Отпустите → \(group.name)" : "\(group.name) · \(workspace.sidebarGroupCount(group.id))")
                        .lineLimit(1).contentTransition(.opacity)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityIdentifier("diagrams.groups.header.\(group.id)")
                .accessibilityLabel("\(group.name), схем: \(workspace.sidebarGroupCount(group.id))")
            if !group.isSystem {
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red)
                    .opacity(hovered ? 1 : 0)
                    .help("Удалить группу схем").accessibilityLabel("Удалить группу \(group.name)")
                    .accessibilityIdentifier("diagrams.groups.delete.\(group.id)")
                    .disabled(workspace.model.deletingDiagramJobs)
            }
            Image(systemName: dropTargeted ? "arrow.down.to.line" : "checkmark").frame(width: 16)
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.primary)
                .opacity(dropTargeted || workspace.model.diagramGroups.defaultID == group.id ? 1 : 0)
                .help(dropTargeted ? "Отпустите для добавления в группу" : "Группа для новых схем")
        }
        .font(.subheadline.weight(.semibold)).padding(.vertical, 8).padding(.horizontal, 6)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Сделать группой по умолчанию") {
                Task { await workspace.model.changeDiagramGroups { try $0.setDefault(group.id) } }
            }.disabled(workspace.model.diagramGroups.defaultID == group.id)
            if !group.isSystem {
                Button("Переименовать", action: rename)
                Button("Удалить группу", role: .destructive, action: delete)
                    .disabled(workspace.model.deletingDiagramJobs)
            }
        }
    }
}

@MainActor private struct DiagramGroupDrop: DropDelegate {
    let workspace: DiagramWorkspaceModel
    let groupID: String
    let draggedDiagram: String?
    @Binding var targeted: Bool
    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [DiagramTransferTypes.diagram]) else { return false }
        return draggedDiagram.map { workspace.model.diagramGroups.groupID(for: $0) != groupID } ?? true
    }
    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: [DiagramTransferTypes.diagram]).first else { return false }
        SidebarItemTransfer.load(provider, type: DiagramTransferTypes.diagram) { id in
            Task { await workspace.model.moveDiagrams([id], to: groupID) }
        }
        return true
    }
}

private struct DiagramGroupInsertionLine: View {
    @ObservedObject var workspace: DiagramWorkspaceModel
    let before: String
    @Binding var draggedGroup: String?
    @State private var targeted = false
    var body: some View {
        Rectangle().fill(targeted && draggedGroup != before ? Color.accentColor : Color.clear)
            .frame(height: 3).padding(.vertical, 3).contentShape(Rectangle())
            .onDrop(of: [DiagramTransferTypes.group], delegate: DiagramGroupOrderDrop(
                workspace: workspace, before: before, draggedGroup: draggedGroup, targeted: $targeted))
    }
}

@MainActor private struct DiagramGroupOrderDrop: DropDelegate {
    let workspace: DiagramWorkspaceModel
    let before: String
    let draggedGroup: String?
    @Binding var targeted: Bool
    func validateDrop(info: DropInfo) -> Bool {
        !workspace.search.active && draggedGroup != before && draggedGroup != RecordingGroup.ungroupedID
            && info.hasItemsConforming(to: [DiagramTransferTypes.group])
    }
    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info), let provider = info.itemProviders(for: [DiagramTransferTypes.group]).first else { return false }
        SidebarItemTransfer.load(provider, type: DiagramTransferTypes.group) { id in
            guard !workspace.search.active else { return }
            Task { await workspace.model.changeDiagramGroups { try $0.move(id, before: before) } }
        }
        return true
    }
}

struct SidebarDiagramDeletion: Identifiable {
    let id = UUID()
    let ids: Set<String>

    @MainActor @discardableResult
    static func request(_ ids: Set<String>, model: AppModel, presentation: Binding<Self?>) -> Bool {
        guard presentation.wrappedValue == nil, !model.deletingDiagramJobs else { return false }
        let existingIDs = ids.filter { model.diagram($0) != nil }
        guard !existingIDs.isEmpty else { return false }
        presentation.wrappedValue = Self(ids: existingIDs)
        return true
    }
}

struct DeleteDiagramsView: View {
    @ObservedObject var workspace: DiagramWorkspaceModel
    let ids: Set<String>
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(ids.count > 1 ? "Удалить выбранные схемы (\(ids.count))?" : "Удалить схему?").font(.title2)
            Text("Копии изображений и результаты в LocalScribe будут удалены без возможности восстановления. Внешние оригиналы и ваши экспорты сохранятся.")
            HStack {
                Button("Отмена", action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Удалить", role: .destructive) {
                    dismiss()
                    Task { await workspace.deleteSelected(ids) }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("diagrams.sidebar.confirmDelete")
            }
        }.padding(24).frame(width: 500).onExitCommand(perform: dismiss)
    }
}

struct DeleteDiagramGroupView: View {
    let workspace: DiagramWorkspaceModel
    @ObservedObject var model: AppModel
    let group: RecordingGroup
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Удалить группу «\(group.name)»?").font(.title2)
            Text("Количество схем в группе — \(model.diagrams(in: group.id).count). Если удалить только группу, схемы перейдут в «Без темы». При удалении вместе со схемами LocalScribe удалит архивные копии изображений и результаты без возможности восстановления. Внешние оригиналы и экспорты сохранятся.")
            HStack {
                Button("Отмена", action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Удалить только группу") {
                    dismiss()
                    Task { await workspace.deleteGroup(group.id, deleteDiagrams: false) }
                }
                .accessibilityIdentifier("diagrams.groups.confirmDelete")
            }
            Button("Удалить группу и схемы", role: .destructive) {
                dismiss()
                Task { await workspace.deleteGroup(group.id, deleteDiagrams: true) }
            }
            .foregroundStyle(.red)
            .accessibilityIdentifier("diagrams.groups.confirmDeleteDiagrams")
        }.padding(24).frame(width: 540).onExitCommand(perform: dismiss)
    }
}

struct RenameDiagramView: View {
    @ObservedObject var workspace: DiagramWorkspaceModel
    let diagram: DiagramManifest
    let dismiss: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Переименовать схему").font(.title2)
            TextField("Название схемы", text: $name)
                .focused($focused)
                .accessibilityIdentifier("diagrams.rename.field")
                .onSubmit(save)
            HStack {
                Button("Отмена", action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Сохранить", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("diagrams.rename.save")
            }
        }.padding(24).frame(width: 460)
            .onAppear { name = diagram.displayTitle; focused = true }
            .onExitCommand(perform: dismiss)
    }
    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismiss()
        Task { await workspace.model.renameDiagram(diagram.id, title: trimmed) }
    }
}
