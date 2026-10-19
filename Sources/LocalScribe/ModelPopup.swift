import AppKit
import SwiftUI
import LocalScribeCore

struct ModelMenuOption {
    let id: String
    let title: String
    let reason: String?
    let recommended: Bool
    var enabled: Bool { reason == nil }

    init(profile: ModelProfile, hardware: ModelHardware, recommended: Bool) {
        id = profile.id
        reason = hardware.warning(for: profile)
        self.recommended = recommended && reason == nil
        let size = ByteCountFormatter.string(fromByteCount: profile.bytes, countStyle: .file)
        title = "\(profile.displayName) · \(size)" + (self.recommended ? " · Максимально рекомендуется" : "")
    }

    func menuItem(target: AnyObject?, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target; item.representedObject = id; item.isEnabled = enabled
        item.toolTip = reason ?? title
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: recommended ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) : NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: enabled ? NSColor.labelColor : NSColor.disabledControlTextColor
        ])
        item.setAccessibilityLabel(title)
        item.setAccessibilityHelp(reason ?? "Модель совместима с этим Mac")
        return item
    }
}

/// Native attributed menu titles preserve bold recommendations on macOS.
struct ModelPopup: NSViewRepresentable {
    let options: [ModelMenuOption]
    @Binding var selection: String
    var prompt = "Нет совместимой модели"
    var imports = false
    var onChoose: ((String) -> Void)?
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let view = NSPopUpButton(frame: .zero, pullsDown: imports)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.cell?.lineBreakMode = .byTruncatingTail
        return view
    }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let menu = NSMenu(); menu.autoenablesItems = false
        if imports || !options.contains(where: { $0.id == selection }) {
            let placeholder = NSMenuItem(title: prompt, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        }
        for option in options {
            menu.addItem(option.menuItem(target: context.coordinator, action: #selector(Coordinator.choose(_:))))
        }
        view.menu = menu
        view.isEnabled = isEnabled
        if !imports, let item = menu.items.first(where: { ($0.representedObject as? String) == selection }) {
            view.select(item)
            view.toolTip = item.toolTip
            view.setAccessibilityHelp(item.toolTip)
        } else {
            view.selectItem(at: 0)
            view.toolTip = prompt
        }
    }
    final class Coordinator: NSObject {
        var parent: ModelPopup
        init(_ parent: ModelPopup) { self.parent = parent }
        @objc func choose(_ sender: NSMenuItem) {
            guard sender.isEnabled, let id = sender.representedObject as? String,
                  parent.isEnabled, parent.options.contains(where: { $0.id == id && $0.enabled }) else { return }
            if parent.imports { parent.onChoose?(id) }
            else { parent.selection = id }
        }
    }
}
