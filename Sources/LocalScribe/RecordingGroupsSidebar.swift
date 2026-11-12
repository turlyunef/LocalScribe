import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

struct RecordingGroupsSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var search: RecordingSearch
    @Binding private var mode: WorkspaceMode
    private let deletion: Binding<SidebarDeletion?>?
    private let newRecording: (() -> Void)?
    init(model: AppModel, mode: Binding<WorkspaceMode> = .constant(.recordings),
         deletion: Binding<SidebarDeletion?>? = nil, newRecording: (() -> Void)? = nil) {
        self.model = model; self.search = model.recordingSearch
        _mode = mode
        self.deletion = deletion
        self.newRecording = newRecording
    }
    @State private var editor: GroupNameDraft?
    @State private var deleting: RecordingGroup?
    @State private var deletingRecordings: SidebarDeletion?
    @State private var draggedRecording: String?
    @State private var draggedGroup: String?
    private var deletionPresentation: Binding<SidebarDeletion?> { deletion ?? $deletingRecordings }

    var body: some View {
        VStack(spacing: 0) {
            SidebarWorkspaceHeader(mode: $mode) {
                expansionButton(expanded: true)
                expansionButton(expanded: false)
                SidebarActionButton(icon: "folder.badge.plus", title: L10n.text("Добавить группу"), identifier: "groups.add") {
                    if editor == nil { editor = GroupNameDraft(groupID: nil, name: "") }
                }
                .disabled(model.deletingGroupID != nil)
            } archiveActions: {
                if let newRecording {
                    SidebarActionButton(icon: "mic", title: L10n.text("Новая запись"), identifier: "recordings.sidebar.new",
                                        action: newRecording)
                        .disabled(!model.canStartRecording)
                    SidebarActionButton(icon: "square.and.arrow.down", title: L10n.text("Импортировать аудио"),
                                        identifier: "recordings.sidebar.import", action: model.chooseImport)
                } else {
                    SidebarEmptyAction()
                }
            }
            RecordingSearchField(search: search)
                .padding(.horizontal, 12).padding(.bottom, 8)
            if search.active && search.completed {
                SidebarSearchStatus(
                    countTitle: L10n.text("Найдено: %1$@", String(search.matchingIDs.count)),
                    countIdentifier: "recordings.search.count",
                    emptyTitle: L10n.text("Записи не найдены"),
                    emptyHint: L10n.text("Попробуйте другое название или очистите поиск"),
                    emptyIdentifier: "recordings.search.empty",
                    empty: search.matchingIDs.isEmpty)
            }
            SidebarLazyScrollColumn(focusTarget: editor?.id, revealTarget: model.sidebarRevealID) {
                if let draft = editor, draft.groupID == nil { nameEditor(draft).id(draft.id) }
                ForEach(model.sidebarGroups(editing: editor?.groupID)) { group in
                    if !search.active {
                        GroupInsertionLine(model: model, before: group.id, draggedGroup: $draggedGroup)
                    }
                    RecordingGroupDropArea(model: model, groupID: group.id, draggedRecording: draggedRecording) { targeted in
                        if let draft = editor, draft.groupID == group.id {
                            nameEditor(draft).id(draft.id)
                        } else {
                            RecordingGroupHeader(model: model, search: search, group: group,
                                draggedRecording: $draggedRecording, draggedGroup: $draggedGroup, dropTargeted: targeted,
                                rename: { editor = GroupNameDraft(groupID: group.id, name: group.name) },
                                delete: { deleting = group })
                        }
                        if search.expanded(group) {
                            let members = model.visibleRecordings(in: group.id)
                            if members.isEmpty && !search.active {
                                Text(L10n.text("Перетащите записи сюда или начните новую запись"))
                                    .accessibilityIdentifier("groups.empty.\(group.id)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 10)
                            }
                            ForEach(members) { recording in
                                SidebarRecordingRow(model: model, recording: recording)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 28).padding(.trailing, 10)
                                .contentShape(Rectangle())
                                .onTapGesture {} // Mouse-down selection also applies when the gesture becomes a drag.
                                .focusable()
                                .focusEffectDisabled()
                                .onKeyPress(.return) { model.selectSidebarRecording(recording.id); return .handled }
                                .onKeyPress(.space) { model.selectSidebarRecording(recording.id); return .handled }
                                .accessibilityElement(children: .contain)
                                .accessibilityAction { model.selectSidebarRecording(recording.id) }
                                .accessibilityAddTraits(model.sidebarSelection.ids.contains(recording.id) ? .isSelected : [])
                                .background(model.sidebarSelection.ids.contains(recording.id) ? Color.accentColor.opacity(0.16) : Color.clear)
                                .background(SidebarMouseSelection { event in
                                    if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                                        model.selectSidebarContext(recording.id)
                                    } else {
                                        model.selectSidebarRecording(recording.id,
                                            command: event.modifierFlags.contains(.command),
                                            shift: event.modifierFlags.contains(.shift))
                                    }
                                })
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityIdentifier("sidebar.recording.\(recording.id)")
                                .onDrag {
                                    model.selectSidebarContext(recording.id)
                                    draggedGroup = nil; draggedRecording = recording.id
                                    return SidebarTransfer.provider(recording.id, type: SidebarTransfer.recording)
                                }
                                // The destination proposes .move; SwiftUI sources allow only .copy by default.
                                .dragConfiguration(DragConfiguration(allowMove: true))
                                .contextMenu {
                                    RecordingContextMenuItems(model: model, recordingID: recording.id) { ids in
                                        SidebarDeletion.request(ids, model: model, presentation: deletionPresentation)
                                    }
                                }
                                .id(recording.id)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $deleting) { group in
            DeleteRecordingGroupView(model: model, group: group) { deleting = nil }
        }
        .sheet(item: deletionPresentation) { deletion in
            DeleteSidebarRecordingsView(model: model, ids: deletion.ids) { deletionPresentation.wrappedValue = nil }
        }
    }
    private func nameEditor(_ draft: GroupNameDraft) -> some View {
        GroupNameEditor(draft: draft, save: { name in
            try await model.saveGroupName(name, id: draft.groupID)
            editor = nil
        }, cancel: { editor = nil }).id(draft.id)
    }

    private func expansionButton(expanded: Bool) -> some View {
        SidebarExpansionButton(
            expanded: expanded,
            title: expanded ? L10n.text("Развернуть все группы") : L10n.text("Свернуть все группы"),
            identifier: expanded ? "groups.expandAll" : "groups.collapseAll",
            disabled: model.deletingGroupID != nil) {
            Task { await model.setAllSidebarExpanded(expanded) }
        }
    }
}

/// Observe selection inside the retained native menu, including its delete action.
private struct RecordingContextMenuItems: View {
    @ObservedObject var model: AppModel
    let recordingID: String
    let delete: (Set<String>) -> Void

    var body: some View {
        Menu(L10n.text("Переместить в")) {
            RecordingMoveMenuItems(model: model, recordingID: recordingID)
        }.disabled(model.deletingGroupID != nil || model.deletingSidebarRecordings)
        Divider()
        let ids = model.sidebarActionIDs(for: recordingID)
        Button(ids.count > 1 ? L10n.text("Удалить выбранные записи…") : L10n.text("Удалить запись…"), role: .destructive) {
            delete(ids)
        }.disabled(!model.canDeleteSidebarRecordings(ids))
    }
}

/// SwiftUI can retain a row's native context menu after the row moves between
/// sections. Observe current membership by recording ID, not the former section.
struct RecordingMoveMenuItems: View {
    @ObservedObject var model: AppModel
    let recordingID: String

    var body: some View {
        let ids = model.sidebarActionIDs(for: recordingID)
        ForEach(model.recordingGroups.groups.filter { target in
            ids.contains { model.recordingGroups.groupID(for: $0) != target.id }
        }) { target in
            Button(target.displayName) { Task { await model.moveRecordings(ids, to: target.id) } }
        }
    }
}

/// A group accepts drops over its header, empty-state hint and member rows.
private struct RecordingGroupDropArea<Content: View>: View {
    @ObservedObject var model: AppModel
    let groupID: String
    let draggedRecording: String?
    let content: (Bool) -> Content

    init(model: AppModel, groupID: String, draggedRecording: String?,
         @ViewBuilder content: @escaping (Bool) -> Content) {
        self.model = model; self.groupID = groupID
        self.draggedRecording = draggedRecording; self.content = content
    }

    var body: some View {
        SidebarDropArea(of: [SidebarTransfer.recording, .fileURL]) { targeted in
            GroupContentDrop(model: model, groupID: groupID, draggedRecording: draggedRecording, targeted: targeted)
        } content: { targeted in
            content(targeted)
        }
    }
}

private struct RecordingGroupHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var search: RecordingSearch
    let group: RecordingGroup
    @Binding var draggedRecording: String?
    @Binding var draggedGroup: String?
    let dropTargeted: Bool
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovered = false
    private enum HeaderFocus: Hashable { case disclosure, delete }
    @FocusState private var focus: HeaderFocus?
    private var controlsVisible: Bool { hovered || focus != nil }
    var body: some View {
        HStack(spacing: 5) {
            if !group.isSystem && !search.active {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 14).opacity(controlsVisible ? 1 : 0)
                    .help(L10n.text("Перетащите, чтобы изменить порядок групп"))
                    .accessibilityLabel(L10n.text("Переставить группу %1$@", group.displayName))
                    .onDrag {
                        draggedRecording = nil; draggedGroup = group.id
                        return SidebarTransfer.provider(group.id, type: SidebarTransfer.group)
                    }
                    .dragConfiguration(DragConfiguration(allowMove: true))
            } else if !group.isSystem {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    .frame(width: 14).opacity(controlsVisible ? 1 : 0)
                    .help(L10n.text("Очистите поиск, чтобы переставить группы"))
                    .accessibilityLabel(L10n.text("Очистите поиск, чтобы переставить группы"))
            } else { Color.clear.frame(width: 14, height: 14) }
            Button {
                Task { await model.setSidebarExpanded(group) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: search.expanded(group) ? "chevron.down" : "chevron.right").frame(width: 10)
                    Text(dropTargeted ? L10n.text("Отпустите → %1$@", group.displayName) : "\(group.displayName) · \(model.sidebarGroupCount(group.id))")
                        .lineLimit(1).contentTransition(.opacity)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).focused($focus, equals: .disclosure)
                .accessibilityIdentifier("groups.header.\(group.id)")
                .accessibilityValue(dropTargeted ? L10n.text("Отпустите для добавления в группу") : "")
                .accessibilityLabel(L10n.text("%1$@, записей: %2$@, %3$@", group.displayName, String(model.sidebarGroupCount(group.id)), search.expanded(group) ? L10n.text("раскрыта") : L10n.text("свёрнута")))
            if !group.isSystem {
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red)
                    .focused($focus, equals: .delete)
                    .opacity(controlsVisible ? 1 : 0)
                    .help(L10n.text("Удалить группу")).accessibilityLabel(L10n.text("Удалить группу %1$@", group.displayName))
                    .accessibilityIdentifier("groups.delete.\(group.id)")
            } else { Color.clear.frame(width: 16, height: 16) }
            Image(systemName: dropTargeted ? "arrow.down.to.line" : "checkmark").frame(width: 16)
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.primary)
                .opacity(dropTargeted || model.recordingGroups.defaultID == group.id ? 1 : 0)
                .help(dropTargeted ? L10n.text("Отпустите для добавления в группу") : L10n.text("Группа для новых записей"))
                .accessibilityLabel(dropTargeted ? L10n.text("Отпустите для добавления в группу") : model.recordingGroups.defaultID == group.id ? L10n.text("Группа для новых записей") : "")
        }
        .font(.subheadline.weight(.semibold)).padding(.vertical, 8).padding(.horizontal, 6)
        .onHover { hovered = $0 }
        .contextMenu {
            Button(L10n.text("Сделать группой по умолчанию")) { Task { await model.changeGroups { try $0.setDefault(group.id) } } }
                .disabled(model.recordingGroups.defaultID == group.id)
            if !group.isSystem {
                Button(L10n.text("Переименовать"), action: rename)
                Button(L10n.text("Удалить группу"), role: .destructive, action: delete)
            }
        }
        .disabled(model.deletingGroupID != nil)
    }
}

