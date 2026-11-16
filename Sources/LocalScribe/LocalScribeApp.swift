import SwiftUI
import AppKit
import LocalScribeCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    let aboutPanel = AboutPanelPresenter()
    let keyboardShortcuts = KeyboardShortcutsPanel()
    var shutdownTimeout: Duration = .seconds(15)
    private var cleanup: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var reply: ((Bool) -> Void)?
    private var timedOut = false
    private(set) var shutdownFinished = false

    @discardableResult
    func requestMenuRecording(using model: AppModel) -> Task<Void, Never>? {
        guard model.canStartRecording else { return nil }
        self.model = model
        model.errorHandler.startPresenting()
        return model.requestRecording(groupID: model.defaultGroup.id)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // NSApp does not exist before App.main(), so the saved theme is applied
        // here, before any window is shown.
        ApplicationTheme.selection(in: .standard).apply()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }

    func requestTermination(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        guard !shutdownFinished, let model else { return .terminateNow }
        guard self.reply == nil else { return .terminateLater }
        self.reply = reply
        if cleanup == nil {
            cleanup = Task { [weak self] in
                await model.shutdown()
                guard let self else { return }
                shutdownFinished = true
                finishTermination(allow: true)
            }
        }
        timeout = Task { [weak self, shutdownTimeout] in
            do { try await Task.sleep(for: shutdownTimeout) } catch { return }
            guard let self else { return }
            if timedOut {
                model.supervisor.terminateNow()
                finishTermination(allow: true)
            } else {
                timedOut = true
                finishTermination(allow: false)
                model.errorHandler.startPresenting()
                model.errorHandler.report(message: L10n.text("Не удалось вовремя завершить сохранение. Повторите выход, чтобы завершить приложение при следующем таймауте."))
            }
        }
        return .terminateLater
    }

    private func finishTermination(allow: Bool) {
        timeout?.cancel()
        timeout = nil
        let reply = self.reply
        self.reply = nil
        reply?(allow)
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
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "workspace") {
            ContentView(model: model).frame(minWidth: 850, minHeight: 560)
                .environment(\.locale, L10n.locale)
                .onAppear { delegate.model = model; model.errorHandler.startPresenting() }
        }.defaultSize(width: 1100, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                // The workspace handles Command-N as New Recording.
                Button(L10n.text("Новое окно")) { openWindow(id: "workspace") }
            }
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
            CommandGroup(after: .help) {
                Button(L10n.text("Горячие клавиши")) { delegate.keyboardShortcuts.show() }
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
                    delegate.requestMenuRecording(using: model)
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
