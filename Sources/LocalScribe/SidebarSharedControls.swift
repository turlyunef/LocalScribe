import SwiftUI
import LocalScribeCore

/// A compact, in-sidebar version of the Settings window's toolbar tabs.
/// Keep it above the changing sidebar content so selection can slide between tabs.
struct WorkspaceModePicker: View {
    @Binding var mode: WorkspaceMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceMode.allCases) { value in
                Button {
                    mode = value
                } label: {
                    Text(value.title)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .foregroundStyle(mode == value ? .primary : .secondary)
                        .background {
                            if mode == value {
                                Capsule()
                                    .fill(.primary.opacity(0.09))
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == value ? .isSelected : [])
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(4)
        .background(.background.opacity(0.55), in: Capsule())
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Раздел архива"))
        .accessibilityIdentifier("workspace.mode")
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

struct SidebarActions<GroupActions: View, ItemActions: View>: View {
    @ViewBuilder let groupActions: () -> GroupActions
    @ViewBuilder let itemActions: () -> ItemActions

    var body: some View {
        HStack(spacing: 4) {
            groupActions()
            Spacer(minLength: 0)
            itemActions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct SidebarActionButton: View {
    let icon: String
    let title: String
    let identifier: String
    var iconVerticalOffset: CGFloat = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .offset(y: iconVerticalOffset)
                .frame(width: 20, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
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
