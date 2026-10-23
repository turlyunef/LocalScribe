import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

enum SidebarTransfer {
    static let recording = UTType(exportedAs: "app.localscribe.recording", conformingTo: .data)
    static let group = UTType(exportedAs: "app.localscribe.group", conformingTo: .data)

    static func provider(_ id: String, type: UTType) -> NSItemProvider {
        NSItemProvider(item: Data(id.utf8) as NSData, typeIdentifier: type.identifier)
    }
    static func identifier(_ data: Data?) -> String? {
        guard let data, let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil else { return nil }
        return id
    }
    @MainActor static func load(_ provider: NSItemProvider, type: UTType, perform: @escaping @MainActor (String) -> Void) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let id = identifier(data) else { return }
            Task { @MainActor in perform(id) }
        }
    }
}

struct RecordingGroupsSidebar: View {
    @ObservedObject var model: AppModel
    @State private var editor: GroupNameDraft?
    @State private var deleting: RecordingGroup?
    @State private var draggedRecording: String?
    @State private var draggedGroup: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Записи").font(.headline)
                Spacer()
                Button {
                    if editor == nil { editor = GroupNameDraft(groupID: nil, name: "") }
                } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help("Добавить группу").accessibilityLabel("Добавить группу")
                    .accessibilityIdentifier("groups.add")
                    .disabled(model.deletingGroupID != nil)
            }.padding(.horizontal, 12).padding(.vertical, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let draft = editor, draft.groupID == nil { nameEditor(draft).id(draft.id) }
                        ForEach(model.recordingGroups.groups) { group in
                            GroupInsertionLine(model: model, before: group.id, draggedGroup: $draggedGroup)
                            if let draft = editor, draft.groupID == group.id {
                                nameEditor(draft).id(draft.id)
                            } else {
                                RecordingGroupHeader(model: model, group: group,
                                    draggedRecording: $draggedRecording, draggedGroup: $draggedGroup,
                                    rename: { editor = GroupNameDraft(groupID: group.id, name: group.name) },
                                    delete: { deleting = group })
                            }
                            if group.expanded {
                                let members = model.recordings(in: group.id)
                                if members.isEmpty {
                                    Text("Перетащите записи сюда или начните новую запись")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 10)
                                }
                                ForEach(members) { recording in
                                    SidebarRecordingRow(model: model, recording: recording)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 28).padding(.trailing, 10)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selection = recording.id }
                                    .focusable()
                                    .onKeyPress(.return) { model.selection = recording.id; return .handled }
                                    .onKeyPress(.space) { model.selection = recording.id; return .handled }
                                    .accessibilityElement(children: .contain)
                                    .accessibilityAction { model.selection = recording.id }
                                    .background(model.selection == recording.id ? Color.accentColor.opacity(0.16) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .accessibilityIdentifier("sidebar.recording.\(recording.id)")
                                    .onDrag {
                                        draggedGroup = nil; draggedRecording = recording.id
                                        return SidebarTransfer.provider(recording.id, type: SidebarTransfer.recording)
                                    }
                                    .contextMenu {
                                        Menu("Переместить в") {
                                            RecordingMoveMenuItems(model: model, recordingID: recording.id)
                                        }.disabled(model.deletingGroupID != nil)
                                    }
                                    .id(recording.id)
                                }
                            }
                        }
                    }.padding(.horizontal, 6)
                }
                .onChange(of: editor?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: model.sidebarRevealID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .sheet(item: $deleting) { group in
            DeleteRecordingGroupView(model: model, group: group) { deleting = nil }
        }
    }
    private func nameEditor(_ draft: GroupNameDraft) -> some View {
        GroupNameEditor(draft: draft, save: { name in
            try await model.saveGroupName(name, id: draft.groupID)
            editor = nil
        }, cancel: { editor = nil }).id(draft.id)
    }
}

/// SwiftUI can retain a row's native context menu after the row moves between
/// sections. Observe current membership by recording ID, not the former section.
struct RecordingMoveMenuItems: View {
    @ObservedObject var model: AppModel
    let recordingID: String

    var body: some View {
        let currentGroupID = model.recordingGroups.groupID(for: recordingID)
        ForEach(model.recordingGroups.groups.filter { $0.id != currentGroupID }) { target in
            Button(target.name) { Task { await model.moveRecording(recordingID, to: target.id) } }
        }
    }
}

struct GroupNameDraft: Identifiable {
    let id = UUID()
    let groupID: String?
    let name: String
}

struct GroupNameEditor: View {
    let draft: GroupNameDraft
    let save: (String) async throws -> Void
    let cancel: () -> Void
    @State private var name: String
    @State private var error: String?
    @State private var saving = false
    @State private var finished = false
    @FocusState private var focused: Bool
    init(draft: GroupNameDraft, save: @escaping (String) async throws -> Void, cancel: @escaping () -> Void) {
        self.draft = draft; self.save = save; self.cancel = cancel
        _name = State(initialValue: draft.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Название группы", text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier("groups.name")
                .onSubmit { commit(blur: false) }
                .onExitCommand { guard !saving else { return }; finished = true; cancel() }
                .onChange(of: focused) { _, value in if !value { commit(blur: true) } }
                .disabled(saving)
            if let error { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("groups.name.error") }
        }.padding(8)
            .task { await Task.yield(); focused = true }
    }
    private func commit(blur: Bool) {
        guard !finished, !saving else { return }
        if blur && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finished = true; cancel(); return
        }
        saving = true
        Task {
            do { try await save(name); finished = true }
            catch { self.error = error.localizedDescription; saving = false; focused = true }
            saving = false
        }
    }
}

