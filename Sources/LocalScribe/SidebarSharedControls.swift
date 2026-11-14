import SwiftUI
import AppKit
import LocalScribeCore

/// Deterministic segmented switcher for the three archive sections. The
/// SwiftUI-bridged picker keeps its intrinsic (equal-width) size in
/// long-lived processes and overflows the fixed header frame; the pinned
/// intrinsic size keeps the header layout identical in every process state.
private struct WorkspaceModePicker: NSViewRepresentable {
    @Binding var mode: WorkspaceMode

    final class Control: NSSegmentedControl {
        override var intrinsicContentSize: NSSize { NSSize(width: 216, height: 20) }
        override func sizeToFit() { bounds.size = intrinsicContentSize }
    }

    final class Coordinator: NSObject {
        let mode: Binding<WorkspaceMode>
        init(mode: Binding<WorkspaceMode>) { self.mode = mode }

        @objc func changed(_ sender: NSSegmentedControl) {
            let all = WorkspaceMode.allCases
            guard sender.selectedSegment >= 0, sender.selectedSegment < all.count else { return }
            mode.wrappedValue = all[sender.selectedSegment]
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(mode: $mode) }

    func makeNSView(context: Context) -> Control {
        let control = Control()
        control.segmentCount = WorkspaceMode.allCases.count
        control.controlSize = .small
        for (index, value) in WorkspaceMode.allCases.enumerated() {
            control.setLabel(L10n.text(value.title), forSegment: index)
        }
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setAccessibilityLabel(L10n.text("Раздел архива"))
        return control
    }

    func updateNSView(_ control: Control, context: Context) {
        let index = WorkspaceMode.allCases.firstIndex(of: mode) ?? 0
        if control.selectedSegment != index { control.selectedSegment = index }
    }
}

struct SidebarWorkspaceHeader<GroupActions: View, ArchiveActions: View>: View {
    @Binding var mode: WorkspaceMode
    @ViewBuilder let groupActions: () -> GroupActions
    @ViewBuilder let archiveActions: () -> ArchiveActions

    var body: some View {
        HStack(spacing: 4) {
            WorkspaceModePicker(mode: $mode)
                .frame(width: 216)
                .accessibilityIdentifier("workspace.mode")

            Spacer(minLength: 0)
            groupActions()
            archiveActions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

struct SidebarEmptyAction: View {
    var body: some View {
        Color.clear.frame(width: 20, height: 24).allowsHitTesting(false).accessibilityHidden(true)
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
