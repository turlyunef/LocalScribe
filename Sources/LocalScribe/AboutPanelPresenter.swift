import AppKit

@MainActor final class AboutPanelPresenter: NSObject {
    func show(options: [NSApplication.AboutPanelOptionKey: Any]) {
        let center = NotificationCenter.default
        center.removeObserver(self)
        let application = NSApplication.shared
        application.orderFrontStandardAboutPanel(options: options)
        guard let panel = application.keyWindow else { return }
        center.addObserver(self, selector: #selector(panelDidResignKey(_:)),
                           name: NSWindow.didResignKeyNotification, object: panel)
        center.addObserver(self, selector: #selector(panelWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: panel)
    }

    @objc private func panelDidResignKey(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        (notification.object as? NSWindow)?.close()
    }

    @objc private func panelWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }
}
