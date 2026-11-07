import SwiftUI
import AppKit

/// Read modifiers before menu/drag tracking starts; pass the original event
/// through. Contains no domain logic and is reused by every lazy sidebar row.
struct SidebarMouseSelection: NSViewRepresentable {
    var select: (NSEvent) -> Void

    func makeNSView(context: Context) -> SelectionView { SelectionView() }
    func updateNSView(_ view: SelectionView, context: Context) { view.select = select }
    static func dismantleNSView(_ view: SelectionView, coordinator: ()) { view.stopMonitoring() }

    final class SelectionView: NSView {
        var select: ((NSEvent) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.select?(event)
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
