import SwiftUI
import LocalScribeCore

struct RecordingActionsView: View {
    var canEdit: Bool
    var canRepeatAnalysis: Bool
    var canRecreateSummary: Bool
    var canDelete: Bool
    var showAudio: () -> Void
    var liveCaptionControl: LiveCaptionControl? = nil
    var editResult: () -> Void
    var repeatAnalysis: () -> Void
    var recreateSummary: (String) -> Void
    var deleteRecording: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                fileActions
                analysisActions
            }
            .controlSize(.small)
            .fixedSize()

            HStack(spacing: 4) {
                fileActions
                analysisActions
            }
            .controlSize(.mini)
            .fixedSize()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) { fileActions }
                HStack(spacing: 8) { analysisActions }
            }
            .controlSize(.small)
        }
    }

    private var fileActions: some View {
        Group {
            Button(L10n.text("Показать аудио в Finder"), action: showAudio)
                .help(L10n.text("Показать исходный аудиофайл записи в Finder"))
                .accessibilityIdentifier("recording.showAudio")
            liveCaptionControl
            Button(L10n.text("Редактировать"), action: editResult)
                .disabled(!canEdit)
                .help(L10n.text("Изменить текст расшифровки и итогов"))
                .accessibilityIdentifier("result.edit")
        }
    }

    private var analysisActions: some View {
        Group {
            Button(L10n.text("Обработать заново"), action: repeatAnalysis)
                .help(L10n.text("Заново распознать речь, определить участников и создать итоги"))
                .disabled(!canRepeatAnalysis)
                .accessibilityIdentifier("recording.repeatAnalysis")
            Menu(L10n.text("Пересоздать итоги")) {
                Button(L10n.text("Русский")) { recreateSummary("ru") }.help(L10n.text("Создать итоги на русском языке"))
                Button("English") { recreateSummary("en") }.help(L10n.text("Создать итоги на английском языке"))
            }
            .menuIndicator(.hidden)
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
    }
}
