import AppKit
import SwiftUI
import LocalScribeCore

/// Diagnostics snapshot taken when an error is reported; the clipboard form
/// must give the full picture needed to fix the problem offline.
struct AppErrorReport {
    let message: String
    let appVersion: String
    let build: String
    let osVersion: String
    let timestamp: Date
    /// Neutral key-value facts supplied by the reporting site (stage, worker
    /// termination, protocol state); never archive or conversation content.
    let context: [(String, String)]
    /// GUI call stack leading to the report, app frames only.
    let stack: [String]

    init(message: String,
         appVersion: String = AppInfo.version,
         build: String = AppInfo.build,
         osVersion: String = AppErrorReport.currentOSVersion,
         timestamp: Date = Date(),
         context: [(String, String)] = [],
         stack: [String] = AppErrorReport.callStack()) {
        self.message = L10n.message(message)
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.timestamp = timestamp
        self.context = context
        self.stack = stack
    }

    static var currentOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static func callStack(limit: Int = 24) -> [String] {
        Thread.callStackSymbols
            .filter { $0.contains("LocalScribe") && !$0.contains("AppErrorHandler") }
            .prefix(limit)
            .map { String($0) }
    }

    var clipboardText: String {
        var lines = [
            L10n.text("LocalScribe %1$@ (сборка %2$@)", appVersion, build),
            osVersion,
            L10n.text("Время ошибки: %1$@", Self.timestampFormatter.string(from: timestamp)),
            "",
            L10n.text("Ошибка:"),
            message
        ]
        if !context.isEmpty {
            lines.append("")
            lines.append(L10n.text("Технические сведения:"))
            lines += context.map { "  \($0.0): \($0.1)" }
        }
        if !stack.isEmpty {
            lines.append("")
            lines.append(L10n.text("Стек вызовов (GUI):"))
            lines += stack.map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    private static let timestampFormatter = ISO8601DateFormatter()
}

/// One presentation path for errors from the archive, editor, models and worker.
@MainActor final class AppErrorHandler: NSObject, NSWindowDelegate {
    private(set) var reports: [AppErrorReport] = []
    var messages: [String] { reports.map(\.message) }
    private(set) var window: NSPanel?
    private var presenting = false
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        super.init()
    }

    func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        if let failure = error as? WorkerFailureError {
            report(message: failure.userMessage, context: failure.context)
        } else {
            report(message: error.localizedDescription)
        }
    }

    func report(message: String?, context: [(String, String)] = []) {
        guard let message, !message.isEmpty else { return }
        reports.append(AppErrorReport(message: message, context: context))
        presentIfNeeded()
    }

    // Startup errors wait until the app has a window. Later errors also work
    // while Settings or the result editor is open.
    func startPresenting() {
        presenting = true
        presentIfNeeded()
    }

    func dismissCurrent() {
        guard !reports.isEmpty else { return }
        reports.removeFirst()
        if reports.isEmpty {
            window?.close()
            window = nil
        } else {
            presentIfNeeded()
        }
    }

    /// Copies the shown error with the full diagnostics (message, technical
    /// context, GUI stack, app version, build, OS, report time). The window
    /// and the message queue stay as is.
    @discardableResult
    func copyCurrent() -> String? {
        guard let report = reports.first else { return nil }
        let text = report.clipboardText
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return text
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissCurrent()
        return false
    }

    private func presentIfNeeded() {
        guard presenting, let report = reports.first else { return }
        let panel: NSPanel
        if let window {
            panel = window
        } else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = L10n.text("Ошибка — LocalScribe")
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
        panel.contentView = NSHostingView(rootView: AppErrorView(report: report, count: reports.count,
                                                                 copy: { [weak self] in self?.copyCurrent() }) { [weak self] in
            self?.dismissCurrent()
        })
        panel.makeKeyAndOrderFront(nil)
    }
}

struct AppErrorView: View {
    let report: AppErrorReport
    let count: Int
    let copy: () -> String?
    let dismiss: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text("Не удалось выполнить действие"), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            ScrollView {
                Text(report.message).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("error.message")
            }
            HStack {
                if count > 1 { Text(L10n.text("Ещё сообщений: %1$@", String(count - 1))).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button {
                    guard copy() != nil else { return }
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? L10n.text("Скопировано") : L10n.text("Копировать ошибку"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("error.copy")
                .help(L10n.text("Скопировать сообщение об ошибке, технические сведения и версию приложения"))
                Button(count > 1 ? L10n.text("Далее") : L10n.text("Закрыть"), action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("error.dismiss")
                    .help(L10n.text("Закрыть сообщение об ошибке"))
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand(perform: dismiss)
    }
}
