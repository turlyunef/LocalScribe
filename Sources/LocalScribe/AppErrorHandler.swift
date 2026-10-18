import AppKit
import SwiftUI

/// One presentation path for errors from the archive, editor, models and worker.
@MainActor final class AppErrorHandler: NSObject, NSWindowDelegate {
    private(set) var messages: [String] = []
    private(set) var window: NSPanel?
    private var presenting = false

    func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        report(message: error.localizedDescription)
    }

    func report(message: String?) {
        guard let message, !message.isEmpty else { return }
        messages.append(message)
        presentIfNeeded()
    }

    // Startup errors wait until the app has a window. Later errors also work
    // while Settings or the result editor is open.
    func startPresenting() {
        presenting = true
        presentIfNeeded()
    }

    func dismissCurrent() {
        guard !messages.isEmpty else { return }
        messages.removeFirst()
        if messages.isEmpty {
            window?.close()
            window = nil
        } else {
            presentIfNeeded()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissCurrent()
        return false
    }

    private func presentIfNeeded() {
        guard presenting, let message = messages.first else { return }
        let panel: NSPanel
        if let window {
            panel = window
        } else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Ошибка — LocalScribe"
            panel.identifier = NSUserInterfaceItemIdentifier("app.error")
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.worksWhenModal = true
            panel.level = .modalPanel
            panel.minSize = NSSize(width: 420, height: 240)
            panel.delegate = self
            panel.center()
            window = panel
        }
        panel.contentView = NSHostingView(rootView: AppErrorView(message: message, count: messages.count) { [weak self] in
            self?.dismissCurrent()
        })
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct AppErrorView: View {
    let message: String
    let count: Int
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Не удалось выполнить действие", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            ScrollView {
                Text(message).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("error.message")
            }
            HStack {
                if count > 1 { Text("Ещё сообщений: \(count - 1)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(count > 1 ? "Далее" : "Закрыть", action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("error.dismiss")
                    .help("Закрыть сообщение об ошибке")
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand(perform: dismiss)
    }
}
