import SwiftUI
import LocalScribeCore

struct AnonymizationRestorationView: View {
    @ObservedObject var editor: AnonymizationCardEditor
    let cardID: String
    let scrollSync: AnonymizationScrollSync

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
        }
    }

    private func panel(_ content: AnonymizationPanelContent, scrollSync: AnonymizationScrollSync,
                       side: AnonymizationScrollSync.Side) -> some View {
        AnonymizationTextEditor(value: AnonymizationTextEditor.Value(content), editable: false, jump: nil,
                                scrollSync: scrollSync, scrollSide: side, onEdit: { _ in })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
