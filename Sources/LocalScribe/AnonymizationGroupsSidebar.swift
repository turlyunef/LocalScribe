import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

/// Sidebar of the text-anonymization section: shared workspace header with the
/// section switcher, title search, group organization (create/rename/default/
/// order/expansion) and card rows with mouse-down selection, internal drag and
/// assignment menu. Card deletion confirmations arrive through the `deletion`
/// binding, group deletion opens its own sheet here (work 11); the external
/// file import pipeline belongs to work 6.
struct AnonymizationGroupsSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: AnonymizationWorkspaceModel
    @ObservedObject private var search: RecordingSearch
    private let deletion: Binding<SidebarTextDeletion?>?
    init(model: AppModel, workspace: AnonymizationWorkspaceModel, deletion: Binding<SidebarTextDeletion?>? = nil) {
        self.model = model; self.workspace = workspace; self.search = model.anonymizationSearch
        self.deletion = deletion
    }
    @State private var editor: GroupNameDraft?
    @State private var renaming: AnonymizationCardSummary?
    @State private var deletingGroup: TextGroupDeletionRequest?
    @State private var draggedCard: String?
    @State private var draggedGroup: String?

    var body: some View {
        VStack(spacing: 0) {
            RecordingSearchField(search: search, identifierPrefix: "texts", placeholder: L10n.text("Поиск по названиям"),
                                 label: L10n.text("Поиск по названиям текстов"), shortcutActive: true)
                .padding(.horizontal, 12).padding(.top, 8)
            SidebarActions {
                expansionButton(expanded: false)
                expansionButton(expanded: true)
                SidebarAddGroupButton(title: L10n.text("Добавить группу текстов"), identifier: "texts.groups.add", editor: $editor)
                .disabled(model.deletingTextJobs)
            } itemActions: {
                SidebarActionButton(icon: "square.and.arrow.down", title: L10n.text("Загрузить файл"),
                                    identifier: "texts.import", action: workspace.presentImportPanel)
            }
            if search.active && search.completed {
                SidebarSearchStatus(
                    countTitle: L10n.text("Найдено: %1$@", String(search.matchingIDs.count)),
                    countIdentifier: "texts.search.count",
                    emptyTitle: L10n.text("Тексты не найдены"),
                    emptyHint: L10n.text("Попробуйте другое название или очистите поиск"),
                    emptyIdentifier: "texts.search.empty",
                    empty: search.matchingIDs.isEmpty)
            }
            SidebarLazyScrollColumn(focusTarget: editor?.id, revealTarget: workspace.sidebarRevealID) {
                if let draft = editor, draft.groupID == nil { nameEditor(draft).id(draft.id) }
                ForEach(workspace.sidebarGroups(editing: editor?.groupID)) { group in
                    if !search.active {
                        TextGroupInsertionLine(workspace: workspace, before: group.id, draggedGroup: $draggedGroup)
                    }
                    SidebarDropArea(of: [TextTransferTypes.card, .fileURL]) { targeted in
                        TextGroupDrop(workspace: workspace, groupID: group.id, draggedCard: draggedCard, targeted: targeted)
                    } content: { targeted in
                        if let draft = editor, draft.groupID == group.id {
                            nameEditor(draft).id(draft.id)
                        } else {
                            TextGroupHeader(workspace: workspace, group: group,
                                draggedGroup: $draggedGroup, dropTargeted: targeted,
                                rename: { editor = GroupNameDraft(groupID: group.id, name: group.name) },
                                delete: { requestGroupDeletion(group) })
                        }
                        if search.expanded(group) {
                            let members = workspace.visibleTextCards(in: group.id)
                            if members.isEmpty {
                                Text(L10n.text("Загрузите файл TXT или Markdown, чтобы добавить текст"))
                                    .accessibilityIdentifier("texts.groups.empty.\(group.id)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 10)
                            }
                            ForEach(members) { card in
                                SidebarTextCardRow(model: model, workspace: workspace, card: card,
                                    rename: { renaming = card })
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 28).padding(.trailing, 10)
                                .contentShape(Rectangle())
                                .onTapGesture {}
                                .focusable()
                                .focusEffectDisabled()
                                .onKeyPress(.return) { workspace.selectSidebarTextCard(card.id); return .handled }
                                .onKeyPress(.space) { workspace.selectSidebarTextCard(card.id); return .handled }
                                .accessibilityElement(children: .contain)
                                .accessibilityAction { workspace.selectSidebarTextCard(card.id) }
                                .accessibilityAddTraits(workspace.sidebarSelection.ids.contains(card.id) ? .isSelected : [])
                                .background(workspace.sidebarSelection.ids.contains(card.id) ? Color.accentColor.opacity(0.16) : Color.clear)
                                .background(SidebarMouseSelection { event in
                                    if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                                        workspace.selectSidebarContext(card.id)
                                    } else {
                                        workspace.selectSidebarTextCard(card.id,
                                            command: event.modifierFlags.contains(.command),
                                            shift: event.modifierFlags.contains(.shift))
                                    }
                                })
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityIdentifier("texts.sidebar.card.\(card.id)")
                                .onDrag {
                                    workspace.selectSidebarContext(card.id)
                                    draggedGroup = nil; draggedCard = card.id
                                    return SidebarItemTransfer.provider(card.id, type: TextTransferTypes.card)
                                }
                                .dragConfiguration(DragConfiguration(allowMove: true))
                                .contextMenu {
                                    TextContextMenuItems(workspace: workspace, cardID: card.id, rename: { renaming = card },
                                        delete: { ids in requestCardDeletion(ids) })
                                }
                                .id(card.id)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $deletingGroup) { request in
            DeleteTextGroupView(model: model, request: request) { deletingGroup = nil }
        }
        .sheet(item: $renaming) { card in
            RenameTextCardView(workspace: workspace, card: card) { renaming = nil }
        }
    }
    /// Card deletion confirmation: the UUID set is frozen at the moment the
    /// dialog opens (mass actions arrive narrowed to the current search
    /// results through `sidebarActionIDs`).
    private func requestCardDeletion(_ ids: Set<String>) {
        guard let deletion else { return }
        _ = SidebarTextDeletion.request(ids, model: model, presentation: deletion)
    }
    /// Group deletion confirmation freezes the full membership — including
    /// cards hidden by the active search filter — when the dialog opens.
    private func requestGroupDeletion(_ group: RecordingGroup) {
        guard deletingGroup == nil, !model.deletingTextJobs, !group.isSystem else { return }
        deletingGroup = TextGroupDeletionRequest(
            group: group, confirmedIDs: Set(model.textCards(in: group.id).map(\.id)))
    }
    private func nameEditor(_ draft: GroupNameDraft) -> some View {
        GroupNameEditor(draft: draft, placeholder: L10n.text("Название группы текстов"),
            fieldIdentifier: "texts.groups.name", errorIdentifier: "texts.groups.name.error",
            save: { name in
                try await workspace.saveGroupName(name, id: draft.groupID)
                editor = nil
            }, cancel: { editor = nil }).id(draft.id)
    }
    private func expansionButton(expanded: Bool) -> some View {
        SidebarExpansionButton(
            expanded: expanded,
            title: expanded ? L10n.text("Развернуть все группы текстов") : L10n.text("Свернуть все группы текстов"),
            identifier: expanded ? "texts.groups.expandAll" : "texts.groups.collapseAll", disabled: false) {
            Task { await workspace.setAllSidebarExpanded(expanded) }
        }
    }
}

private struct SidebarTextCardRow: View {
    @ObservedObject var model: AppModel
    let workspace: AnonymizationWorkspaceModel
    let card: AnonymizationCardSummary
    let rename: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(card.displayName).lineLimit(2).fontWeight(.medium)
            Label(card.statusTitle, systemImage: card.statusIcon)
                .foregroundStyle(card.attemptState == .failed ? .red : .secondary)
                .font(.caption)
                .accessibilityIdentifier("texts.status.\(card.id)")
        }.padding(.vertical, 5)
    }
}

private struct TextContextMenuItems: View {
    @ObservedObject var workspace: AnonymizationWorkspaceModel
    let cardID: String
    let rename: () -> Void
    let delete: (Set<String>) -> Void
    var body: some View {
        Menu(L10n.text("Переместить в")) {
            let ids = workspace.sidebarActionIDs(for: cardID)
            ForEach(workspace.model.textGroups.groups.filter { target in
                ids.contains { workspace.model.textGroups.groupID(for: $0) != target.id }
            }) { target in
                Button(target.displayName) { Task { await workspace.model.moveTextCards(ids, to: target.id) } }
            }
        }
        Divider()
        Button(L10n.text("Переименовать…"), action: rename)
        let ids = workspace.sidebarActionIDs(for: cardID)
        Button(ids.count > 1 ? L10n.text("Удалить выбранные тексты…") : L10n.text("Удалить текст…"), role: .destructive) {
            delete(ids)
        }
        .disabled(workspace.model.deletingTextJobs)
    }
}

private struct TextGroupHeader: View {
    @ObservedObject var workspace: AnonymizationWorkspaceModel
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
                    .help(L10n.text("Перетащите, чтобы изменить порядок групп"))
                    .accessibilityLabel(L10n.text("Переставить группу %1$@", group.displayName))
                    .onDrag {
                        draggedGroup = group.id
                        return SidebarItemTransfer.provider(group.id, type: TextTransferTypes.group)
                    }
                    .dragConfiguration(DragConfiguration(allowMove: true))
            } else if !group.isSystem {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    .frame(width: 14).opacity(hovered ? 1 : 0)
                    .help(L10n.text("Очистите поиск, чтобы переставить группы"))
                    .accessibilityLabel(L10n.text("Очистите поиск, чтобы переставить группы"))
            } else { Color.clear.frame(width: 14, height: 14) }
            Button {
                Task { await workspace.setSidebarExpanded(group) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: workspace.search.expanded(group) ? "chevron.down" : "chevron.right").frame(width: 10)
                    Text(dropTargeted ? L10n.text("Отпустите → %1$@", group.displayName) : "\(group.displayName) · \(workspace.sidebarGroupCount(group.id))")
                        .lineLimit(1).contentTransition(.opacity)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityIdentifier("texts.groups.header.\(group.id)")
                .accessibilityValue(dropTargeted ? L10n.text("Отпустите для добавления в группу") : "")
                .accessibilityLabel(L10n.text("%1$@, текстов: %2$@, %3$@", group.displayName, String(workspace.sidebarGroupCount(group.id)), workspace.search.expanded(group) ? L10n.text("раскрыта") : L10n.text("свёрнута")))
            if !group.isSystem {
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red)
                    .opacity(hovered ? 1 : 0)
                    .help(L10n.text("Удалить группу текстов")).accessibilityLabel(L10n.text("Удалить группу %1$@", group.displayName))
                    .accessibilityIdentifier("texts.groups.delete.\(group.id)")
                    .disabled(workspace.model.deletingTextJobs)
            }
            Image(systemName: dropTargeted ? "arrow.down.to.line" : "checkmark").frame(width: 16)
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.primary)
                .opacity(dropTargeted || workspace.model.textGroups.defaultID == group.id ? 1 : 0)
                .help(dropTargeted ? L10n.text("Отпустите для добавления в группу") : L10n.text("Группа для новых текстов"))
                .accessibilityLabel(dropTargeted ? L10n.text("Отпустите для добавления в группу") : workspace.model.textGroups.defaultID == group.id ? L10n.text("Группа для новых текстов") : "")
        }
        .font(.subheadline.weight(.semibold)).padding(.vertical, 8).padding(.horizontal, 6)
        .onHover { hovered = $0 }
        .contextMenu {
            Button(L10n.text("Сделать группой по умолчанию")) {
                Task { await workspace.model.changeTextGroups { try $0.setDefault(group.id) } }
            }.disabled(workspace.model.textGroups.defaultID == group.id)
            if !group.isSystem {
                Button(L10n.text("Переименовать"), action: rename)
                Button(L10n.text("Удалить группу"), role: .destructive, action: delete)
                    .disabled(workspace.model.deletingTextJobs)
            }
        }
    }
}

