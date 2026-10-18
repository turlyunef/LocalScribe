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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button("Показать аудио в Finder", action: showAudio)
                .help("Показать исходный аудиофайл записи в Finder")
                .accessibilityIdentifier("recording.showAudio")
            Button("Обработать заново", action: repeatAnalysis)
                .help("Заново распознать речь, определить участников и создать итоги")
                .disabled(!canRepeatAnalysis)
                .accessibilityIdentifier("recording.repeatAnalysis")
            Menu("Пересоздать итоги") {
                Button("Русский") { recreateSummary("ru") }.help("Создать итоги на русском языке")
                Button("English") { recreateSummary("en") }.help("Создать итоги на английском языке")
            }
            .disabled(!canRecreateSummary)
            .help("Создать новые итоги по готовой расшифровке на выбранном языке")
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
