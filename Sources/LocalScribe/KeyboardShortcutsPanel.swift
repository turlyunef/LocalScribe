import AppKit
import SwiftUI
import LocalScribeCore

@MainActor final class KeyboardShortcutsPanel {
    private lazy var panel: NSPanel = {
        let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("Горячие клавиши")
        window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: KeyboardShortcutsView { [weak window] in window?.close() })
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
        return window
    }()

    func show() { panel.makeKeyAndOrderFront(nil) }
}

private struct KeyboardShortcutsView: View {
    let close: () -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            ForEach(WorkspaceCommand.allCases, id: \.self) { command in
                row(command.title, command.shortcutLabel)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            row(L10n.text("Поиск по названиям"), "⌘F")
            row(L10n.text("Предыдущий или следующий элемент архива"), "↑ / ↓")
            row(L10n.text("Запросить удаление выбранных элементов"), "⌘⌫")
            row(L10n.text("Закрыть карточку или отменить действие"), "Esc")
            row(L10n.text("Сохранить правки результата"), "⌘S")
            row(L10n.text("Открыть настройки"), "⌘,")
        }
        .padding(24)
        .onExitCommand(perform: close)
    }

    private func row(_ title: String, _ shortcut: String) -> some View {
        GridRow {
            Text(title)
            Text(shortcut).monospaced().foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