@MainActor private struct GroupContentDrop: DropDelegate {
    let model: AppModel
    let groupID: String
    let draggedRecording: String?
    @Binding var targeted: Bool
    func validateDrop(info: DropInfo) -> Bool {
        guard model.deletingGroupID == nil else { return false }
        if info.hasItemsConforming(to: [SidebarTransfer.recording]) {
            return draggedRecording.map { model.recordingGroups.groupID(for: $0) != groupID } ?? true
        }
        return info.hasItemsConforming(to: [.fileURL])
    }
    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: info.hasItemsConforming(to: [SidebarTransfer.recording]) ? .move : .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        if let provider = info.itemProviders(for: [SidebarTransfer.recording]).first {
            SidebarTransfer.load(provider, type: SidebarTransfer.recording) { id in
                Task { await model.moveRecording(id, to: groupID) }
            }
            return true
        }
        return model.importProviders(info.itemProviders(for: [.fileURL]), groupID: groupID)
    }
}

private struct GroupInsertionLine: View {
    @ObservedObject var model: AppModel
    let before: String
    @Binding var draggedGroup: String?
    @State private var targeted = false
    var body: some View {
        Rectangle().fill(targeted && draggedGroup != before ? Color.accentColor : Color.clear)
            .frame(height: 3).padding(.vertical, 3).contentShape(Rectangle())
            .onDrop(of: [SidebarTransfer.group], delegate: GroupOrderDrop(
                model: model, before: before, draggedGroup: draggedGroup, targeted: $targeted))
    }
}

