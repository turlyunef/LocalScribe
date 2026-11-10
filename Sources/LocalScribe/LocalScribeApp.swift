import SwiftUI
import AppKit
import LocalScribeCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    let aboutPanel = AboutPanelPresenter()
    private var quitting = false
    private var shutdownFinished = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shutdownFinished, let model else { return .terminateNow }
        if !quitting {
            quitting = true
            // Finish asynchronous cleanup, then issue a fresh termination request.
            DispatchQueue.main.async { Task { await model.shutdown(); self.shutdownFinished = true; sender.terminate(nil) } }
        }
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { model?.supervisor.terminateNow() }
}
@main struct LocalScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model).frame(minWidth: 850, minHeight: 560)
                .onAppear { delegate.model = model; model.errorHandler.startPresenting() }
        }.defaultSize(width: 1100, height: 740)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { model.settingsWindow.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button("О LocalScribe") {
                    delegate.aboutPanel.show(options: [
                        .applicationVersion: AppInfo.version,
                        .credits: NSAttributedString(string: "Локальная запись, расшифровка и подведение итогов встреч на вашем Mac.")
                    ])
                }
            }
        }
        MenuBarExtra("LocalScribe", systemImage: model.recordingID == nil ? "waveform" : "record.circle.fill") {
            if model.recordingID != nil {
                RecordingStatusText(indicators: model.indicators, finalizing: model.finalizingRecording, prefix: "Идёт запись")
                Button("Остановить и сохранить") { Task { await model.stopRecording() } }.disabled(model.finalizingRecording).help("Остановить запись и сохранить аудио")
            } else {
                Text("LocalScribe · локальный архив")
                Button("Начать запись") {
                    guard model.canStartRecording else { return }
                    let destination = model.defaultGroup.id
                    delegate.model = model
                    model.errorHandler.startPresenting()
                    Task { await model.startRecording(groupID: destination) }
                }
                .disabled(!model.canStartRecording)
            }
            Button("Открыть окно") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain && $0 !== model.settingsWindow.window }?.makeKeyAndOrderFront(nil)
            }.help("Показать главное окно LocalScribe")
            Button("Закрыть") {
                delegate.model = model
                NSApp.terminate(nil)
            }
        }
    }
}
