import SwiftUI
import AppKit

struct RecordingSearchField: View {
    @ObservedObject var search: RecordingSearch
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Поиск по названиям", text: $search.query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused)
                .accessibilityLabel("Поиск по названиям записей")
                .accessibilityIdentifier("recordings.search")
                .onExitCommand {
                    if search.query.isEmpty { focused = false }
                    else { search.query = ""; focused = true }
                }
            ZStack {
                if search.query.isEmpty {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .allowsHitTesting(false).accessibilityHidden(true)
                } else {
                    Button { search.query = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Очистить поиск")
                        .accessibilityIdentifier("recordings.search.clear")
                }
            }.frame(width: 16, height: 20)
        }
        .padding(.leading, 9).padding(.trailing, 9).frame(height: 30)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 8)).onTapGesture { focused = true }
        .background(SearchFindShortcut(isFocused: focused) { window in
            focused = true
            Task { @MainActor in
                await Task.yield()
                (window.firstResponder as? NSTextView)?.selectAll(nil)
            }
        })
    }
}

/// Window-local Command-F. A text editor with its own find handling keeps the event.
private struct SearchFindShortcut: NSViewRepresentable {
    let isFocused: Bool
    let focus: (NSWindow) -> Void
    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }
    func updateNSView(_ view: ShortcutView, context: Context) {
        view.isFocused = isFocused; view.focus = focus
    }
    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.stop() }
    final class ShortcutView: NSView {
        var isFocused = false
        var focus: ((NSWindow) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "f" else { return event }
                if window.firstResponder is NSTextView && !self.isFocused { return event }
                self.focus?(window)
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