@MainActor private struct GroupOrderDrop: DropDelegate {
    let model: AppModel
    let before: String
    let draggedGroup: String?
    @Binding var targeted: Bool
    func validateDrop(info: DropInfo) -> Bool {
        !model.recordingSearch.active && model.deletingGroupID == nil && draggedGroup != before && draggedGroup != RecordingGroup.ungroupedID
            && info.hasItemsConforming(to: [SidebarTransfer.group])
    }
    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info), let provider = info.itemProviders(for: [SidebarTransfer.group]).first else { return false }
        SidebarTransfer.load(provider, type: SidebarTransfer.group) { id in
            guard !model.recordingSearch.active else { return }
            Task { await model.changeGroups { try $0.move(id, before: before) } }
        }
        return true
    }
}

struct SidebarDeletion: Identifiable {
    let id = UUID()
    let ids: Set<String>

    @MainActor @discardableResult
    static func request(_ ids: Set<String>, model: AppModel, presentation: Binding<Self?>) -> Bool {
        guard presentation.wrappedValue == nil, model.canDeleteSidebarRecordings(ids) else { return false }
        presentation.wrappedValue = Self(ids: ids)
        return true
    }
}

struct DeleteSidebarRecordingsView: View {
    @ObservedObject var model: AppModel
    let ids: Set<String>
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(ids.count > 1 ? L10n.text("Удалить выбранные записи (%1$@)?", String(ids.count)) : L10n.text("Удалить запись?")).font(.title2)
            Text(L10n.text("Копии аудио и результаты в LocalScribe будут удалены без возможности восстановления. Внешние оригиналы и ваши экспорты сохранятся."))
            if !model.canDeleteSidebarRecordings(ids) {
                Text(L10n.text("Дождитесь завершения текущей операции и остановите выбранную запись.")).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.text("Отмена"), action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("Удалить"), role: .destructive) {
                    guard model.canDeleteSidebarRecordings(ids) else { return }
                    dismiss()
                    Task { await model.deleteSidebarRecordings(ids) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canDeleteSidebarRecordings(ids))
                .accessibilityIdentifier("sidebar.confirmDeleteRecordings")
            }
        }.padding(24).frame(width: 500).onExitCommand(perform: dismiss)
    }
}