@MainActor private struct TextGroupDrop: DropDelegate {
    let workspace: AnonymizationWorkspaceModel
    let groupID: String
    let draggedCard: String?
    @Binding var targeted: Bool
    func validateDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [TextTransferTypes.card]) {
            return draggedCard.map { workspace.model.textGroups.groupID(for: $0) != groupID } ?? true
        }
        // External file drops go through the shared import pipeline; the same
        // effective size limit and decoding rules apply as in the panel.
        return workspace.canImportFiles && info.hasItemsConforming(to: [.fileURL])
    }
    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: info.hasItemsConforming(to: [TextTransferTypes.card]) ? .move : .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        if let provider = info.itemProviders(for: [TextTransferTypes.card]).first {
            SidebarItemTransfer.load(provider, type: TextTransferTypes.card) { id in
                Task { await workspace.model.moveTextCards([id], to: groupID) }
            }
            return true
        }
        return workspace.importProviders(info.itemProviders(for: [.fileURL]), groupID: groupID)
    }
}

private struct TextGroupInsertionLine: View {
    @ObservedObject var workspace: AnonymizationWorkspaceModel
    let before: String
    @Binding var draggedGroup: String?
    @State private var targeted = false
    var body: some View {
        Rectangle().fill(targeted && draggedGroup != before ? Color.accentColor : Color.clear)
            .frame(height: 3).padding(.vertical, 3).contentShape(Rectangle())
            .onDrop(of: [TextTransferTypes.group], delegate: TextGroupOrderDrop(
                workspace: workspace, before: before, draggedGroup: draggedGroup, targeted: $targeted))
    }
}

