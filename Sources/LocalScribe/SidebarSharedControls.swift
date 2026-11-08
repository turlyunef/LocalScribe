import SwiftUI

struct SidebarWorkspaceHeader<GroupActions: View>: View {
    @Binding var mode: WorkspaceMode
    var importImage: (() -> Void)?
    @ViewBuilder var groupActions: () -> GroupActions

    var body: some View {
        HStack(spacing: 4) {
            Picker("Раздел архива", selection: $mode) {
                ForEach(WorkspaceMode.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .tint(.blue)
            .frame(width: 116)
            .accessibilityIdentifier("workspace.mode")

            Spacer(minLength: 0)
            groupActions()
            Group {
                if let importImage {
                    Button(action: importImage) {
                        Image(systemName: "photo.badge.plus")
                            .offset(y: 1)
                            .frame(width: 20, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help("Загрузить изображение").accessibilityLabel("Загрузить изображение")
                    .accessibilityIdentifier("diagrams.import")
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
            .frame(width: 20, height: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Icon-only "expand all / collapse all" button with stacked chevrons.
/// Titles and accessibility identifiers are caller-defined.
struct SidebarExpansionButton: View {
    let expanded: Bool
    let title: String
    let identifier: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title).accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .disabled(disabled)
    }
}

/// Counter of an active search with a no-match hint. Texts and accessibility
/// identifiers are caller-defined.
struct SidebarSearchStatus: View {
    let countTitle: String
    let countIdentifier: String
    let emptyTitle: String
    let emptyHint: String
    let emptyIdentifier: String
    let empty: Bool

    var body: some View {
        Text(countTitle)
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier(countIdentifier)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 6)
        if empty {
            VStack(alignment: .leading, spacing: 4) {
                Text(emptyTitle)
                Text(emptyHint).font(.caption).foregroundStyle(.secondary)
            }.accessibilityIdentifier(emptyIdentifier)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}

/// Lazy scroll column skeleton. When the focus target changes the row is
/// revealed at the top edge; the reveal target scrolls to the center.
struct SidebarLazyScrollColumn<FocusID: Hashable, RevealID: Hashable, Content: View>: View {
    let focusTarget: FocusID?
    let revealTarget: RevealID?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.horizontal, 6)
            }
            .onChange(of: focusTarget) { _, id in
                if let id { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: revealTarget) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}
