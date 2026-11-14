import SwiftUI
import LocalScribeCore

struct AnonymizationRestorationView: View {
    @ObservedObject var workspace: AnonymizationWorkspaceModel
    @ObservedObject private var editor: AnonymizationCardEditor
    let cardID: String
    let scrollSync: AnonymizationScrollSync

    init(workspace: AnonymizationWorkspaceModel, cardID: String, scrollSync: AnonymizationScrollSync) {
        self.workspace = workspace
        self.editor = workspace.cardEditor
        self.cardID = cardID
        self.scrollSync = scrollSync
    }

    private var panels: AnonymizationRestorationPanels? {
        editor.cardID == cardID ? editor.restorationPanels : nil
    }

    var body: some View {
        AnonymizationComparisonView(scrollSync: scrollSync) { sync in
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Текст для восстановления")).font(.headline)
                if let panels {
                    panel(panels.source, scrollSync: sync, side: .left)
                        .accessibilityIdentifier("texts.restoration.sourceEditor")
                } else {
                    Text(L10n.text("Импортируйте или вставьте обезличенный текст"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } right: { sync in
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Восстановленный текст")).font(.headline)
                if let panels {
                    panel(panels.result, scrollSync: sync, side: .right)
                        .accessibilityIdentifier("texts.restoration.resultEditor")
                }
            }
        } actions: {
            HStack(spacing: 8) {
                Button {
                    Task { await workspace.importRestoration(cardID) }
                } label: {
                    Label(L10n.text("Импортировать"), systemImage: "folder")
                }
                .accessibilityIdentifier("texts.restoration.import")
                Button {
                    Task { await workspace.pasteRestoration(cardID) }
                } label: {
                    Label(L10n.text("Вставить"), systemImage: "document.on.clipboard")
                }
                .accessibilityIdentifier("texts.restoration.paste")
                if workspace.restorationBusyCardID == cardID {
                    ProgressView().controlSize(.small)
                }
            }
            .disabled(!workspace.canStartRestoration(cardID))
        }
    }

    private func panel(_ content: AnonymizationPanelContent, scrollSync: AnonymizationScrollSync,
                       side: AnonymizationScrollSync.Side) -> some View {
        AnonymizationTextEditor(value: AnonymizationTextEditor.Value(content), editable: false, jump: nil,
                                scrollSync: scrollSync, scrollSide: side, onEdit: { _ in })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