@MainActor private struct TextGroupOrderDrop: DropDelegate {
    let workspace: AnonymizationWorkspaceModel
    let before: String
    let draggedGroup: String?
    @Binding var targeted: Bool
    func validateDrop(info: DropInfo) -> Bool {
        !workspace.search.active && draggedGroup != before && draggedGroup != AnonymizationGroup.systemID
            && info.hasItemsConforming(to: [TextTransferTypes.group])
    }
    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info), let provider = info.itemProviders(for: [TextTransferTypes.group]).first else { return false }
        SidebarItemTransfer.load(provider, type: TextTransferTypes.group) { id in
            guard !workspace.search.active else { return }
            Task { await workspace.model.changeTextGroups { try $0.move(id, before: before) } }
        }
        return true
    }
}

/// Frozen card-deletion request of the text archive: the UUID set is captured
/// when the confirmation opens; the row menu, ⌘⌫ and the card's trash button
/// all pass through here.
struct SidebarTextDeletion: Identifiable {
    let id = UUID()
    let ids: Set<String>

    @MainActor @discardableResult
    static func request(_ ids: Set<String>, model: AppModel, presentation: Binding<Self?>) -> Bool {
        guard presentation.wrappedValue == nil, model.canDeleteTextCards(ids) else { return false }
        let existingIDs = ids.filter { model.textCard($0) != nil }
        guard !existingIDs.isEmpty else { return false }
        presentation.wrappedValue = Self(ids: existingIDs)
        return true
    }
}