struct DeleteRecordingGroupView: View {
    @ObservedObject var model: AppModel
    let group: RecordingGroup
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("Удалить группу «%1$@»?", group.displayName)).font(.title2)
            Text(L10n.text("В группе %1$@ записей. Можно удалить группу вместе со всеми её записями, аудио и результатами без возможности восстановления либо сохранить записи, переместив их в «Без темы». Внешние исходные файлы и экспорты сохранятся.", String(model.recordings(in: group.id).count)))
            if !model.canDeleteRecordings(in: group.id) {
                Text(L10n.text("Сначала остановите запись")).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.text("Отмена"), action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("Нет, удалить только группу")) {
                    dismiss(); Task { await model.deleteGroup(group.id, deleteRecordings: false) }
                }
            }
            Button(L10n.text("Да, удалить записи"), role: .destructive) {
                guard model.canDeleteRecordings(in: group.id) else { return }
                dismiss(); Task { await model.deleteGroup(group.id, deleteRecordings: true) }
            }
            .foregroundStyle(.red)
            .disabled(!model.canDeleteRecordings(in: group.id))
            .accessibilityIdentifier("groups.confirmDeleteRecordings")
        }.padding(24).frame(width: 540)
            .onExitCommand(perform: dismiss)
    }
}

private struct SidebarRecordingRow: View {
    @ObservedObject var model: AppModel
    let recording: Manifest

