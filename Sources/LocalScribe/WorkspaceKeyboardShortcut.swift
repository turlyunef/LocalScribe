import SwiftUI
import AppKit
import Carbon.HIToolbox
import LocalScribeCore

enum WorkspaceCommand: CaseIterable {
    case newRecording, importFile, recordings, diagrams, anonymization, addGroup, revealSource, copyResult

    var title: String {
        switch self {
        case .newRecording: return L10n.text("Новая запись")
        case .importFile: return L10n.text("Импортировать")
        case .recordings: return WorkspaceMode.recordings.title
        case .diagrams: return WorkspaceMode.diagrams.title
        case .anonymization: return WorkspaceMode.anonymization.title
        case .addGroup: return L10n.text("Добавить группу")
        case .revealSource: return L10n.text("Показать исходник в Finder")
        case .copyResult: return L10n.text("Копировать результат")
        }
    }

    private var key: (code: Int, label: String) {
        switch self {
        case .newRecording, .addGroup: return (kVK_ANSI_N, "N")
        case .importFile: return (kVK_ANSI_I, "I")
        case .recordings: return (kVK_ANSI_1, "1")
        case .diagrams: return (kVK_ANSI_2, "2")
        case .anonymization: return (kVK_ANSI_3, "3")
        case .revealSource: return (kVK_ANSI_R, "R")
        case .copyResult: return (kVK_ANSI_C, "C")
        }
    }

    private var shifted: Bool { self == .addGroup || self == .copyResult }
    var shortcutLabel: String { (shifted ? "⇧⌘" : "⌘") + key.label }

    static func matching(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> Self? {
        guard modifiers == .command || modifiers == [.command, .shift] else { return nil }
        // Use physical keys so the same commands work with Russian and Latin layouts.
        return allCases.first { $0.key.code == keyCode && $0.shifted == modifiers.contains(.shift) }
    }
}

/// Window-level shortcuts that let sheets and text editors handle their own keys.
struct WorkspaceKeyboardShortcut: NSViewRepresentable {
    enum Action { case closeSelection, deleteSelection, selectAdjacent(down: Bool), command(WorkspaceCommand) }
    @Environment(\.isEnabled) private var isEnabled
    let handle: (Action) -> Bool

    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }
    func updateNSView(_ view: ShortcutView, context: Context) { view.handle = isEnabled ? handle : nil }
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
                    guard !event.isARepeat, !self.isHiddenOrHasHiddenAncestor, text?.hasMarkedText() != true,
                          let command = WorkspaceCommand.matching(keyCode: Int(event.keyCode), modifiers: modifiers)
                    else { return event }
                    return self.handle?(.command(command)) == true ? nil : event
                }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
