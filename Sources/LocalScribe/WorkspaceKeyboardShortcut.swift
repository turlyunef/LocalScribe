import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Window-level shortcuts that let sheets and text editors handle their own keys.
struct WorkspaceKeyboardShortcut: NSViewRepresentable {
    enum Action { case closeSelection, deleteRecordings }
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
                      window.attachedSheet == nil, NSApp.modalWindow == nil, !event.isARepeat
                else { return event }

                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let text = window.firstResponder as? NSTextView
                switch Int(event.keyCode) {
                case kVK_Escape where modifiers.isEmpty:
                    if let text, text.isEditable || text.isFieldEditor || text.hasMarkedText() { return event }
                    return self.handle?(.closeSelection) == true ? nil : event
                case kVK_Delete where modifiers == .command:
                    guard text == nil else { return event }
                    return self.handle?(.deleteRecordings) == true ? nil : event
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
