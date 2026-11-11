import SwiftUI
import LocalScribeCore

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
            Button(L10n.text("Показать аудио в Finder"), action: showAudio)
                .help(L10n.text("Показать исходный аудиофайл записи в Finder"))
                .accessibilityIdentifier("recording.showAudio")
            Button(L10n.text("Обработать заново"), action: repeatAnalysis)
                .help(L10n.text("Заново распознать речь, определить участников и создать итоги"))
                .disabled(!canRepeatAnalysis)
                .accessibilityIdentifier("recording.repeatAnalysis")
            Menu(L10n.text("Пересоздать итоги")) {
                Button(L10n.text("Русский")) { recreateSummary("ru") }.help(L10n.text("Создать итоги на русском языке"))
                Button("English") { recreateSummary("en") }.help(L10n.text("Создать итоги на английском языке"))
            }
            .disabled(!canRecreateSummary)
            .help(L10n.text("Создать новые итоги по готовой расшифровке на выбранном языке"))
            .accessibilityLabel(L10n.text("Пересоздать итоги"))
            .accessibilityIdentifier("recording.recreateSummary")
            Button(role: .destructive, action: deleteRecording) {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Удалить запись"))
            .accessibilityLabel(L10n.text("Удалить запись"))
            .accessibilityIdentifier("recording.delete")
            .disabled(!canDelete)
        }
        .controlSize(.small)
        .fixedSize()
    }
}