    private var displayedState: JobState {
        recording.state == .completedWithWarnings ? .completed : recording.state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(recording.displayTitle).lineLimit(2).fontWeight(.medium)
            Text("\(timecode(recording.durationMs)) · \(recording.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: L10n.locale)))").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if recording.state == .queued, let position = model.queuePosition(for: recording.id) {
                    Text("\(position)").foregroundStyle(.red).accessibilityLabel(L10n.text("Место в очереди: %1$@", String(position))).accessibilityIdentifier("recording.queuePosition.\(recording.id)")
                }
                Label(recording.state == .queued && model.queuePosition(for: recording.id) != nil ? model.resourcePauseTitle.map(L10n.message) ?? displayedState.title : displayedState.title,
                      systemImage: recording.state == .recording ? "record.circle.fill" : displayedState == .completed ? "checkmark.circle" : "waveform")
                    .foregroundStyle(recording.state == .recording ? .red : .secondary)
                    .accessibilityIdentifier("recording.status.\(recording.id)")
            }.font(.caption)
            if let processing = recording.captureProcessing, recording.state == .recording {
                HStack(spacing: 5) {
                    if processing == .queued, let position = model.queuePosition(for: recording.id) {
                        Text("\(position)").foregroundStyle(.red).accessibilityLabel(L10n.text("Место в очереди: %1$@", String(position))).accessibilityIdentifier("recording.queuePosition.\(recording.id)")
                    }
                    Label(model.resourcePauseTitle.map(L10n.message) ?? (processing == .transcribing ? L10n.text("Речь распознаётся в фоне") : processing == .queued ? L10n.text("Распознавание в очереди") : L10n.text("Распознавание приостановлено; запись идёт")), systemImage: "waveform")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recording.captureStatus.\(recording.id)")
                }.font(.caption2)
            }
        }.padding(.vertical, 5)
    }
}
