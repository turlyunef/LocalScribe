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
@main enum LocalScribeMain {
    @MainActor static func main() {
        let defaults = UserDefaults.standard
        let language = ApplicationLanguage.selection(in: defaults)
        L10n.configure(language)
        if language != .system {
            var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["AppleLanguages"] = [language.rawValue]
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        LocalScribeApp.main()
    }
}

struct LocalScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model).frame(minWidth: 850, minHeight: 560)
                .environment(\.locale, L10n.locale)
                .onAppear { delegate.model = model; model.errorHandler.startPresenting() }
        }.defaultSize(width: 1100, height: 740)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("Настройки…")) { model.settingsWindow.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("О LocalScribe")) {
                    delegate.aboutPanel.show(options: [
                        .applicationVersion: AppInfo.version,
                        .credits: NSAttributedString(string: L10n.text("Локальная запись, расшифровка и подведение итогов встреч на вашем Mac."))
                    ])
                }
            }
        }
        MenuBarExtra("LocalScribe", systemImage: model.recordingID == nil ? "waveform" : "record.circle.fill") {
            if model.recordingID != nil {
                RecordingStatusText(indicators: model.indicators, finalizing: model.finalizingRecording, prefix: L10n.text("Идёт запись"))
                CaptureStatusNotices(indicators: model.indicators, enableFallback: model.enableFallbackMicrophone)
                Button(L10n.text("Остановить и сохранить")) { Task { await model.stopRecording() } }.disabled(model.finalizingRecording).help(L10n.text("Остановить запись и сохранить аудио"))
            } else {
                Text(L10n.text("LocalScribe · локальный архив"))
                Button(L10n.text("Начать запись")) {
                    guard model.canStartRecording else { return }
                    delegate.model = model
                    model.errorHandler.startPresenting()
                    model.requestRecording(groupID: model.defaultGroup.id)
                }
                .disabled(!model.canStartRecording)
            }
            Button(L10n.text("Открыть окно")) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain && $0 !== model.settingsWindow.window }?.makeKeyAndOrderFront(nil)
            }.help(L10n.text("Показать главное окно LocalScribe"))
            Button(L10n.text("Закрыть")) {
                delegate.model = model
                NSApp.terminate(nil)
            }
        }
    }
}
