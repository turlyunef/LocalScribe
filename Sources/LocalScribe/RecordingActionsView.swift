import SwiftUI
import LocalScribeCore

struct RecordingActionsView: View {
    var canEdit: Bool
    var canRepeatAnalysis: Bool
    var canRecreateSummary: Bool
    var canDelete: Bool
    var showAudio: () -> Void
    var liveCaptionLanguageMenu: LiveCaptionLanguageMenu? = nil
    var liveCaptionControl: LiveCaptionControl? = nil
    var editResult: () -> Void
    var repeatAnalysis: () -> Void
    var recreateSummary: (String) -> Void
    var deleteRecording: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            actions(spacing: 8).controlSize(.small).labelStyle(.titleOnly)
            actions(spacing: 4).controlSize(.mini).labelStyle(.titleOnly)
            actions(spacing: 4).controlSize(.small).labelStyle(.iconOnly)
        }
    }

    private func actions(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            fileActions
            analysisActions
        }
        .fixedSize()
    }

    private var fileActions: some View {
        Group {
            Button(L10n.text("Показать аудио в Finder"), systemImage: "folder", action: showAudio)
                .help(L10n.text("Показать исходный аудиофайл записи в Finder"))
                .accessibilityIdentifier("recording.showAudio")
            liveCaptionLanguageMenu
            liveCaptionControl
            Button(L10n.text("Редактировать"), systemImage: "pencil", action: editResult)
                .disabled(!canEdit)
                .help(L10n.text("Изменить текст расшифровки и итогов"))
                .accessibilityIdentifier("result.edit")
        }
    }

    private var analysisActions: some View {
        Group {
            Button(L10n.text("Обработать заново"), systemImage: "arrow.clockwise", action: repeatAnalysis)
                .help(L10n.text("Заново распознать речь, определить участников и создать итоги"))
                .disabled(!canRepeatAnalysis)
                .accessibilityIdentifier("recording.repeatAnalysis")
            Menu {
                Button(L10n.text("Русский")) { recreateSummary("ru") }.help(L10n.text("Создать итоги на русском языке"))
                Button("English") { recreateSummary("en") }.help(L10n.text("Создать итоги на английском языке"))
            } label: {
                Label(L10n.text("Пересоздать итоги"), systemImage: "text.page")
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