/// Confirmation for deleting text cards from the archive (row menu, ⌘⌫ over
/// the section selection, or the trash button of the open card). Enter
/// confirms «Удалить», Esc closes; the frozen set from the dialog opening is
/// deleted after a fresh protection check.
struct DeleteTextCardsView: View {
    @ObservedObject var model: AppModel
    let ids: Set<String>
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(ids.count > 1
                 ? L10n.text("Удалить выбранные тексты (%1$@)?", String(ids.count))
                 : L10n.text("Удалить текст «%1$@»?", ids.first.flatMap { model.textCard($0)?.displayName } ?? ""))
                .font(.title2)
            Text(L10n.text("Тексты, их результаты и задания будут удалены из LocalScribe без возможности восстановления. Внешние файлы и ваши экспорты сохранятся."))
            HStack {
                Button(L10n.text("Отмена"), action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("Удалить"), role: .destructive) {
                    guard model.canDeleteTextCards(ids),
                          ids.contains(where: { model.textCard($0) != nil }) else { return }
                    dismiss()
                    Task { await model.deleteTextCards(ids) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canDeleteTextCards(ids))
                .accessibilityIdentifier("texts.sidebar.confirmDelete")
            }
        }.padding(24).frame(width: 500).onExitCommand(perform: dismiss)
    }
}

