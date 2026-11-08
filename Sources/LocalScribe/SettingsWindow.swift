import AppKit
import SwiftUI
import LocalScribeCore

@MainActor final class SettingsDraft: ObservableObject {
    @Published var backgroundRecognition: Bool
    @Published var automaticSummaries: Bool
    @Published var modelIDs: [ModelRole: String] = [:]

    init(model: AppModel) {
        backgroundRecognition = model.backgroundRecognition
        automaticSummaries = model.automaticSummaries
    }

    func changedModels(in library: ModelLibrary) -> [ModelRole: String] {
        modelIDs.filter { library.selectedByRole[$0.key.rawValue] != $0.value }
    }

    func hasChanges(from model: AppModel) -> Bool {
        backgroundRecognition != model.backgroundRecognition || automaticSummaries != model.automaticSummaries
            || !changedModels(in: model.modelLibrary).isEmpty
    }
}

@MainActor final class SettingsWindow: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private let defaults: UserDefaults
    private var draft: SettingsDraft?
    private(set) var window: NSWindow?

    init(model: AppModel, defaults: UserDefaults) {
        self.model = model
        self.defaults = defaults
    }

    func show(tab: SettingsTab? = nil) {
        guard let model else { return }
        if let tab { model.settingsTab = tab }
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let draft = SettingsDraft(model: model)
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false, screen: screen)
        window.title = "Настройки"
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            ModelSettings(model: model, draft: draft)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Отмена") { [weak self] in self?.window?.close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.cancel")
                Button("ОК") { [weak self] in self?.saveAndClose() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.ok")
            }
            .padding(12)
        })
        hosting.sizingOptions = []
        window.contentView = hosting

        let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)).insetBy(dx: 24, dy: 24)
        let available = window.contentRect(forFrameRect: visible).size
        let minimum = NSSize(width: min(480, available.width), height: min(320, available.height))
        window.contentMinSize = minimum
        let saved = NSSizeFromString(defaults.string(forKey: "settingsWindowSize") ?? "")
        let size = NSSize(
            width: min(max(saved.width > 0 ? saved.width : 760, minimum.width), available.width),
            height: min(max(saved.height > 0 ? saved.height : 700, minimum.height), available.height)
        )
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        window.setFrame(NSRect(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2,
                               width: frame.width, height: frame.height), display: false)
        self.draft = draft
        self.window = window
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
    }

    private func saveAndClose() {
        guard let model, let draft else { return }
        do {
            try model.applySettings(draft)
            window?.close()
        } catch { model.errorHandler.report(error) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, let draft, draft.hasChanges(from: model) else { return true }
        guard sender.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Сохранить изменения настроек?"
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Не сохранять")
        alert.addButton(withTitle: "Продолжить редактирование").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            if response == .alertFirstButtonReturn { self?.saveAndClose() }
            if response == .alertSecondButtonReturn { sender?.close() }
        }
        return false
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, window.isVisible, !window.isMiniaturized else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        defaults.set(NSStringFromSize(size), forKey: "settingsWindowSize")
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        draft = nil
    }
}
