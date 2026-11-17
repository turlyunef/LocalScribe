import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LocalScribeCore

@MainActor final class DiagnosticsWindow {
    private let handler: AppErrorHandler
    private var window: NSPanel?

    init(handler: AppErrorHandler) {
        self.handler = handler
    }

    func show() {
        if let window {
            if !window.isVisible { window.contentView = NSHostingView(rootView: DiagnosticsView(handler: handler)) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 690, height: 465),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = L10n.text("Диагностика LocalScribe")
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: DiagnosticsView(handler: handler))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}

private struct DiagnosticsExport: Encodable {
    let schemaVersion = 1
    let history: DiagnosticsJournal.History
    let nativeCrash: NativeCrashAttachment?
}

private struct DiagnosticsView: View {
    let handler: AppErrorHandler
    @State private var history = DiagnosticsJournal.History()
    @State private var selectedID: UUID?
    @State private var attachment: NativeCrashAttachment?
    @State private var feedback: String?
    @State private var loadingAttachment = false
    @State private var exporting = false

    private var selection: DiagnosticReport? { history.reports.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if history.reports.isEmpty {
                ContentUnavailableView(L10n.text("Сохранённых ошибок нет"), systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(history.reports.reversed()) { report in
                        VStack(alignment: .leading) {
                            Text(report.failure.code.rawValue).font(.body.monospaced())
                            Text(report.time.formatted() + " · " + report.operation.rawValue)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(report.id)
                    }
                }
            }
            if let attachment {
                HStack {
                    Text(L10n.text("Приложен отчёт macOS: %1$@", attachment.executable.rawValue))
                    Button(L10n.text("Убрать вложение")) { self.attachment = nil }
                }
            }
            if let feedback { Text(feedback).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button(L10n.text("Обновить")) { Task { await refresh() } }
                Button(L10n.text("Копировать ошибку")) {
                    if let selection, handler.copy(selection) != nil { feedback = L10n.text("Скопировано") }
                }
                .disabled(selection == nil)
                Spacer()
                Button(L10n.text("Приложить отчёт macOS…")) { Task { await attach() } }
                    .disabled(loadingAttachment)
                Button(L10n.text("Экспорт событий…")) { Task { await export() } }
                    .disabled(exporting || loadingAttachment)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 660, minHeight: 340)
        .task { await refresh() }
    }

    private func refresh() async {
        history = await handler.journal.snapshot()
        if selection == nil { selectedID = history.reports.last?.id }
    }

    private func attach() async {
        loadingAttachment = true
        defer { loadingAttachment = false }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ips") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            attachment = try await Task.detached { try NativeCrashAttachment.read(url) }.value
            feedback = nil
        } catch {
            feedback = L10n.text("Выберите отчёт о сбое LocalScribe в формате .ips.")
        }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LocalScribe-diagnostics.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let export = DiagnosticsExport(history: await handler.journal.snapshot(), nativeCrash: attachment)
        do {
            try await Task.detached {
                let access = destination.startAccessingSecurityScopedResource()
                defer { if access { destination.stopAccessingSecurityScopedResource() } }
                try DiagnosticJSON.data(export).write(to: destination, options: .atomic)
            }.value
            feedback = L10n.text("Диагностика сохранена.")
        } catch {
            feedback = L10n.text("Не удалось сохранить диагностику.")
        }
    }
}
