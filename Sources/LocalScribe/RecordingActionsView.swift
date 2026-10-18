import SwiftUI

struct RecordingActionsView: View {
    var canRepeatAnalysis: Bool
    var canRecreateSummary: Bool
    var canDelete: Bool
    var showAudio: () -> Void
    var repeatAnalysis: () -> Void
    var recreateSummary: (String) -> Void
    var deleteRecording: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Показать аудио в Finder", action: showAudio)
                .accessibilityIdentifier("recording.showAudio")
            Button("Обработать заново", action: repeatAnalysis)
                .disabled(!canRepeatAnalysis)
                .accessibilityIdentifier("recording.repeatAnalysis")
            Menu("Пересоздать итоги") {
                Button("Русский") { recreateSummary("ru") }
                Button("English") { recreateSummary("en") }
            }
            .disabled(!canRecreateSummary)
            .accessibilityLabel("Пересоздать итоги")
            .accessibilityIdentifier("recording.recreateSummary")
            Button(role: .destructive, action: deleteRecording) {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Удалить запись")
            .accessibilityLabel("Удалить запись")
            .accessibilityIdentifier("recording.delete")
            .disabled(!canDelete)
        }
        .controlSize(.small)
        .fixedSize()
    }
}