/// Frozen group-deletion request: the full membership of the group —
/// including cards hidden by the active search filter — is captured when the
/// confirmation opens (AC-26).
struct TextGroupDeletionRequest: Identifiable {
    let id = UUID()
    let group: RecordingGroup
    let confirmedIDs: Set<String>
}

/// Group deletion of the text archive: «Удалить только группу» moves the whole
/// membership to «Без темы» in one catalog write; «Удалить группу и тексты»
/// removes the group with its files, re-confirming the membership when it
/// changed since the dialog opened. The choice is explicit — Enter never
/// triggers a destructive action here.
struct DeleteTextGroupView: View {
    @ObservedObject var model: AppModel
    let request: TextGroupDeletionRequest
    let dismiss: () -> Void
    @State private var confirmedIDs: Set<String>
    @State private var compositionChanged = false
    init(model: AppModel, request: TextGroupDeletionRequest, dismiss: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.request = request
        self.dismiss = dismiss
        _confirmedIDs = State(initialValue: request.confirmedIDs)
    }
    /// Full membership regardless of the search filter.
    private var currentIDs: Set<String> { Set(model.textCards(in: request.group.id).map(\.id)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("Удалить группу «%1$@»?", request.group.displayName)).font(.title2)
            Text(L10n.text("Количество текстов в группе — %1$@. Если удалить только группу, тексты перейдут в «Без темы». При удалении вместе с текстами LocalScribe удалит их документы, результаты и задания без возможности восстановления. Внешние файлы и ваши экспорты сохранятся.", String(currentIDs.count)))
                .accessibilityIdentifier("texts.groups.delete.count")
            if compositionChanged {
                Label(L10n.text("Состав группы изменился. Проверьте актуальное количество текстов — %1$@ — и подтвердите удаление ещё раз.", String(currentIDs.count)),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("texts.groups.delete.changed")
            }
            HStack {
                Button(L10n.text("Отмена"), action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("Удалить только группу")) {
                    guard !model.deletingTextJobs else { return }
                    dismiss()
                    Task { await model.deleteTextGroup(request.group.id, deleteFiles: false) }
                }
                .disabled(model.deletingTextJobs)
                .accessibilityIdentifier("texts.groups.confirmDeleteGroupOnly")
            }
            Button(L10n.text("Удалить группу и тексты"), role: .destructive) {
                guard !model.deletingTextJobs else { return }
                // The destructive action follows the confirmed composition: a
                // membership that changed since the last confirmation needs a
                // fresh explicit confirmation of the actual set (AC-26).
                let current = currentIDs
                guard current == confirmedIDs else {
                    compositionChanged = true
                    confirmedIDs = current
                    return
                }
                dismiss()
                Task { await model.deleteTextGroup(request.group.id, deleteFiles: true) }
            }
            .foregroundStyle(.red)
            .disabled(model.deletingTextJobs)
            .accessibilityIdentifier("texts.groups.confirmDeleteWithTexts")
        }.padding(24).frame(width: 540).onExitCommand(perform: dismiss)
    }
}

/// Archive renaming of one card (display name). The name participates in the
/// title search immediately after the snapshot reload (AC-39).
struct RenameTextCardView: View {
    @ObservedObject var workspace: AnonymizationWorkspaceModel
    let card: AnonymizationCardSummary
    let dismiss: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("Переименовать текст")).font(.title2)
            TextField(L10n.text("Название текста"), text: $name)
                .focused($focused)
                .accessibilityIdentifier("texts.rename.field")
                .onSubmit(save)
            HStack {
                Button(L10n.text("Отмена"), action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("Сохранить"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("texts.rename.save")
            }
        }.padding(24).frame(width: 460)
            .onAppear { name = card.displayName; focused = true }
            .onExitCommand(perform: dismiss)
    }
    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismiss()
        Task { await workspace.model.renameTextCard(card.id, to: trimmed) }
    }
}