private struct RecordingGroupHeader: View {
    @ObservedObject var model: AppModel
    let group: RecordingGroup
    @Binding var draggedRecording: String?
    @Binding var draggedGroup: String?
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovered = false
    @State private var targeted = false
    private enum HeaderFocus: Hashable { case disclosure, delete }
    @FocusState private var focus: HeaderFocus?
    private var controlsVisible: Bool { hovered || focus != nil }
    var body: some View {
        HStack(spacing: 5) {
            if !group.isSystem {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 14).opacity(controlsVisible ? 1 : 0)
                    .help("Перетащите, чтобы изменить порядок групп")
                    .accessibilityLabel("Переставить группу \(group.name)")
                    .onDrag {
                        draggedRecording = nil; draggedGroup = group.id
                        return SidebarTransfer.provider(group.id, type: SidebarTransfer.group)
                    }
            } else { Color.clear.frame(width: 14, height: 14) }
            Button {
                Task { await model.changeGroups { try $0.setExpanded(group.id, !group.expanded) } }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: group.expanded ? "chevron.down" : "chevron.right").frame(width: 10)
                    Text("\(group.name) · \(model.recordings(in: group.id).count)").lineLimit(1)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).focused($focus, equals: .disclosure)
                .accessibilityIdentifier("groups.header.\(group.id)")
                .accessibilityLabel("\(group.name), записей: \(model.recordings(in: group.id).count), \(group.expanded ? "раскрыта" : "свёрнута")")
            if !group.isSystem {
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red)
                    .focused($focus, equals: .delete)
                    .opacity(controlsVisible ? 1 : 0)
                    .help("Удалить группу").accessibilityLabel("Удалить группу \(group.name)")
                    .accessibilityIdentifier("groups.delete.\(group.id)")
            } else { Color.clear.frame(width: 16, height: 16) }
            Image(systemName: "checkmark").frame(width: 16)
                .opacity(model.recordingGroups.defaultID == group.id ? 1 : 0)
                .help("Группа для новых записей")
                .accessibilityLabel(model.recordingGroups.defaultID == group.id ? "Группа для новых записей" : "")
        }
        .font(.subheadline.weight(.semibold)).padding(.vertical, 8).padding(.horizontal, 6)
        .background(targeted ? Color.accentColor.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Сделать группой по умолчанию") { Task { await model.changeGroups { try $0.setDefault(group.id) } } }
                .disabled(model.recordingGroups.defaultID == group.id)
            if !group.isSystem {
                Button("Переименовать", action: rename)
                Button("Удалить группу", role: .destructive, action: delete)
            }
        }
        .onDrop(of: [SidebarTransfer.recording, .fileURL], delegate: GroupContentDrop(
            model: model, groupID: group.id, draggedRecording: draggedRecording, targeted: $targeted))
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
        } else {
            model.importProviders(info.itemProviders(for: [.fileURL]), groupID: groupID)
        }
        return true
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
        model.deletingGroupID == nil && draggedGroup != before && draggedGroup != RecordingGroup.ungroupedID
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
            Task { await model.changeGroups { try $0.move(id, before: before) } }
        }
        return true
    }
}

struct DeleteRecordingGroupView: View {
    @ObservedObject var model: AppModel
    let group: RecordingGroup
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Удалить группу «\(group.name)»?").font(.title2)
            Text("В группе \(model.recordings(in: group.id).count) записей. Можно удалить группу вместе со всеми её записями, аудио и результатами без возможности восстановления либо сохранить записи, переместив их в «Без темы». Внешние исходные файлы и экспорты сохранятся.")
            if !model.canDeleteRecordings(in: group.id) {
                Text("Сначала остановите запись").foregroundStyle(.secondary)
            }
            HStack {
                Button("Отмена", action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Нет, удалить только группу") {
                    dismiss(); Task { await model.deleteGroup(group.id, deleteRecordings: false) }
                }
            }
            Button("Да, удалить записи", role: .destructive) {
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
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(recording.displayTitle).lineLimit(2).fontWeight(.medium)
            Text("\(timecode(recording.durationMs)) · \(recording.createdAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if recording.state == .queued, let position = model.queuePosition(for: recording.id) {
                    Text("\(position)").foregroundStyle(.red).accessibilityLabel("Место в очереди: \(position)").accessibilityIdentifier("recording.queuePosition.\(recording.id)")
                }
                Label(recording.state.title, systemImage: recording.state == .recording ? "record.circle.fill" : recording.state == .completed ? "checkmark.circle" : "waveform")
                    .foregroundStyle(recording.state == .recording ? .red : .secondary)
                    .accessibilityIdentifier("recording.status.\(recording.id)")
            }.font(.caption)
            if let processing = recording.captureProcessing, recording.state == .recording {
                HStack(spacing: 5) {
                    if processing == .queued, let position = model.queuePosition(for: recording.id) {
                        Text("\(position)").foregroundStyle(.red).accessibilityLabel("Место в очереди: \(position)").accessibilityIdentifier("recording.queuePosition.\(recording.id)")
                    }
                    Label(processing == .transcribing ? "Речь распознаётся в фоне" : processing == .queued ? "Распознавание в очереди" : "Распознавание приостановлено; запись идёт", systemImage: "waveform")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recording.captureStatus.\(recording.id)")
                }.font(.caption2)
            }
        }.padding(.vertical, 5)
    }
}
