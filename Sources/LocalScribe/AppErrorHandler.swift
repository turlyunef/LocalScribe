import AppKit
import SwiftUI
import LocalScribeCore

/// The full display message is transient. Only the typed snapshot is exported.
struct AppErrorReport {
    let message: String
    let snapshot: DiagnosticReport?
    var clipboardText: String? { snapshot?.clipboardText }
}

/// One presentation path for errors from the archive, editor, models and worker.
@MainActor final class AppErrorHandler: NSObject, NSWindowDelegate {
    private(set) var reports: [AppErrorReport] = []
    var messages: [String] { reports.map(\.message) }
    private(set) var window: NSPanel?
    private var presenting = false
    private let pasteboard: NSPasteboard
    private let environment: DiagnosticEnvironment
    private let session = UUID()
    private var recentEvents: [DiagnosticEvent] = []
    private(set) var journal: DiagnosticsJournal

    init(pasteboard: NSPasteboard = .general, hardware: ModelHardware? = nil) {
        self.pasteboard = pasteboard
        self.environment = DiagnosticEnvironment(hardware: hardware)
        journal = DiagnosticsJournal(root: nil)
        super.init()
    }

    func startJournal(at root: URL?) {
        journal = DiagnosticsJournal(root: root)
        note(.appStarted)
    }

    func note(_ kind: DiagnosticEvent.Kind, operation: DiagnosticOperation? = nil,
              job: DiagnosticJob? = nil, worker: DiagnosticWorkerExit? = nil) {
        let event = DiagnosticEvent(time: Date(), session: session, kind: kind,
                                    environment: kind == .appStarted ? environment : nil, operation: operation, job: job, worker: worker)
        remember(event)
        journal.append(event: event)
    }

    func report(_ error: Error) {
        report(error, operation: .application)
    }

    func report(_ error: Error, operation: DiagnosticOperation, job: DiagnosticJob? = nil,
                failure fallback: DiagnosticFailure? = nil, message: String? = nil, show: Bool = true) {
        guard !(error is CancellationError) else { return }
        let worker = error as? WorkerFailureError
        let classified = error as? ClassifiedDiagnosticError
        var failure = worker?.diagnostic ?? classified?.diagnostic ?? fallback
            ?? DiagnosticFailure(.operationFailed, phase: job?.phase, error: error)
        if failure.phase == nil { failure.phase = job?.phase }
        report(message: message ?? error.localizedDescription, operation: operation, job: job,
               failure: failure, worker: worker?.exit, show: show)
    }

    func report(message: String?, operation: DiagnosticOperation = .application, job: DiagnosticJob? = nil,
                failure: DiagnosticFailure = DiagnosticFailure(.operationFailed), worker: DiagnosticWorkerExit? = nil,
                show: Bool = true) {
        guard let message, !message.isEmpty else { return }
        let now = Date()
        let snapshot = DiagnosticReport(schemaVersion: 1, id: UUID(), time: now, environment: environment,
                                        operation: operation, failure: failure, job: job, worker: worker,
                                        events: Array(recentEvents.suffix(16)))
        let event = DiagnosticEvent(time: now, session: session, kind: .error, operation: operation, job: job, failure: failure, worker: worker)
        remember(event)
        journal.append(event: event, report: snapshot)
        if show { present(AppErrorReport(message: L10n.message(message), snapshot: snapshot)) }
    }

    func presentStored(_ reference: DiagnosticJobReference?, message: String) async {
        let history = await journal.snapshot()
        guard let reference, let snapshot = history.reports.last(where: { $0.job?.reference == reference }) else {
            presentMessage(message)
            return
        }
        present(AppErrorReport(message: L10n.message(message), snapshot: snapshot))
    }

    private func presentMessage(_ message: String) {
        present(AppErrorReport(message: L10n.message(message), snapshot: nil))
    }

    private func remember(_ event: DiagnosticEvent) {
        recentEvents.append(event)
        if recentEvents.count > 16 { recentEvents.removeFirst() }
    }

    private func present(_ report: AppErrorReport) {
        if reports.count >= 50 { reports.remove(at: 1) }
        reports.append(report)
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

    @discardableResult
    func copyCurrent() -> String? {
        guard let snapshot = reports.first?.snapshot else { return nil }
        return copy(snapshot)
    }

    @discardableResult
    func copy(_ snapshot: DiagnosticReport) -> String? {
        let text = snapshot.clipboardText
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return nil }
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
                if report.snapshot != nil {
                    Button {
                        guard copy() != nil else { return }
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    } label: {
                        Label(copied ? L10n.text("Скопировано") : L10n.text("Копировать ошибку"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("error.copy")
                    .help(L10n.text("Скопировать технический отчёт без содержимого файлов"))
                }
                Button(count > 1 ? L10n.text("Далее") : L10n.text("Закрыть"), action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("error.dismiss")
                    .help(L10n.text("Закрыть сообщение об ошибке"))
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand(perform: dismiss)
    }
}
