import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Window-level shortcuts that let sheets and text editors handle their own keys.
struct WorkspaceKeyboardShortcut: NSViewRepresentable {
    enum Action { case closeSelection, deleteSelection, selectAdjacent(down: Bool) }
    let handle: (Action) -> Bool

    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }
    func updateNSView(_ view: ShortcutView, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.stop() }

    final class ShortcutView: NSView {
        var handle: ((Action) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      window.attachedSheet == nil, NSApp.modalWindow == nil
                else { return event }

                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let text = window.firstResponder as? NSTextView
                switch Int(event.keyCode) {
                case kVK_Escape where modifiers.isEmpty && !event.isARepeat:
                    if let text, text.isEditable || text.isFieldEditor || text.hasMarkedText() { return event }
                    return self.handle?(.closeSelection) == true ? nil : event
                case kVK_Delete where modifiers == .command && !event.isARepeat:
                    // Read-only transcript text must not swallow deletion of the selection.
                    if let text, text.isEditable || text.isFieldEditor || text.hasMarkedText() { return event }
                    return self.handle?(.deleteSelection) == true ? nil : event
                case kVK_UpArrow where modifiers.isEmpty, kVK_DownArrow where modifiers.isEmpty:
                    // Arrows belong to any responder that edits or scrolls text
                    // (query caret, transcript, editors) and to native controls
                    // such as segmented pickers. The one exception is an empty
                    // field editor — the initially focused search field — which
                    // lets the arrows walk the visible list. Held-down repeats
                    // keep navigating.
                    let responder = window.firstResponder
                    if responder is NSControl { return event }
                    if let text = responder as? NSTextView,
                       !(text.isFieldEditor && text.string.isEmpty) { return event }
                    let down = Int(event.keyCode) == kVK_DownArrow
                    return self.handle?(.selectAdjacent(down: down)) == true ? nil : event
                default:
                    return event
                }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
