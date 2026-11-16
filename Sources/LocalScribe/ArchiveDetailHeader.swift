import SwiftUI

struct ArchiveDetailHeader<Title: View, Actions: View, Result: View, ResultActions: View>: View {
    @ViewBuilder let title: () -> Title
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let result: () -> Result
    @ViewBuilder let resultActions: () -> ResultActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title()
            // Small buttons need 20 points. The native result picker and icon buttons need 24.
            actions().frame(maxWidth: .infinity, minHeight: 20, alignment: .trailing)
            HStack(spacing: 8) {
                result().lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 4, content: resultActions)
                    .fixedSize()
            }
            .frame(minHeight: ArchiveActionIcon.height)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ArchiveResultMenu<Items: View>: View {
    let icon: String
    let title: String
    let help: String
    let identifier: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) {
            ArchiveActionIcon(icon: icon)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .frame(width: ArchiveActionIcon.width, height: ArchiveActionIcon.height)
    }
}
