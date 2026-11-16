import AppKit
import SwiftUI
import LocalScribeCore

/// Keeps the window controls and archive actions above the sidebar.
struct WorkspaceToolbar: NSViewRepresentable {
    var sidebarVisible: Bool
    var showSidebar: () -> Void
    var openSettings: (() -> Void)?

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.sidebarVisible = sidebarVisible
        view.showSidebar = showSidebar
        view.openSettings = openSettings
        view.updateToolbar()
    }

    final class AnchorView: NSView, NSToolbarDelegate, NSToolbarItemValidation {
        private static let settings = NSToolbarItem.Identifier("workspace.settings")
        private static let expandedItems: [NSToolbarItem.Identifier] =
            [.flexibleSpace, settings, .toggleSidebar, .sidebarTrackingSeparator]
        private let toolbar = NSToolbar(identifier: "LocalScribe.workspace")
        private var revealAccessory: NSTitlebarAccessoryViewController?
        var sidebarVisible = true
        var showSidebar: (() -> Void)?
        var openSettings: (() -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window, window !== newWindow { removeRevealAccessory(from: window) }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateToolbar()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func updateToolbar() {
            // Install after the split view joins the window so AppKit can track its divider.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window else { return }
                if window.toolbar !== toolbar {
                    toolbar.delegate = self
                    toolbar.displayMode = .iconOnly
                    toolbar.allowsDisplayModeCustomization = false
                    window.styleMask.insert(.fullSizeContentView)
                    window.titleVisibility = .hidden
                    window.titlebarAppearsTransparent = true
                    window.titlebarSeparatorStyle = .none
                    window.toolbar = toolbar
                }
                let items = sidebarVisible ? Self.expandedItems : []
                if toolbar.itemIdentifiers != items { toolbar.itemIdentifiers = items }
                if sidebarVisible {
                    removeRevealAccessory(from: window)
                } else if revealAccessory == nil {
                    installRevealAccessory(in: window)
                }
                toolbar.items.first { $0.itemIdentifier == Self.settings }?.isEnabled = openSettings != nil
            }
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            sidebarVisible ? Self.expandedItems : []
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            Self.expandedItems
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            guard identifier == Self.settings else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = L10n.text("Настройки")
            item.toolTip = L10n.text("Открыть настройки")
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: item.label)
            item.isBordered = true
            item.target = self
            item.action = #selector(showSettings)
            return item
        }

        func validateToolbarItem(_ item: NSToolbarItem) -> Bool { openSettings != nil }

        private func installRevealAccessory(in window: NSWindow) {
            // The toolbar's bezel can intercept edge clicks on the collapsed toggle.
            // In the title bar accessory the button owns the entire visible circle.
            let title = L10n.text("Показать боковую панель")
            let button = NSButton()
            button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
            button.imagePosition = .imageOnly
            button.bezelStyle = .glass
            button.borderShape = .circle
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.setAccessibilityIdentifier("workspace.revealSidebar")
            button.target = self
            button.action = #selector(revealSidebar)

            let size: CGFloat = 36
            let padding: CGFloat = 8
            button.frame = CGRect(x: padding, y: padding, width: size, height: size)
            let content = NSView(frame: CGRect(x: 0, y: 0, width: size + 2 * padding, height: size + 2 * padding))
            content.addSubview(button)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = content
            accessory.layoutAttribute = .left
            window.addTitlebarAccessoryViewController(accessory)
            revealAccessory = accessory
        }

        private func removeRevealAccessory(from window: NSWindow) {
            if let revealAccessory, let index = window.titlebarAccessoryViewControllers.firstIndex(of: revealAccessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            revealAccessory = nil
        }

        @objc private func revealSidebar() { showSidebar?() }

        @objc private func showSettings() { openSettings?() }
    }
}
