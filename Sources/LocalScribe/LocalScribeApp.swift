import SwiftUI
import AppKit
import LocalScribeCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
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
                .onAppear { delegate.model = model }
        }.defaultSize(width: 1100, height: 740)
        Settings { ModelSettings(model: model).frame(width: 570, height: 470) }
        MenuBarExtra("LocalScribe", systemImage: model.recordingID == nil ? "waveform" : "record.circle.fill") {
            if model.recordingID != nil {
                Text(model.finalizingRecording ? "Сохраняем аудио…" : "Идёт запись · \(timecode(Int(model.elapsed*1000)))")
                Button("Остановить и сохранить") { Task { await model.stopRecording() } }.disabled(model.finalizingRecording)
            } else { Text("LocalScribe · локальный архив") }
            Button("Открыть окно") { NSApplication.shared.activate(ignoringOtherApps: true); NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil) }
        }
    }
}
