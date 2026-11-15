import SwiftUI

struct ArchiveDetailHeader<Title: View, Actions: View, Result: View>: View {
    @ViewBuilder let title: () -> Title
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let result: () -> Result

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title()
            actions().frame(maxWidth: .infinity, minHeight: 32, alignment: .trailing)
            result().frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
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
